package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	Listen      string
	BotToken    string
	AdminUserID int64
	Routers     map[string]*Router
}

type Router struct {
	ID       string
	Name     string
	Token    string
	LastSeen time.Time
	Status   string
	Queue    []Command
	Results  []Result
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
	At        string `json:"at,omitempty"`
}

type Server struct {
	cfg       Config
	mu        sync.Mutex
	lastUpdID int64
}

func main() {
	cfgPath := flag.String("config", "/etc/xray-go-control-server.conf", "config path")
	flag.Parse()
	cfg, err := loadConfig(*cfgPath)
	if err != nil { log.Fatalf("config: %v", err) }
	s := &Server{cfg: cfg}
	mux := http.NewServeMux()
	mux.HandleFunc("/agent/poll", s.handlePoll)
	mux.HandleFunc("/agent/result", s.handleResult)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("OK\n")) })
	go s.telegramLoop()
	log.Printf("xray-go-control-server listen=%s routers=%d", cfg.Listen, len(cfg.Routers))
	log.Fatal(http.ListenAndServe(cfg.Listen, mux))
}

func (s *Server) handlePoll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost { http.Error(w, "POST required", http.StatusMethodNotAllowed); return }
	rt := s.authRouter(r)
	if rt == nil { http.Error(w, "unauthorized", http.StatusUnauthorized); return }
	var hb struct{ RouterID, Name, Status string }
	_ = json.NewDecoder(r.Body).Decode(&hb)
	s.mu.Lock()
	rt.LastSeen = time.Now()
	if hb.Status != "" { rt.Status = hb.Status }
	var cmd *Command
	if len(rt.Queue) > 0 {
		c := rt.Queue[0]
		rt.Queue = rt.Queue[1:]
		cmd = &c
	}
	s.mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]any{"command": cmd})
}

func (s *Server) handleResult(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost { http.Error(w, "POST required", http.StatusMethodNotAllowed); return }
	rt := s.authRouter(r)
	if rt == nil { http.Error(w, "unauthorized", http.StatusUnauthorized); return }
	var res Result
	if err := json.NewDecoder(r.Body).Decode(&res); err != nil { http.Error(w, err.Error(), http.StatusBadRequest); return }
	res.At = time.Now().Format("2006-01-02 15:04:05")
	s.mu.Lock()
	rt.Results = append(rt.Results, res)
	if len(rt.Results) > 20 { rt.Results = rt.Results[len(rt.Results)-20:] }
	s.mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]string{"ok": "1"})
	if s.cfg.BotToken != "" && s.cfg.AdminUserID != 0 {
		status := "OK"
		if !res.OK { status = "FAIL" }
		msg := fmt.Sprintf("%s: %s %s\n%s", rt.Name, status, res.CommandID, limit(res.Output, 3500))
		s.sendMessage(s.cfg.AdminUserID, msg)
	}
}

func (s *Server) authRouter(r *http.Request) *Router {
	auth := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if auth == "" { return nil }
	s.mu.Lock(); defer s.mu.Unlock()
	for _, rt := range s.cfg.Routers {
		if rt.Token == auth { return rt }
	}
	return nil
}

func (s *Server) telegramLoop() {
	if s.cfg.BotToken == "" || s.cfg.AdminUserID == 0 { return }
	for {
		updates, err := s.getUpdates()
		if err != nil { log.Printf("telegram: %v", err); time.Sleep(5*time.Second); continue }
		for _, u := range updates { s.handleTelegramUpdate(u) }
	}
}

type tgUpdate struct { UpdateID int64 `json:"update_id"`; Message *tgMessage `json:"message"` }
type tgMessage struct { Chat tgChat `json:"chat"`; From tgUser `json:"from"`; Text string `json:"text"` }
type tgChat struct { ID int64 `json:"id"` }
type tgUser struct { ID int64 `json:"id"` }

func (s *Server) getUpdates() ([]tgUpdate, error) {
	url := fmt.Sprintf("https://api.telegram.org/bot%s/getUpdates?timeout=25&offset=%d", s.cfg.BotToken, s.lastUpdID+1)
	resp, err := http.Get(url)
	if err != nil { return nil, err }
	defer resp.Body.Close()
	var data struct { OK bool `json:"ok"`; Result []tgUpdate `json:"result"` }
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil { return nil, err }
	for _, u := range data.Result { if u.UpdateID > s.lastUpdID { s.lastUpdID = u.UpdateID } }
	return data.Result, nil
}

func (s *Server) handleTelegramUpdate(u tgUpdate) {
	if u.Message == nil || strings.TrimSpace(u.Message.Text) == "" { return }
	if u.Message.From.ID != s.cfg.AdminUserID { s.sendMessage(u.Message.Chat.ID, "Access denied"); return }
	chatID := u.Message.Chat.ID
	text := strings.TrimSpace(u.Message.Text)
	if text == "/start" || text == "/help" { s.sendMessage(chatID, helpText()); return }
	if text == "/routers" { s.sendMessage(chatID, s.routerList()); return }
	if strings.HasPrefix(text, "/results_") { s.sendMessage(chatID, s.results(strings.TrimPrefix(text, "/results_"))); return }
	if strings.HasPrefix(text, "/set_primary_") { s.handleSetSource(chatID, text, "primary"); return }
	if strings.HasPrefix(text, "/set_backup_") { s.handleSetSource(chatID, text, "backup"); return }
	if strings.HasPrefix(text, "/") { s.handleCommand(chatID, text); return }
	s.sendMessage(chatID, "Неизвестная команда. /help")
}

func (s *Server) handleCommand(chatID int64, text string) {
	name, routerID, ok := parseCmdRouter(text)
	if !ok { s.sendMessage(chatID, "Формат: /status_home или /doctor_home. Список: /routers"); return }
	action := map[string]string{
		"status": "status", "doctor": "doctor", "switch_primary": "switch_primary", "switch_backup": "switch_backup",
		"recover_status": "recover_status", "recover_check": "recover_check", "recover": "recover_run", "recover_enable": "recover_enable", "recover_disable": "recover_disable",
		"history": "history", "watchdog": "watchdog_log", "recoverylog": "recovery_log", "source_status": "source_status",
	}[name]
	if action == "" { s.sendMessage(chatID, "Команда не поддерживается: "+name); return }
	id, err := s.enqueue(routerID, Command{Action: action})
	if err != nil { s.sendMessage(chatID, err.Error()); return }
	s.sendMessage(chatID, "Команда поставлена в очередь: "+id)
}

func (s *Server) handleSetSource(chatID int64, text, slot string) {
	prefix := "/set_" + slot + "_"
	rest := strings.TrimPrefix(text, prefix)
	parts := strings.Fields(rest)
	if len(parts) < 3 { s.sendMessage(chatID, "Формат: "+prefix+"<router> <selector> <url>"); return }
	routerID := parts[0]
	selector := parts[1]
	source := strings.Join(parts[2:], " ")
	action := "set_primary_source"
	if slot == "backup" { action = "set_backup_source" }
	id, err := s.enqueue(routerID, Command{Action: action, Selector: selector, Source: source})
	if err != nil { s.sendMessage(chatID, err.Error()); return }
	s.sendMessage(chatID, "Источник поставлен в очередь: "+id+" (значение скрыто)")
}

func parseCmdRouter(text string) (string, string, bool) {
	text = strings.TrimPrefix(strings.Fields(text)[0], "/")
	idx := strings.LastIndex(text, "_")
	if idx < 0 { return "", "", false }
	return text[:idx], text[idx+1:], true
}

func (s *Server) enqueue(routerID string, c Command) (string, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	rt := s.cfg.Routers[routerID]
	if rt == nil { return "", fmt.Errorf("unknown router: %s", routerID) }
	c.ID = fmt.Sprintf("%s-%d", c.Action, time.Now().Unix())
	rt.Queue = append(rt.Queue, c)
	return c.ID, nil
}

func (s *Server) routerList() string {
	s.mu.Lock(); defer s.mu.Unlock()
	lines := []string{"Роутеры:"}
	for _, rt := range s.cfg.Routers {
		state := "offline"
		if time.Since(rt.LastSeen) < 30*time.Second { state = "online" }
		lines = append(lines, fmt.Sprintf("%s (%s): %s\n  %s", rt.Name, rt.ID, state, rt.Status))
	}
	return strings.Join(lines, "\n")
}

func (s *Server) results(routerID string) string {
	s.mu.Lock(); defer s.mu.Unlock()
	rt := s.cfg.Routers[routerID]
	if rt == nil { return "unknown router" }
	if len(rt.Results) == 0 { return "результатов пока нет" }
	out := []string{}
	for _, r := range rt.Results { out = append(out, fmt.Sprintf("[%s] %s ok=%v\n%s", r.At, r.CommandID, r.OK, limit(r.Output, 900))) }
	return strings.Join(out, "\n---\n")
}

func (s *Server) sendMessage(chatID int64, text string) {
	if s.cfg.BotToken == "" { return }
	payload, _ := json.Marshal(map[string]any{"chat_id": chatID, "text": limit(text, 3900)})
	url := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", s.cfg.BotToken)
	resp, err := http.Post(url, "application/json", bytes.NewReader(payload))
	if err != nil { log.Printf("sendMessage: %v", err); return }
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
}

func helpText() string {
	return strings.TrimSpace(`Команды:
/routers
/status_<router>
/doctor_<router>
/switch_primary_<router>
/switch_backup_<router>
/recover_status_<router>
/recover_check_<router>
/recover_<router>
/recover_enable_<router>
/recover_disable_<router>
/history_<router>
/watchdog_<router>
/recoverylog_<router>
/source_status_<router>
/results_<router>
/set_primary_<router> <selector> <url>
/set_backup_<router> <selector> <url>`)
}

func loadConfig(path string) (Config, error) {
	cfg := Config{Listen: ":18090", Routers: map[string]*Router{}}
	data, err := os.ReadFile(path)
	if err != nil { return cfg, err }
	vals := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") { continue }
		k, v, ok := strings.Cut(line, "=")
		if !ok { continue }
		vals[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), "\"")
	}
	if vals["LISTEN"] != "" { cfg.Listen = vals["LISTEN"] }
	cfg.BotToken = vals["BOT_TOKEN"]
	if vals["ADMIN_USER_ID"] != "" { cfg.AdminUserID, _ = strconv.ParseInt(vals["ADMIN_USER_ID"], 10, 64) }
	for _, item := range strings.Split(vals["ROUTERS"], ",") {
		parts := strings.SplitN(strings.TrimSpace(item), ":", 3)
		if len(parts) < 2 { continue }
		name := parts[0]
		if len(parts) == 3 { name = parts[2] }
		cfg.Routers[parts[0]] = &Router{ID: parts[0], Token: parts[1], Name: name}
	}
	if cfg.BotToken == "" || cfg.AdminUserID == 0 { return cfg, fmt.Errorf("BOT_TOKEN and ADMIN_USER_ID are required") }
	if len(cfg.Routers) == 0 { return cfg, fmt.Errorf("ROUTERS is required") }
	return cfg, nil
}

func limit(s string, n int) string { if len(s) <= n { return s }; return s[:n] + "\n...truncated..." }
