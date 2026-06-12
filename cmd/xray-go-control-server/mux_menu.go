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
	text := strings.TrimSpace("⚙️ XMUX / XUDP\n\n📡 " + name + "\nID: " + routerID + "\n\nПорядок:\n1. Нажми 💾 Точка отката.\n2. Проверь 📍 Статус.\n3. Для XHTTP включай XMUX: 2 / 4 / 8 / 16 / 31.\n4. XUDP тестируй отдельно: 4 / 8 / 16 / 32.\n\nXMUX:\n• 4 — осторожно.\n• 8/16 — обычно рабочий диапазон.\n• 31 — агрессивный тест.\n\nXUDP:\n• Включает только UDP mux.\n• TCP old mux остаётся выключен: concurrency=-1.\n• UDP/443 = skip, чтобы не ломать QUIC/HTTP3.\n\nАгент меняет только клиентский outbound Xray на роутере, делает config test, перезапускает Xray и при ошибке возвращает backup.")
	return text, muxKeyboard(routerID), true
}

func muxKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "📍 Статус", CallbackData: "mux-status:" + routerID}, {Text: "💾 Точка отката", CallbackData: "mux-snapshot:" + routerID}},
		{{Text: "XMUX 2", CallbackData: "mux-enable:" + routerID + ":2"}, {Text: "XMUX 4", CallbackData: "mux-enable:" + routerID + ":4"}, {Text: "XMUX 8", CallbackData: "mux-enable:" + routerID + ":8"}},
		{{Text: "XMUX 16", CallbackData: "mux-enable:" + routerID + ":16"}, {Text: "XMUX 31", CallbackData: "mux-enable:" + routerID + ":31"}},
		{{Text: "XUDP 4", CallbackData: "mux-xudp:" + routerID + ":4"}, {Text: "XUDP 8", CallbackData: "mux-xudp:" + routerID + ":8"}, {Text: "XUDP 16", CallbackData: "mux-xudp:" + routerID + ":16"}},
		{{Text: "XUDP 32", CallbackData: "mux-xudp:" + routerID + ":32"}, {Text: "XUDP off", CallbackData: "mux-xudp:" + routerID + ":-1"}},
		{{Text: "❌ Выключить", CallbackData: "mux-disable:" + routerID}, {Text: "↩️ Откат", CallbackData: "mux-rollback:" + routerID}},
		{{Text: "⬅️ Назад", CallbackData: "router:" + routerID}, {Text: "🏠 Главное меню", CallbackData: "menu"}},
	}}
}

func (s *Server) enqueueMuxPreset(callbackID string, chatID int64, messageID int, data string) {
	parts := strings.SplitN(data, ":", 3)
	if len(parts) != 3 {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка XMUX", mainMenuKeyboard())
		return
	}
	routerID := parts[1]
	maxConcurrency, err := strconv.Atoi(parts[2])
	if err != nil || maxConcurrency <= 0 {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректное значение maxConcurrency", muxKeyboard(routerID))
		return
	}
	payload := fmt.Sprintf(`{"maxConcurrency":%d,"xudpConcurrency":-1,"xudpProxyUDP443":"skip"}`, maxConcurrency)
	s.enqueueMuxCommand(callbackID, chatID, messageID, routerID, "mux_enable", payload, fmt.Sprintf("⏳ XMUX поставлен в очередь\nmaxConcurrency: %d\nXUDP: off", maxConcurrency))
}

func (s *Server) enqueueMuxXUDPPreset(callbackID string, chatID int64, messageID int, data string) {
	parts := strings.SplitN(data, ":", 3)
	if len(parts) != 3 {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка XUDP", mainMenuKeyboard())
		return
	}
	routerID := parts[1]
	xudpConcurrency, err := strconv.Atoi(parts[2])
	if err != nil || xudpConcurrency == 0 || xudpConcurrency < -1 || xudpConcurrency > 1024 {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректное значение xudpConcurrency", muxKeyboard(routerID))
		return
	}
	payload := fmt.Sprintf(`{"xudpConcurrency":%d,"xudpProxyUDP443":"skip"}`, xudpConcurrency)
	label := strconv.Itoa(xudpConcurrency)
	if xudpConcurrency < 0 {
		label = "off"
	}
	s.enqueueMuxCommand(callbackID, chatID, messageID, routerID, "mux_enable", payload, "⏳ XUDP поставлен в очередь\nxudpConcurrency: "+label+"\nxudpProxyUDP443: skip\nTCP old mux: off")
}

func (s *Server) enqueueMuxSimple(callbackID string, chatID int64, messageID int, data, action, label string) {
	routerID := strings.TrimSpace(strings.TrimPrefix(data, label+":"))
	if routerID == "" {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка XMUX/XUDP", mainMenuKeyboard())
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
