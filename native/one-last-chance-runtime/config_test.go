//nolint:testpackage // These tests exercise unexported configuration and lifecycle boundaries.
package runtimebridge

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
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
	first, err := loadOrCreateDeviceID(path)
	if err != nil {
		t.Fatalf("loadOrCreateDeviceID() error = %v", err)
	}
	second, err := loadOrCreateDeviceID(path)
	if err != nil {
		t.Fatalf("loadOrCreateDeviceID() second error = %v", err)
	}
	if first == "" || second != first {
		t.Fatalf("device IDs = %q and %q, want one persisted value", first, second)
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
