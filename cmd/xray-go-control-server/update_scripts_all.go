package main

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

func (s *Server) routersKeyboardWithUpdateScripts() inlineKeyboard {
	kb := s.routersKeyboard()
	rows := [][]inlineButton{
		{{Text: "🩺 Диагностика всех", CallbackData: "doctor_all"}},
		{{Text: "🔄 Обновить скрипты на всех", CallbackData: "update_scripts_all"}},
		{{Text: "🔁 Обновить агентов на всех", CallbackData: "update_agents_all"}},
	}
	if len(kb.InlineKeyboard) == 0 {
		kb.InlineKeyboard = append(kb.InlineKeyboard, rows...)
		return kb
	}
	last := kb.InlineKeyboard[len(kb.InlineKeyboard)-1]
	kb.InlineKeyboard = append(kb.InlineKeyboard[:len(kb.InlineKeyboard)-1], rows...)
	kb.InlineKeyboard = append(kb.InlineKeyboard, last)
	return kb
}

func (s *Server) enqueueDoctorAll() string {
	return s.enqueueBulkActionWithCommandID("doctor", "doctor_all", "🩺 Диагностика поставлена в очередь", "Команда безопасная: выполняет doctor на каждом роутере и вернёт результат отдельным сообщением/в Results.")
}

func (s *Server) enqueueUpdateScriptsAll() string {
	return s.enqueueBulkActionWithCommandID("update_scripts", "update_scripts_all", "🔄 Обновление скриптов поставлено в очередь", "Команда безопасная: auto_latest --update-only --no-restart. Итог будет отправлен отдельным сообщением.")
}

func (s *Server) enqueueUpdateAgentsAll() string {
	return s.enqueueBulkAction("update_agent", "🔁 Обновление агентов поставлено в очередь", "Команда перезапустит agent service. После обновления ожидайте agent_start от каждого роутера.")
}

func (s *Server) enqueueBulkAction(action, title, note string) string {
	return s.enqueueBulkActionWithCommandID(action, action, title, note)
}

func (s *Server) enqueueBulkActionWithCommandID(action, idPrefix, title, note string) string {
	now := time.Now().Unix()
	commandID := fmt.Sprintf("%s-%d", idPrefix, now)
	s.mu.Lock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id := range s.cfg.Routers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	queued := make([]string, 0, len(ids))
	expected := map[string]string{}
	for _, id := range ids {
		rt := s.cfg.Routers[id]
		if rt == nil {
			continue
		}
		name := rt.Name
		if strings.TrimSpace(name) == "" {
			name = id
		}
		cmd := Command{ID: commandID, Action: action}
		rt.Queue = append(rt.Queue, cmd)
		queued = append(queued, fmt.Sprintf("• %s (%s): %s", name, id, cmd.ID))
		expected[id] = name
	}
	s.mu.Unlock()

	if idPrefix == "doctor_all" {
		rememberDoctorBatch(commandID, expected)
	}
	if idPrefix == "update_scripts_all" {
		rememberUpdateScriptsBatch(commandID, expected)
	}
	if len(queued) == 0 {
		return "⚠️ Роутеры не найдены."
	}
	return title + "\n\n" + strings.Join(queued, "\n") + "\n\n" + note
}

type updateScriptsBatch struct {
	CommandID string
	Expected  map[string]string
	Results   map[string]updateScriptsBatchResult
	CreatedAt time.Time
	Sent      bool
}

type updateScriptsBatchResult struct {
	RouterID string
	Name     string
	OK       bool
	Edition  string
	LogPath  string
}

var updateScriptsBatchState = struct {
	sync.Mutex
	batches map[string]*updateScriptsBatch
}{batches: map[string]*updateScriptsBatch{}}

func rememberUpdateScriptsBatch(commandID string, expected map[string]string) {
	if commandID == "" || len(expected) == 0 {
		return
	}
	updateScriptsBatchState.Lock()
	defer updateScriptsBatchState.Unlock()
	for id, b := range updateScriptsBatchState.batches {
		if time.Since(b.CreatedAt) > 2*time.Hour {
			delete(updateScriptsBatchState.batches, id)
		}
	}
	updateScriptsBatchState.batches[commandID] = &updateScriptsBatch{CommandID: commandID, Expected: expected, Results: map[string]updateScriptsBatchResult{}, CreatedAt: time.Now()}
}

func (s *Server) recordUpdateScriptsAllResult(routerName string, res Result) (string, bool) {
	if !strings.HasPrefix(res.CommandID, "update_scripts_all-") {
		return "", false
	}
	updateScriptsBatchState.Lock()
	defer updateScriptsBatchState.Unlock()
	b := updateScriptsBatchState.batches[res.CommandID]
	if b == nil || b.Sent {
		return "", false
	}
	name := strings.TrimSpace(routerName)
	if name == "" {
		name = res.RouterID
	}
	b.Results[res.RouterID] = updateScriptsBatchResult{RouterID: res.RouterID, Name: name, OK: res.OK, Edition: updateSummaryValue(res.Output, "edition"), LogPath: updateSummaryValue(res.Output, "log")}
	if len(b.Results) < len(b.Expected) {
		return "", false
	}
	b.Sent = true
	return formatUpdateScriptsBatchSummary(b), true
}

func updateSummaryValue(output, key string) string {
	prefix := key + ":"
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}

func formatUpdateScriptsBatchSummary(b *updateScriptsBatch) string {
	ids := make([]string, 0, len(b.Expected))
	for id := range b.Expected {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	okCount, failCount := 0, 0
	lines := []string{}
	for _, id := range ids {
		name := b.Expected[id]
		if strings.TrimSpace(name) == "" {
			name = id
		}
		r, got := b.Results[id]
		icon := "⚫"
		status := "NO RESULT"
		if got {
			if r.OK {
				icon = "✅"
				status = "OK"
				okCount++
			} else {
				icon = "❌"
				status = "FAIL"
				failCount++
			}
			if r.Edition != "" {
				status += " / " + r.Edition
			}
		} else {
			failCount++
		}
		lines = append(lines, fmt.Sprintf("%s %s: %s", icon, name, status))
	}
	return fmt.Sprintf("🔄 Обновление скриптов завершено\n\n✅ OK: %d\n❌ FAIL/NO RESULT: %d\n\n%s\n\nЛоги на роутерах: /opt/var/log/xray-go-update-scripts.log", okCount, failCount, strings.Join(lines, "\n"))
}
