package main

import (
	"fmt"
	"strings"
	"time"
)

func agentUpdateKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{
			{Text: "✅ Latest", CallbackData: "agent-check:latest:" + routerID},
			{Text: "🧪 Dev", CallbackData: "agent-check:dev:" + routerID},
		},
		{
			{Text: "🔎 Статус", CallbackData: "agent-status:" + routerID},
			{Text: "↩️ Откат", CallbackData: "agent-rollback-confirm:" + routerID},
		},
		{
			{Text: "⬅️ К роутеру", CallbackData: "router:" + routerID},
			{Text: "🏠 Главное меню", CallbackData: "menu"},
		},
	}}
}

func agentUpdatePendingKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "⬅️ К роутеру", CallbackData: "router:" + routerID}},
		{{Text: "🏠 Главное меню", CallbackData: "menu"}},
	}}
}

func agentUpdateInstallKeyboard(routerID, channel string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "⬆️ Установить " + strings.ToUpper(channel), CallbackData: "agent-apply-confirm:" + channel + ":" + routerID}},
		{
			{Text: "✅ Latest", CallbackData: "agent-check:latest:" + routerID},
			{Text: "🧪 Dev", CallbackData: "agent-check:dev:" + routerID},
		},
		{{Text: "⬅️ Назад", CallbackData: "agent-update:" + routerID}},
	}}
}

func agentUpdateApplyConfirmKeyboard(routerID, channel string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "✅ Подтвердить установку", CallbackData: "agent-apply:" + channel + ":" + routerID}},
		{{Text: "Отмена", CallbackData: "agent-update:" + routerID}},
	}}
}

func agentUpdateRollbackConfirmKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "↩️ Подтвердить откат", CallbackData: "agent-rollback:" + routerID}},
		{{Text: "Отмена", CallbackData: "agent-update:" + routerID}},
	}}
}

func agentBootstrapKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{
			{Text: "✅ Latest", CallbackData: "agent-bootstrap:latest:" + routerID},
			{Text: "🧪 Dev", CallbackData: "agent-bootstrap:dev:" + routerID},
		},
		{{Text: "⬅️ К роутеру", CallbackData: "router:" + routerID}},
	}}
}

func agentBootstrapPendingKeyboard(routerID string) inlineKeyboard {
	return inlineKeyboard{InlineKeyboard: [][]inlineButton{
		{{Text: "🔄 Проверить статус", CallbackData: "agent-update:" + routerID}},
		{{Text: "⬅️ К роутеру", CallbackData: "router:" + routerID}},
	}}
}

func (s *Server) openAgentUpdateMenu(callbackID string, chatID int64, messageID int, routerID string) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	lastSeen := time.Time{}
	if rt != nil {
		lastSeen = rt.LastSeen
	}
	s.mu.Unlock()
	if rt == nil {
		s.editMenuOnly(callbackID, chatID, messageID, "Роутер не найден: "+routerID, s.routersKeyboardWithUpdateScripts())
		return
	}
	if _, state := onlineState(lastSeen); state != "online" {
		text := "🤖 Агент\n\nНет свежего heartbeat от роутера. Обновление не поставлено в очередь, чтобы не выбрать неверный механизм для неизвестной версии.\n\nПосле восстановления связи нажмите Агент ещё раз."
		s.editMenuOnly(callbackID, chatID, messageID, text, inlineKeyboard{InlineKeyboard: [][]inlineButton{
			{{Text: "🔄 Проверить снова", CallbackData: "agent-update:" + routerID}},
			{{Text: "⬅️ К роутеру", CallbackData: "router:" + routerID}},
		}})
		return
	}
	if !s.agentReleaseUpdateSupported(routerID) {
		text := "🤖 Агент\n\nТекущая версия использует старый механизм обновления. Выберите Latest или Dev — бот сам отправит привычную команду update_agent. Скачанный установщик возьмёт выбранный канал у control-server, обновит агент и переведёт его на HTTPS.\n\nКоманду на роутере копировать не нужно."
		s.editMenuOnly(callbackID, chatID, messageID, text, agentBootstrapKeyboard(routerID))
		return
	}
	s.setActiveAgentMenu(routerID, chatID, messageID)
	id, err := s.enqueue(routerID, Command{Action: "agent_update_status"})
	if err != nil {
		s.editMenuOnly(callbackID, chatID, messageID, err.Error(), s.routersKeyboardWithUpdateScripts())
		return
	}
	text := s.agentUpdateMenuText(routerID, "⏳ Читаю локальное состояние обновлений…\n"+id)
	s.editMenuOnly(callbackID, chatID, messageID, text, agentUpdateKeyboard(routerID))
}

func (s *Server) enqueueLegacyAgentBootstrap(callbackID string, chatID int64, messageID int, data string) {
	channel, routerID, ok := parseAgentChannelCallback(data, "agent-bootstrap")
	if !ok {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка bootstrap", mainMenuKeyboard())
		return
	}
	s.setActiveAgentMenu(routerID, chatID, messageID)
	id, err := s.enqueueLegacyAgentChannelUpdate(routerID, channel)
	if err != nil {
		s.editMenuOnly(callbackID, chatID, messageID, err.Error(), s.routersKeyboardWithUpdateScripts())
		return
	}
	text := s.agentUpdateMenuText(routerID, fmt.Sprintf("⏳ Обновление до %s поставлено в очередь\n%s\n\nСтарый агент выполнит обычный update_agent автоматически. После запуска новая версия переведёт подключение на HTTPS.", strings.ToUpper(channel), id))
	s.editMenuOnly(callbackID, chatID, messageID, text, agentBootstrapPendingKeyboard(routerID))
}

func (s *Server) enqueueLegacyAgentChannelUpdate(routerID, channel string) (string, error) {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	if rt == nil {
		s.mu.Unlock()
		return "", fmt.Errorf("unknown router: %s", routerID)
	}
	channel = normalizedAgentChannel(channel)
	rt.RequestedAgentChannel = channel
	queue := rt.Queue[:0]
	for _, pending := range rt.Queue {
		if pending.Action != "update_agent" {
			queue = append(queue, pending)
		}
	}
	id := fmt.Sprintf("update_agent-%d", time.Now().Unix())
	rt.Queue = append(queue, Command{ID: id, Action: "update_agent", Channel: channel})
	s.persistStateLocked()
	s.mu.Unlock()
	return id, nil
}

func (s *Server) enqueueAgentUpdateStatus(callbackID string, chatID int64, messageID int, routerID string) {
	s.setActiveAgentMenu(routerID, chatID, messageID)
	id, err := s.enqueue(routerID, Command{Action: "agent_update_status"})
	if err != nil {
		s.editMenuOnly(callbackID, chatID, messageID, err.Error(), s.routersKeyboardWithUpdateScripts())
		return
	}
	s.editMenuOnly(callbackID, chatID, messageID, s.agentUpdateMenuText(routerID, "⏳ Обновляю статус…\n"+id), agentUpdateKeyboard(routerID))
}

func (s *Server) enqueueAgentUpdateCheck(callbackID string, chatID int64, messageID int, data string) {
	channel, routerID, ok := parseAgentChannelCallback(data, "agent-check")
	if !ok {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка канала обновлений", mainMenuKeyboard())
		return
	}
	s.setActiveAgentMenu(routerID, chatID, messageID)
	id, err := s.enqueue(routerID, Command{Action: "agent_update_check", Channel: channel})
	if err != nil {
		s.editMenuOnly(callbackID, chatID, messageID, err.Error(), s.routersKeyboardWithUpdateScripts())
		return
	}
	extra := fmt.Sprintf("⏳ Проверяю канал %s…\n%s\n\nЕсли доступна другая сборка, установка продолжится автоматически в неактивный A/B-слот.", strings.ToUpper(channel), id)
	s.editMenuOnly(callbackID, chatID, messageID, s.agentUpdateMenuText(routerID, extra), agentUpdatePendingKeyboard(routerID))
}

func (s *Server) showAgentUpdateApplyConfirm(callbackID string, chatID int64, messageID int, data string) {
	channel, routerID, ok := parseAgentChannelCallback(data, "agent-apply-confirm")
	if !ok {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка подтверждения", mainMenuKeyboard())
		return
	}
	s.setActiveAgentMenu(routerID, chatID, messageID)
	preview := s.lastAgentCheckPreview(routerID, channel)
	text := "⚠️ Подтверждение обновления агента\n\n" + preview + "\n\nНовая версия будет установлена в неактивный A/B-слот. Если она не подтвердит связь с control-server, роутер автоматически вернёт предыдущую рабочую версию."
	s.editMenuOnly(callbackID, chatID, messageID, text, agentUpdateApplyConfirmKeyboard(routerID, channel))
}

func (s *Server) enqueueAgentUpdateApply(callbackID string, chatID int64, messageID int, data string) {
	channel, routerID, ok := parseAgentChannelCallback(data, "agent-apply")
	if !ok {
		s.editMenuOnly(callbackID, chatID, messageID, "Некорректная кнопка установки", mainMenuKeyboard())
		return
	}
	s.setActiveAgentMenu(routerID, chatID, messageID)
	expectedVersion, expectedSHA256, found := s.lastAgentCheckExpectation(routerID, channel)
	if !found {
		s.editMenuOnly(callbackID, chatID, messageID, s.agentUpdateMenuText(routerID, "Предпросмотр канала отсутствует или устарел. Сначала снова нажмите Latest или Dev."), agentUpdateKeyboard(routerID))
		return
	}
	id, err := s.enqueue(routerID, Command{Action: "agent_update_apply", Channel: channel, ExpectedVersion: expectedVersion, ExpectedSHA256: expectedSHA256})
	if err != nil {
		s.editMenuOnly(callbackID, chatID, messageID, err.Error(), s.routersKeyboardWithUpdateScripts())
		return
	}
	extra := fmt.Sprintf("⏳ Установка %s поставлена в очередь\n%s\n\nСначала агент скачает и проверит сборку. Перезапуск произойдёт только после успешной проверки.", strings.ToUpper(channel), id)
	s.editMenuOnly(callbackID, chatID, messageID, s.agentUpdateMenuText(routerID, extra), agentUpdateKeyboard(routerID))
}

func (s *Server) showAgentUpdateRollbackConfirm(callbackID string, chatID int64, messageID int, routerID string) {
	s.setActiveAgentMenu(routerID, chatID, messageID)
	text := s.agentUpdateMenuText(routerID, "⚠️ Вернуть агента на второй локальный A/B-слот?\n\nОткат выполняется без скачивания из интернета. Перед переключением агент повторно проверит SHA256 и запуск сохранённого бинарника.")
	s.editMenuOnly(callbackID, chatID, messageID, text, agentUpdateRollbackConfirmKeyboard(routerID))
}

func (s *Server) enqueueAgentUpdateRollback(callbackID string, chatID int64, messageID int, routerID string) {
	s.setActiveAgentMenu(routerID, chatID, messageID)
	id, err := s.enqueue(routerID, Command{Action: "agent_update_rollback"})
	if err != nil {
		s.editMenuOnly(callbackID, chatID, messageID, err.Error(), s.routersKeyboardWithUpdateScripts())
		return
	}
	s.editMenuOnly(callbackID, chatID, messageID, s.agentUpdateMenuText(routerID, "⏳ Откат поставлен в очередь\n"+id), agentUpdateKeyboard(routerID))
}

func parseAgentChannelCallback(data, action string) (string, string, bool) {
	parts := strings.SplitN(data, ":", 3)
	if len(parts) != 3 || parts[0] != action {
		return "", "", false
	}
	channel := strings.ToLower(strings.TrimSpace(parts[1]))
	if channel != "latest" && channel != "dev" {
		return "", "", false
	}
	routerID := strings.TrimSpace(parts[2])
	if !validRouterID(routerID) {
		return "", "", false
	}
	return channel, routerID, true
}

func (s *Server) agentReleaseUpdateSupported(routerID string) bool {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	status := ""
	if rt != nil {
		status = rt.Status
	}
	s.mu.Unlock()
	return rt != nil && featuresFromStatus(status)["agent_release_update"]
}

func (s *Server) agentUpdateMenuText(routerID, extra string) string {
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	name := routerID
	status := ""
	if rt != nil {
		status = rt.Status
		if strings.TrimSpace(rt.Name) != "" {
			name = rt.Name
		}
	}
	s.mu.Unlock()
	version := agentVersionFromRouterStatus(status)
	if version == "" {
		version = "неизвестна"
	}
	text := "🤖 Агент\n\n📡 " + name + "\nID: " + routerID + "\nВерсия по heartbeat: " + version
	if strings.TrimSpace(extra) != "" {
		text += "\n\n" + strings.TrimSpace(extra)
	}
	return limit(text, 3900)
}

func agentVersionFromRouterStatus(status string) string {
	marker := "agent: go version="
	idx := strings.Index(status, marker)
	if idx < 0 {
		return ""
	}
	value := status[idx+len(marker):]
	if end := strings.Index(value, ";"); end >= 0 {
		value = value[:end]
	}
	return strings.TrimSpace(value)
}

func isAgentUpdateResult(commandID string) bool {
	return strings.HasPrefix(commandID, "agent_update_") || strings.HasPrefix(commandID, "update_agent-") || commandID == "agent_start"
}

func (s *Server) editActiveAgentUpdateResult(routerID string, res Result) bool {
	active, ok := s.activeMenu(routerID)
	if !ok || active.Kind != "agent-update" {
		return false
	}
	extra := formatAgentUpdateResult(res)
	keyboard := agentUpdateKeyboard(routerID)
	if strings.HasPrefix(res.CommandID, "agent_update_check-") && res.OK {
		values := parseAgentUpdateValues(res.Output)
		channel := values["channel"]
		if values["update_available"] == "yes" && (channel == "latest" || channel == "dev") {
			version := strings.TrimSpace(values["target_version"])
			sha := strings.ToLower(strings.TrimSpace(values["target_sha256"]))
			if version != "" && len(sha) == 64 {
				id, err := s.enqueue(routerID, Command{Action: "agent_update_apply", Channel: channel, ExpectedVersion: version, ExpectedSHA256: sha})
				if err != nil {
					extra += "\n\n❌ Не удалось поставить установку в очередь: " + err.Error()
				} else {
					extra += "\n\n⏳ Установка " + strings.ToUpper(channel) + " запущена автоматически.\n" + id
					keyboard = agentUpdatePendingKeyboard(routerID)
				}
			}
		}
	}
	text := s.agentUpdateMenuText(routerID, extra)
	return s.editMessageWithKeyboard(active.ChatID, active.MessageID, text, keyboard)
}

func formatAgentUpdateResult(res Result) string {
	values := parseAgentUpdateValues(res.Output)
	lines := []string{}
	switch {
	case res.CommandID == "agent_update_committed":
		lines = append(lines, "✅ Новая версия подтверждена control-server и отмечена рабочей.")
	case res.CommandID == "agent_update_rolled_back":
		lines = append(lines, "⚠️ Новая версия не прошла проверку. Выполнен автоматический откат.")
	case res.CommandID == "agent_start":
		lines = append(lines, "✅ Агент снова в сети после запуска.")
	case strings.HasPrefix(res.CommandID, "update_agent-"):
		if res.OK {
			lines = append(lines, "⏳ Старый агент принял автоматическое обновление и запускает установщик выбранного канала.")
		} else {
			lines = append(lines, "❌ Старый агент не смог запустить автоматическое обновление.")
		}
	case strings.HasPrefix(res.CommandID, "agent_update_check-"):
		if res.OK {
			lines = append(lines, "🔎 Проверка канала завершена.")
		} else {
			lines = append(lines, "❌ Не удалось проверить канал.")
		}
	case strings.HasPrefix(res.CommandID, "agent_update_apply-"):
		if res.OK {
			lines = append(lines, "⏳ Обновление подготовлено. Агент перезапускается; автоматический откат активен.")
		} else {
			lines = append(lines, "❌ Обновление не было запущено.")
		}
	case strings.HasPrefix(res.CommandID, "agent_update_rollback-"):
		if res.OK {
			lines = append(lines, "⏳ Локальный откат подготовлен. Агент перезапускается.")
		} else {
			lines = append(lines, "❌ Откат не был запущен.")
		}
	case strings.HasPrefix(res.CommandID, "agent_update_status-"):
		lines = append(lines, "📍 Локальное состояние обновлений.")
	}
	labels := []struct {
		Key   string
		Label string
	}{
		{"status", "Состояние"},
		{"channel", "Канал"},
		{"current_version", "Текущая версия"},
		{"current_channel", "Текущий канал"},
		{"target_version", "Доступная версия"},
		{"target_commit", "Commit"},
		{"target_sha256", "SHA256 сборки"},
		{"architecture", "Архитектура"},
		{"active_slot", "Активный слот"},
		{"rollback_available", "Откат доступен"},
		{"rollback_version", "Версия для отката"},
		{"update_available", "Обновление доступно"},
		{"automatic_rollback", "Автооткат"},
		{"last_error", "Последняя ошибка"},
		{"rollback_reason", "Причина отката"},
	}
	for _, item := range labels {
		if value := strings.TrimSpace(values[item.Key]); value != "" {
			lines = append(lines, item.Label+": "+value)
		}
	}
	if !res.OK && strings.TrimSpace(res.Output) != "" && res.CommandID != "agent_update_rolled_back" {
		lines = append(lines, "Ошибка: "+strings.TrimSpace(res.Output))
	} else if len(lines) == 0 {
		lines = append(lines, strings.TrimSpace(res.Output))
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func parseAgentUpdateValues(output string) map[string]string {
	values := map[string]string{}
	for _, line := range strings.Split(output, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		values[key] = strings.TrimSpace(value)
	}
	return values
}

func (s *Server) lastAgentCheckPreview(routerID, channel string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	rt := s.cfg.Routers[routerID]
	if rt == nil {
		return "Роутер не найден."
	}
	for i := len(rt.Results) - 1; i >= 0; i-- {
		res := rt.Results[i]
		if !strings.HasPrefix(res.CommandID, "agent_update_check-") || !res.OK {
			continue
		}
		values := parseAgentUpdateValues(res.Output)
		if values["channel"] != channel {
			continue
		}
		return strings.Join([]string{
			"Канал: " + strings.ToUpper(channel),
			"Текущая версия: " + firstAgentUpdateValue(values["current_version"], "неизвестна"),
			"Новая версия: " + firstAgentUpdateValue(values["target_version"], "неизвестна"),
			"Commit: " + firstAgentUpdateValue(values["target_commit"], "неизвестен"),
			"Размер: " + formatAgentUpdateSize(values["size_bytes"]),
		}, "\n")
	}
	return "Канал: " + strings.ToUpper(channel) + "\nПредпросмотр устарел или отсутствует. Перед установкой агент повторно скачает manifest и выполнит все проверки."
}

func (s *Server) lastAgentCheckExpectation(routerID, channel string) (string, string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rt := s.cfg.Routers[routerID]
	if rt == nil {
		return "", "", false
	}
	for i := len(rt.Results) - 1; i >= 0; i-- {
		res := rt.Results[i]
		if !strings.HasPrefix(res.CommandID, "agent_update_check-") || !res.OK {
			continue
		}
		values := parseAgentUpdateValues(res.Output)
		if values["channel"] != channel || values["update_available"] != "yes" {
			continue
		}
		version := strings.TrimSpace(values["target_version"])
		sha := strings.ToLower(strings.TrimSpace(values["target_sha256"]))
		if version != "" && len(sha) == 64 {
			return version, sha, true
		}
	}
	return "", "", false
}

func formatAgentUpdateSize(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "неизвестен"
	}
	var size int64
	if _, err := fmt.Sscanf(raw, "%d", &size); err != nil || size <= 0 {
		return raw + " байт"
	}
	return fmt.Sprintf("%.1f МБ", float64(size)/(1024*1024))
}

func firstAgentUpdateValue(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return strings.TrimSpace(value)
}
