//nolint:testpackage // These tests exercise unexported configuration and lifecycle boundaries.
package runtimebridge

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDecodeConfigurationAppliesDefaults(t *testing.T) {
	raw := `{
		"node":{
			"name":" node ",
			"provider":"jitsi",
			"transport":"vp8channel",
			"room":" https://meet.jit.si/example ",
			"key":"` + strings.Repeat("ab", 32) + `"
		},
		"deviceIDPath":"/tmp/device-id"
	}`

	cfg, err := decodeConfiguration(raw)
	if err != nil {
		t.Fatalf("decodeConfiguration() error = %v", err)
	}
	selectedNode := cfg.Node
	if selectedNode.Name != "node" || selectedNode.Room != "https://meet.jit.si/example" {
		t.Fatalf("configuration was not trimmed: %#v", selectedNode)
	}
	if selectedNode.VP8FPS != 30 || selectedNode.VP8BatchSize != 64 {
		t.Fatalf(
			"VP8 defaults = %d/%d, want 30/64",
			selectedNode.VP8FPS,
			selectedNode.VP8BatchSize,
		)
	}
}

func TestDecodeConfigurationRejectsInvalidInput(t *testing.T) {
	tests := map[string]string{
		"empty node":    `{"node":{},"deviceIDPath":"/tmp/id"}`,
		"unknown field": `{"node":{},"deviceIDPath":"/tmp/id","extra":true}`,
		"unsupported node": `{"node":{"name":"n","provider":"bad","transport":"vp8channel","room":"r","key":"` + strings.Repeat(
			"ab",
			32,
		) + `"},"deviceIDPath":"/tmp/id"}`,
		"unsupported transport": `{"node":{"name":"n","provider":"jitsi","transport":"unsupported","room":"r","key":"` + strings.Repeat(
			"ab",
			32,
		) + `"},"deviceIDPath":"/tmp/id"}`,
		"unsupported pairing": `{"node":{"name":"n","provider":"wbstream","transport":"datachannel","room":"r","key":"` + strings.Repeat(
			"ab",
			32,
		) + `"},"deviceIDPath":"/tmp/id"}`,
		"invalid key": `{"node":{"name":"n","provider":"jitsi","transport":"vp8channel","room":"r","key":"00"},"deviceIDPath":"/tmp/id"}`,
		"invalid vp8 fps": `{"node":{"name":"n","provider":"jitsi","transport":"vp8channel","room":"r","key":"` + strings.Repeat(
			"ab",
			32,
		) + `","vp8FPS":121},"deviceIDPath":"/tmp/id"}`,
		"invalid vp8 batch": `{"node":{"name":"n","provider":"jitsi","transport":"vp8channel","room":"r","key":"` + strings.Repeat(
			"ab",
			32,
		) + `","vp8BatchSize":65},"deviceIDPath":"/tmp/id"}`,
	}

	for name, raw := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeConfiguration(raw); err == nil {
				t.Fatal("decodeConfiguration() unexpectedly succeeded")
			}
		})
	}
}

func TestDeviceIDIsPersisted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "device-id")
	startWithInvalidRoom(t, path)
	first, err := os.ReadFile(path) // #nosec G304 -- The path belongs to t.TempDir().
	if err != nil {
		t.Fatalf("read generated device ID: %v", err)
	}
	startWithInvalidRoom(t, path)
	second, err := os.ReadFile(path) // #nosec G304 -- The path belongs to t.TempDir().
	if err != nil {
		t.Fatalf("read reused device ID: %v", err)
	}
	if strings.TrimSpace(string(first)) == "" || string(second) != string(first) {
		t.Fatalf("device IDs = %q and %q, want one persisted value", first, second)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("device ID permissions = %v, error = %v, want 0600", info, err)
	}
}

func TestExistingDeviceIDSurvivesUpgrade(t *testing.T) {
	path := filepath.Join(t.TempDir(), "device-id")
	const existing = "b629fc10-d9f5-4f65-b6b8-6a2c329ef6f9\n"
	if err := os.WriteFile(path, []byte(existing), 0o600); err != nil {
		t.Fatal(err)
	}
	startWithInvalidRoom(t, path)
	actual, err := os.ReadFile(path) // #nosec G304 -- The path belongs to t.TempDir().
	if err != nil || string(actual) != existing {
		t.Fatalf("existing device ID changed: %q, error = %v", actual, err)
	}
}

func startWithInvalidRoom(t *testing.T, deviceIDPath string) {
	t.Helper()
	runtime := NewRuntime(nil, nil)
	t.Cleanup(runtime.Stop)
	raw, err := json.Marshal(configuration{
		Node: node{
			Name: "node", Provider: "jitsi", Transport: "datachannel",
			// Jitsi rejects this before any network request, after resolving the device ID.
			Room: "missing-host-and-room", Key: strings.Repeat("ab", 32),
		},
		DeviceIDPath: deviceIDPath,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err = runtime.Start(string(raw)); err == nil || !strings.Contains(err.Error(), "invalid room URL") {
		t.Fatalf("Start() error = %v, want upstream room validation failure", err)
	}
	if runtime.core.IsRunning() {
		t.Fatal("failed Start left the runtime running")
	}
}

func TestStoppedRuntimeCannotStart(t *testing.T) {
	runtime := NewRuntime(nil, nil)
	runtime.Stop()

	raw, err := json.Marshal(configuration{
		Node: node{
			Name:      "node",
			Provider:  "jitsi",
			Transport: "datachannel",
			Room:      "room",
			Key:       strings.Repeat("ab", 32),
		},
		DeviceIDPath: filepath.Join(t.TempDir(), "device-id"),
	})
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	startErr := runtime.Start(string(raw))
	if startErr == nil || !strings.Contains(startErr.Error(), "already stopped") {
		t.Fatalf("Runtime.Start() error = %v, want already stopped", startErr)
	}
}

func TestStopCancelsPendingConnection(t *testing.T) {
	listener, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	accepted := make(chan net.Conn, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- connection
		}
	}()
	runtime := NewRuntime(nil, nil)
	t.Cleanup(runtime.Stop)
	raw, err := json.Marshal(configuration{
		Node: node{
			Name: "node", Provider: "jitsi", Transport: "datachannel",
			Room: "https://" + listener.Addr().String() + "/room", Key: strings.Repeat("ab", 32),
		},
		DeviceIDPath: filepath.Join(t.TempDir(), "device-id"),
	})
	if err != nil {
		t.Fatal(err)
	}
	started := make(chan error, 1)
	go func() { started <- runtime.Start(string(raw)) }()
	select {
	case connection := <-accepted:
		// Hold the connection before TLS completes, so startup cannot finish by itself.
		t.Cleanup(func() { _ = connection.Close() })
	case err = <-started:
		t.Fatalf("startup ended before connecting: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("runtime did not connect to the local server")
	}
	runtime.Stop()
	select {
	case err = <-started:
		if err == nil || runtime.core.IsRunning() {
			t.Fatalf("Stop left a successful or active session: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not cancel pending startup")
	}
}
