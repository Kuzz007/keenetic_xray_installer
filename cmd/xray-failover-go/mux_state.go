package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

func applySavedMuxState(cfg map[string]interface{}, defaultTag string) {
	_ = json.Valid
	_ = fmt.Fprintf
	_ = os.Stderr
	_ = strings.TrimSpace
}
