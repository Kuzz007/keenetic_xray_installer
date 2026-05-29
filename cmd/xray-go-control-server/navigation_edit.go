package main

import "strings"

func (s *Server) handleCallbackEditable(cb *tgCallbackQuery) {
	if cb.From.ID != s.cfg.AdminUserID {
		s.answerCallback(cb.ID, "Access denied")
		return
	}
	chatID := s.cfg.AdminUserID
	messageID := 0
	if cb.Message != nil {
		chatID = cb.Message.Chat.ID
		messageID = cb.Message.MessageID
	}
	data := cb.Data
	s.answerCallback(cb.ID, "")
	switch {
	case data == "menu":
		s.editMenuOnly(cb.ID, chatID, messageID, prettyMainMenuText(), mainMenuKeyboard())
	case data == "help":
		s.editMenuOnly(cb.ID, chatID, messageID, helpText(), mainMenuKeyboard())
	case data == "routers":
		s.editMenuOnly(cb.ID, chatID, messageID, s.groupedRouterList(), s.routersKeyboardWithUpdateScripts())
	case strings.HasPrefix(data, "group:"):
		text, kb := s.routerGroupView(strings.TrimPrefix(data, "group:"))
		s.editMenuOnly(cb.ID, chatID, messageID, text, kb)
	case data == "doctor_all":
		text := s.enqueueDoctorAll()
		s.editMenuOnly(cb.ID, chatID, messageID, text+"\n\n"+s.groupedRouterList(), s.routersKeyboardWithUpdateScripts())
	case data == "update_scripts_all":
		text := s.enqueueUpdateScriptsAll()
		s.editMenuOnly(cb.ID, chatID, messageID, text+"\n\n"+s.groupedRouterList(), s.routersKeyboardWithUpdateScripts())
	case data == "update_agents_all":
		text := s.enqueueUpdateAgentsAll()
		s.editMenuOnly(cb.ID, chatID, messageID, text+"\n\n"+s.groupedRouterList(), s.routersKeyboardWithUpdateScripts())
	case data == "add_router_help":
		s.startAddRouterWizard(chatID)
	case strings.HasPrefix(data, "routes-custom:"):
		routerID := strings.TrimPrefix(data, "routes-custom:")
		s.startCustomRoutesWizard(chatID, routerID)
	case strings.HasPrefix(data, "routes-remove:"):
		parts := strings.SplitN(data, ":", 3)
		if len(parts) == 3 {
			s.enqueueRoutesRemove(chatID, messageID, parts[1], parts[2])
			return
		}
		s.editMenuOnly(cb.ID, chatID, messageID, "Некорректная кнопка удаления маршрутов", mainMenuKeyboard())
	case strings.HasPrefix(data, "routes-apply:"):
		parts := strings.SplitN(data, ":", 3)
		if len(parts) == 3 {
			s.enqueueRoutesApply(chatID, messageID, parts[1], parts[2])
			return
		}
		s.editMenuOnly(cb.ID, chatID, messageID, "Некорректная кнопка применения маршрутов", mainMenuKeyboard())
	case strings.HasPrefix(data, "routes-preview:"):
		parts := strings.SplitN(data, ":", 3)
		if len(parts) == 3 {
			s.enqueueRoutesPreview(chatID, messageID, parts[1], parts[2])
			return
		}
		s.editMenuOnly(cb.ID, chatID, messageID, "Некорректная кнопка маршрутов", mainMenuKeyboard())
	case strings.HasPrefix(data, "routes-list:"):
		s.enqueueRoutesList(chatID, messageID, strings.TrimPrefix(data, "routes-list:"))
	case strings.HasPrefix(data, "routes:"):
		routerID := strings.TrimPrefix(data, "routes:")
		s.setActiveMenu(routerID, chatID, messageID)
		text, kb, ok := s.routesMenuView(routerID)
		if !ok {
			s.editMenuOnly(cb.ID, chatID, messageID, text, s.routersKeyboardWithUpdateScripts())
			return
		}
		s.editMenuOnly(cb.ID, chatID, messageID, text, kb)
	case strings.HasPrefix(data, "install:"):
		routerID := strings.TrimPrefix(data, "install:")
		s.setActiveMenu(routerID, chatID, messageID)
		text, kb, ok := s.agentInstallMenuView(routerID)
		if !ok {
			s.editMenuOnly(cb.ID, chatID, messageID, text, s.routersKeyboardWithUpdateScripts())
			return
		}
		s.editMenuOnly(cb.ID, chatID, messageID, text, kb)
	case strings.HasPrefix(data, "install-go:"):
		s.sendAgentInstallCommand(chatID, strings.TrimPrefix(data, "install-go:"), "go")
	case strings.HasPrefix(data, "install-shell:"):
		s.sendAgentInstallCommand(chatID, strings.TrimPrefix(data, "install-shell:"), "shell")
	case strings.HasPrefix(data, "refresh-subscription:"):
		routerID := strings.TrimPrefix(data, "refresh-subscription:")
		s.setActiveMenu(routerID, chatID, messageID)
		id, err := s.enqueue(routerID, Command{Action: "update_subscription"})
		if err != nil {
			s.editMenuOnly(cb.ID, chatID, messageID, err.Error(), s.routersKeyboardWithUpdateScripts())
			return
		}
		text := s.routerMenuTextWithExtra(routerID, "⏳ Обновление подписки поставлено в очередь\n"+id+"\n\nБудет использован уже сохранённый source активного Go-слота.")
		s.editMenuOnly(cb.ID, chatID, messageID, text, s.currentRouterKeyboard(routerID))
	case strings.HasPrefix(data, "sources:"):
		routerID := strings.TrimPrefix(data, "sources:")
		s.setActiveMenu(routerID, chatID, messageID)
		text, kb, ok := s.sourceMenuView(routerID)
		if !ok {
			s.editMenuOnly(cb.ID, chatID, messageID, text, s.routersKeyboardWithUpdateScripts())
			return
		}
		s.editMenuOnly(cb.ID, chatID, messageID, text, kb)
	case strings.HasPrefix(data, "setsrc:"):
		parts := strings.SplitN(data, ":", 3)
		if len(parts) == 3 {
			s.startSetSourceWizard(chatID, parts[2], parts[1])
		}
	case strings.HasPrefix(data, "delete-router:"):
		s.sendDeleteRouterConfirm(chatID, strings.TrimPrefix(data, "delete-router:"))
	case strings.HasPrefix(data, "confirm-delete-router:"):
		s.deleteRouter(chatID, strings.TrimPrefix(data, "confirm-delete-router:"))
	case strings.HasPrefix(data, "router:"):
		routerID := strings.TrimPrefix(data, "router:")
		s.setActiveMenu(routerID, chatID, messageID)
		text, kb, ok := s.routerMenuView(routerID)
		if !ok {
			s.editMenuOnly(cb.ID, chatID, messageID, text, s.routersKeyboardWithUpdateScripts())
			return
		}
		s.editMenuOnly(cb.ID, chatID, messageID, text, kb)
	case strings.HasPrefix(data, "act:"):
		s.handleActionCallbackStrict(cb.ID, chatID, messageID, data)
	default:
		s.editMenuOnly(cb.ID, chatID, messageID, "Неизвестная кнопка", mainMenuKeyboard())
	}
}

func (s *Server) editMenuOnly(callbackID string, chatID int64, messageID int, text string, keyboard inlineKeyboard) bool {
	if messageID > 0 && s.editMessageWithKeyboard(chatID, messageID, text, keyboard) {
		return true
	}
	s.answerCallback(callbackID, "Не удалось обновить это сообщение. Открой /menu заново.")
	return false
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
		return "unknown router: " + routerID, s.routersKeyboardWithUpdateScripts(), false
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
		return "⚠️ Роутер не найден: " + routerID, s.routersKeyboardWithUpdateScripts(), false
	}
	text := "🔗 Источники\n\n📡 " + name + "\nID: " + routerID + "\n\nВыберите действие для primary/backup источников."
	return text, sourceKeyboard(routerID), true
}

func (s *Server) agentInstallMenuView(routerID string) (string, inlineKeyboard, bool) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	s.mu.Unlock()
	if rt == nil {
		return "⚠️ Router not found: " + routerID, s.routersKeyboardWithUpdateScripts(), false
	}
	msg := strings.TrimSpace("📦 Установка агента\n\n📡 " + rt.Name + "\nID: " + rt.ID + "\n\nРекомендуемый вариант: ⚙️ Auto install.\n\nОн сам определит архитектуру роутера и выберет агент:\n• ARM64 / aarch64 → Go-agent\n• MIPS / MT7621 / старые Keenetic → Legacy shell-agent\n\n🧩 Legacy shell-agent оставлен как ручной вариант для диагностики и старых MIPS.")
	return msg, agentInstallKeyboard(routerID), true
}
