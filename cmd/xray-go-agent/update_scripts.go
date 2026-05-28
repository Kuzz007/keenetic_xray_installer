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
const routesCatalogURL = "https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-keenetic-routes-catalog.sh"
const updateScriptsLogPath = "/opt/var/log/xray-go-update-scripts.log"

func updateScripts() (bool, string) {
	if err := os.MkdirAll("/opt/tmp", 0755); err != nil {
		return false, err.Error()
	}
	_ = os.MkdirAll("/opt/var/log", 0755)

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
	if !strings.HasPrefix(string(body), "#!/bin/sh") && !strings.HasPrefix(string(body), "#!/opt/bin/sh") {
		return false, "downloaded auto_latest script does not look like a shell script"
	}
	if err := os.WriteFile(autoLatestPath, body, 0755); err != nil {
		return false, err.Error()
	}
	if err := checkShellSyntax(autoLatestPath); err != nil {
		return false, "downloaded auto_latest script failed syntax check: " + err.Error()
	}

	cmd := exec.Command(autoLatestPath, "--update-only", "--no-restart")
	out, err := cmd.CombinedOutput()
	text := strings.TrimSpace("Updating router scripts via auto_latest safe-wrapper repair path...\n" + string(out))

	routesText, routesErr := installRoutesCatalogHelper(client)
	if routesText != "" {
		text = strings.TrimSpace(text + "\n\n" + routesText)
	}

	_ = os.WriteFile(updateScriptsLogPath, []byte(text+"\n"), 0644)
	summary := updateScriptsSummary(text)
	if routesErr != nil {
		summary += "\nroutes-catalog: failed"
	} else if exists(routesCatalogPath) {
		summary += "\nroutes-catalog: installed"
	}
	if err != nil {
		return false, summary + "\nstatus: failed\nerror: " + err.Error()
	}
	if routesErr != nil {
		return false, summary + "\nstatus: failed\nerror: " + routesErr.Error()
	}
	return true, summary
}

func installRoutesCatalogHelper(client *http.Client) (string, error) {
	if err := os.MkdirAll("/opt/bin", 0755); err != nil {
		return "Installing routes catalog helper...\nERROR: " + err.Error(), err
	}
	req, err := http.NewRequest(http.MethodGet, routesCatalogURL, nil)
	if err != nil {
		return "Installing routes catalog helper...\nERROR: " + err.Error(), err
	}
	req.Header.Set("Cache-Control", "no-cache")
	resp, err := client.Do(req)
	if err != nil {
		return "Installing routes catalog helper...\nERROR: " + err.Error(), err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		err := fmt.Errorf("routes catalog helper download failed: HTTP %s", resp.Status)
		return "Installing routes catalog helper...\nERROR: " + err.Error(), err
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 512*1024))
	if err != nil {
		return "Installing routes catalog helper...\nERROR: " + err.Error(), err
	}
	if !strings.HasPrefix(string(body), "#!/bin/sh") && !strings.HasPrefix(string(body), "#!/opt/bin/sh") {
		err := fmt.Errorf("downloaded routes catalog helper does not look like a shell script")
		return "Installing routes catalog helper...\nERROR: " + err.Error(), err
	}
	tmp := routesCatalogPath + ".tmp"
	if err := os.WriteFile(tmp, body, 0755); err != nil {
		return "Installing routes catalog helper...\nERROR: " + err.Error(), err
	}
	if err := checkShellSyntax(tmp); err != nil {
		_ = os.Remove(tmp)
		err = fmt.Errorf("downloaded routes catalog helper failed syntax check: %w", err)
		return "Installing routes catalog helper...\nERROR: " + err.Error(), err
	}
	if err := os.Rename(tmp, routesCatalogPath); err != nil {
		_ = os.Remove(tmp)
		return "Installing routes catalog helper...\nERROR: " + err.Error(), err
	}
	return "Installing routes catalog helper...\nInstalled: " + routesCatalogPath, nil
}

func checkShellSyntax(path string) error {
	candidates := []string{"/opt/bin/sh", "/bin/sh"}
	unsupported := []string{}
	for _, shell := range candidates {
		if !exists(shell) {
			continue
		}
		cmd := exec.Command(shell, "-n", path)
		out, err := cmd.CombinedOutput()
		msg := strings.TrimSpace(string(out))
		if err == nil {
			return nil
		}
		if strings.Contains(msg, "Invalid option") || strings.Contains(msg, "illegal option") || strings.Contains(msg, "bad option") || strings.Contains(msg, "unknown option") {
			unsupported = append(unsupported, shell+": "+msg)
			continue
		}
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("%s: %s", shell, msg)
	}
	if len(unsupported) > 0 {
		return nil
	}
	return fmt.Errorf("no shell available for syntax check")
}

func updateScriptsSummary(output string) string {
	edition := firstValueAfter(output, "Selected edition:")
	if edition == "" {
		edition = "unknown"
	}
	mode := firstValueAfter(output, "Mode:")
	if mode == "" {
		mode = "update-only"
	}
	minimalMenu := "no"
	if exists("/opt/bin/minimal-go-menu") {
		minimalMenu = "yes"
	}
	recovery := "unknown"
	if exists("/opt/bin/vless-go-recover") {
		recovery = "updated"
	}
	return strings.Join([]string{
		"✅ Scripts update completed",
		"installer: safe-wrapper",
		"edition: " + edition,
		"mode: " + mode,
		"recovery: " + recovery,
		"minimal-go-menu: " + minimalMenu,
		"log: " + updateScriptsLogPath,
	}, "\n")
}

func firstValueAfter(output, prefix string) string {
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}
