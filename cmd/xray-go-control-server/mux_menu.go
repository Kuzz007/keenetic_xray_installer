package main

import (
	"fmt"
	"strconv"
	"strings"
)

func (s *Server) muxMenuView(routerID string) (string, inlineKeyboard, bool) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	s.mu.Unlock()
	if rt == nil {
		return "⚠️ Роутер не найден: " + routerID, s.routersKeyboardWithUpdateScripts(), false
	}
	name := rt.Name
	if strings.TrimSpace(name) == "" {
		name = routerID
	}
	text := strings.TrimSpace("⚙️ Mux\n\n📡 " + name + "\nID: " + routerID + "\n\nРекомендуемый безопасный порядок:\n1. Нажми 💾 Точка отката.\n2. Проверь 📍 Статус.\n3. Для теста включи ✅ ON 8.\n\nПамятка по режимам:\n• ON 4 — осторожно, меньше риска.\n• ON 8 — оптимальный старт.\n• ON 16 — агрессивнее, больше мелких запросов.\n• ON 32 — эксперимент, только для сравнения.\n\nАгент изменит только клиентский outbound Xray на роутере, проверит config test, перезапустит Xray и при ошибке вернёт backup.")
	return text, muxKeyboard(routerID), true
}

func muxKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "📍 Статус", CallbackData: "mux-status:" + routerID}, {Text: "💾 Точка отката", CallbackData: "mux-snapshot:" + routerID}},
		{{Text: "✅ ON 4", CallbackData: "mux-enable:" + routerID + ":4"}, {Text: "✅ ON 8", CallbackData: "mux-enable:" + routerID + ":8"}, {Text: "✅ ON 16", CallbackData: "mux-enable:" + routerID + ":16"}},
		{{Text: "✅ ON 32", CallbackData: "mux-enable:" + routerID + ":32"}},
		{{Text: "❌ Выключить", CallbackData: "mux-disable:" + routerID}, {Text: "↩️ Откат", CallbackData: "mux-rollback:" + routerID}},
		{{Text: "⬅️ Назад", CallbackData: "router:" + routerID}, {Text: "🏠 Главное меню", CallbackData: "menu"}},
	}}
}

func (s *Server) enqueueMuxPreset(callbackID string, chatID int64, messageID int, data string) {
	parts := strings.SplitN(data, ":", 3)
	if len(parts) != 3 {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка Mux", mainMenuKeyboard())
		return
	}
	routerID := parts[1]
	concurrency, err := strconv.Atoi(parts[2])
	if err != nil || concurrency <= 0 {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректное значение concurrency", muxKeyboard(routerID))
		return
	}
	payload := fmt.Sprintf(`{"concurrency":%d,"xudpConcurrency":-1,"xudpProxyUDP443":"skip"}`, concurrency)
	s.enqueueMuxCommand(callbackID, chatID, messageID, routerID, "mux_enable", payload, fmt.Sprintf("⏳ Mux ON поставлен в очередь\nconcurrency: %d", concurrency))
}

func (s *Server) enqueueMuxSimple(callbackID string, chatID int64, messageID int, data, action, label string) {
	routerID := strings.TrimSpace(strings.TrimPrefix(data, label+":"))
	if routerID == "" {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка Mux", mainMenuKeyboard())
		return
	}
	s.enqueueMuxCommand(callbackID, chatID, messageID, routerID, action, "", "⏳ "+label+" поставлено в очередь")
}

func (s *Server) enqueueMuxCommand(callbackID string, chatID int64, messageID int, routerID, action, source, queuedText string) {
	if messageID > 0 {
		s.setActiveMenu(routerID, chatID, messageID)
	}
	id, err := s.enqueue(routerID, Command{Action: action, Source: source})
	if err != nil {
		s.editMenuOnly(callbackID, chatID, messageID, err.Error(), s.routersKeyboardWithUpdateScripts())
		return
	}
	text := s.routerMenuTextWithExtra(routerID, queuedText+"\n"+id)
	s.editMenuOnly(callbackID, chatID, messageID, text, muxKeyboard(routerID))
}
