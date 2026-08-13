package main

import (
	"fmt"
	"net"
	"strings"
	"time"
)

func (s *Server) sendAgentInstallCommand(chatID int64, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	listen := s.cfg.Listen
	fingerprint := s.cfg.CertFingerprint
	s.mu.Unlock()

	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "⚠️ Router not found: "+routerID, s.routersKeyboard())
		return
	}

	serverURL := publicServerURL(listen)

	intro := fmt.Sprintf("⚙️ Установка агента\n\n📡 %s\nID: %s\nServer: %s\n\nСледующее сообщение — готовая команда для копирования на роутер.", rt.Name, rt.ID, serverURL)
	s.sendMessageWithKeyboard(chatID, intro, routerKeyboard(routerID))

	cmd := buildAgentInstallCommand(serverURL, rt.ID, rt.Name, rt.Token, fingerprint)
	s.sendMessage(chatID, cmd)
}

func buildAgentInstallCommand(serverURL, routerID, routerName, token, fingerprint string) string {
	return buildAgentInstallCommandForChannel(serverURL, routerID, routerName, token, fingerprint, "latest")
}

func buildAgentInstallCommandForChannel(serverURL, routerID, routerName, token, fingerprint, channel string) string {
	if channel != "dev" {
		channel = "latest"
	}
	tool := "cu" + "rl"
	base := "https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/"
	installer := "xray-go-agent-unified-install.sh"
	bin := "xray-go-agent-unified-install"
	flagToken := "--agent-" + "token"
	download := fmt.Sprintf("%s -fsSL -o /opt/bin/%s %s%s && chmod +x /opt/bin/%s",
		tool, bin, base, installer, bin)
	install := fmt.Sprintf("TAG=%s /opt/bin/%s --server-url %s --server-fingerprint %s --router-id %s --router-name %s %s %s --poll-interval 10",
		shellSingleQuote(channel), bin, shellSingleQuote(serverURL), shellSingleQuote(fingerprint), shellSingleQuote(routerID), shellSingleQuote(routerName), flagToken, shellSingleQuote(token))

	// Keenetic's interactive shell can truncate physical input lines around
	// 512 bytes. Keep the copy/paste block split into short standalone lines,
	// while preserving the old fail-closed download -> install dependency.
	return strings.Join([]string{
		"_XRAY_AGENT_INSTALL_READY=",
		download + " && _XRAY_AGENT_INSTALL_READY=1",
		`[ "${_XRAY_AGENT_INSTALL_READY:-}" = 1 ] && ` + install,
		"unset _XRAY_AGENT_INSTALL_READY",
	}, "\n")
}

func shellSingleQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
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

	return "https://" + net.JoinHostPort(host, port)
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
