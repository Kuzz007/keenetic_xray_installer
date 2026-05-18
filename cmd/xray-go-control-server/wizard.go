package main

import (
	"fmt"
	"strings"
	"sync"
)

type wizardState struct {
	Flow     string
	Step     string
	RouterID string
	Name     string
	Slot     string
	Selector string
	Values   string
}

var wizardMu sync.Mutex
var wizardByChat = map[int64]wizardState{}

func wizardCancel(chatID int64) {
	wizardMu.Lock()
	delete(wizardByChat, chatID)
	wizardMu.Unlock()
}

func (s *Server) startAddRouterWizard(chatID int64) {
	wizardMu.Lock()
	wizardByChat[chatID] = wizardState{Flow: "add_router", Step: "router_id"}
	wizardMu.Unlock()
	s.sendMessage(chatID, "➕ Добавление роутера\n\nВведите ID роутера латиницей.\n\nПримеры: home, dacha, office\n\nДля отмены: /cancel")
}

func sourceKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "📊 Статус источников", CallbackData: "act:source_status:" + routerID}},
		{{Text: "⬆️ Заменить основной", CallbackData: "setsrc:primary:" + routerID}},
		{{Text: "⬇️ Заменить резервный", CallbackData: "setsrc:backup:" + routerID}},
		{{Text: "⬅️ Назад", CallbackData: "router:" + routerID}, {Text: "🏠 Главное меню", CallbackData: "menu"}},
	}}
}

func (s *Server) sendSourceMenu(chatID int64, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	name := routerID
	if rt != nil && strings.TrimSpace(rt.Name) != "" {
		name = rt.Name
	}
	s.mu.Unlock()
	if rt == nil {
		s.sendMessageWithKeyboard(chatID, "⚠️ Роутер не найден: "+routerID, s.routersKeyboard())
		return
	}
	s.sendMessageWithKeyboard(chatID, "🔗 Источники\n\n📡 "+name+"\nID: "+routerID+"\n\nВыберите действие для primary/backup источников.", sourceKeyboard(routerID))
}

func (s *Server) startSetSourceWizard(chatID int64, routerID, slot string) {
	wizardMu.Lock()
	wizardByChat[chatID] = wizardState{Flow: "set_source", Step: "selector", RouterID: routerID, Slot: slot}
	wizardMu.Unlock()
	s.sendMessage(chatID, "🔗 Замена источника\n\n📡 Роутер: "+routerID+"\nСлот: "+slot+"\n\nВведите selector.\n\nПримеры:\n• first\n• index:0\n• index:1\n\nМожно ввести просто 0 или 1 — бот преобразует в index:0 / index:1.\n\nДля отмены: /cancel")
}

func (s *Server) startCustomRoutesWizard(chatID int64, routerID string) {
	s.mu.Lock()
	_, ok := s.cfg.Routers[routerID]
	s.mu.Unlock()
	if !ok {
		s.sendMessage(chatID, "⚠️ Роутер не найден: "+routerID)
		return
	}
	wizardMu.Lock()
	wizardByChat[chatID] = wizardState{Flow: "custom_routes", Step: "id", RouterID: routerID}
	wizardMu.Unlock()
	s.sendMessage(chatID, "➕ Свой список маршрутов\n\n📡 Роутер: "+routerID+"\n\nВведите ID списка.\n\nПримеры:\n• mykino\n• work_sites\n• family-video\n\nРазрешены только латиница, цифры, _ и -.\n\nДля отмены: /cancel")
}

func (s *Server) handleWizardText(chatID int64, text string) bool {
	wizardMu.Lock()
	st, ok := wizardByChat[chatID]
	wizardMu.Unlock()
	if !ok {
		return false
	}
	text = strings.TrimSpace(text)
	if text == "/cancel" || strings.EqualFold(text, "cancel") {
		wizardCancel(chatID)
		s.sendMessage(chatID, "↩️ Диалог отменён.")
		return true
	}
	switch st.Flow {
	case "add_router":
		return s.handleAddRouterWizardStep(chatID, st, text)
	case "set_source":
		return s.handleSetSourceWizardStep(chatID, st, text)
	case "custom_routes":
		return s.handleCustomRoutesWizardStep(chatID, st, text)
	default:
		wizardCancel(chatID)
		s.sendMessage(chatID, "⚠️ Диалог сброшен: неизвестный flow.")
		return true
	}
}

func (s *Server) handleAddRouterWizardStep(chatID int64, st wizardState, text string) bool {
	switch st.Step {
	case "router_id":
		if !validRouterID(text) {
			s.sendMessage(chatID, "⚠️ Некорректный ID.\n\nИспользуй только латиницу, цифры, _ или -.\nПример: dacha\n\nДля отмены: /cancel")
			return true
		}
		s.mu.Lock()
		_, exists := s.cfg.Routers[text]
		s.mu.Unlock()
		if exists {
			s.sendMessage(chatID, "⚠️ Такой роутер уже есть: "+text+"\n\nВведите другой ID или /cancel")
			return true
		}
		st.RouterID = text
		st.Step = "name"
		wizardMu.Lock()
		wizardByChat[chatID] = st
		wizardMu.Unlock()
		s.sendMessage(chatID, "🏷 Имя роутера\n\nВведите display name.\n\nПримеры: Дом, Дача, Офис\n\nДля отмены: /cancel")
		return true
	case "name":
		name := strings.TrimSpace(text)
		if name == "" {
			name = st.RouterID
		}
		token, err := randomTokenHex(24)
		if err != nil {
			wizardCancel(chatID)
			s.sendMessage(chatID, "❌ Не удалось сгенерировать token:\n"+err.Error())
			return true
		}
		s.mu.Lock()
		if _, exists := s.cfg.Routers[st.RouterID]; exists {
			s.mu.Unlock()
			wizardCancel(chatID)
			s.sendMessage(chatID, "⚠️ Роутер уже существует: "+st.RouterID)
			return true
		}
		s.cfg.Routers[st.RouterID] = &Router{ID: st.RouterID, Name: name, Token: token}
		err = s.persistConfigLocked()
		if err != nil {
			delete(s.cfg.Routers, st.RouterID)
		}
		s.mu.Unlock()
		wizardCancel(chatID)
		if err != nil {
			s.sendMessage(chatID, "❌ Роутер не сохранён:\n"+err.Error())
			return true
		}
		serverURL := agentServerURL(s.cfg.Listen)
		s.sendMessageWithKeyboard(chatID, addRouterDoneMessage(st.RouterID, name, token, serverURL), routerKeyboard(st.RouterID))
		return true
	default:
		wizardCancel(chatID)
		s.sendMessage(chatID, "⚠️ Диалог сброшен.")
		return true
	}
}

func (s *Server) handleSetSourceWizardStep(chatID int64, st wizardState, text string) bool {
	switch st.Step {
	case "selector":
		st.Selector = normalizeSelector(text)
		st.Step = "source"
		wizardMu.Lock()
		wizardByChat[chatID] = st
		wizardMu.Unlock()
		s.sendMessage(chatID, "🔐 Источник\n\nSelector: "+st.Selector+"\n\nТеперь отправьте VLESS ссылку или subscription URL.\nСсылка не будет показана обратно в чат.\n\nДля отмены: /cancel")
		return true
	case "source":
		if strings.TrimSpace(text) == "" {
			s.sendMessage(chatID, "⚠️ Источник пустой.\n\nОтправьте ссылку или /cancel")
			return true
		}
		action := "set_primary_source"
		if st.Slot == "backup" {
			action = "set_backup_source"
		}
		id, err := s.enqueue(st.RouterID, Command{Action: action, Selector: st.Selector, Source: text})
		wizardCancel(chatID)
		if err != nil {
			s.sendMessage(chatID, err.Error())
			return true
		}
		extra := fmt.Sprintf("⏳ Источник поставлен в очередь\n%s\n\nSlot: %s\nSelector: %s\nЗначение скрыто.", id, st.Slot, st.Selector)
		mid := s.sendMessageWithKeyboardID(chatID, s.routerMenuTextWithExtra(st.RouterID, extra), s.currentRouterKeyboard(st.RouterID))
		if mid != 0 {
			s.setActiveMenu(st.RouterID, chatID, mid)
		}
		return true
	default:
		wizardCancel(chatID)
		s.sendMessage(chatID, "⚠️ Диалог сброшен.")
		return true
	}
}

func (s *Server) handleCustomRoutesWizardStep(chatID int64, st wizardState, text string) bool {
	switch st.Step {
	case "id":
		id := normalizeRouteCallbackID(text)
		if id == "" {
			s.sendMessage(chatID, "⚠️ Некорректный ID списка.\n\nРазрешены только латиница, цифры, _ и -.\nПример: mykino\n\nДля отмены: /cancel")
			return true
		}
		st.Selector = id
		st.Step = "values"
		wizardMu.Lock()
		wizardByChat[chatID] = st
		wizardMu.Unlock()
		s.sendMessage(chatID, "🧾 Значения списка\n\nID: "+id+"\n\nОтправьте домены/IP/CIDR, каждый с новой строки.\n\nПример:\nexample.com\ncdn.example.com\n1.2.3.0/24\n\nНе используйте https:// и пути.\nМаксимум: 300 строк.\n\nДля отмены: /cancel")
		return true
	case "values":
		values, count, err := normalizeCustomRouteValues(text)
		if err != nil {
			s.sendMessage(chatID, "⚠️ "+err.Error()+"\n\nОтправьте список заново или /cancel")
			return true
		}
		id, err := s.enqueue(st.RouterID, Command{Action: "routes_apply_custom", Selector: st.Selector, Source: values})
		wizardCancel(chatID)
		if err != nil {
			s.sendMessage(chatID, err.Error())
			return true
		}
		extra := fmt.Sprintf("⏳ Свой список маршрутов поставлен в очередь\n%s\n\nList: %s\nEntries: %d\nPayload скрыт.\n\nБудет создан backup running-config перед изменениями.", id, st.Selector, count)
		mid := s.sendMessageWithKeyboardID(chatID, s.routerMenuTextWithExtra(st.RouterID, extra), s.currentRouterKeyboard(st.RouterID))
		if mid != 0 {
			s.setActiveMenu(st.RouterID, chatID, mid)
		}
		return true
	default:
		wizardCancel(chatID)
		s.sendMessage(chatID, "⚠️ Диалог сброшен.")
		return true
	}
}

func normalizeCustomRouteValues(text string) (string, int, error) {
	lines := []string{}
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.ContainsAny(line, " \t|;&`$()<>\"'") {
			return "", 0, fmt.Errorf("недопустимые символы в строке: %s", line)
		}
		if strings.HasPrefix(line, "http://") || strings.HasPrefix(line, "https://") || strings.Contains(line, "://") {
			return "", 0, fmt.Errorf("URL не поддерживается, укажите домен без протокола: %s", line)
		}
		if strings.Contains(line, "/") && !looksLikeIPv4CIDR(line) {
			return "", 0, fmt.Errorf("пути не поддерживаются, либо укажите IPv4/CIDR: %s", line)
		}
		lines = append(lines, line)
		if len(lines) > 300 {
			return "", 0, fmt.Errorf("слишком много строк, максимум 300")
		}
	}
	if len(lines) == 0 {
		return "", 0, fmt.Errorf("список пустой")
	}
	return strings.Join(lines, "\n") + "\n", len(lines), nil
}

func looksLikeIPv4CIDR(value string) bool {
	parts := strings.Split(value, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return false
	}
	for _, r := range parts[0] + parts[1] {
		if (r >= '0' && r <= '9') || r == '.' {
			continue
		}
		return false
	}
	return strings.Count(parts[0], ".") == 3
}

func addRouterDoneMessage(routerID, name, token, serverURL string) string {
	msg := fmt.Sprintf("✅ Роутер добавлен\n\n📡 %s\nID: %s\n\nAgent token:\n%s\n\nОткрой меню роутера и нажми 📦 Установка агента.", name, routerID, token)
	if strings.Contains(serverURL, "VPS_IP") {
		msg += "\n\n⚠️ Если в команде установки будет VPS_IP, замени его на внешний IP или DNS VPS."
	}
	return msg
}

func agentServerURL(listen string) string {
	listen = strings.TrimSpace(listen)
	if listen == "" || strings.HasPrefix(listen, ":") || strings.HasPrefix(listen, "0.0.0.0:") || strings.HasPrefix(listen, "[::]:") {
		port := "18090"
		if idx := strings.LastIndex(listen, ":"); idx >= 0 && idx+1 < len(listen) {
			port = listen[idx+1:]
		}
		return "http://VPS_IP:" + port
	}
	if strings.HasPrefix(listen, "http://") || strings.HasPrefix(listen, "https://") {
		return listen
	}
	return "http://" + listen
}

func agentInstallCommand(serverURL, routerID, name, token string) string {
	return fmt.Sprintf("curl -fsSL -o /opt/bin/xray-go-agent-install https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-agent-install.sh\nchmod +x /opt/bin/xray-go-agent-install\n/opt/bin/xray-go-agent-install --server-url %s --router-id %s --router-name %s --agent-token %s --poll-interval 5", shellQuote(serverURL), shellQuote(routerID), shellQuote(name), shellQuote(token))
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func normalizeSelector(selector string) string {
	selector = strings.TrimSpace(selector)
	if selector == "" {
		return "first"
	}
	if selector == "first" || strings.HasPrefix(selector, "index:") {
		return selector
	}
	allDigits := true
	for _, r := range selector {
		if r < '0' || r > '9' {
			allDigits = false
			break
		}
	}
	if allDigits {
		return "index:" + selector
	}
	return selector
}
