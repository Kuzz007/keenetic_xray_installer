package main

import (
	"fmt"
	"net"
	"strings"
	"time"
)

func agentInstallKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "⚙️ Auto install", CallbackData: "install-go:" + routerID}},
		{{Text: "🧩 Legacy shell-agent", CallbackData: "install-shell:" + routerID}},
		{{Text: "⬅️ Назад", CallbackData: "router:" + routerID}, {Text: "📡 Роутеры", CallbackData: "routers"}},
	}}
}

func (s *Server) sendAgentInstallMenu(chatID int64, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	s.mu.Unlock()

	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "⚠️ Router not found: "+routerID, s.routersKeyboard())
		return
	}

	msg := strings.TrimSpace(fmt.Sprintf(`📦 Установка агента

📡 %s
ID: %s

Рекомендуемый вариант: ⚙️ Auto install.

Он сам определит архитектуру роутера и выберет агент:
• ARM64 / aarch64 → Go-agent
• MIPS / MT7621 / старые Keenetic → Legacy shell-agent

🧩 Legacy shell-agent оставлен как ручной вариант для диагностики и старых MIPS.`, rt.Name, rt.ID))
	s.sendMessageWithKeyboard(chatID, msg, agentInstallKeyboard(routerID))
}

func (s *Server) sendAgentInstallCommand(chatID int64, routerID, kind string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	listen := s.cfg.Listen
	s.mu.Unlock()

	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "⚠️ Router not found: "+routerID, s.routersKeyboard())
		return
	}

	serverURL := publicServerURL(listen)

	var installer string
	var bin string
	var title string
	var icon string

	switch kind {
	case "shell":
		installer = "xray-go-agent-shell-install.sh"
		bin = "xray-go-agent-shell-install"
		title = "Legacy shell-agent"
		icon = "🧩"
	default:
		installer = "xray-go-agent-auto-install.sh"
		bin = "xray-go-agent-auto-install"
		title = "Auto agent install"
		icon = "⚙️"
	}

	intro := fmt.Sprintf("%s %s\n\n📡 %s\nID: %s\nServer: %s\n\nСледующее сообщение — готовая команда для копирования на роутер.", icon, title, rt.Name, rt.ID, serverURL)
	s.sendMessageWithKeyboard(chatID, intro, agentInstallKeyboard(routerID))

	cmd := buildAgentInstallCommand(bin, installer, serverURL, rt.ID, rt.Name, rt.Token)
	s.sendMessage(chatID, cmd)
}

func buildAgentInstallCommand(bin, installer, serverURL, routerID, routerName, token string) string {
	tool := "cu" + "rl"
	base := "https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/"
	flagToken := "--agent-" + "token"
	return fmt.Sprintf("%s -fsSL -o /opt/bin/%s %s%s && chmod +x /opt/bin/%s && /opt/bin/%s --server-url '%s' --router-id '%s' --router-name '%s' %s '%s' --poll-interval 5",
		tool, bin, base, installer, bin, bin, serverURL, routerID, routerName, flagToken, token)
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