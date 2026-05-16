package main

import (
	"fmt"
	"sort"
	"strings"
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
	return s.enqueueBulkAction("doctor", "🩺 Диагностика поставлена в очередь", "Команда безопасная: выполняет doctor на каждом роутере и вернёт результат отдельным сообщением/в Results.")
}

func (s *Server) enqueueUpdateScriptsAll() string {
	return s.enqueueBulkAction("update_scripts", "🔄 Обновление скриптов поставлено в очередь", "Команда безопасная: auto_latest --update-only --no-restart.")
}

func (s *Server) enqueueUpdateAgentsAll() string {
	return s.enqueueBulkAction("update_agent", "🔁 Обновление агентов поставлено в очередь", "Команда перезапустит agent service. После обновления ожидайте agent_start от каждого роутера.")
}

func (s *Server) enqueueBulkAction(action, title, note string) string {
	now := time.Now().Unix()
	s.mu.Lock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id := range s.cfg.Routers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	queued := make([]string, 0, len(ids))
	for _, id := range ids {
		rt := s.cfg.Routers[id]
		if rt == nil {
			continue
		}
		name := rt.Name
		if strings.TrimSpace(name) == "" {
			name = id
		}
		cmd := Command{ID: fmt.Sprintf("%s-%d", action, now), Action: action}
		rt.Queue = append(rt.Queue, cmd)
		queued = append(queued, fmt.Sprintf("• %s (%s): %s", name, id, cmd.ID))
	}
	s.mu.Unlock()

	if len(queued) == 0 {
		return "⚠️ Роутеры не найдены."
	}
	return title + "\n\n" + strings.Join(queued, "\n") + "\n\n" + note
}
