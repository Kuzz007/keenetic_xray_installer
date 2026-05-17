package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

func isLinuxServerNode(rt *Router) bool {
	if rt == nil {
		return false
	}
	status := strings.ToLower(rt.Status)
	return strings.Contains(status, "kind: server") || strings.Contains(status, "agent: server") || strings.HasPrefix(strings.ToLower(rt.ID), "srv-") || strings.HasPrefix(strings.ToLower(rt.ID), "vps-")
}

func (s *Server) serverList() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := []string{}
	for id, rt := range s.cfg.Routers {
		if isLinuxServerNode(rt) {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	if len(ids) == 0 {
		return strings.TrimSpace(`🖥 Серверы

Серверов пока нет.

MVP использует тот же control-server и outbound polling, но отдельный Linux server-agent.

Как добавить сервер:
1. Добавь node через /add_router с ID вида vps-main или srv-main.
2. Открой созданную карточку и используй команду установки server-agent из этого раздела.
3. После первого heartbeat сервер появится здесь.`)
	}
	online := 0
	items := []string{}
	for _, id := range ids {
		rt := s.cfg.Routers[id]
		_, state := onlineState(rt.LastSeen)
		if state == "online" {
			online++
		}
		name := rt.Name
		if strings.TrimSpace(name) == "" {
			name = id
		}
		items = append(items, prettyServerListItem(name, rt.LastSeen, rt.Status))
	}
	return fmt.Sprintf("🖥 Серверы\n\n🟢 online: %d  •  ⚫ offline: %d  •  всего: %d\n\n%s", online, len(ids)-online, len(ids), strings.Join(items, "\n\n"))
}

func prettyServerListItem(name string, lastSeen time.Time, status string) string {
	dot, state := onlineState(lastSeen)
	lines := []string{fmt.Sprintf("%s %s — %s, heartbeat %s", dot, name, state, heartbeatAge(lastSeen))}
	for _, part := range importantStatusParts(status) {
		lines = append(lines, "   "+part)
	}
	return strings.Join(lines, "\n")
}

func (s *Server) serversKeyboard() inlineKeyboard {
	s.mu.Lock()
	ids := []string{}
	for id, rt := range s.cfg.Routers {
		if isLinuxServerNode(rt) {
			ids = append(ids, id)
		}
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
		rows = append(rows, []inlineButton{{Text: text, CallbackData: "server:" + id}})
	}
	s.mu.Unlock()
	rows = append(rows, []inlineButton{{Text: "➕ Добавить сервер", CallbackData: "server_add_help"}})
	rows = append(rows, []inlineButton{{Text: "🔄 Обновить", CallbackData: "servers"}, {Text: "⬅️ Назад", CallbackData: "menu"}})
	return inlineKeyboard{InlineKeyboard: rows}
}

func prettyServerCard(rt *Router) string {
	if rt == nil {
		return "unknown server"
	}
	dot, state := onlineState(rt.LastSeen)
	name := rt.Name
	if strings.TrimSpace(name) == "" {
		name = rt.ID
	}
	lines := []string{
		fmt.Sprintf("🖥 %s", name),
		fmt.Sprintf("%s %s", dot, state),
		fmt.Sprintf("heartbeat: %s", heartbeatAge(rt.LastSeen)),
		"",
	}
	parts := importantStatusParts(rt.Status)
	if len(parts) == 0 {
		lines = append(lines, "status: нет данных")
	} else {
		for _, part := range parts {
			lines = append(lines, "• "+part)
		}
	}
	if !rt.LastSeen.IsZero() {
		lines = append(lines, "", "Последнее обновление: "+rt.LastSeen.Format("15:04:05"))
	}
	return strings.Join(lines, "\n")
}

func (s *Server) serverMenuView(serverID string) (string, inlineKeyboard, bool) {
	s.mu.Lock()
	rt := s.cfg.Routers[serverID]
	s.mu.Unlock()
	if rt == nil {
		return "unknown server: " + serverID, s.serversKeyboard(), false
	}
	return prettyServerCard(rt), serverKeyboard(serverID), true
}

func serverKeyboard(serverID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "📊 Статус", CallbackData: "serveract:status:" + serverID}, {Text: "🩺 Doctor", CallbackData: "serveract:doctor:" + serverID}},
		{{Text: "🧩 Version", CallbackData: "serveract:server_version:" + serverID}, {Text: "📜 Journal", CallbackData: "serveract:server_journal:" + serverID}},
		{{Text: "🤖 Agent log", CallbackData: "serveract:agent_result_log:" + serverID}, {Text: "📬 Results", CallbackData: "serveract:results:" + serverID}},
		{{Text: "📦 Установка агента", CallbackData: "server_install:" + serverID}},
		{{Text: "⬅️ Назад", CallbackData: "servers"}, {Text: "🏠 Главное меню", CallbackData: "menu"}},
	}}
}

func serverAction(name string) string {
	switch name {
	case "status":
		return "status"
	case "doctor":
		return "doctor"
	case "server_version":
		return "server_version"
	case "server_journal":
		return "server_journal"
	case "agent_result_log":
		return "agent_result_log"
	default:
		return ""
	}
}

func (s *Server) handleServerActionCallback(chatID int64, messageID int, data string) {
	parts := strings.SplitN(data, ":", 3)
	if len(parts) != 3 {
		s.editOrSendMessageWithKeyboard(chatID, messageID, "Некорректная кнопка", s.serversKeyboard())
		return
	}
	name, serverID := parts[1], parts[2]
	if messageID > 0 {
		s.setActiveMenu(serverID, chatID, messageID)
	}
	if name == "results" {
		s.editOrSendMessageWithKeyboard(chatID, messageID, s.results(serverID), serverKeyboard(serverID))
		return
	}
	action := serverAction(name)
	if action == "" {
		s.editOrSendMessageWithKeyboard(chatID, messageID, "Действие не поддерживается: "+name, serverKeyboard(serverID))
		return
	}
	id, err := s.enqueue(serverID, Command{Action: action})
	if err != nil {
		s.editOrSendMessageWithKeyboard(chatID, messageID, err.Error(), s.serversKeyboard())
		return
	}
	s.editOrSendMessageWithKeyboard(chatID, messageID, s.routerMenuTextWithExtra(serverID, "⏳ Команда в очереди\n"+id), serverKeyboard(serverID))
}

func serverAddHelpText() string {
	return strings.TrimSpace(`➕ Добавить сервер

MVP server-agent использует outbound polling и тот же token-механизм, что роутеры.

1. Сначала создай node:
/add_router vps-main VPS Main

2. Потом открой созданную карточку и нажми:
📦 Установка агента

3. После первого heartbeat сервер появится в разделе 🖥 Серверы.

Безопасность MVP:
- нет произвольного shell exec
- только allowlist actions: status, doctor, version, journal, agent log
- агент сам ходит на control-server, inbound порт на сервере не нужен`)
}

func (s *Server) serverInstallText(serverID string) string {
	s.mu.Lock()
	rt := s.cfg.Routers[serverID]
	s.mu.Unlock()
	if rt == nil {
		return "unknown server: " + serverID
	}
	name := rt.Name
	if strings.TrimSpace(name) == "" {
		name = rt.ID
	}
	serverURL := agentServerURL(s.cfg.Listen)
	cmd := fmt.Sprintf("curl -fsSL -o /tmp/xray-go-linux-agent-install.sh https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-linux-agent-install.sh\nsh /tmp/xray-go-linux-agent-install.sh --server-url %s --node-id %s --node-name %s --agent-token %s --poll-interval 5", shellQuote(serverURL), shellQuote(rt.ID), shellQuote(name), shellQuote(rt.Token))
	return "📦 Установка Linux server-agent\n\n" + cmd
}
