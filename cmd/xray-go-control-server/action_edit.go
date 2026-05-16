package main

import "strings"

func (s *Server) handleActionCallbackStrict(callbackID string, chatID int64, messageID int, data string) {
	parts := strings.SplitN(data, ":", 3)
	if len(parts) != 3 {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка", mainMenuKeyboard())
		return
	}

	name, routerID := parts[1], parts[2]
	if messageID > 0 {
		s.setActiveMenu(routerID, chatID, messageID)
	}

	if name == "results" {
		s.editMenuOnly(callbackID, chatID, messageID, s.results(routerID), s.currentRouterKeyboard(routerID))
		return
	}

	action := callbackAction(name)
	if action == "" {
		s.editMenuOnly(callbackID, chatID, messageID, "Действие не поддерживается: "+name, routerKeyboard(routerID))
		return
	}

	id, err := s.enqueue(routerID, Command{Action: action})
	if err != nil {
		s.editMenuOnly(callbackID, chatID, messageID, err.Error(), s.routersKeyboard())
		return
	}

	text := s.routerMenuTextWithExtra(routerID, "⏳ Команда в очереди\n"+id)
	s.editMenuOnly(callbackID, chatID, messageID, text, s.currentRouterKeyboard(routerID))
}
