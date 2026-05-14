package main

import (
	"fmt"
	"net"
	"strings"
	"time"
)

func agentInstallKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "Auto install", CallbackData: "install-auto:" + routerID}},
		{{Text: "Go-agent manual", CallbackData: "install-go:" + routerID}},
		{{Text: "Legacy shell-agent manual", CallbackData: "install-shell:" + routerID}},
		{{Text: "Back", CallbackData: "router:" + routerID}, {Text: "Routers", CallbackData: "routers"}},
	}}
}

func (s *Server) sendAgentInstallMenu(chatID int64, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	s.mu.Unlock()

	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "Router not found: "+routerID, s.routersKeyboard())
		return
	}

	msg := "Agent install for " + rt.Name + " (" + rt.ID + "):\n\n" +
		"Auto install is recommended: the router selects the agent by architecture.\n\n" +
		"ARM64/aarch64 -> Go-agent.\n" +
		"MIPS/MT7621/old Keenetic -> Legacy shell-agent.\n\n" +
		"Manual options are kept for diagnostics."
	s.sendMessageWithKeyboard(chatID, msg, agentInstallKeyboard(routerID))
}

func (s *Server) sendAgentInstallCommand(chatID int64, routerID, kind string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	listen := s.cfg.Listen
	s.mu.Unlock()

	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "Router not found: "+routerID, s.routersKeyboard())
		return
	}

	serverURL := publicServerURL(listen)

	var installer string
	var bin string
	var title string

	switch kind {
	case "auto":
		installer = "xray-go-agent-auto-install.sh"
		bin = "xray-go-agent-auto-install"
		title = "Auto agent install"
	case "shell":
		installer = "xray-go-agent-shell-install.sh"
		bin = "xray-go-agent-shell-install"
		title = "Legacy shell-agent"
	default:
		installer = "xray-go-agent-install.sh"
		bin = "xray-go-agent-install"
		title = "Go-agent"
	}

	intro := fmt.Sprintf("%s for %s (%s).\nThe next message is the copy-paste install command only.", title, rt.Name, rt.ID)
	s.sendMessageWithKeyboard(chatID, intro, agentInstallKeyboard(routerID))

	cmd := fmt.Sprintf("curl -fsSL -o /opt/bin/%s https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/%s && chmod +x /opt/bin/%s && /opt/bin/%s --server-url '%s' --router-id '%s' --router-name '%s' --agent-token '%s' --poll-interval 5",
		bin, installer, bin, bin, serverURL, rt.ID, rt.Name, rt.Token)

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
