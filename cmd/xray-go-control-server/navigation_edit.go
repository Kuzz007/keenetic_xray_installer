package main

import "strings"

func (s *Server) editOrSendMessageWithKeyboard(chatID int64, messageID int, text string, keyboard inlineKeyboard) {
	if messageID > 0 && s.editMessageWithKeyboard(chatID, messageID, text, keyboard) {
		return
	}
	s.sendMessageWithKeyboard(chatID, text, keyboard)
}

func (s *Server) routerMenuView(routerID string) (string, inlineKeyboard, bool) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	card := prettyRouterCard(rt)
	status := ""
	if rt != nil {
		status = rt.Status
	}
	s.mu.Unlock()
	if rt == nil {
		return "unknown router: " + routerID, s.routersKeyboard(), false
	}
	return card, routerKeyboardForStatus(routerID, status), true
}

func (s *Server) sourceMenuView(routerID string) (string, inlineKeyboard, bool) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	name := routerID
	if rt != nil && strings.TrimSpace(rt.Name) != "" {
		name = rt.Name
	}
	s.mu.Unlock()
	if rt == nil {
		return "⚠️ Роутер не найден: " + routerID, s.routersKeyboard(), false
	}
	text := "🔗 Источники\n\n📡 " + name + "\nID: " + routerID + "\n\nВыберите действие для primary/backup источников."
	return text, sourceKeyboard(routerID), true
}
