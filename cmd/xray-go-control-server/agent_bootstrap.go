package main

import (
	"fmt"
	"net/http"
	"strings"
)

// handleAgentBootstrap is consumed by the freshly downloaded legacy
// auto-installer. It lets an old update_agent command discover the channel
// selected in Telegram and migrate its existing http:// config to pinned TLS.
func (s *Server) handleAgentBootstrap(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	rt := s.authRouter(r)
	if rt == nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.mu.Lock()
	channel := normalizedAgentChannel(rt.RequestedAgentChannel)
	listen := s.cfg.Listen
	fingerprint := s.cfg.CertFingerprint
	s.mu.Unlock()
	serverURL := publicServerURL(listen)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	fmt.Fprintf(w, "channel=%s\nserver_url=%s\nserver_fingerprint=%s\n", channel, serverURL, fingerprint)
}

func normalizedAgentChannel(channel string) string {
	if strings.EqualFold(strings.TrimSpace(channel), "dev") {
		return "dev"
	}
	return "latest"
}
