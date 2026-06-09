package main

import (
	"strings"
)

func (s *Server) enqueueProfileInstall(chatID int64, messageID int, routerID, profile string) {
	profile = normalizeGoProfile(profile)
	if profile == "" {
		s.editMenuOnly("", chatID, messageID, "⚠️ Неизвестный профиль установки", s.currentRouterKeyboard(routerID))
		return
	}
	id, err := s.enqueue(routerID, Command{Action: "install_" + profile})
	if err != nil {
		s.editMenuOnly("", chatID, messageID, err.Error(), s.routersKeyboardWithUpdateScripts())
		return
	}
	name := "Minimal Go"
	if profile == "full_go" {
		name = "Full Go"
	}
	text := s.routerMenuTextWithExtra(routerID, "⏳ Установка профиля "+name+" поставлена в очередь\n"+id+"\n\nПолитика:\n• SOCKS без авторизации по умолчанию\n• xray-core update helper не ставится\n• установка идёт из main")
	s.editMenuOnly("", chatID, messageID, text, s.currentRouterKeyboard(routerID))
}

func normalizeGoProfile(profile string) string {
	profile = strings.TrimSpace(strings.ToLower(profile))
	profile = strings.ReplaceAll(profile, "-", "_")
	switch profile {
	case "minimal", "minimal_go":
		return "minimal_go"
	case "full", "full_go", "full_lite", "full_lite_go":
		return "full_go"
	default:
		return ""
	}
}
