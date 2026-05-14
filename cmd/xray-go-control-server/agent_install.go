package main

import (
	"fmt"
	"strings"
)

func agentInstallKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "Go-agent", CallbackData: "install-go:" + routerID}},
		{{Text: "Legacy shell-agent", CallbackData: "install-shell:" + routerID}},
		{{Text: "Назад", CallbackData: "router:" + routerID}, {Text: "К списку", CallbackData: "routers"}},
	}}
}

func (s *Server) sendAgentInstallMenu(chatID int64, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	s.mu.Unlock()

	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "Роутер не найден: "+routerID, s.routersKeyboard())
		return
	}

	msg := "Выбери тип агента для " + rt.Name + " (" + rt.ID + "):\n\n" +
		"Go-agent — Full Go / Minimal Go / Minimal Next / ARM64 / совместимые MIPS.\n\n" +
		"Legacy shell-agent — Viva / MT7621 / старые MIPS / legacy без рабочего Go-бинаря."
	s.sendMessageWithKeyboard(chatID, msg, agentInstallKeyboard(routerID))
}

func (s *Server) sendAgentInstallCommand(chatID int64, routerID, kind string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	listen := s.cfg.Listen
	s.mu.Unlock()

	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "Роутер не найден: "+routerID, s.routersKeyboard())
		return
	}

	serverURL := publicServerURL(listen)

	var installer string
	var bin string
	var title string

	switch kind {
	case "shell":
		installer = "xray-go-agent-shell-install.sh"
		bin = "xray-go-agent-shell-install"
		title = "Legacy shell-agent"
	default:
		installer = "xray-go-agent-install.sh"
		bin = "xray-go-agent-install"
		title = "Go-agent"
	}

	intro := fmt.Sprintf("%s для %s (%s).\nСледующим сообщением будет только копируемая команда установки.", title, rt.Name, rt.ID)
	s.sendMessageWithKeyboard(chatID, intro, agentInstallKeyboard(routerID))

	cmd := fmt.Sprintf("curl -fsSL -o /opt/bin/%s https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/%s && chmod +x /opt/bin/%s && /opt/bin/%s --server-url '%s' --router-id '%s' --router-name '%s' --agent-token '%s' --poll-interval 5",
		bin, installer, bin, bin, serverURL, rt.ID, rt.Name, rt.Token)

	s.sendMessage(chatID, cmd)
}

func publicServerURL(listen string) string {
	listen = strings.TrimSpace(listen)
	if listen == "" || listen == ":18090" {
		return "http://VPS_IP:18090"
	}
	if strings.HasPrefix(listen, ":") {
		return "http://VPS_IP" + listen
	}
	if strings.HasPrefix(listen, "http://") || strings.HasPrefix(listen, "https://") {
		return listen
	}
	return "http://" + listen
}
