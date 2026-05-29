package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

type Config struct {
	ServerURL string
	RouterID string
	RouterName string
	AgentToken string
	PollInterval time.Duration
}

type Command struct {
	ID string `json:"id"`
	Action string `json:"action"`
	Slot string `json:"slot,omitempty"`
	Selector string `json:"selector,omitempty"`
	Source string `json:"source,omitempty"`
}

type PollResponse struct { Command *Command `json:"command,omitempty"` }

type Heartbeat struct {
	RouterID string `json:"router_id"`
	RouterName string `json:"router_name"`
	AgentVersion string `json:"agent_version"`
	Arch string `json:"arch"`
	Status string `json:"status"`
	Capabilities []string `json:"capabilities"`
	Summary string `json:"summary"`
}

type Result struct {
	RouterID string `json:"router_id"`
	CommandID string `json:"command_id"`
	OK bool `json:"ok"`
	Output string `json:"output"`
}

const version = "0.1.0-web-experimental"
const defaultConfig = "/opt/etc/xray/xray-web-agent.conf"

func main() {
	cfgPath := flag.String("config", defaultConfig, "config path")
	once := flag.Bool("once", false, "run once")
	flag.Parse()
	cfg, err := loadConfig(*cfgPath)
	if err != nil { fatal("config: %v", err) }
	logf("xray-web-agent started version=%s router_id=%s server=%s", version, cfg.RouterID, cfg.ServerURL)
	_ = postHeartbeat(cfg)
	for {
		if err := pollOnce(cfg); err != nil { logf("poll failed: %v", err) }
		if *once { return }
		time.Sleep(cfg.PollInterval)
	}
}

func loadConfig(path string) (Config, error) {
	b, err := os.ReadFile(path); if err != nil { return Config{}, err }
	m := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") { continue }
		parts := strings.SplitN(line, "=", 2)
		k := strings.TrimSpace(parts[0])
		v := strings.Trim(strings.TrimSpace(parts[1]), "\"")
		m[k] = v
	}
	pi := 10 * time.Second
	if v := m["POLL_INTERVAL"]; v != "" { if d, err := time.ParseDuration(v+"s"); err == nil { pi = d } }
	cfg := Config{ServerURL:m["SERVER_URL"], RouterID:m["ROUTER_ID"], RouterName:m["ROUTER_NAME"], AgentToken:m["AGENT_TOKEN"], PollInterval:pi}
	if cfg.ServerURL == "" || cfg.RouterID == "" || cfg.AgentToken == "" { return cfg, fmt.Errorf("SERVER_URL, ROUTER_ID and AGENT_TOKEN are required") }
	if cfg.RouterName == "" { cfg.RouterName = cfg.RouterID }
	return cfg, nil
}

func pollOnce(cfg Config) error {
	hb := makeHeartbeat(cfg)
	payload, _ := json.Marshal(hb)
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(cfg.ServerURL,"/")+"/api/agent/poll", bytes.NewReader(payload)); if err != nil { return err }
	req.Header.Set("Content-Type", "application/json"); req.Header.Set("Authorization", "Bearer "+cfg.AgentToken)
	resp, err := http.DefaultClient.Do(req); if err != nil { return err }
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK { b,_:=io.ReadAll(resp.Body); return fmt.Errorf("poll status %s: %s", resp.Status, strings.TrimSpace(string(b))) }
	var pr PollResponse
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil { return err }
	if pr.Command == nil || pr.Command.ID == "" { return nil }
	ok, out := runCommand(*pr.Command)
	return postResult(cfg, Result{RouterID:cfg.RouterID, CommandID:pr.Command.ID, OK:ok, Output:redact(out, pr.Command.Source)})
}

func postHeartbeat(cfg Config) error {
	payload,_ := json.Marshal(makeHeartbeat(cfg))
	return postJSON(cfg, "/api/agent/heartbeat", payload)
}

func postResult(cfg Config, res Result) error { payload,_ := json.Marshal(res); return postJSON(cfg, "/api/agent/result", payload) }

func postJSON(cfg Config, path string, payload []byte) error {
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(cfg.ServerURL,"/")+path, bytes.NewReader(payload)); if err != nil { return err }
	req.Header.Set("Content-Type", "application/json"); req.Header.Set("Authorization", "Bearer "+cfg.AgentToken)
	resp, err := http.DefaultClient.Do(req); if err != nil { return err }
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK { b,_:=io.ReadAll(resp.Body); return fmt.Errorf("post status %s: %s", resp.Status, strings.TrimSpace(string(b))) }
	return nil
}

func makeHeartbeat(cfg Config) Heartbeat {
	ok, status := runBest(statusCommands(), 12*time.Second)
	summary := oneLine(status)
	state := "OK"; if !ok { state = "DEGRADED" }
	return Heartbeat{RouterID:cfg.RouterID, RouterName:cfg.RouterName, AgentVersion:version, Arch:runtime.GOARCH, Status:state, Capabilities:capabilities(), Summary:summary}
}

func capabilities() []string { return []string{"status","source_status","switch_primary","switch_backup","update_subscription","update_scripts","doctor","recover_status","recover_run","recover_enable","recover_disable","history","watchdog_log","recovery_log","agent_result_log","reboot"} }

func runCommand(c Command) (bool,string) {
	switch c.Action {
	case "status", "source_status": return runBest(statusCommands(), 25*time.Second)
	case "doctor": return runBest([][]string{{"/opt/bin/xray-go","doctor","--support"},{"/opt/bin/vless-go-recover","status"},{"/opt/bin/minimal-go-status"}}, 45*time.Second)
	case "switch_primary": return runBest([][]string{{"/opt/bin/xray-go","switch","primary"},{"/opt/bin/minimal-go-switch","primary"},{"/opt/bin/vless-go-failover","switch","primary","--first"}}, 45*time.Second)
	case "switch_backup": return runBest([][]string{{"/opt/bin/xray-go","switch","backup"},{"/opt/bin/minimal-go-switch","backup"},{"/opt/bin/vless-go-failover","switch","backup","--first"}}, 45*time.Second)
	case "update_subscription": return runBest([][]string{{"/opt/bin/vless-go-auto-update","run"},{"/opt/bin/vless-go-failover","update-active"},{"/opt/bin/vless-go-update"},{"/opt/bin/minimal-go-switch", activeSlot()}}, 60*time.Second)
	case "update_scripts": return runScriptUpdate()
	case "update_agent": return runAgentUpdate()
	case "recover_status": return runBest([][]string{{"/opt/bin/vless-go-recover","status"}}, 30*time.Second)
	case "recover_run": return runBest([][]string{{"/opt/bin/vless-go-recover","run"}}, 90*time.Second)
	case "recover_enable": return runBest([][]string{{"/opt/bin/vless-go-recover","enable-hourly"}}, 30*time.Second)
	case "recover_disable": return runBest([][]string{{"/opt/bin/vless-go-recover","disable-hourly"}}, 30*time.Second)
	case "history": return runBest([][]string{{"/opt/bin/xray-go","history"},{"/opt/bin/vless-go-history","tail","80"}}, 30*time.Second)
	case "watchdog_log": return tailFile("/opt/var/log/vless-go-watchdog.log", 120)
	case "recovery_log": return tailFile("/opt/var/log/vless-go-recover.log", 120)
	case "agent_result_log": return tailFile("/opt/var/log/xray-web-agent.log", 120)
	case "reboot": go func(){ time.Sleep(2*time.Second); exec.Command("reboot").Run() }(); return true, "Router reboot scheduled"
	default: return false, "unknown action: "+c.Action
	}
}

func statusCommands() [][]string { return [][]string{{"/opt/bin/xray-go","status"},{"/opt/bin/minimal-go-status"},{"/opt/bin/vless-go-recover","status"}} }

func runBest(cmds [][]string, timeout time.Duration) (bool,string) {
	last := ""
	for _, cmd := range cmds { if len(cmd)==0 || cmd[0]=="" || !exists(cmd[0]) { continue }; ok,out := run(cmd, timeout); if ok { return true,out }; last = out }
	if last == "" { last = "no supported command found" }
	return false,last
}

func run(cmd []string, timeout time.Duration) (bool,string) {
	c := exec.Command(cmd[0], cmd[1:]...)
	done := make(chan struct{}); var out []byte; var err error
	go func(){ out,err = c.CombinedOutput(); close(done) }()
	select { case <-done: return err==nil, string(out); case <-time.After(timeout): _=c.Process.Kill(); return false, "command timeout: "+strings.Join(cmd," ") }
}

func runScriptUpdate() (bool,string) {
	url := "https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh"
	dst := "/opt/tmp/xray_vless_failover_auto_latest.sh"
	os.MkdirAll("/opt/tmp",0755)
	ok,out := run([]string{"/opt/bin/curl","-fsSL","-o",dst,url}, 60*time.Second); if !ok { return ok,out }
	os.Chmod(dst,0755)
	return run([]string{dst,"--update-only","--no-restart"}, 120*time.Second)
}

func runAgentUpdate() (bool,string) {
	url := "https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/web-control-experiment/scripts/xray-web-agent-install.sh"
	dst := "/opt/tmp/xray-web-agent-install.sh"
	os.MkdirAll("/opt/tmp",0755)
	ok,out := run([]string{"/opt/bin/curl","-fsSL","-o",dst,url}, 60*time.Second); if !ok { return ok,out }
	os.Chmod(dst,0755)
	go exec.Command(dst).Run()
	return true, "Web agent update scheduled in background"
}

func activeSlot() string { for _, p := range []string{"/opt/etc/xray/minimal-go-active","/opt/etc/xray/vless-go.active"} { if b,e:=os.ReadFile(p); e==nil { s:=strings.TrimSpace(string(b)); if s!="" { return s } } }; return "primary" }
func tailFile(path string, n int) (bool,string) { if !exists(path) { return false,"not found: "+path }; return run([]string{"/opt/bin/tail","-n",fmt.Sprint(n),path}, 10*time.Second) }
func exists(p string) bool { _,err:=os.Stat(p); return err==nil }
func oneLine(s string) string { s=strings.TrimSpace(strings.ReplaceAll(s,"\r","")); if i:=strings.IndexByte(s,'\n'); i>=0 { s=s[:i] }; if len(s)>220 { s=s[:220] }; return s }
func redact(out, secret string) string { if secret != "" { out = strings.ReplaceAll(out, secret, "***") }; return out }
func logf(f string, a ...any) { line := time.Now().Format("2006-01-02 15:04:05 ")+fmt.Sprintf(f,a...)+"\n"; os.MkdirAll("/opt/var/log",0755); file,_:=os.OpenFile("/opt/var/log/xray-web-agent.log",os.O_CREATE|os.O_APPEND|os.O_WRONLY,0644); if file!=nil { defer file.Close(); file.WriteString(line) } }
func fatal(f string, a ...any) { logf(f,a...); fmt.Fprintf(os.Stderr, f+"\n", a...); os.Exit(1) }
