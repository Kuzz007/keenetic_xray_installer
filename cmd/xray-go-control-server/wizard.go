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
	s.sendMessage(chatID, "Введите ID роутера латиницей, например: home, dacha, office\n\nДля отмены: /cancel")
}

func sourceKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "Статус источников", CallbackData: "act:source_status:" + routerID}},
		{{Text: "Заменить основной", CallbackData: "setsrc:primary:" + routerID}},
		{{Text: "Заменить резервный", CallbackData: "setsrc:backup:" + routerID}},
		{{Text: "Назад", CallbackData: "router:" + routerID}, {Text: "Главное меню", CallbackData: "menu"}},
	}}
}

func (s *Server) sendSourceMenu(chatID int64, routerID string) {
	s.sendMessageWithKeyboard(chatID, "Источники роутера: "+routerID, sourceKeyboard(routerID))
}

func (s *Server) startSetSourceWizard(chatID int64, routerID, slot string) {
	wizardMu.Lock()
	wizardByChat[chatID] = wizardState{Flow: "set_source", Step: "selector", RouterID: routerID, Slot: slot}
	wizardMu.Unlock()
	s.sendMessage(chatID, "Роутер: "+routerID+"\nСлот: "+slot+"\n\nВведите selector, например: first, 0, 1 или имя профиля.\n\nДля отмены: /cancel")
}

func (s *Server) handleWizardText(chatID int64, text string) bool {
	wizardMu.Lock()
	st, ok := wizardByChat[chatID]
	wizardMu.Unlock()
	if !ok { return false }
	text = strings.TrimSpace(text)
	if text == "/cancel" || strings.EqualFold(text, "cancel") {
		wizardCancel(chatID)
		s.sendMessage(chatID, "Диалог отменён.")
		return true
	}
	switch st.Flow {
	case "add_router":
		return s.handleAddRouterWizardStep(chatID, st, text)
	case "set_source":
		return s.handleSetSourceWizardStep(chatID, st, text)
	default:
		wizardCancel(chatID)
		s.sendMessage(chatID, "Диалог сброшен: неизвестный flow.")
		return true
	}
}

func (s *Server) handleAddRouterWizardStep(chatID int64, st wizardState, text string) bool {
	switch st.Step {
	case "router_id":
		if !validRouterID(text) {
			s.sendMessage(chatID, "Некорректный ID. Используй только латиницу, цифры, _ или -. Пример: dacha\n\nДля отмены: /cancel")
			return true
		}
		s.mu.Lock()
		_, exists := s.cfg.Routers[text]
		s.mu.Unlock()
		if exists {
			s.sendMessage(chatID, "Такой роутер уже есть: "+text+"\nВведите другой ID или /cancel")
			return true
		}
		st.RouterID = text
		st.Step = "name"
		wizardMu.Lock()
		wizardByChat[chatID] = st
		wizardMu.Unlock()
		s.sendMessage(chatID, "Введите имя роутера, например: Дом, Дача, Офис\n\nДля отмены: /cancel")
		return true
	case "name":
		name := strings.TrimSpace(text)
		if name == "" { name = st.RouterID }
		token, err := randomTokenHex(24)
		if err != nil {
			wizardCancel(chatID)
			s.sendMessage(chatID, "Не удалось сгенерировать token: "+err.Error())
			return true
		}
		s.mu.Lock()
		if _, exists := s.cfg.Routers[st.RouterID]; exists {
			s.mu.Unlock()
			wizardCancel(chatID)
			s.sendMessage(chatID, "Роутер уже существует: "+st.RouterID)
			return true
		}
		s.cfg.Routers[st.RouterID] = &Router{ID: st.RouterID, Name: name, Token: token}
		err = s.persistConfigLocked()
		if err != nil { delete(s.cfg.Routers, st.RouterID) }
		s.mu.Unlock()
		wizardCancel(chatID)
		if err != nil {
			s.sendMessage(chatID, "Роутер не сохранён: "+err.Error())
			return true
		}
		s.sendMessageWithKeyboard(chatID, addRouterDoneMessage(st.RouterID, name, token, s.cfg.Listen), routerKeyboard(st.RouterID))
		return true
	default:
		wizardCancel(chatID)
		s.sendMessage(chatID, "Диалог сброшен.")
		return true
	}
}

func (s *Server) handleSetSourceWizardStep(chatID int64, st wizardState, text string) bool {
	switch st.Step {
	case "selector":
		if text == "" { text = "first" }
		st.Selector = text
		st.Step = "source"
		wizardMu.Lock()
		wizardByChat[chatID] = st
		wizardMu.Unlock()
		s.sendMessage(chatID, "Теперь отправьте VLESS ссылку или subscription URL.\nСсылка не будет показана обратно в чат.\n\nДля отмены: /cancel")
		return true
	case "source":
		if strings.TrimSpace(text) == "" {
			s.sendMessage(chatID, "Источник пустой. Отправьте ссылку или /cancel")
			return true
		}
		action := "set_primary_source"
		if st.Slot == "backup" { action = "set_backup_source" }
		id, err := s.enqueue(st.RouterID, Command{Action: action, Selector: st.Selector, Source: text})
		wizardCancel(chatID)
		if err != nil {
			s.sendMessage(chatID, err.Error())
			return true
		}
		s.sendMessageWithKeyboard(chatID, "Источник поставлен в очередь: "+id+"\nЗначение скрыто.", routerKeyboard(st.RouterID))
		return true
	default:
		wizardCancel(chatID)
		s.sendMessage(chatID, "Диалог сброшен.")
		return true
	}
}

func addRouterDoneMessage(routerID, name, token, listen string) string {
	serverURL := agentServerURL(listen)
	return fmt.Sprintf("Роутер добавлен: %s (%s)\n\nAgent token:\n%s\n\nГотовая команда для роутера Entware:\n\n%s\n\nЕсли в SERVER_URL указан VPS_IP, замени его на внешний IP или DNS VPS.", routerID, name, token, agentInstallCommand(serverURL, routerID, name, token))
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
