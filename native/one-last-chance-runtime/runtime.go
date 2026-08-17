// Package runtimebridge exposes the pinned olcrtc mobile client through one
// gomobile lifecycle.
package runtimebridge

import (
	"errors"
	"fmt"
	"log" //nolint:depguard // olcRTC mobile and the native bridge share the standard log sink.
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	olcmobile "github.com/openlibrecommunity/olcrtc/mobile"
)

const (
	startTimeout         = 60 * time.Second
	runtimeWatchInterval = time.Second
	socksPort            = 21_080
	runtimeStateIdle     = "idle"
	runtimeStateRunning  = "running"
	runtimeStateStarting = "starting"
	runtimeStateStopped  = "stopped"
	runtimeStateStopping = "stopping"
)

// RuntimeObserver is notified when a fully started runtime fails asynchronously.
type RuntimeObserver interface {
	RuntimeFailed(message string)
}

// Runtime owns the process-wide olcrtc mobile session.
type Runtime struct {
	mu         sync.Mutex
	observer   RuntimeObserver
	state      string
	generation uint64
}

// NewRuntime creates an idle runtime and installs the single process log sink.
func NewRuntime(writer LogWriter, observer RuntimeObserver) *Runtime {
	installLogging(writer)
	return &Runtime{observer: observer, state: runtimeStateIdle}
}

// Start connects the selected node and waits until its SOCKS listener is ready.
func (r *Runtime) Start(rawConfiguration string) error {
	cfg, err := decodeConfiguration(rawConfiguration)
	if err != nil {
		return err
	}
	deviceID, err := loadOrCreateDeviceID(cfg.DeviceIDPath)
	if err != nil {
		return err
	}
	r.mu.Lock()
	if r.state != runtimeStateIdle {
		r.mu.Unlock()
		return fmt.Errorf("runtime is already %s", r.state)
	}
	r.generation++
	generation := r.generation
	r.state = runtimeStateStarting
	r.mu.Unlock()

	selectedNode := cfg.Node
	if !r.isCurrent(generation) {
		return errors.New("runtime was stopped")
	}
	log.Printf(
		"Starting selected node %q (%s/%s) on 127.0.0.1:%d.",
		safeName(selectedNode.Name), selectedNode.Provider, selectedNode.Transport, socksPort,
	)
	olcmobile.SetVP8Options(selectedNode.VP8FPS, selectedNode.VP8BatchSize)
	err = olcmobile.StartWithTransport(
		selectedNode.Provider,
		selectedNode.Transport,
		selectedNode.Room,
		deviceID,
		selectedNode.Key,
		socksPort,
		"",
		"",
	)
	if err == nil && !r.isCurrent(generation) {
		err = errors.New("runtime was stopped")
	}
	if err == nil {
		err = olcmobile.WaitReady(int(startTimeout / time.Millisecond))
	}
	if err == nil && r.markReady(generation) {
		log.Printf("Node %q is ready on 127.0.0.1:%d.", safeName(selectedNode.Name), socksPort)
		go r.watch(generation)
		return nil
	}
	olcmobile.Stop()
	if err == nil {
		err = errors.New("runtime was stopped")
	}

	r.mu.Lock()
	if r.generation == generation {
		r.state = runtimeStateStopped
	}
	r.mu.Unlock()
	log.Printf("Node %q failed: %v.", safeName(selectedNode.Name), err)
	return fmt.Errorf("selected node did not become ready: %w", err)
}

// Stop idempotently shuts down olcrtc.
func (r *Runtime) Stop() {
	r.mu.Lock()
	if r.state == runtimeStateStopped || r.state == runtimeStateStopping {
		r.mu.Unlock()
		return
	}
	if r.state == runtimeStateIdle {
		r.generation++
		r.state = runtimeStateStopped
		r.mu.Unlock()
		log.Printf("Runtime stopped.")
		return
	}
	r.state = runtimeStateStopping
	r.generation++
	r.mu.Unlock()

	olcmobile.Stop()

	r.mu.Lock()
	r.state = runtimeStateStopped
	r.mu.Unlock()
	log.Printf("Runtime stopped.")
}

func (r *Runtime) markReady(generation uint64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.generation != generation {
		return false
	}
	r.state = runtimeStateRunning
	return true
}

func (r *Runtime) isCurrent(generation uint64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.generation == generation
}

func (r *Runtime) watch(generation uint64) {
	ticker := time.NewTicker(runtimeWatchInterval)
	defer ticker.Stop()
	for range ticker.C {
		if !r.isCurrent(generation) {
			return
		}
		if olcmobile.IsRunning() {
			continue
		}
		r.fail(generation, "olcrtc stopped unexpectedly")
		return
	}
}

func (r *Runtime) fail(generation uint64, message string) {
	r.mu.Lock()
	if r.generation != generation {
		r.mu.Unlock()
		return
	}
	r.state = runtimeStateStopped
	observer := r.observer
	r.mu.Unlock()
	log.Printf("%s.", message)
	if observer != nil {
		observer.RuntimeFailed(message)
	}
}

func loadOrCreateDeviceID(path string) (string, error) {
	data, readErr := os.ReadFile(path)
	if readErr == nil {
		if id := strings.TrimSpace(string(data)); id != "" {
			return id, nil
		}
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return "", fmt.Errorf("read device ID: %w", readErr)
	}

	deviceID, uuidErr := uuid.NewRandom()
	if uuidErr != nil {
		return "", fmt.Errorf("generate device ID: %w", uuidErr)
	}
	id := deviceID.String()
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return "", fmt.Errorf("create device ID directory: %w", err)
	}
	if err := os.WriteFile(path, []byte(id+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("write device ID: %w", err)
	}
	return id, nil
}
