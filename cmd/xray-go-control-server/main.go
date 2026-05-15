package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	ConfigPath  string
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
	if err != nil {
		log.Fatalf("config: %v", err)
	}
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
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	rt := s.authRouter(r)
	if rt == nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var hb struct{ RouterID, Name, Status string }
	_ = json.NewDecoder(r.Body).Decode(&hb)
	s.mu.Lock()
	rt.LastSeen = time.Now()
	if hb.Status != "" {
		rt.Status = hb.Status
	}
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
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	rt := s.authRouter(r)
	if rt == nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var res Result
	if err := json.NewDecoder(r.Body).Decode(&res); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	res.At = time.Now().Format("2006-01-02 15:04:05")
	s.mu.Lock()
	rt.Results = append(rt.Results, res)
	if len(rt.Results) > 20 {
		rt.Results = rt.Results[len(rt.Results)-20:]
	}
	s.mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]string{"ok": "1"})
	if s.cfg.BotToken != "" && s.cfg.AdminUserID != 0 {
		s.sendMessage(s.cfg.AdminUserID, prettyResultMessage(rt.Name, res))
	}
}

func (s *Server) authRouter(r *http.Request) *Router {
	auth := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if auth == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, rt := range s.cfg.Routers {
		if rt.Token == auth {
			return rt
		}
	}
	return nil
}

func (s *Server) telegramLoop() {
	if s.cfg.BotToken == "" || s.cfg.AdminUserID == 0 {
		return
	}
	if err := s.setBotCommands(); err != nil {
		log.Printf("telegram setMyCommands: %v", err)
	}
	for {
		updates, err := s.getUpdates()
		if err != nil {
			log.Printf("telegram: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}
		for _, u := range updates {
			s.handleTelegramUpdate(u)
		}
	}
}

type tgUpdate struct {
	UpdateID      int64            `json:"update_id"`
	Message       *tgMessage       `json:"message"`
	CallbackQuery *tgCallbackQuery `json:"callback_query"`
}
type tgMessage struct {
	Chat tgChat `json:"chat"`
	From tgUser `json:"from"`
	Text string `json:"text"`
}
type tgChat struct {
	ID int64 `json:"id"`
}
type tgUser struct {
	ID int64 `json:"id"`
}
type tgCallbackQuery struct {
	ID      string     `json:"id"`
	From    tgUser     `json:"from"`
	Message *tgMessage `json:"message"`
	Data    string     `json:"data"`
}

type inlineKeyboard struct {
	InlineKeyboard [][]inlineButton `json:"inline_keyboard"`
}
type inlineButton struct {
	Text         string `json:"text"`
	CallbackData string `json:"callback_data"`
}

func (s *Server) setBotCommands() error {
	payload := map[string]any{
		"commands": []map[string]string{
			{"command": "menu", "description": "Открыть меню управления"},
			{"command": "routers", "description": "Список роутеров"},
			{"command": "add_router", "description": "Добавить роутер"},
			{"command": "help", "description": "Помощь"},
		},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	url := fmt.Sprintf("https://api.telegram.org/bot%s/setMyCommands", s.cfg.BotToken)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("telegram setMyCommands status=%s body=%s", resp.Status, string(b))
	}

	var data struct {
		OK          bool   `json:"ok"`
		Description string `json:"description"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return err
	}
	if !data.OK {
		return fmt.Errorf("telegram setMyCommands failed: %s", data.Description)
	}
	return nil
}

func (s *Server) getUpdates() ([]tgUpdate, error) {
	url := fmt.Sprintf("https://api.telegram.org/bot%s/getUpdates?timeout=25&offset=%d", s.cfg.BotToken, s.lastUpdID+1)
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var data struct {
		OK     bool       `json:"ok"`
		Result []tgUpdate `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	for _, u := range data.Result {
		if u.UpdateID > s.lastUpdID {
			s.lastUpdID = u.UpdateID
		}
	}
	return data.Result, nil
}

func (s *Server) handleTelegramUpdate(u tgUpdate) {
	if u.CallbackQuery != nil {
		s.handleCallback(u.CallbackQuery)
		return
	}
	if u.Message == nil || strings.TrimSpace(u.Message.Text) == "" {
		return
	}
	if u.Message.From.ID != s.cfg.AdminUserID {
		s.sendMessage(u.Message.Chat.ID, "Access denied")
		return
	}
	chatID := u.Message.Chat.ID
	text := strings.TrimSpace(u.Message.Text)
	if text == "/cancel" {
		wizardCancel(chatID)
		s.sendMessage(chatID, "Диалог отменён.")
		return
	}
	if s.handleWizardText(chatID, text) {
		return
	}
	if text == "/start" || text == "/menu" {
		s.sendMainMenu(chatID)
		return
	}
	if text == "/help" {
		s.sendMessageWithKeyboard(chatID, helpText(), mainMenuKeyboard())
		return
	}
	if text == "/routers" {
		s.sendMessageWithKeyboard(chatID, s.routerList(), s.routersKeyboard())
		return
	}
	if strings.HasPrefix(text, "/add_router") {
		s.handleAddRouter(chatID, text)
		return
	}
	if strings.HasPrefix(text, "/results_") {
		s.sendMessage(chatID, s.results(strings.TrimPrefix(text, "/results_")))
		return
	}
	if strings.HasPrefix(text, "/set_primary_") {
		s.handleSetSource(chatID, text, "primary")
		return
	}
	if strings.HasPrefix(text, "/set_backup_") {
		s.handleSetSource(chatID, text, "backup")
		return
	}
	if strings.HasPrefix(text, "/") {
		s.handleCommand(chatID, text)
		return
	}
	s.sendMessageWithKeyboard(chatID, "Неизвестная команда. Нажми /menu или выбери действие.", mainMenuKeyboard())
}

func (s *Server) handleCallback(cb *tgCallbackQuery) {
	if cb.From.ID != s.cfg.AdminUserID {
		s.answerCallback(cb.ID, "Access denied")
		return
	}
	chatID := s.cfg.AdminUserID
	if cb.Message != nil {
		chatID = cb.Message.Chat.ID
	}
	data := cb.Data
	s.answerCallback(cb.ID, "")
	switch {
	case data == "menu":
		s.sendMainMenu(chatID)
	case data == "help":
		s.sendMessageWithKeyboard(chatID, helpText(), mainMenuKeyboard())
	case data == "routers":
		s.sendMessageWithKeyboard(chatID, s.routerList(), s.routersKeyboard())
	case data == "add_router_help":
		s.startAddRouterWizard(chatID)
	case strings.HasPrefix(data, "install:"):
		routerID := strings.TrimPrefix(data, "install:")
		s.sendAgentInstallMenu(chatID, routerID)
	case strings.HasPrefix(data, "install-go:"):
		routerID := strings.TrimPrefix(data, "install-go:")
		s.sendAgentInstallCommand(chatID, routerID, "go")
	case strings.HasPrefix(data, "install-shell:"):
		routerID := strings.TrimPrefix(data, "install-shell:")
		s.sendAgentInstallCommand(chatID, routerID, "shell")
	case strings.HasPrefix(data, "sources:"):
		routerID := strings.TrimPrefix(data, "sources:")
		s.sendSourceMenu(chatID, routerID)
	case strings.HasPrefix(data, "setsrc:"):
		parts := strings.SplitN(data, ":", 3)
		if len(parts) == 3 {
			s.startSetSourceWizard(chatID, parts[2], parts[1])
		}
	case strings.HasPrefix(data, "delete-router:"):
		routerID := strings.TrimPrefix(data, "delete-router:")
		s.sendDeleteRouterConfirm(chatID, routerID)
	case strings.HasPrefix(data, "confirm-delete-router:"):
		routerID := strings.TrimPrefix(data, "confirm-delete-router:")
		s.deleteRouter(chatID, routerID)
	case strings.HasPrefix(data, "router:"):
		routerID := strings.TrimPrefix(data, "router:")
		s.sendRouterMenu(chatID, routerID)
	case strings.HasPrefix(data, "act:"):
		s.handleActionCallback(chatID, data)
	default:
		s.sendMessageWithKeyboard(chatID, "Неизвестная кнопка", mainMenuKeyboard())
	}
}

func (s *Server) sendMainMenu(chatID int64) {
	s.sendMessageWithKeyboard(chatID, prettyMainMenuText(), mainMenuKeyboard())
}

func mainMenuKeyboard() inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "📡 Роутеры", CallbackData: "routers"}, {Text: "➕ Добавить роутер", CallbackData: "add_router_help"}},
		{{Text: "🔄 Обновить", CallbackData: "routers"}, {Text: "❔ Помощь", CallbackData: "help"}},
	}}
}

func (s *Server) routersKeyboard() inlineKeyboard {
	s.mu.Lock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id := range s.cfg.Routers {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	rows := [][]inlineButton{}
	for _, id := range ids {
		rt := s.cfg.Routers[id]
		text := id
		if rt != nil && strings.TrimSpace(rt.Name) != "" {
			text = rt.Name
		}
		if rt != nil {
			dot, _ := onlineState(rt.LastSeen)
			text = dot + " " + text
		}
		rows = append(rows, []inlineButton{{Text: text, CallbackData: "router:" + id}})
	}
	s.mu.Unlock()

	rows = append(rows, []inlineButton{{Text: "🔄 Обновить", CallbackData: "routers"}, {Text: "⬅️ Назад", CallbackData: "menu"}})
	return inlineKeyboard{InlineKeyboard: rows}
}

func routerKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "📊 Статус", CallbackData: "act:status:" + routerID}, {Text: "🩺 Doctor", CallbackData: "act:doctor:" + routerID}},
		{{Text: "⬆️ Основной", CallbackData: "act:switch_primary:" + routerID}, {Text: "⬇️ Резерв", CallbackData: "act:switch_backup:" + routerID}},
		{{Text: "🔗 Источники", CallbackData: "sources:" + routerID}},
		{{Text: "🛡 Recovery status", CallbackData: "act:recover_status:" + routerID}, {Text: "♻️ Recover now", CallbackData: "act:recover:" + routerID}},
		{{Text: "🕘 History", CallbackData: "act:history:" + routerID}, {Text: "👁 Watchdog log", CallbackData: "act:watchdog:" + routerID}},
		{{Text: "📄 Recovery log", CallbackData: "act:recoverylog:" + routerID}, {Text: "📬 Results", CallbackData: "act:results:" + routerID}},
		{{Text: "🔄 Перезагрузить роутер", CallbackData: "act:reboot:" + routerID}},
		{{Text: "📦 Установка агента", CallbackData: "install:" + routerID}},
		{{Text: "🗑 Удалить роутер", CallbackData: "delete-router:" + routerID}},
		{{Text: "⬅️ Назад", CallbackData: "routers"}, {Text: "🏠 Главное меню", CallbackData: "menu"}},
	}}
}

func (s *Server) routerKeyboardCurrent(routerID string) inlineKeyboard {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	status := ""
	if rt != nil {
		status = rt.Status
	}
	s.mu.Unlock()
	if status == "" {
		return routerKeyboard(routerID)
	}
	return routerKeyboardForStatus(routerID, status)
}

func (s *Server) sendRouterMenu(chatID int64, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	card := prettyRouterCard(rt)
	status := ""
	if rt != nil {
		status = rt.Status
	}
	s.mu.Unlock()
	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "unknown router: "+routerID, s.routersKeyboard())
		return
	}
	s.sendMessageWithKeyboard(chatID, card, routerKeyboardForStatus(routerID, status))
}

func (s *Server) handleActionCallback(chatID int64, data string) {
	parts := strings.SplitN(data, ":", 3)
	if len(parts) != 3 {
		s.sendMessageWithKeyboard(chatID, "Некорректная кнопка", mainMenuKeyboard())
		return
	}
	name, routerID := parts[1], parts[2]
	if name == "results" {
		s.mu.Lock()
		rt := s.cfg.Routers[routerID]
		status := ""
		if rt != nil {
			status = rt.Status
		}
		s.mu.Unlock()
		s.sendMessageWithKeyboard(chatID, s.results(routerID), routerKeyboardForStatus(routerID, status))
		return
	}
	action := callbackAction(name)
	if action == "" {
		s.sendMessageWithKeyboard(chatID, "Действие не поддерживается: "+name, s.routerKeyboardCurrent(routerID))
		return
	}
	id, err := s.enqueue(routerID, Command{Action: action})
	if err != nil {
		s.sendMessageWithKeyboard(chatID, err.Error(), s.routersKeyboard())
		return
	}
	s.sendMessageWithKeyboard(chatID, "📨 Команда поставлена в очередь:\n"+id, s.routerKeyboardCurrent(routerID))
}

func callbackAction(name string) string {
	return map[string]string{
		"status": "status", "doctor": "doctor", "switch_primary": "switch_primary", "switch_backup": "switch_backup",
		"recover_status": "recover_status", "recover_check": "recover_check", "recover": "recover_run", "recover_enable": "recover_enable", "recover_disable": "recover_disable",
		"history": "history", "watchdog": "watchdog_log", "recoverylog": "recovery_log", "source_status": "source_status", "reboot": "reboot",
	}[name]
}

func (s *Server) routerIDs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id := range s.cfg.Routers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func (s *Server) handleCommand(chatID int64, text string) {
	name, routerID, ok := parseCmdRouter(text)
	if !ok {
		s.sendMessage(chatID, "Формат: /status_home или /doctor_home. Список: /routers")
		return
	}
	action := callbackAction(name)
	if action == "" {
		s.sendMessage(chatID, "Команда не поддерживается: "+name)
		return
	}
	id, err := s.enqueue(routerID, Command{Action: action})
	if err != nil {
		s.sendMessage(chatID, err.Error())
		return
	}
	s.sendMessage(chatID, "📨 Команда поставлена в очередь:\n"+id)
}

func (s *Server) handleAddRouter(chatID int64, text string) {
	parts := strings.Fields(text)
	if len(parts) < 2 {
		s.sendMessageWithKeyboard(chatID, "Формат: /add_router <router_id> [имя]\nПример: /add_router dacha Дача", mainMenuKeyboard())
		return
	}
	routerID := parts[1]
	if !validRouterID(routerID) {
		s.sendMessage(chatID, "router_id должен содержать только латинские буквы, цифры, _ или -. Пример: dacha")
		return
	}
	name := routerID
	if len(parts) > 2 {
		name = strings.Join(parts[2:], " ")
	}
	token, err := randomTokenHex(24)
	if err != nil {
		s.sendMessage(chatID, "Не удалось сгенерировать token: "+err.Error())
		return
	}
	s.mu.Lock()
	if _, exists := s.cfg.Routers[routerID]; exists {
		s.mu.Unlock()
		s.sendMessage(chatID, "Роутер уже существует: "+routerID)
		return
	}
	s.cfg.Routers[routerID] = &Router{ID: routerID, Name: name, Token: token}
	err = s.persistConfigLocked()
	if err != nil {
		delete(s.cfg.Routers, routerID)
	}
	s.mu.Unlock()
	if err != nil {
		s.sendMessage(chatID, "Роутер не сохранён: "+err.Error()+"\nПроверь права: /etc/xray-go-control-server.conf должен быть writable для группы xraygo.")
		return
	}
	msg := fmt.Sprintf("✅ Роутер добавлен\n\n📡 %s\nID: %s\n\nAgent token:\n%s\n\nОткрой меню роутера и нажми 📦 Установка агента.", name, routerID, token)
	s.sendMessageWithKeyboard(chatID, msg, routerKeyboard(routerID))
}

func (s *Server) handleSetSource(chatID int64, text, slot string) {
	prefix := "/set_" + slot + "_"
	rest := strings.TrimPrefix(text, prefix)
	parts := strings.Fields(rest)
	if len(parts) < 3 {
		s.sendMessage(chatID, "Формат: "+prefix+"<router> <selector> <url>")
		return
	}
	routerID := parts[0]
	selector := normalizeSelector(parts[1])
	source := strings.Join(parts[2:], " ")
	action := "set_primary_source"
	if slot == "backup" {
		action = "set_backup_source"
	}
	id, err := s.enqueue(routerID, Command{Action: action, Selector: selector, Source: source})
	if err != nil {
		s.sendMessage(chatID, err.Error())
		return
	}
	s.sendMessage(chatID, "🔗 Источник поставлен в очередь:\n"+id+"\n\nЗначение скрыто.")
}

func parseCmdRouter(text string) (string, string, bool) {
	text = strings.TrimPrefix(strings.Fields(text)[0], "/")
	idx := strings.LastIndex(text, "_")
	if idx < 0 {
		return "", "", false
	}
	return text[:idx], text[idx+1:], true
}

func (s *Server) enqueue(routerID string, c Command) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rt := s.cfg.Routers[routerID]
	if rt == nil {
		return "", fmt.Errorf("unknown router: %s", routerID)
	}
	c.ID = fmt.Sprintf("%s-%d", c.Action, time.Now().Unix())
	rt.Queue = append(rt.Queue, c)
	return c.ID, nil
}

func (s *Server) routerList() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id := range s.cfg.Routers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	online := 0
	items := []string{}
	for _, id := range ids {
	rt := s.cfg.Routers[id]
		if rt != nil && time.Since(rt.LastSeen) < 30*time.Second {
			online++
		}
	}
	items = append(items, prettyRouterListHeader(len(ids), online))
	for _, id := range ids {
		rt := s.cfg.Routers[id]
		if rt == nil {
			continue
		}
		name := id
		if strings.TrimSpace(rt.Name) != "" {
			name = rt.Name
		}
		items = append(items, prettyRouterListItem(name, rt.LastSeen, rt.Status))
	}
	return strings.Join(items, "\n")
}

func (s *Server) results(routerID string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	rt := s.cfg.Routers[routerID]
	if rt == nil {
		return "unknown router: " + routerID
	}
	if len(rt.Results) == 0 {
		return "Результатов пока нет."
	}
	lines := []string{"📬 Последние результаты: " + rt.Name}
	for _, r := range rt.Results {
		status := "✅ OK"
		if !r.OK {
			status = "❌ FAIL"
		}
		out := strings.TrimSpace(r.Output)
		if len(out) > 3500 {
			out = out[:3500] + "\n..."
		}
		lines = append(lines, fmt.Sprintf("\n%s %s\n%s", status, r.CommandID, out))
	}
	return strings.Join(lines, "\n")
}

func (s *Server) sendAgentInstallMenu(chatID int64, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	s.mu.Unlock()
	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "unknown router: "+routerID, s.routersKeyboard())
		return
	}
	kb := inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "🤖 Go agent", CallbackData: "install-go:" + routerID}, {Text: "🐚 Shell agent", CallbackData: "install-shell:" + routerID}},
		{{Text: "⬅️ Назад", CallbackData: "router:" + routerID}},
	}}
	text := fmt.Sprintf("📦 Установка агента для %s\n\nGo agent: для поддерживаемых arch.\nShell agent: fallback для MIPS/старых Entware.", rt.Name)
	s.sendMessageWithKeyboard(chatID, text, kb)
}

func (s *Server) sendAgentInstallCommand(chatID int64, routerID, agentType string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	s.mu.Unlock()
	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "unknown router: "+routerID, s.routersKeyboard())
		return
	}
	cmd := fmt.Sprintf("curl -fsSL -o /opt/bin/xray-go-agent-auto-install https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-agent-auto-install.sh && chmod +x /opt/bin/xray-go-agent-auto-install && /opt/bin/xray-go-agent-auto-install --server-url '%s' --router-id '%s' --router-name '%s' --agent-token '%s' --poll-interval 5", publicServerURL(), rt.ID, shellQuoteValue(rt.Name), rt.Token)
	if agentType == "go" {
		cmd += " --agent go"
	} else if agentType == "shell" {
		cmd += " --agent shell"
	}
	s.sendMessageWithKeyboard(chatID, "Выполни на роутере:\n\n`"+cmd+"`", routerKeyboard(routerID))
}

func publicServerURL() string {
	u := os.Getenv("XRAY_GO_PUBLIC_SERVER_URL")
	if strings.TrimSpace(u) != "" {
		return strings.TrimSpace(u)
	}
	return "http://185.252.177.2:18090"
}
