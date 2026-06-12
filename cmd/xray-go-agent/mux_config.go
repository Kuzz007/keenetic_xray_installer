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
const muxBackupDir = "/opt/etc/xray/xmux-backups"
const muxStatePath = "/opt/etc/xray/xmux-state.json"
const legacyMuxStatePath = "/opt/etc/xray/mux-state.json"
const muxReapplyStampPath = "/opt/var/run/xray-go-agent.xmux-reapply"
const muxAutoReapplyInterval = 6 * time.Hour

type muxPayload struct {
	OutboundTag      string `json:"outbound_tag,omitempty"`
	ConfigPath       string `json:"config_path,omitempty"`
	MaxConcurrency  int    `json:"maxConcurrency,omitempty"`
	Concurrency      int    `json:"concurrency,omitempty"`
	XUDPConcurrency int    `json:"xudpConcurrency,omitempty"`
	XUDPProxyUDP443  string `json:"xudpProxyUDP443,omitempty"`
	RemoveOnDisable  bool   `json:"remove_on_disable,omitempty"`

	legacyConcurrency bool
	preserveMax       bool
}

func muxSupported() bool { return exists(muxConfigPath) }

func muxStatusLine() string {
	if !muxSupported() { return "" }
	ok, out := muxStatus("", "")
	if !ok { return "xmux: unavailable" }
	xmuxLine := ""
	xudpLine := ""
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "xmux:") { xmuxLine = line }
		if strings.HasPrefix(line, "xudp:") { xudpLine = line }
	}
	if xmuxLine != "" && xudpLine != "" && !strings.Contains(xudpLine, "off") { return xmuxLine + "; " + xudpLine }
	return xmuxLine
}

func muxStatus(selector, source string) (bool, string) {
	payload, err := parseMuxPayload(selector, source)
	if err != nil { return false, err.Error() }
	cfg, err := readXrayConfig(payload.ConfigPath)
	if err != nil { return false, err.Error() }
	outbound, tag, protocol, err := findMuxOutbound(cfg, payload.OutboundTag)
	if err != nil { return false, err.Error() + "\n" + outboundSummary(cfg) }
	lines := []string{"XMUX/XUDP status", "config: " + payload.ConfigPath, "outbound: " + tagProtocol(tag, protocol)}
	legacyNote := "old outbound mux: absent"
	if _, ok := outbound["mux"]; ok { legacyNote = "old outbound mux: present" }
	lines = append(lines, legacyNote)
	_, xh, extra, xmux, err := xhttpExtraMaps(outbound, false)
	if err != nil {
		lines = append(lines, "xmux: unavailable: "+err.Error())
	} else if len(xmux) > 0 {
		line := "xmux: " + formatXmuxMap(xmux)
		desired, desiredOK, _ := loadMuxDesired()
		if desiredOK && !muxMatches(xmux, desired) { line += " desired=" + formatMuxPayloadShort(desired) }
		lines = append(lines, line)
		_ = xh
		_ = extra
	} else {
		line := "xmux: off/no xmux block"
		desired, desiredOK, _ := loadMuxDesired()
		if desiredOK { line += " desired=on " + formatMuxPayloadShort(desired) }
		lines = append(lines, line)
		_ = xh
		_ = extra
	}
	lines = append(lines, xudpStatusLine(outbound))
	if desired, desiredOK, _ := loadMuxDesired(); desiredOK { lines = append(lines, "persistent state: "+muxStatePath+" "+formatMuxPayloadShort(desired)) } else { lines = append(lines, "persistent state: none") }
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
	return true, "XMUX/XUDP rollback point created\nbackup: " + backup
}

func muxSet(selector, source string, enabled bool) (bool, string) {
	payload, err := parseMuxPayload(selector, source)
	if err != nil { return false, err.Error() }
	cfg, err := readXrayConfig(payload.ConfigPath)
	if err != nil { return false, err.Error() }
	outbound, tag, protocol, err := findMuxOutbound(cfg, payload.OutboundTag)
	if err != nil { return false, err.Error() + "\n" + outboundSummary(cfg) }
	payload = resolveMuxPayloadForOutbound(payload, outbound)
	backup, err := createMuxBackup(payload.ConfigPath, "pre-xmux-xudp-change")
	if err != nil { return false, err.Error() }
	if enabled {
		_, _, extra, _, err := xhttpExtraMaps(outbound, true)
		if err != nil { return false, err.Error() }
		extra["xmux"] = muxMapFromPayload(payload)
		applyXUDP(outbound, payload)
	} else {
		delete(outbound, "mux")
		removeXmux(outbound)
	}
	if err := writeXrayConfig(payload.ConfigPath, cfg); err != nil { return false, err.Error() }
	if ok, out := testXrayConfig(payload.ConfigPath); !ok { _ = restoreMuxBackup(backup, payload.ConfigPath); return false, "Xray config test failed. Restored rollback point.\nbackup: " + backup + "\n\n" + out }
	if ok, out := restartXray(); !ok { _ = restoreMuxBackup(backup, payload.ConfigPath); _, restoreOut := restartXray(); return false, "Xray restart failed. Restored rollback point.\nbackup: " + backup + "\n\nrestart error:\n" + out + "\n\nrestore restart:\n" + restoreOut }
	pruneMuxBackups(20)
	persistNote := ""
	if enabled {
		if err := saveMuxDesired(payload); err != nil { persistNote = "\nwarning: persistent XMUX/XUDP state save failed: " + err.Error() } else { persistNote = "\npersistent state: saved " + muxStatePath }
		_ = os.Remove(legacyMuxStatePath)
	} else {
		if err := clearMuxDesired(); err != nil { persistNote = "\nwarning: persistent XMUX/XUDP state clear failed: " + err.Error() } else { persistNote = "\npersistent state: cleared" }
	}
	state := "disabled"; if enabled { state = "enabled" }
	statusOK, status := muxStatus(selector, source)
	if statusOK { return true, "XMUX/XUDP " + state + "\nrollback: " + backup + persistNote + "\n\n" + status }
	return true, "XMUX/XUDP " + state + "\nrollback: " + backup + persistNote + "\nconfig: " + payload.ConfigPath + "\noutbound: " + tagProtocol(tag, protocol)
}

func muxRollback(selector, source string) (bool, string) {
	payload, err := parseMuxPayload(selector, source)
	if err != nil { return false, err.Error() }
	backup := latestMuxBackup()
	if backup == "" { return false, "no XMUX/XUDP rollback backups found: " + muxBackupDir }
	currentBackup, err := createMuxBackup(payload.ConfigPath, "pre-rollback")
	if err != nil { return false, err.Error() }
	if err := restoreMuxBackup(backup, payload.ConfigPath); err != nil { return false, err.Error() }
	if ok, out := testXrayConfig(payload.ConfigPath); !ok { _ = restoreMuxBackup(currentBackup, payload.ConfigPath); return false, "Rollback config test failed. Current config restored.\nrollback tried: " + backup + "\ncurrent backup: " + currentBackup + "\n\n" + out }
	if ok, out := restartXray(); !ok { _ = restoreMuxBackup(currentBackup, payload.ConfigPath); _, restoreOut := restartXray(); return false, "Rollback restart failed. Current config restored.\nrollback tried: " + backup + "\ncurrent backup: " + currentBackup + "\n\nrestart error:\n" + out + "\n\nrestore restart:\n" + restoreOut }
	clearNote := ""
	if err := clearMuxDesired(); err != nil { clearNote = "\nwarning: persistent XMUX/XUDP state clear failed: " + err.Error() } else { clearNote = "\npersistent state: cleared" }
	statusOK, status := muxStatus(selector, source)
	if statusOK { return true, "XMUX/XUDP rollback applied\nrestored: " + backup + "\ncurrent saved as: " + currentBackup + clearNote + "\n\n" + status }
	return true, "XMUX/XUDP rollback applied\nrestored: " + backup + "\ncurrent saved as: " + currentBackup + clearNote
}

func parseMuxPayload(selector, source string) (muxPayload, error) {
	payload := muxPayload{ConfigPath: muxConfigPath, RemoveOnDisable: true, XUDPConcurrency: -1, XUDPProxyUDP443: "skip"}
	selector = strings.TrimSpace(selector); if selector != "" { payload.OutboundTag = selector }
	source = strings.TrimSpace(source)
	if source != "" {
		if strings.HasPrefix(source, "{") {
			var raw map[string]json.RawMessage
			if err := json.Unmarshal([]byte(source), &raw); err != nil { return payload, fmt.Errorf("invalid XMUX/XUDP payload JSON: %w", err) }
			_, hasMax := raw["maxConcurrency"]
			_, hasConcurrency := raw["concurrency"]
			_, hasXUDP := raw["xudpConcurrency"]
			if err := json.Unmarshal([]byte(source), &payload); err != nil { return payload, fmt.Errorf("invalid XMUX/XUDP payload JSON: %w", err) }
			payload.legacyConcurrency = hasConcurrency && !hasMax
			payload.preserveMax = hasXUDP && !hasMax && !hasConcurrency
		} else if n, err := strconv.Atoi(source); err == nil {
			payload.MaxConcurrency = n
		} else {
			payload.OutboundTag = source
		}
	}
	return normalizeMuxPayload(payload)
}

func normalizeMuxPayload(payload muxPayload) (muxPayload, error) {
	payload.OutboundTag = strings.TrimSpace(payload.OutboundTag); payload.ConfigPath = strings.TrimSpace(payload.ConfigPath)
	payload.XUDPProxyUDP443 = strings.TrimSpace(payload.XUDPProxyUDP443)
	if payload.ConfigPath == "" { payload.ConfigPath = muxConfigPath }
	if payload.XUDPProxyUDP443 == "" { payload.XUDPProxyUDP443 = "skip" }
	if payload.MaxConcurrency <= 0 && payload.Concurrency > 0 { payload.MaxConcurrency = payload.Concurrency }
	if payload.MaxConcurrency <= 0 { payload.MaxConcurrency = 4 }
	if payload.MaxConcurrency > 1024 { return payload, fmt.Errorf("maxConcurrency too high: %d", payload.MaxConcurrency) }
	if payload.XUDPConcurrency == 0 { payload.XUDPConcurrency = -1 }
	if payload.XUDPConcurrency > 1024 { return payload, fmt.Errorf("xudpConcurrency too high: %d", payload.XUDPConcurrency) }
	if payload.XUDPConcurrency < -1 { return payload, fmt.Errorf("xudpConcurrency invalid: %d", payload.XUDPConcurrency) }
	payload.RemoveOnDisable = true
	return payload, nil
}

func saveMuxDesired(payload muxPayload) error {
	payload, err := normalizeMuxPayload(payload); if err != nil { return err }
	payload.Concurrency = 0
	payload.legacyConcurrency = false
	payload.preserveMax = false
	if err := os.MkdirAll(filepath.Dir(muxStatePath), 0700); err != nil { return fmt.Errorf("XMUX/XUDP state dir failed: %w", err) }
	data, err := json.MarshalIndent(payload, "", "  "); if err != nil { return fmt.Errorf("XMUX/XUDP state marshal failed: %w", err) }
	data = append(data, '\n'); tmp := fmt.Sprintf("%s.%d.tmp", muxStatePath, os.Getpid())
	if err := os.WriteFile(tmp, data, 0600); err != nil { return fmt.Errorf("XMUX/XUDP state write failed: %w", err) }
	if err := os.Rename(tmp, muxStatePath); err != nil { _ = os.Remove(tmp); return fmt.Errorf("XMUX/XUDP state replace failed: %w", err) }
	return nil
}

func loadMuxDesired() (muxPayload, bool, error) {
	data, err := os.ReadFile(muxStatePath)
	if err != nil { if os.IsNotExist(err) { return muxPayload{}, false, nil }; return muxPayload{}, false, err }
	var payload muxPayload
	if err := json.Unmarshal(data, &payload); err != nil { return muxPayload{}, false, fmt.Errorf("XMUX/XUDP state parse failed: %w", err) }
	payload, err = normalizeMuxPayload(payload); if err != nil { return muxPayload{}, false, err }
	return payload, true, nil
}

func clearMuxDesired() error { if err := os.Remove(muxStatePath); err != nil && !os.IsNotExist(err) { return err }; _ = os.Remove(legacyMuxStatePath); _ = os.Remove(muxReapplyStampPath); return nil }

func muxAutoReapplyIfNeeded() (bool, string) {
	if !muxSupported() { return false, "" }
	payload, desired, err := loadMuxDesired(); if err != nil { return false, "desired XMUX/XUDP state read failed: " + err.Error() }
	if !desired { return false, "" }
	cfg, err := readXrayConfig(payload.ConfigPath); if err != nil { return false, err.Error() }
	outbound, tag, protocol, err := findMuxOutbound(cfg, payload.OutboundTag); if err != nil { return false, err.Error() }
	_, _, _, xmux, mapErr := xhttpExtraMaps(outbound, false)
	if mapErr == nil && len(xmux) > 0 && muxMatches(xmux, payload) && xudpMatches(outbound, payload) { return false, "" }
	if !muxReapplyAllowed(muxAutoReapplyInterval) { return false, "desired XMUX/XUDP missing, but auto-reapply throttled; run preset again after updating scripts" }
	touchMuxReapplyStamp()
	backup, err := createMuxBackup(payload.ConfigPath, "auto-reapply")
	if err != nil { return false, err.Error() }
	_, _, extra, err := ensureXhttpExtraMaps(outbound)
	if err != nil { return false, err.Error() }
	extra["xmux"] = muxMapFromPayload(payload)
	applyXUDP(outbound, payload)
	if err := writeXrayConfig(payload.ConfigPath, cfg); err != nil { return false, err.Error() }
	if ok, out := testXrayConfig(payload.ConfigPath); !ok { _ = restoreMuxBackup(backup, payload.ConfigPath); return false, "auto-reapply XMUX/XUDP config test failed; restored backup: " + backup + "\n" + out }
	if ok, out := restartXray(); !ok { _ = restoreMuxBackup(backup, payload.ConfigPath); _, restoreOut := restartXray(); return false, "auto-reapply XMUX/XUDP restart failed; restored backup: " + backup + "\nrestart error:\n" + out + "\nrestore restart:\n" + restoreOut }
	pruneMuxBackups(20)
	_ = os.Remove(legacyMuxStatePath)
	return true, "reapplied desired XMUX/XUDP to " + tagProtocol(tag, protocol) + " backup=" + backup + " " + formatMuxPayloadShort(payload)
}

func resolveMuxPayloadForOutbound(payload muxPayload, outbound map[string]interface{}) muxPayload {
	if payload.preserveMax || (payload.XUDPConcurrency > 0 && payload.legacyConcurrency) {
		if mc := currentXmuxMax(outbound); mc > 0 { payload.MaxConcurrency = mc } else if desired, ok, _ := loadMuxDesired(); ok && desired.MaxConcurrency > 0 { payload.MaxConcurrency = desired.MaxConcurrency }
	}
	payload.Concurrency = 0
	return payload
}
func currentXmuxMax(outbound map[string]interface{}) int { _, _, _, xmux, err := xhttpExtraMaps(outbound, false); if err != nil || len(xmux) == 0 { return 0 }; if mc, ok := intValue(xmux["maxConcurrency"]); ok { return mc }; return 0 }
func muxReapplyAllowed(interval time.Duration) bool { if interval <= 0 { return true }; st, err := os.Stat(muxReapplyStampPath); if err != nil { return true }; return time.Since(st.ModTime()) >= interval }
func touchMuxReapplyStamp() { _ = os.MkdirAll(filepath.Dir(muxReapplyStampPath), 0755); _ = os.WriteFile(muxReapplyStampPath, []byte(time.Now().Format(time.RFC3339)+"\n"), 0644) }
func muxMapFromPayload(payload muxPayload) map[string]interface{} { return map[string]interface{}{"maxConcurrency": payload.MaxConcurrency, "maxConnections": 0, "cMaxReuseTimes": 0, "hMaxRequestTimes": 0, "hMaxReusableSecs": 0, "hKeepAlivePeriod": 0} }
func xudpMapFromPayload(payload muxPayload) map[string]interface{} { return map[string]interface{}{"enabled": true, "concurrency": -1, "xudpConcurrency": payload.XUDPConcurrency, "xudpProxyUDP443": payload.XUDPProxyUDP443} }
func applyXUDP(outbound map[string]interface{}, payload muxPayload) { if payload.XUDPConcurrency > 0 { outbound["mux"] = xudpMapFromPayload(payload) } else { delete(outbound, "mux") } }
func muxMatches(m map[string]interface{}, payload muxPayload) bool { maxConcurrency, ok := intValue(m["maxConcurrency"]); return ok && maxConcurrency == payload.MaxConcurrency }
func xudpMatches(outbound map[string]interface{}, payload muxPayload) bool { mux, ok := mapValue(outbound["mux"]); if payload.XUDPConcurrency <= 0 { return !ok }; if !ok { return false }; enabled, _ := boolValue(mux["enabled"]); concurrency, cok := intValue(mux["concurrency"]); xudp, xok := intValue(mux["xudpConcurrency"]); proxy := stringValue(mux["xudpProxyUDP443"]); if proxy == "" { proxy = "skip" }; return enabled && cok && concurrency == -1 && xok && xudp == payload.XUDPConcurrency && proxy == payload.XUDPProxyUDP443 }
func formatMuxPayloadShort(payload muxPayload) string { parts := []string{fmt.Sprintf("maxConcurrency=%d", payload.MaxConcurrency)}; if payload.XUDPConcurrency > 0 { parts = append(parts, fmt.Sprintf("xudpConcurrency=%d", payload.XUDPConcurrency), "xudpProxyUDP443="+payload.XUDPProxyUDP443) } else { parts = append(parts, "xudp=off") }; return strings.Join(parts, " ") }
func xudpStatusLine(outbound map[string]interface{}) string { mux, ok := mapValue(outbound["mux"]); if !ok { return "xudp: off/no mux block" }; xudp, xok := intValue(mux["xudpConcurrency"]); concurrency, _ := intValue(mux["concurrency"]); proxy := stringValue(mux["xudpProxyUDP443"]); if proxy == "" { proxy = "skip" }; if xok && xudp > 0 { return fmt.Sprintf("xudp: on xudpConcurrency=%d xudpProxyUDP443=%s tcpConcurrency=%d", xudp, proxy, concurrency) }; return "xudp: off/mux block present" }

func readXrayConfig(path string) (map[string]interface{}, error) { data, err := os.ReadFile(path); if err != nil { return nil, fmt.Errorf("read config failed: %w", err) }; var cfg map[string]interface{}; if err := json.Unmarshal(data, &cfg); err != nil { return nil, fmt.Errorf("parse config JSON failed: %w", err) }; return cfg, nil }
func writeXrayConfig(path string, cfg map[string]interface{}) error { data, err := json.MarshalIndent(cfg, "", "  "); if err != nil { return fmt.Errorf("marshal config failed: %w", err) }; data = append(data, '\n'); tmp := fmt.Sprintf("%s.xmux.%d.tmp", path, os.Getpid()); if err := os.WriteFile(tmp, data, 0600); err != nil { return fmt.Errorf("write temp config failed: %w", err) }; if err := os.Rename(tmp, path); err != nil { _ = os.Remove(tmp); return fmt.Errorf("replace config failed: %w", err) }; return nil }
func findMuxOutbound(cfg map[string]interface{}, requestedTag string) (map[string]interface{}, string, string, error) { raw, ok := cfg["outbounds"]; if !ok { return nil, "", "", fmt.Errorf("config has no outbounds") }; items, ok := raw.([]interface{}); if !ok { return nil, "", "", fmt.Errorf("config outbounds is not a JSON array") }; requestedTag = strings.TrimSpace(requestedTag); if requestedTag != "" { for _, item := range items { m, ok := item.(map[string]interface{}); if !ok { continue }; tag := stringValue(m["tag"]); if tag == requestedTag { return m, tag, stringValue(m["protocol"]), nil } }; return nil, "", "", fmt.Errorf("outbound tag not found: %s", requestedTag) }; for _, item := range items { m, ok := item.(map[string]interface{}); if !ok { continue }; if strings.EqualFold(stringValue(m["protocol"]), "vless") { return m, stringValue(m["tag"]), stringValue(m["protocol"]), nil } }; for _, item := range items { m, ok := item.(map[string]interface{}); if !ok { continue }; proto := strings.ToLower(stringValue(m["protocol"])); if proto != "freedom" && proto != "blackhole" { return m, stringValue(m["tag"]), stringValue(m["protocol"]), nil } }; return nil, "", "", fmt.Errorf("no suitable proxy outbound found") }
func createMuxBackup(configPath, reason string) (string, error) { data, err := os.ReadFile(configPath); if err != nil { return "", fmt.Errorf("backup read failed: %w", err) }; if err := os.MkdirAll(muxBackupDir, 0700); err != nil { return "", fmt.Errorf("backup dir failed: %w", err) }; name := time.Now().Format("20060102-150405") + "." + safeBackupReason(reason) + ".config.json"; path := filepath.Join(muxBackupDir, name); if err := os.WriteFile(path, data, 0600); err != nil { return "", fmt.Errorf("backup write failed: %w", err) }; return path, nil }
func restoreMuxBackup(backupPath, configPath string) error { data, err := os.ReadFile(backupPath); if err != nil { return fmt.Errorf("restore read failed: %w", err) }; tmp := fmt.Sprintf("%s.restore.%d.tmp", configPath, os.Getpid()); if err := os.WriteFile(tmp, data, 0600); err != nil { return fmt.Errorf("restore write temp failed: %w", err) }; if err := os.Rename(tmp, configPath); err != nil { _ = os.Remove(tmp); return fmt.Errorf("restore replace failed: %w", err) }; return nil }
func latestMuxBackup() string { items, err := filepath.Glob(filepath.Join(muxBackupDir, "*.config.json")); if err != nil || len(items) == 0 { return "" }; sort.Strings(items); return items[len(items)-1] }
func pruneMuxBackups(keep int) { if keep <= 0 { return }; items, err := filepath.Glob(filepath.Join(muxBackupDir, "*.config.json")); if err != nil || len(items) <= keep { return }; sort.Strings(items); for _, path := range items[:len(items)-keep] { _ = os.Remove(path) } }
func testXrayConfig(configPath string) (bool, string) { for _, bin := range []string{"/opt/sbin/xray", "/opt/bin/xray", "/usr/sbin/xray", "/usr/bin/xray"} { if exists(bin) { return run([]string{bin, "run", "-test", "-config", configPath}, 60*time.Second) } }; return false, "xray binary not found" }
func restartXray() (bool, string) { for _, init := range []string{"/opt/etc/init.d/S24xray", "/etc/init.d/xray", "/opt/etc/init.d/xray"} { if exists(init) { return run([]string{init, "restart"}, 60*time.Second) } }; return false, "xray init script not found" }
func outboundSummary(cfg map[string]interface{}) string { raw, ok := cfg["outbounds"]; if !ok { return "available outbounds: none" }; items, ok := raw.([]interface{}); if !ok { return "available outbounds: invalid outbounds array" }; parts := []string{}; for i, item := range items { m, ok := item.(map[string]interface{}); if !ok { continue }; tag := stringValue(m["tag"]); if tag == "" { tag = fmt.Sprintf("#%d", i) }; parts = append(parts, tagProtocol(tag, stringValue(m["protocol"]))) }; if len(parts) == 0 { return "available outbounds: none" }; return "available outbounds: " + strings.Join(parts, ", ") }
func tagProtocol(tag, protocol string) string { if tag == "" { tag = "<empty>" }; if protocol == "" { protocol = "unknown" }; return tag + " (" + protocol + ")" }
func formatXmuxMap(m map[string]interface{}) string { parts := []string{"on"}; for _, key := range []string{"maxConcurrency", "maxConnections", "cMaxReuseTimes", "hMaxRequestTimes", "hMaxReusableSecs", "hKeepAlivePeriod"} { if value, ok := m[key]; ok { parts = append(parts, fmt.Sprintf("%s=%v", key, value)) } }; return strings.Join(parts, " ") }
func stringValue(v interface{}) string { if s, ok := v.(string); ok { return s }; return "" }
func intValue(v interface{}) (int, bool) { switch n := v.(type) { case int: return n, true; case int64: return int(n), true; case float64: return int(n), true; case json.Number: i, err := n.Int64(); return int(i), err == nil }; return 0, false }
func boolValue(v interface{}) (bool, bool) { b, ok := v.(bool); return b, ok }
func safeBackupReason(reason string) string { reason = strings.TrimSpace(reason); if reason == "" { reason = "manual" }; var b strings.Builder; for _, r := range reason { if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' { b.WriteRune(r) } }; if b.Len() == 0 { return "manual" }; return b.String() }

func mapValue(v interface{}) (map[string]interface{}, bool) { m, ok := v.(map[string]interface{}); return m, ok }

func xhttpExtraMaps(outbound map[string]interface{}, create bool) (map[string]interface{}, map[string]interface{}, map[string]interface{}, map[string]interface{}, error) {
	ss, ok := mapValue(outbound["streamSettings"])
	if !ok {
		if !create { return nil, nil, nil, nil, fmt.Errorf("outbound has no streamSettings") }
		ss = map[string]interface{}{}
		outbound["streamSettings"] = ss
	}
	if network := strings.ToLower(stringValue(ss["network"])); network != "xhttp" && network != "splithttp" {
		return nil, nil, nil, nil, fmt.Errorf("XMUX requires streamSettings.network=xhttp, got %q", stringValue(ss["network"]))
	}
	xh, ok := mapValue(ss["xhttpSettings"])
	if !ok {
		if !create { return ss, nil, nil, nil, fmt.Errorf("outbound has no xhttpSettings") }
		xh = map[string]interface{}{}
		ss["xhttpSettings"] = xh
	}
	extra, ok := mapValue(xh["extra"])
	if !ok {
		if !create { return ss, xh, nil, nil, nil }
		extra = map[string]interface{}{}
		xh["extra"] = extra
	}
	xmux, _ := mapValue(extra["xmux"])
	return ss, xh, extra, xmux, nil
}

func ensureXhttpExtraMaps(outbound map[string]interface{}) (map[string]interface{}, map[string]interface{}, map[string]interface{}, error) {
	ss, xh, extra, _, err := xhttpExtraMaps(outbound, true)
	return ss, xh, extra, err
}

func removeXmux(outbound map[string]interface{}) {
	_, xh, extra, _, err := xhttpExtraMaps(outbound, false)
	if err != nil || extra == nil { return }
	delete(extra, "xmux")
	if len(extra) == 0 && xh != nil { delete(xh, "extra") }
}
