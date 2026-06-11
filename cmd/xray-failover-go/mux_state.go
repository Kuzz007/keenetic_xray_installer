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
	_ = data
	_ = cfg
	_ = defaultTag
	_ = json.Valid
	_ = fmt.Fprintf
	_ = os.Stderr
	_ = strings.TrimSpace
}

func stringMapValue(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}
