package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

func (s *Server) routersKeyboardWithUpdateScripts() inlineKeyboard {
	kb := s.routersKeyboard()
	row := []inlineButton{{Text: "🔄 Обновить скрипты на всех", CallbackData: "update_scripts_all"}}
	if len(kb.InlineKeyboard) == 0 {
		kb.InlineKeyboard = append(kb.InlineKeyboard, row)
		return kb
	}
	last := kb.InlineKeyboard[len(kb.InlineKeyboard)-1]
	kb.InlineKeyboard = append(kb.InlineKeyboard[:len(kb.InlineKeyboard)-1], row, last)
	return kb
}

func (s *Server) enqueueUpdateScriptsAll() string {
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
		cmd := Command{ID: fmt.Sprintf("update_scripts-%d", now), Action: "update_scripts"}
		rt.Queue = append(rt.Queue, cmd)
		queued = append(queued, fmt.Sprintf("• %s (%s): %s", name, id, cmd.ID))
	}
	s.mu.Unlock()

	if len(queued) == 0 {
		return "⚠️ Роутеры не найдены."
	}
	return "🔄 Обновление скриптов поставлено в очередь\n\n" + strings.Join(queued, "\n") + "\n\nКоманда безопасная: auto_latest --update-only --no-restart."
}
