package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

const autoLatestURL = "https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh"
const autoLatestPath = "/opt/tmp/xray_vless_failover_auto_latest.sh"

func updateScripts() (bool, string) {
	if err := os.MkdirAll("/opt/tmp", 0755); err != nil {
		return false, err.Error()
	}

	client := &http.Client{Timeout: 60 * time.Second}
	req, err := http.NewRequest(http.MethodGet, autoLatestURL, nil)
	if err != nil {
		return false, err.Error()
	}
	req.Header.Set("Cache-Control", "no-cache")

	resp, err := client.Do(req)
	if err != nil {
		return false, err.Error()
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return false, fmt.Sprintf("download failed: HTTP %s", resp.Status)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1024*1024))
	if err != nil {
		return false, err.Error()
	}
	if !strings.HasPrefix(string(body), "#!/bin/sh") {
		return false, "downloaded auto_latest script does not look like a shell script"
	}
	if err := os.WriteFile(autoLatestPath, body, 0755); err != nil {
		return false, err.Error()
	}

	cmd := exec.Command(autoLatestPath, "--update-only", "--no-restart")
	out, err := cmd.CombinedOutput()
	text := strings.TrimSpace("Updating router scripts via auto_latest repair path...\n" + string(out))
	if err != nil {
		return false, text + "\nERROR: " + err.Error()
	}
	return true, text
}
