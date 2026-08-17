package runtimebridge

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

const (
	defaultVP8FPS       = 30
	defaultVP8BatchSize = 64
	maximumNameRunes    = 80
	providerJitsi       = "jitsi"
	providerTelemost    = "telemost"
	providerWBStream    = "wbstream"
	transportData       = "datachannel"
	transportVP8        = "vp8channel"
)

type configuration struct {
	Node         node   `json:"node"`
	DeviceIDPath string `json:"deviceIDPath"`
}

type node struct {
	Name         string `json:"name"`
	Provider     string `json:"provider"`
	Transport    string `json:"transport"`
	Room         string `json:"room"`
	Key          string `json:"key"`
	VP8FPS       int    `json:"vp8FPS"`
	VP8BatchSize int    `json:"vp8BatchSize"`
}

func decodeConfiguration(raw string) (configuration, error) {
	var cfg configuration
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return configuration{}, fmt.Errorf("decode configuration: %w", err)
	}
	if strings.TrimSpace(cfg.DeviceIDPath) == "" {
		return configuration{}, errors.New("device ID path is empty")
	}
	cfg.Node.applyDefaults()
	if err := cfg.Node.validate(); err != nil {
		return configuration{}, fmt.Errorf("node: %w", err)
	}
	return cfg, nil
}

func (n *node) applyDefaults() {
	n.Name = strings.TrimSpace(n.Name)
	n.Provider = strings.TrimSpace(n.Provider)
	n.Transport = strings.TrimSpace(n.Transport)
	n.Room = strings.TrimSpace(n.Room)
	n.Key = strings.TrimSpace(n.Key)
	if n.VP8FPS == 0 {
		n.VP8FPS = defaultVP8FPS
	}
	if n.VP8BatchSize == 0 {
		n.VP8BatchSize = defaultVP8BatchSize
	}
}

func (n *node) validate() error {
	if n.Name == "" || n.Provider == "" || n.Transport == "" || n.Room == "" {
		return errors.New("name, provider, transport, and room are required")
	}
	key, err := hex.DecodeString(n.Key)
	if err != nil || len(key) != 32 {
		return errors.New("key must be 64 hexadecimal characters")
	}
	switch n.Provider {
	case providerJitsi, providerTelemost, providerWBStream:
	default:
		return fmt.Errorf("unsupported provider %q", n.Provider)
	}
	switch n.Transport {
	case transportData, transportVP8:
	default:
		return fmt.Errorf("transport %q is unavailable in the pinned stable mobile runtime", n.Transport)
	}
	if n.Transport == transportData && n.Provider != providerJitsi {
		return fmt.Errorf("datachannel is unavailable with provider %q in the guest mobile runtime", n.Provider)
	}
	if n.VP8FPS < 1 || n.VP8FPS > 120 {
		return errors.New("vp8FPS must be between 1 and 120")
	}
	if n.VP8BatchSize < 1 || n.VP8BatchSize > 64 {
		return errors.New("vp8BatchSize must be between 1 and 64")
	}
	return nil
}

func safeName(value string) string {
	value = strings.ReplaceAll(value, "\n", " ")
	runes := []rune(value)
	if len(runes) > maximumNameRunes {
		runes = runes[:maximumNameRunes]
	}
	return string(runes)
}
