package main

import (
	"encoding/json"
	"fmt"
	"net/http"
)

const controlServerVersion = "0.1.5-go-polish"

var buildCommit = "dev"
var buildTime = "unknown"

func versionPayload() map[string]string {
	return map[string]string{
		"name":       "xray-go-control-server",
		"version":    controlServerVersion,
		"commit":     buildCommit,
		"build_time": buildTime,
	}
}

func versionLine() string {
	return fmt.Sprintf("version=%s commit=%s build_time=%s", controlServerVersion, buildCommit, buildTime)
}

func handleVersion(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(versionPayload())
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = fmt.Fprintf(w, "OK\n%s\n", versionLine())
}
