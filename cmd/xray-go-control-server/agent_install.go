package main

import (
	"fmt"
	"net"
	"strings"
	"time"
)

func agentInstallKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "Автоустановка агента", CallbackData: "install-auto:" + routerID}},
		{{Text: "Go-agent вручную", CallbackData: "install-go:" + routerID}},
		{{Text: "Legacy shell-agent вручную", CallbackData: "install-shell:" + routerID}},
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

	msg := "Установка агента для " + rt.Name + " (" + rt.ID + "):\n\n" +
		"Автоустановка — рекомендуемый вариант: роутер сам выберет агент по архитектуре.\n\n" +
		"ARM64/aarch64 → Go-agent.\n" +
		"MIPS/MT7621/старые Keenetic → Legacy shell-agent.\n\n" +
		"Ручные варианты оставлены для диагностики."
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
	var extraArgs string

	switch kind {
	case "auto":
		installer = "xray-go-agent-auto-install.sh"
		bin = "xray-go-agent-auto-install"
		title = "Автоустановка агента"
	case "shell":
		installer = "xray-go-agent-shell-install.sh"
		bin = "xray-go-agent-shell-install"
		title = "Legacy shell-agent"
		extraArgs = " --agent shell"
	default:
		installer = "xray-go-agent-install.sh"
		bin = "xray-go-agent-install"
		title = "Go-agent"
		extraArgs = " --agent go"
	}

	intro := fmt.Sprintf("%s для %s (%s).\nСледующим сообщением будет только копируемая команда установки.", title, rt.Name, rt.ID)
	s.sendMessageWithKeyboard(chatID, intro, agentInstallKeyboard(routerID))

	cmd := fmt.Sprintf("curl -fsSL -o /opt/bin/%s https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/%s && chmod +x /opt/bin/%s && /opt/bin/%s --server-url '%s' --router-id '%s' --router-name '%s' --agent-token '%s' --poll-interval 5%s",
		bin, installer, bin, bin, serverURL, rt.ID, rt.Name, rt.Token, extraArgs)

	s.sendMessage(chatID, cmd)
}

func publicServerURL(listen string) string {
	listen = strings.TrimSpace(listen)
	if listen == "" {
		listen = ":18090"
	}
	if strings.HasPrefix(listen, "http://") || strings.HasPrefix(listen, "https://") {
		return listen
	}

	host, port := listenHostPort(listen)
	if port == "" {
		port = "18090"
	}
	if isWildcardListenHost(host) {
		host = detectOutboundIP()
	}
	if host == "" {
		host = "VPS_IP"
	}

	return "http://" + net.JoinHostPort(host, port)
}

func listenHostPort(listen string) (string, string) {
	if strings.HasPrefix(listen, ":") {
		return "", strings.TrimPrefix(listen, ":")
	}

	host, port, err := net.SplitHostPort(listen)
	if err == nil {
		return strings.Trim(host, "[]"), port
	}

	return listen, ""
}

func isWildcardListenHost(host string) bool {
	host = strings.TrimSpace(strings.Trim(host, "[]"))
	return host == "" || host == "0.0.0.0" || host == "::"
}

func detectOutboundIP() string {
	conn, err := net.DialTimeout("udp", "8.8.8.8:80", 2*time.Second)
	if err != nil {
		return ""
	}
	defer conn.Close()

	addr, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok || addr.IP == nil {
		return ""
	}
	return addr.IP.String()
}
