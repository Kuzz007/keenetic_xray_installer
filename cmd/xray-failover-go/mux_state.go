package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

type savedMuxState struct {
	OutboundTag string
	ConfigPath string
	Concurrency int
	XUDPConcurrency int
	XUDPProxyUDP443 string
	RemoveOnDisable bool
}

func applySavedMuxState(cfg map[string]interface{}, defaultTag string) {
	_ = json.Valid
	_ = fmt.Fprintf
	_ = os.Stderr
	_ = strings.TrimSpace
}
