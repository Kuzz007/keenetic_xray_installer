package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const muxConfigPath = "/opt/etc/xray/config.json"
const muxBackupDir = "/opt/etc/xray/mux-backups"
const muxStatePath = "/opt/etc/xray/mux-state.json"
const muxReapplyStampPath = "/opt/var/run/xray-go-agent.mux-reapply"
const muxAutoReapplyInterval = 6 * time.Hour

type muxPayload struct {
	OutboundTag     string `json:"outbound_tag,omitempty"`
	ConfigPath      string `json:"config_path,omitempty"`
	Concurrency     int    `json:"concurrency,omitempty"`
	XUDPConcurrency int    `json:"xudpConcurrency,omitempty"`
	XUDPProxyUDP443 string `json:"xudpProxyUDP443,omitempty"`
	RemoveOnDisable bool   `json:"remove_on_disable,omitempty"`
}

func muxSupported() bool { return exists(muxConfigPath) }

func muxStatusLine() string {
	if !muxSupported() { return "" }
	ok, out := muxStatus("", "")
	if !ok { return "mux: unavailable" }
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "mux:") { return line }
	}
	return ""
}

func muxStatus(selector, source string) (bool, string) {
	payload, err := parseMuxPayload(selector, source)
	if err != nil { return false, err.Error() }
	cfg, err := readXrayConfig(payload.ConfigPath)
	if err != nil { return false, err.Error() }
	outbound, tag, protocol, err := findMuxOutbound(cfg, payload.OutboundTag)
	if err != nil { return false, err.Error() + "\n" + outboundSummary(cfg) }
	lines := []string{"⚙️ Mux status", "config: " + payload.ConfigPath, "outbound: " + tagProtocol(tag, protocol)}
	desired, desiredOK, _ := loadMuxDesired()
	if muxRaw, ok := outbound["mux"]; ok {
		if muxMap, ok := muxRaw.(map[string]interface{}); ok {
			line := "mux: " + formatMuxMap(muxMap)
			if desiredOK && !muxMatches(muxMap, desired) { line += " desired=" + formatMuxPayloadShort(desired) }
			lines = append(lines, line)
		} else { lines = append(lines, "mux: present but has unexpected JSON type") }
	} else {
		line := "mux: off/no mux block"
		if desiredOK { line += " desired=on " + formatMuxPayloadShort(desired) }
		lines = append(lines, line)
	}
	if desiredOK { lines = append(lines, "persistent state: "+muxStatePath) } else { lines = append(lines, "persistent state: none") }
	if latest := latestMuxBackup(); latest != "" { lines = append(lines, "latest rollback: "+latest) } else { lines = append(lines, "latest rollback: none") }
	return true, strings.Join(lines, "\n")
}

func muxSnapshot(selector, source string) (bool, string) {
	payload, err := parseMuxPayload(selector, source)
	if err != nil { return false, err.Error() }
	if _, err := readXrayConfig(payload.ConfigPath); err != nil { return false, err.Error() }
	backup, err := createMuxBackup(payload.ConfigPath, "manual")
	if err != nil { return false, err.Error() }
	pruneMuxBackups(20)
	return true, "✅ Rollback point created\nbackup: " + backup
}

func muxSet(selector, source string, enabled bool) (bool, string) {
	payload, err := parseMuxPayload(selector, source)
	if err != nil { return false, err.Error() }
	cfg, err := readXrayConfig(payload.ConfigPath)
	if err != nil { return false, err.Error() }
	outbound, tag, protocol, err := findMuxOutbound(cfg, payload.OutboundTag)
	if err != nil { return false, err.Error() + "\n" + outboundSummary(cfg) }
	if !enabled {
		_ = clearMuxDesired()
		if _, ok := outbound["mux"]; !ok { return true, "Mux already disabled\npersistent state: cleared\nconfig: " + payload.ConfigPath + "\noutbound: " + tagProtocol(tag, protocol) }
	}
	backup, err := createMuxBackup(payload.ConfigPath, "pre-mux-change")
	if err != nil { return false, err.Error() }
	if enabled { outbound["mux"] = muxMapFromPayload(payload) } else if payload.RemoveOnDisable { delete(outbound, "mux") } else { outbound["mux"] = map[string]interface{}{"enabled": false} }
	if err := writeXrayConfig(payload.ConfigPath, cfg); err != nil { return false, err.Error() }
	if ok, out := testXrayConfig(payload.ConfigPath); !ok { _ = restoreMuxBackup(backup, payload.ConfigPath); return false, "Xray config test failed. Restored rollback point.\nbackup: " + backup + "\n\n" + out }
	if ok, out := restartXray(); !ok { _ = restoreMuxBackup(backup, payload.ConfigPath); _, restoreOut := restartXray(); return false, "Xray restart failed. Restored rollback point.\nbackup: " + backup + "\n\nrestart error:\n" + out + "\n\nrestore restart:\n" + restoreOut }
	pruneMuxBackups(20)
	persistNote := ""
	if enabled {
		if err := saveMuxDesired(payload); err != nil { persistNote = "\nwarning: persistent state save failed: " + err.Error() } else { persistNote = "\npersistent state: saved " + muxStatePath }
	} else {
		if err := clearMuxDesired(); err != nil { persistNote = "\nwarning: persistent state clear failed: " + err.Error() } else { persistNote = "\npersistent state: cleared" }
	}
	state := "disabled"; if enabled { state = "enabled" }
	statusOK, status := muxStatus(selector, source)
	if statusOK { return true, "✅ Mux " + state + "\nrollback: " + backup + persistNote + "\n\n" + status }
	return true, "✅ Mux " + state + "\nrollback: " + backup + persistNote + "\nconfig: " + payload.ConfigPath + "\noutbound: " + tagProtocol(tag, protocol)
}

func muxRollback(selector, source string) (bool, string) {
	payload, err := parseMuxPayload(selector, source)
	if err != nil { return false, err.Error() }
	backup := latestMuxBackup()
	if backup == "" { return false, "no mux rollback backups found: " + muxBackupDir }
	currentBackup, err := createMuxBackup(payload.ConfigPath, "pre-rollback")
	if err != nil { return false, err.Error() }
	if err := restoreMuxBackup(backup, payload.ConfigPath); err != nil { return false, err.Error() }
	if ok, out := testXrayConfig(payload.ConfigPath); !ok { _ = restoreMuxBackup(currentBackup, payload.ConfigPath); return false, "Rollback config test failed. Current config restored.\nrollback tried: " + backup + "\ncurrent backup: " + currentBackup + "\n\n" + out }
	if ok, out := restartXray(); !ok { _ = restoreMuxBackup(currentBackup, payload.ConfigPath); _, restoreOut := restartXray(); return false, "Rollback restart failed. Current config restored.\nrollback tried: " + backup + "\ncurrent backup: " + currentBackup + "\n\nrestart error:\n" + out + "\n\nrestore restart:\n" + restoreOut }
	clearNote := ""
	if err := clearMuxDesired(); err != nil { clearNote = "\nwarning: persistent state clear failed: " + err.Error() } else { clearNote = "\npersistent state: cleared" }
	statusOK, status := muxStatus(selector, source)
	if statusOK { return true, "✅ Rollback applied\nrestored: " + backup + "\ncurrent saved as: " + currentBackup + clearNote + "\n\n" + status }
	return true, "✅ Rollback applied\nrestored: " + backup + "\ncurrent saved as: " + currentBackup + clearNote
}

func parseMuxPayload(selector, source string) (muxPayload, error) {
	payload := muxPayload{ConfigPath: muxConfigPath, Concurrency: 8, XUDPConcurrency: -1, XUDPProxyUDP443: "skip", RemoveOnDisable: true}
	selector = strings.TrimSpace(selector); if selector != "" { payload.OutboundTag = selector }
	source = strings.TrimSpace(source)
	if source != "" { if strings.HasPrefix(source, "{") { if err := json.Unmarshal([]byte(source), &payload); err != nil { return payload, fmt.Errorf("invalid mux payload JSON: %w", err) } } else if n, err := strconv.Atoi(source); err == nil { payload.Concurrency = n } else { payload.OutboundTag = source } }
	return normalizeMuxPayload(payload)
}

func normalizeMuxPayload(payload muxPayload) (muxPayload, error) {
	payload.OutboundTag = strings.TrimSpace(payload.OutboundTag); payload.ConfigPath = strings.TrimSpace(payload.ConfigPath); payload.XUDPProxyUDP443 = strings.TrimSpace(payload.XUDPProxyUDP443)
	if payload.ConfigPath == "" { payload.ConfigPath = muxConfigPath }
	if payload.Concurrency <= 0 { payload.Concurrency = 8 }
	if payload.Concurrency > 1024 { return payload, fmt.Errorf("concurrency too high: %d", payload.Concurrency) }
	if payload.XUDPConcurrency == 0 { payload.XUDPConcurrency = -1 }
	if payload.XUDPConcurrency < -1 || payload.XUDPConcurrency > 1024 { return payload, fmt.Errorf("xudpConcurrency out of range: %d", payload.XUDPConcurrency) }
	if payload.XUDPProxyUDP443 == "" { payload.XUDPProxyUDP443 = "skip" }
	payload.RemoveOnDisable = true
	return payload, nil
}

func saveMuxDesired(payload muxPayload) error {
	payload, err := normalizeMuxPayload(payload); if err != nil { return err }
	if err := os.MkdirAll(filepath.Dir(muxStatePath), 0700); err != nil { return fmt.Errorf("mux state dir failed: %w", err) }
	data, err := json.MarshalIndent(payload, "", "  "); if err != nil { return fmt.Errorf("mux state marshal failed: %w", err) }
	data = append(data, '\n'); tmp := fmt.Sprintf("%s.%d.tmp", muxStatePath, os.Getpid())
	if err := os.WriteFile(tmp, data, 0600); err != nil { return fmt.Errorf("mux state write failed: %w", err) }
	if err := os.Rename(tmp, muxStatePath); err != nil { _ = os.Remove(tmp); return fmt.Errorf("mux state replace failed: %w", err) }
	return nil
}

func loadMuxDesired() (muxPayload, bool, error) {
	data, err := os.ReadFile(muxStatePath)
	if err != nil { if os.IsNotExist(err) { return muxPayload{}, false, nil }; return muxPayload{}, false, err }
	var payload muxPayload
	if err := json.Unmarshal(data, &payload); err != nil { return muxPayload{}, false, fmt.Errorf("mux state parse failed: %w", err) }
	payload, err = normalizeMuxPayload(payload); if err != nil { return muxPayload{}, false, err }
	return payload, true, nil
}

func clearMuxDesired() error { if err := os.Remove(muxStatePath); err != nil && !os.IsNotExist(err) { return err }; _ = os.Remove(muxReapplyStampPath); return nil }

func muxAutoReapplyIfNeeded() (bool, string) {
	if !muxSupported() { return false, "" }
	payload, desired, err := loadMuxDesired(); if err != nil { return false, "desired state read failed: " + err.Error() }
	if !desired { return false, "" }
	cfg, err := readXrayConfig(payload.ConfigPath); if err != nil { return false, err.Error() }
	outbound, tag, protocol, err := findMuxOutbound(cfg, payload.OutboundTag); if err != nil { return false, err.Error() }
	if muxRaw, ok := outbound["mux"]; ok { if muxMap, ok := muxRaw.(map[string]interface{}); ok && muxMatches(muxMap, payload) { return false, "" } }
	if !muxReapplyAllowed(muxAutoReapplyInterval) { return false, "desired mux missing, but auto-reapply throttled; run Mux preset again after updating scripts" }
	touchMuxReapplyStamp()
	backup, err := createMuxBackup(payload.ConfigPath, "auto-reapply"); if err != nil { return false, err.Error() }
	outbound["mux"] = muxMapFromPayload(payload)
	if err := writeXrayConfig(payload.ConfigPath, cfg); err != nil { return false, err.Error() }
	if ok, out := testXrayConfig(payload.ConfigPath); !ok { _ = restoreMuxBackup(backup, payload.ConfigPath); return false, "auto-reapply config test failed; restored backup: " + backup + "\n" + out }
	if ok, out := restartXray(); !ok { _ = restoreMuxBackup(backup, payload.ConfigPath); _, restoreOut := restartXray(); return false, "auto-reapply restart failed; restored backup: " + backup + "\nrestart error:\n" + out + "\nrestore restart:\n" + restoreOut }
	pruneMuxBackups(20)
	return true, "reapplied desired mux to " + tagProtocol(tag, protocol) + " backup=" + backup + " " + formatMuxPayloadShort(payload)
}

func muxReapplyAllowed(interval time.Duration) bool { if interval <= 0 { return true }; st, err := os.Stat(muxReapplyStampPath); if err != nil { return true }; return time.Since(st.ModTime()) >= interval }
func touchMuxReapplyStamp() { _ = os.MkdirAll(filepath.Dir(muxReapplyStampPath), 0755); _ = os.WriteFile(muxReapplyStampPath, []byte(time.Now().Format(time.RFC3339)+"\n"), 0644) }
func muxMapFromPayload(payload muxPayload) map[string]interface{} { return map[string]interface{}{"enabled": true, "concurrency": payload.Concurrency, "xudpConcurrency": payload.XUDPConcurrency, "xudpProxyUDP443": payload.XUDPProxyUDP443} }
func muxMatches(m map[string]interface{}, payload muxPayload) bool { concurrency, ok := intValue(m["concurrency"]); if !ok || concurrency != payload.Concurrency { return false }; xudpConcurrency, ok := intValue(m["xudpConcurrency"]); if !ok || xudpConcurrency != payload.XUDPConcurrency { return false }; return boolValue(m["enabled"]) && stringValue(m["xudpProxyUDP443"]) == payload.XUDPProxyUDP443 }
func formatMuxPayloadShort(payload muxPayload) string { return fmt.Sprintf("concurrency=%d xudpConcurrency=%d xudpProxyUDP443=%s", payload.Concurrency, payload.XUDPConcurrency, payload.XUDPProxyUDP443) }

func readXrayConfig(path string) (map[string]interface{}, error) { data, err := os.ReadFile(path); if err != nil { return nil, fmt.Errorf("read config failed: %w", err) }; var cfg map[string]interface{}; if err := json.Unmarshal(data, &cfg); err != nil { return nil, fmt.Errorf("parse config JSON failed: %w", err) }; return cfg, nil }
func writeXrayConfig(path string, cfg map[string]interface{}) error { data, err := json.MarshalIndent(cfg, "", "  "); if err != nil { return fmt.Errorf("marshal config failed: %w", err) }; data = append(data, '\n'); tmp := fmt.Sprintf("%s.mux.%d.tmp", path, os.Getpid()); if err := os.WriteFile(tmp, data, 0600); err != nil { return fmt.Errorf("write temp config failed: %w", err) }; if err := os.Rename(tmp, path); err != nil { _ = os.Remove(tmp); return fmt.Errorf("replace config failed: %w", err) }; return nil }
func findMuxOutbound(cfg map[string]interface{}, requestedTag string) (map[string]interface{}, string, string, error) { raw, ok := cfg["outbounds"]; if !ok { return nil, "", "", fmt.Errorf("config has no outbounds") }; items, ok := raw.([]interface{}); if !ok { return nil, "", "", fmt.Errorf("config outbounds is not a JSON array") }; requestedTag = strings.TrimSpace(requestedTag); if requestedTag != "" { for _, item := range items { m, ok := item.(map[string]interface{}); if !ok { continue }; tag := stringValue(m["tag"]); if tag == requestedTag { return m, tag, stringValue(m["protocol"]), nil } }; return nil, "", "", fmt.Errorf("outbound tag not found: %s", requestedTag) }; for _, item := range items { m, ok := item.(map[string]interface{}); if !ok { continue }; if strings.EqualFold(stringValue(m["protocol"]), "vless") { return m, stringValue(m["tag"]), stringValue(m["protocol"]), nil } }; for _, item := range items { m, ok := item.(map[string]interface{}); if !ok { continue }; proto := strings.ToLower(stringValue(m["protocol"])); if proto != "freedom" && proto != "blackhole" { return m, stringValue(m["tag"]), stringValue(m["protocol"]), nil } }; return nil, "", "", fmt.Errorf("no suitable proxy outbound found") }
func createMuxBackup(configPath, reason string) (string, error) { data, err := os.ReadFile(configPath); if err != nil { return "", fmt.Errorf("backup read failed: %w", err) }; if err := os.MkdirAll(muxBackupDir, 0700); err != nil { return "", fmt.Errorf("backup dir failed: %w", err) }; name := time.Now().Format("20060102-150405") + "." + safeBackupReason(reason) + ".config.json"; path := filepath.Join(muxBackupDir, name); if err := os.WriteFile(path, data, 0600); err != nil { return "", fmt.Errorf("backup write failed: %w", err) }; return path, nil }
func restoreMuxBackup(backupPath, configPath string) error { data, err := os.ReadFile(backupPath); if err != nil { return fmt.Errorf("restore read failed: %w", err) }; tmp := fmt.Sprintf("%s.restore.%d.tmp", configPath, os.Getpid()); if err := os.WriteFile(tmp, data, 0600); err != nil { return fmt.Errorf("restore write temp failed: %w", err) }; if err := os.Rename(tmp, configPath); err != nil { _ = os.Remove(tmp); return fmt.Errorf("restore replace failed: %w", err) }; return nil }
func latestMuxBackup() string { items, err := filepath.Glob(filepath.Join(muxBackupDir, "*.config.json")); if err != nil || len(items) == 0 { return "" }; sort.Strings(items); return items[len(items)-1] }
func pruneMuxBackups(keep int) { if keep <= 0 { return }; items, err := filepath.Glob(filepath.Join(muxBackupDir, "*.config.json")); if err != nil || len(items) <= keep { return }; sort.Strings(items); for _, path := range items[:len(items)-keep] { _ = os.Remove(path) } }
func testXrayConfig(configPath string) (bool, string) { for _, bin := range []string{"/opt/sbin/xray", "/opt/bin/xray", "/usr/sbin/xray", "/usr/bin/xray"} { if exists(bin) { return run([]string{bin, "run", "-test", "-config", configPath}, 60*time.Second) } }; return false, "xray binary not found" }
func restartXray() (bool, string) { for _, init := range []string{"/opt/etc/init.d/S24xray", "/etc/init.d/xray", "/opt/etc/init.d/xray"} { if exists(init) { return run([]string{init, "restart"}, 60*time.Second) } }; return false, "xray init script not found" }
func outboundSummary(cfg map[string]interface{}) string { raw, ok := cfg["outbounds"]; if !ok { return "available outbounds: none" }; items, ok := raw.([]interface{}); if !ok { return "available outbounds: invalid outbounds array" }; parts := []string{}; for i, item := range items { m, ok := item.(map[string]interface{}); if !ok { continue }; tag := stringValue(m["tag"]); if tag == "" { tag = fmt.Sprintf("#%d", i) }; parts = append(parts, tagProtocol(tag, stringValue(m["protocol"]))) }; if len(parts) == 0 { return "available outbounds: none" }; return "available outbounds: " + strings.Join(parts, ", ") }
func tagProtocol(tag, protocol string) string { if tag == "" { tag = "<empty>" }; if protocol == "" { protocol = "unknown" }; return tag + " (" + protocol + ")" }
func formatMuxMap(m map[string]interface{}) string { enabled := boolValue(m["enabled"]); parts := []string{}; if enabled { parts = append(parts, "on") } else { parts = append(parts, "off") }; for _, key := range []string{"concurrency", "xudpConcurrency", "xudpProxyUDP443"} { if value, ok := m[key]; ok { parts = append(parts, fmt.Sprintf("%s=%v", key, value)) } }; return strings.Join(parts, " ") }
func stringValue(v interface{}) string { if s, ok := v.(string); ok { return s }; return "" }
func intValue(v interface{}) (int, bool) { switch n := v.(type) { case int: return n, true; case int64: return int(n), true; case float64: return int(n), true; case json.Number: i, err := n.Int64(); return int(i), err == nil }; return 0, false }
func boolValue(v interface{}) bool { b, ok := v.(bool); return ok && b }
func safeBackupReason(reason string) string { reason = strings.TrimSpace(reason); if reason == "" { reason = "manual" }; var b strings.Builder; for _, r := range reason { if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' { b.WriteRune(r) } }; if b.Len() == 0 { return "manual" }; return b.String() }
