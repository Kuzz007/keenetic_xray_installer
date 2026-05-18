package main

import (
	"fmt"
	"strings"
)

type routeListItem struct {
	ID    string
	Title string
}

func routesKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "📥 Получить списки", CallbackData: "routes-list:" + routerID}},
		{{Text: "⬅️ Назад", CallbackData: "router:" + routerID}, {Text: "🏠 Главное меню", CallbackData: "menu"}},
	}}
}

func routeListKeyboard(routerID string, items []routeListItem) inlineKeyboard {
	rows := [][]inlineButton{}
	for _, item := range items {
		if item.ID == "" {
			continue
		}
		title := item.Title
		if strings.TrimSpace(title) == "" {
			title = item.ID
		}
		rows = append(rows, []inlineButton{{Text: "▶️ " + title, CallbackData: "routes-preview:" + routerID + ":" + item.ID}})
	}
	rows = append(rows, []inlineButton{{Text: "🔄 Обновить списки", CallbackData: "routes-list:" + routerID}})
	rows = append(rows, []inlineButton{{Text: "⬅️ Маршруты", CallbackData: "routes:" + routerID}, {Text: "🏠 Главное меню", CallbackData: "menu"}})
	return inlineKeyboard{InlineKeyboard: rows}
}

func (s *Server) routesMenuView(routerID string) (string, inlineKeyboard, bool) {
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
	text := strings.Join([]string{
		"🧭 Маршруты",
		"",
		"📡 " + name,
		"ID: " + routerID,
		"",
		"Нажмите 📥 Получить списки — роутер скачает актуальный routes/index.json из репозитория.",
		"Новые списки появятся здесь без обновления бота.",
		"",
		"Apply доступен только после preview выбранного списка.",
	}, "\n")
	return text, routesKeyboard(routerID), true
}

func (s *Server) enqueueRoutesList(chatID int64, messageID int, routerID string) {
	if messageID > 0 {
		s.setActiveMenu(routerID, chatID, messageID)
	}
	id, err := s.enqueue(routerID, Command{Action: "routes_list"})
	if err != nil {
		s.editOrSendMessageWithKeyboard(chatID, messageID, err.Error(), routesKeyboard(routerID))
		return
	}
	text, _, ok := s.routesMenuView(routerID)
	if !ok {
		s.editOrSendMessageWithKeyboard(chatID, messageID, text, s.routersKeyboardWithUpdateScripts())
		return
	}
	s.editOrSendMessageWithKeyboard(chatID, messageID, text+"\n\n⏳ Запрос списков поставлен в очередь\n"+id, routesKeyboard(routerID))
}

func (s *Server) enqueueRoutesPreview(chatID int64, messageID int, routerID, listID string) {
	listID = normalizeRouteCallbackID(listID)
	if listID == "" {
		s.editOrSendMessageWithKeyboard(chatID, messageID, "⚠️ Некорректный route list id", routesKeyboard(routerID))
		return
	}
	if messageID > 0 {
		s.setActiveMenu(routerID, chatID, messageID)
	}
	id, err := s.enqueue(routerID, Command{Action: "routes_preview", Selector: listID})
	if err != nil {
		s.editOrSendMessageWithKeyboard(chatID, messageID, err.Error(), routesKeyboard(routerID))
		return
	}
	text := fmt.Sprintf("🧭 Preview route-list\n\nRouter: %s\nList: %s\n\n⏳ Команда в очереди\n%s", routerID, listID, id)
	s.editOrSendMessageWithKeyboard(chatID, messageID, text, inlineKeyboard{InlineKeyboard: [][]inlineButton{{{Text: "⬅️ Маршруты", CallbackData: "routes:" + routerID}, {Text: "🏠 Главное меню", CallbackData: "menu"}}}})
}

func (s *Server) enqueueRoutesApply(chatID int64, messageID int, routerID, listID string) {
	listID = normalizeRouteCallbackID(listID)
	if listID == "" {
		s.editOrSendMessageWithKeyboard(chatID, messageID, "⚠️ Некорректный route list id", routesKeyboard(routerID))
		return
	}
	if messageID > 0 {
		s.setActiveMenu(routerID, chatID, messageID)
	}
	id, err := s.enqueue(routerID, Command{Action: "routes_apply", Selector: listID})
	if err != nil {
		s.editOrSendMessageWithKeyboard(chatID, messageID, err.Error(), routesKeyboard(routerID))
		return
	}
	text := fmt.Sprintf("🧭 Apply route-list\n\nRouter: %s\nList: %s\n\n⏳ Применение поставлено в очередь\n%s\n\nБудет создан backup running-config перед изменениями.", routerID, listID, id)
	s.editOrSendMessageWithKeyboard(chatID, messageID, text, inlineKeyboard{InlineKeyboard: [][]inlineButton{{{Text: "⬅️ К спискам", CallbackData: "routes-list:" + routerID}, {Text: "🏠 Главное меню", CallbackData: "menu"}}}})
}

func normalizeRouteCallbackID(id string) string {
	id = strings.TrimSpace(id)
	if id == "" {
		return ""
	}
	for _, r := range id {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			continue
		}
		return ""
	}
	return id
}

func parseRoutesCatalogOutput(output string) []routeListItem {
	items := []routeListItem{}
	for _, raw := range strings.Split(output, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "Routes catalog") {
			continue
		}
		parts := strings.SplitN(line, "|", 2)
		if len(parts) != 2 {
			continue
		}
		id := normalizeRouteCallbackID(strings.TrimSpace(parts[0]))
		if id == "" {
			continue
		}
		title := strings.TrimSpace(parts[1])
		items = append(items, routeListItem{ID: id, Title: title})
	}
	return items
}

func parseRoutePreviewListID(output string) string {
	for _, raw := range strings.Split(output, "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "id:") {
			return normalizeRouteCallbackID(strings.TrimSpace(strings.TrimPrefix(line, "id:")))
		}
	}
	return ""
}

func isRoutesListResult(commandID string) bool {
	return strings.HasPrefix(commandID, "routes_list-")
}

func isRoutesPreviewResult(commandID string) bool {
	return strings.HasPrefix(commandID, "routes_preview-")
}

func isRoutesApplyResult(commandID string) bool {
	return strings.HasPrefix(commandID, "routes_apply-")
}

func (s *Server) editActiveRoutesResult(routerID string, res Result) bool {
	active, ok := s.activeMenu(routerID)
	if !ok {
		return false
	}
	if isRoutesListResult(res.CommandID) && res.OK {
		items := parseRoutesCatalogOutput(res.Output)
		text := "📥 Списки из репозитория\n\n" + strings.TrimSpace(res.Output)
		if len(items) == 0 {
			text += "\n\n⚠️ Не удалось распознать списки. Проверьте вывод helper'а."
			return s.editMessageWithKeyboard(active.ChatID, active.MessageID, text, routesKeyboard(routerID))
		}
		text += "\n\nВыберите список для preview:"
		return s.editMessageWithKeyboard(active.ChatID, active.MessageID, text, routeListKeyboard(routerID, items))
	}
	if isRoutesPreviewResult(res.CommandID) {
		listID := parseRoutePreviewListID(res.Output)
		text := "👁 Preview route-list\n\n" + prettyResultMessage("", res)
		rows := [][]inlineButton{}
		if res.OK && listID != "" {
			rows = append(rows, []inlineButton{{Text: "✅ Применить " + listID, CallbackData: "routes-apply:" + routerID + ":" + listID}})
		}
		rows = append(rows, []inlineButton{{Text: "⬅️ К спискам", CallbackData: "routes-list:" + routerID}, {Text: "🏠 Главное меню", CallbackData: "menu"}})
		return s.editMessageWithKeyboard(active.ChatID, active.MessageID, text, inlineKeyboard{InlineKeyboard: rows})
	}
	if isRoutesApplyResult(res.CommandID) {
		text := "✅ Apply route-list\n\n" + prettyResultMessage("", res)
		kb := inlineKeyboard{InlineKeyboard: [][]inlineButton{{{Text: "⬅️ К спискам", CallbackData: "routes-list:" + routerID}, {Text: "🏠 Главное меню", CallbackData: "menu"}}}}
		return s.editMessageWithKeyboard(active.ChatID, active.MessageID, text, kb)
	}
	return false
}
