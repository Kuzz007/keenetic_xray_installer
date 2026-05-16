package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"time"
)

const agentInstallerURL = "https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-agent-auto-install.sh"
const agentInstallerPath = "/opt/tmp/xray-go-agent-auto-install.sh"

func updateAgent() (bool, string) {
	if err := os.MkdirAll("/opt/tmp", 0755); err != nil {
		return false, err.Error()
	}
	if err := os.MkdirAll("/opt/var/log", 0755); err != nil {
		return false, err.Error()
	}

	client := &http.Client{Timeout: 60 * time.Second}
	req, err := http.NewRequest(http.MethodGet, agentInstallerURL, nil)
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
	if err := os.WriteFile(agentInstallerPath, body, 0755); err != nil {
		return false, err.Error()
	}

	logFile, err := os.OpenFile("/opt/var/log/xray-go-agent-update.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return false, err.Error()
	}

	cmd := exec.Command("/bin/sh", "-c", "sleep 2; exec /opt/tmp/xray-go-agent-auto-install.sh")
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return false, err.Error()
	}
	return true, "Agent update scheduled in background. Existing config will be reused.\nLog: /opt/var/log/xray-go-agent-update.log\nA fresh agent_start should arrive after restart."
}
