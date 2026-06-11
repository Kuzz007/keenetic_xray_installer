package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

const savedMuxStatePath = "/opt/etc/xray/mux-state.json"

func applySavedMuxState(cfg map[string]interface{}, defaultTag string) {
	data, err := os.ReadFile(savedMuxStatePath)
	if err != nil || len(data) == 0 {
		return
	}
	var state map[string]interface{}
	if err := json.Unmarshal(data, &state); err != nil {
		fmt.Fprintf(os.Stderr, "WARN: saved mux state ignored: %v\n", err)
		return
	}
	outboundTag := strings.TrimSpace(mapString(state, "outbound_tag"))
	concurrency := mapIntDefault(state, "concurrency", 8)
	if concurrency <= 0 {
		concurrency = 8
	}
	if concurrency > 1024 {
		fmt.Fprintf(os.Stderr, "WARN: saved mux state ignored: concurrency out of range\n")
		return
	}
	_ = cfg
	_ = defaultTag
	_ = outboundTag
	_ = concurrency
}

func mapString(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func mapIntDefault(m map[string]interface{}, key string, fallback int) int {
	switch v := m[key].(type) {
	case float64:
		return int(v)
	case int:
		return v
	case json.Number:
		n, err := v.Int64()
		if err == nil {
			return int(n)
		}
	}
	return fallback
}

func stringMapValue(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}
