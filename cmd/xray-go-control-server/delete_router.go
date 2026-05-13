package main

func deleteRouterConfirmKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "Да, удалить", CallbackData: "confirm-delete-router:" + routerID}},
		{{Text: "Отмена", CallbackData: "router:" + routerID}, {Text: "К списку", CallbackData: "routers"}},
	}}
}

func (s *Server) sendDeleteRouterConfirm(chatID int64, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	name := routerID
	if rt != nil {
		name = rt.Name
	}
	s.mu.Unlock()

	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "Роутер не найден: "+routerID, routersKeyboard(s.routerIDs()))
		return
	}

	s.sendMessageWithKeyboard(chatID,
		"Удалить роутер из control-server?\n\n"+name+" ("+routerID+")\n\nАгент на самом роутере не удаляется автоматически.",
		deleteRouterConfirmKeyboard(routerID),
	)
}

func (s *Server) deleteRouter(chatID int64, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	if rt == nil {
		s.mu.Unlock()
		s.sendMessageWithKeyboard(chatID, "Роутер уже отсутствует: "+routerID, routersKeyboard(s.routerIDs()))
		return
	}

	if len(s.cfg.Routers) <= 1 {
		s.mu.Unlock()
		s.sendMessageWithKeyboard(chatID, "Нельзя удалить последний роутер из registry.", routerKeyboard(routerID))
		return
	}

	delete(s.cfg.Routers, routerID)
	err := s.persistConfigLocked()
	if err != nil {
		s.cfg.Routers[routerID] = rt
	}
	s.mu.Unlock()

	if err != nil {
		s.sendMessageWithKeyboard(chatID, "Роутер не удалён: "+err.Error(), routerKeyboard(routerID))
		return
	}

	s.sendMessageWithKeyboard(chatID, "Роутер удалён из registry: "+routerID, routersKeyboard(s.routerIDs()))
}
