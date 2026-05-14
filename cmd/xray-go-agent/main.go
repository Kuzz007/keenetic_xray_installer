package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type Config struct {
	ServerURL    string
	RouterID     string
	RouterName   string
	AgentToken   string
	PollInterval time.Duration
}

type Command struct {
	ID       string `json:"id"`
	Action   string `json:"action"`
	Slot     string `json:"slot,omitempty"`
	Selector string `json:"selector,omitempty"`
	Source   string `json:"source,omitempty"`
}

type Result struct {
	CommandID string `json:"command_id"`
	RouterID  string `json:"router_id"`
	OK        bool   `json:"ok"`
	Output    string `json:"output"`
}

type PollResponse struct {
	Command *Command `json:"command,omitempty"`
}

func main() {
	cfgPath := flag.String("config", "/opt/etc/xray/xray-go-agent.conf", "config path")
	once := flag.Bool("once", false, "run one poll cycle and exit")
	flag.Parse()

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	log.Printf("xray-go-agent started router_id=%s name=%s server=%s", cfg.RouterID, cfg.RouterName, cfg.ServerURL)
	for {
		if err := pollOnce(cfg); err != nil {
			log.Printf("poll error: %v", err)
		}
		if *once {
			return
		}
		time.Sleep(cfg.PollInterval)
	}
}

func pollOnce(cfg Config) error {
	status := shortStatus()
	body := map[string]string{"router_id": cfg.RouterID, "name": cfg.RouterName, "status": status}
	payload, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(cfg.ServerURL, "/")+"/agent/poll", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+cfg.AgentToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("server status %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	var pr PollResponse
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return err
	}
	if pr.Command == nil || pr.Command.ID == "" {
		return nil
	}
	ok, out := runAllowed(*pr.Command)
	res := Result{CommandID: pr.Command.ID, RouterID: cfg.RouterID, OK: ok, Output: redact(out, pr.Command.Source)}
	return postResult(cfg, res)
}

func postResult(cfg Config, res Result) error {
	payload, _ := json.Marshal(res)
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(cfg.ServerURL, "/")+"/agent/result", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+cfg.AgentToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("result status %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	return nil
}

func runAllowed(c Command) (bool, string) {
	var cmd []string
	switch c.Action {
	case "status":
		cmd = statusCommand()
	case "doctor":
		cmd = doctorCommand()
	case "switch_primary":
		cmd = switchCommand("primary")
	case "switch_backup":
		cmd = switchCommand("backup")
	case "recover_status":
		cmd = recoverCommand("status")
	case "recover_check":
		cmd = recoverCommand("check")
	case "recover_run":
		cmd = recoverCommand("run")
	case "recover_enable":
		cmd = recoverCommand("enable-hourly")
	case "recover_disable":
		cmd = recoverCommand("disable-hourly")
	case "history":
		cmd = historyCommand()
	case "watchdog_log":
		cmd = []string{"/bin/sh", "-c", "tail -n 100 /opt/var/log/vless-go-watchdog.log 2>/dev/null || true"}
	case "recovery_log":
		cmd = []string{"/bin/sh", "-c", "tail -n 100 /opt/var/log/vless-go-recover.log 2>/dev/null || true"}
	case "source_status":
		cmd = statusCommand()
	case "set_primary_source":
		return setSource("primary", c.Selector, c.Source)
	case "set_backup_source":
		return setSource("backup", c.Selector, c.Source)
	default:
		return false, "unknown action: " + c.Action
	}
	if len(cmd) == 0 {
		return false, "unsupported action on this router: " + c.Action
	}
	return run(cmd, 180*time.Second)
}

func setSource(slot, selector, source string) (bool, string) {
	selector = normalizeSelector(selector)
	if strings.TrimSpace(source) == "" {
		return false, "source is empty"
	}
	if slot != "primary" && slot != "backup" {
		return false, "invalid slot"
	}
	cmd := setSourceCommand(slot, selector, source)
	if len(cmd) == 0 {
		return false, "unsupported source update on this router"
	}
	_ = os.MkdirAll("/opt/etc/xray/source-backups", 0700)
	oldPath := "/opt/etc/xray/vless-go." + slot
	if data, err := os.ReadFile(oldPath); err == nil && len(data) > 0 {
		name := time.Now().Format("20060102-150405") + "." + slot
		_ = os.WriteFile(filepath.Join("/opt/etc/xray/source-backups", name), data, 0600)
	}
	ok, out := run(cmd, 180*time.Second)
	if ok {
		return true, "source updated: slot=" + slot + " selector=" + selector + "\n" + redact(out, source)
	}
	return false, redact(out, source)
}

func run(cmd []string, timeout time.Duration) (bool, string) {
	if len(cmd) == 0 {
		return false, "empty command"
	}
	if _, err := os.Stat(cmd[0]); err != nil {
		return false, "not found: " + cmd[0]
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c := exec.CommandContext(ctx, cmd[0], cmd[1:]...)
	var out bytes.Buffer
	c.Stdout = &out
	c.Stderr = &out
	err := c.Run()
	text := strings.TrimSpace(out.String())
	if ctx.Err() == context.DeadlineExceeded {
		return false, text + "\nTIMEOUT"
	}
	if err != nil {
		return false, text + "\nERROR: " + err.Error()
	}
	if text == "" {
		text = "OK"
	}
	return true, text
}

func shortStatus() string {
	cmd := statusCommand()
	features := detectFeatures()
	featureLine := "features: " + strings.Join(features, ",")
	if len(cmd) == 0 {
		return "status_error: no supported status command; " + featureLine
	}
	ok, out := run(cmd, 25*time.Second)
	if !ok {
		return "status_error: " + out + "; " + featureLine
	}
	lines := []string{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "активный слот:") || strings.Contains(line, "health: OK") || strings.Contains(line, "hourly recovery:") || strings.Contains(line, "daemon: запущен") || strings.Contains(line, "основной профиль:") || strings.Contains(line, "резервный профиль:") {
			lines = append(lines, line)
		}
	}
	lines = append(lines, featureLine)
	return strings.Join(lines, "; ")
}

func detectFeatures() []string {
	features := []string{}

	if len(statusCommand()) > 0 {
		features = append(features, "status")
	}
	if len(switchCommand("primary")) > 0 && len(switchCommand("backup")) > 0 {
		features = append(features, "switch")
	}
	if len(setSourceCommand("primary", "first", "probe")) > 0 {
		features = append(features, "source_update")
	}
	if len(doctorCommand()) > 0 {
		features = append(features, "doctor")
	}
	if len(historyCommand()) > 0 {
		features = append(features, "history")
	}
	if exists("/opt/bin/vless-go-watchdog") || exists("/opt/bin/watchdog") || exists("/opt/var/log/vless-go-watchdog.log") {
		features = append(features, "watchdog")
	}
	if len(recoverCommand("status")) > 0 {
		features = append(features, "recovery")
	}
	if len(features) == 0 {
		features = append(features, "status")
	}
	return features
}

func statusCommand() []string {
	if exists("/opt/bin/xray-go") {
		return []string{"/opt/bin/xray-go", "status"}
	}
	if exists("/opt/bin/vless-go-failover") {
		return []string{"/opt/bin/vless-go-failover", "status"}
	}
	if exists("/opt/bin/failover") {
		return []string{"/opt/bin/failover", "status"}
	}
	return nil
}

func doctorCommand() []string {
	if exists("/opt/bin/xray-go") {
		return []string{"/opt/bin/xray-go", "doctor", "--support"}
	}
	if exists("/opt/bin/vless-go-doctor") {
		return []string{"/opt/bin/vless-go-doctor", "--support"}
	}
	if exists("/opt/bin/xray-doctor") {
		return []string{"/opt/bin/xray-doctor", "--support"}
	}
	return nil
}

func switchCommand(slot string) []string {
	if exists("/opt/bin/xray-go") {
		return []string{"/opt/bin/xray-go", "switch", slot}
	}
	if exists("/opt/bin/vless-go-failover") {
		return []string{"/opt/bin/vless-go-failover", "switch", slot}
	}
	if exists("/opt/bin/failover") {
		return []string{"/opt/bin/failover", "switch", slot}
	}
	return nil
}

func recoverCommand(action string) []string {
	if exists("/opt/bin/xray-go") {
		switch action {
		case "run":
			return []string{"/opt/bin/xray-go", "recover"}
		default:
			return []string{"/opt/bin/xray-go", "recover", action}
		}
	}
	if exists("/opt/bin/vless-go-recover") {
		switch action {
		case "run":
			return []string{"/opt/bin/vless-go-recover", "run"}
		default:
			return []string{"/opt/bin/vless-go-recover", action}
		}
	}
	return nil
}

func historyCommand() []string {
	if exists("/opt/bin/xray-go") {
		return []string{"/opt/bin/xray-go", "history"}
	}
	if exists("/opt/bin/vless-go-history") {
		return []string{"/opt/bin/vless-go-history"}
	}
	if exists("/opt/bin/history") {
		return []string{"/opt/bin/history"}
	}
	return nil
}

func setSourceCommand(slot, selector, source string) []string {
	if exists("/opt/bin/vless-go-failover") {
		return []string{"/opt/bin/vless-go-failover", "set-" + slot, source, "--selector", selector}
	}
	if exists("/opt/bin/failover") {
		return []string{"/opt/bin/failover", "set-" + slot, source, "--selector", selector}
	}
	return nil
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func redact(s, secret string) string {
	if secret != "" {
		s = strings.ReplaceAll(s, secret, "<hidden>")
	}
	for _, marker := range []string{"vless://", "vmess://", "trojan://", "ss://"} {
		for {
			i := strings.Index(s, marker)
			if i < 0 {
				break
			}
			j := i
			for j < len(s) && !strings.ContainsAny(string(s[j]), " \n\r\t\"'") {
				j++
			}
			s = s[:i] + "<hidden-url>" + s[j:]
		}
	}
	return s
}

func loadConfig(path string) (Config, error) {
	cfg := Config{PollInterval: 5 * time.Second}
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		v = strings.Trim(strings.TrimSpace(v), "\"")
		switch strings.TrimSpace(k) {
		case "SERVER_URL":
			cfg.ServerURL = v
		case "ROUTER_ID":
			cfg.RouterID = v
		case "ROUTER_NAME":
			cfg.RouterName = v
		case "AGENT_TOKEN":
			cfg.AgentToken = v
		case "POLL_INTERVAL":
			if d, err := time.ParseDuration(v + "s"); err == nil {
				cfg.PollInterval = d
			}
		}
	}
	if cfg.ServerURL == "" || cfg.RouterID == "" || cfg.AgentToken == "" {
		return cfg, fmt.Errorf("SERVER_URL, ROUTER_ID and AGENT_TOKEN are required")
	}
	if cfg.RouterName == "" {
		cfg.RouterName = cfg.RouterID
	}
	return cfg, nil
}

func normalizeSelector(selector string) string {
	selector = strings.TrimSpace(selector)
	if selector == "" {
		return "first"
	}
	if selector == "first" || strings.HasPrefix(selector, "index:") {
		return selector
	}
	allDigits := true
	for _, r := range selector {
		if r < '0' || r > '9' {
			allDigits = false
			break
		}
	}
	if allDigits {
		return "index:" + selector
	}
	return selector
}
