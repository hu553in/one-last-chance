// Package runtimebridge exposes the olcrtc mobile client through one gomobile lifecycle.
package runtimebridge

import (
	"errors"
	"fmt"
	"log" //nolint:depguard // olcRTC mobile and the native bridge share the standard log sink.
	"sync"
	"time"

	olcmobile "github.com/openlibrecommunity/olcrtc/mobile"
)

const (
	startTimeout         = 60 * time.Second
	runtimeWatchInterval = time.Second
	socksPort            = 21_080
)

// RuntimeObserver is notified when a fully started runtime fails asynchronously.
type RuntimeObserver interface {
	RuntimeFailed(message string)
}

// Runtime owns one olcrtc mobile session for a Packet Tunnel lifetime.
type Runtime struct {
	mu       sync.Mutex
	core     *olcmobile.Runtime
	observer RuntimeObserver
	stopped  bool
}

// NewRuntime creates an idle runtime and installs the single process log sink.
func NewRuntime(writer LogWriter, observer RuntimeObserver) *Runtime {
	installLogging(writer)
	return &Runtime{core: olcmobile.New(), observer: observer}
}

// Start connects the selected node and waits until its SOCKS listener is ready.
func (r *Runtime) Start(rawConfiguration string) error {
	cfg, err := decodeConfiguration(rawConfiguration)
	if err != nil {
		return err
	}
	if err = r.startCore(cfg); err != nil {
		return err
	}
	if err = r.core.WaitReady(int(startTimeout / time.Millisecond)); err != nil {
		r.Stop()
		return fmt.Errorf("selected node did not become ready: %w", err)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.stopped {
		return errors.New("runtime was stopped")
	}
	log.Printf("Node %q is ready on 127.0.0.1:%d.", safeName(cfg.Node.Name), socksPort)
	go r.watch()
	return nil
}

func (r *Runtime) startCore(cfg configuration) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.stopped {
		return errors.New("runtime is already stopped")
	}
	if state := r.core.State(); state != "idle" {
		return fmt.Errorf("runtime is already %s", state)
	}
	if err := configureCore(r.core, cfg); err != nil {
		return fmt.Errorf("configure mobile runtime: %w", err)
	}
	log.Printf(
		"Starting selected node %q (%s/%s) on 127.0.0.1:%d.",
		safeName(cfg.Node.Name), cfg.Node.Provider, cfg.Node.Transport, socksPort,
	)
	if err := r.core.Start(); err != nil {
		return fmt.Errorf("start mobile runtime: %w", err)
	}
	return nil
}

func configureCore(core *olcmobile.Runtime, cfg configuration) error {
	if err := core.SetProvider(cfg.Node.Provider); err != nil {
		return err
	}
	if err := core.SetTransport(cfg.Node.Transport); err != nil {
		return err
	}
	if err := core.SetRoom(cfg.Node.Room); err != nil {
		return err
	}
	if err := core.SetKey(cfg.Node.Key); err != nil {
		return err
	}
	if err := core.SetSocksListenHost("127.0.0.1"); err != nil {
		return err
	}
	if err := core.SetSocksPort(socksPort); err != nil {
		return err
	}
	if err := core.SetVP8Options(cfg.Node.VP8FPS, cfg.Node.VP8BatchSize); err != nil {
		return err
	}
	core.SetDeviceIDPath(cfg.DeviceIDPath)
	return nil
}

// Stop idempotently shuts down olcrtc using its bounded native shutdown.
func (r *Runtime) Stop() {
	r.mu.Lock()
	r.stopped = true
	r.mu.Unlock()
	if err := r.core.Stop(0); err != nil {
		log.Printf("Runtime shutdown failed: %v.", err)
		return
	}
	log.Printf("Runtime stopped.")
}

func (r *Runtime) watch() {
	ticker := time.NewTicker(runtimeWatchInterval)
	defer ticker.Stop()
	for range ticker.C {
		r.mu.Lock()
		if r.stopped {
			r.mu.Unlock()
			return
		}
		if r.core.IsRunning() {
			r.mu.Unlock()
			continue
		}
		r.stopped = true
		r.mu.Unlock()
		message := "olcrtc stopped unexpectedly"
		log.Printf("%s.", message)
		if r.observer != nil {
			r.observer.RuntimeFailed(message)
		}
		return
	}
}
