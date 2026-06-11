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
	_ = cfg
	_ = defaultTag
	_ = strings.TrimSpace
	_ = mapString(state, "outbound_tag")
}

func mapString(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func stringMapValue(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}
