package main

import (
	"encoding/base64"
	"fmt"
	"sort"
	"strings"
)

const ungroupedRouterGroup = "Без группы"

func normalizeRouterGroup(group string) string {
	return strings.TrimSpace(group)
}

func routerGroupLabel(group string) string {
	group = normalizeRouterGroup(group)
	if group == "" {
		return ungroupedRouterGroup
	}
	return group
}

func routerGroupKey(group string) string {
	return normalizeRouterGroup(group)
}

func encodeRouterGroupCallback(group string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(routerGroupKey(group)))
}

func decodeRouterGroupCallback(data string) (string, bool) {
	encoded := strings.TrimPrefix(data, "router-group:")
	if encoded == data || encoded == "" {
		return "", false
	}
	b, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return "", false
	}
	return routerGroupKey(string(b)), true
}

func parseRouterGroupAssignments(value string) map[string]string {
	groups := map[string]string{}
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		id, group, ok := strings.Cut(item, "=")
		if !ok {
			continue
		}
		id = strings.TrimSpace(id)
		group = normalizeRouterGroup(group)
		if id == "" || group == "" {
			continue
		}
		groups[id] = group
	}
	return groups
}

func formatRouterGroupAssignments(routers map[string]*Router) string {
	ids := make([]string, 0, len(routers))
	for id, rt := range routers {
		if rt == nil || normalizeRouterGroup(rt.Group) == "" {
			continue
		}
		ids = append(ids, id)
	}
	sort.Strings(ids)
	items := make([]string, 0, len(ids))
	for _, id := range ids {
		items = append(items, id+"="+normalizeRouterGroup(routers[id].Group))
	}
	return strings.Join(items, ",")
}

type routerGroupSummary struct {
	Name   string
	Total  int
	Online int
}

func (s *Server) routerGroupSummariesLocked() []routerGroupSummary {
	byGroup := map[string]*routerGroupSummary{}
	for _, rt := range s.cfg.Routers {
		if rt == nil {
			continue
		}
		group := routerGroupKey(rt.Group)
		summary := byGroup[group]
		if summary == nil {
			summary = &routerGroupSummary{Name: group}
			byGroup[group] = summary
		}
		summary.Total++
		_, state := onlineState(rt.LastSeen)
		if state == "online" {
			summary.Online++
		}
	}
	groups := make([]routerGroupSummary, 0, len(byGroup))
	for _, summary := range byGroup {
		groups = append(groups, *summary)
	}
	sort.Slice(groups, func(i, j int) bool {
		if groups[i].Name == "" {
			return false
		}
		if groups[j].Name == "" {
			return true
		}
		return strings.ToLower(groups[i].Name) < strings.ToLower(groups[j].Name)
	})
	return groups
}

func (s *Server) routerGroupsList() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	groups := s.routerGroupSummariesLocked()
	total, online := 0, 0
	for _, group := range groups {
		total += group.Total
		online += group.Online
	}
	lines := []string{prettyRouterListHeader(total, online), "", "Группы:"}
	if len(groups) == 0 {
		return strings.Join(lines, "\n")
	}
	for _, group := range groups {
		lines = append(lines, fmt.Sprintf("• %s — %d/%d online", routerGroupLabel(group.Name), group.Online, group.Total))
	}
	lines = append(lines, "", "Откройте группу, чтобы выбрать конкретный роутер.")
	return strings.Join(lines, "\n")
}

func (s *Server) routerGroupView(group string) (string, inlineKeyboard) {
	group = routerGroupKey(group)
	s.mu.Lock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id, rt := range s.cfg.Routers {
		if rt != nil && routerGroupKey(rt.Group) == group {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	online := 0
	items := []string{}
	for _, id := range ids {
		rt := s.cfg.Routers[id]
		if rt == nil {
			continue
		}
		_, state := onlineState(rt.LastSeen)
		if state == "online" {
			online++
		}
		name := id
		if strings.TrimSpace(rt.Name) != "" {
			name = rt.Name
		}
		items = append(items, prettyRouterListItem(name, rt.LastSeen, rt.Status))
	}
	s.mu.Unlock()

	lines := []string{fmt.Sprintf("📁 %s", routerGroupLabel(group)), fmt.Sprintf("Роутеры: %d/%d online", online, len(ids))}
	if len(items) == 0 {
		lines = append(lines, "", "В этой группе пока нет роутеров.")
	} else {
		lines = append(lines, "")
		lines = append(lines, items...)
	}
	return strings.Join(lines, "\n\n"), s.routerGroupKeyboard(group)
}

func (s *Server) routerGroupsKeyboard() inlineKeyboard {
	s.mu.Lock()
	groups := s.routerGroupSummariesLocked()
	s.mu.Unlock()
	rows := [][]inlineButton{}
	for _, group := range groups {
		text := fmt.Sprintf("📁 %s %d/%d", routerGroupLabel(group.Name), group.Online, group.Total)
		rows = append(rows, []inlineButton{{Text: text, CallbackData: "router-group:" + encodeRouterGroupCallback(group.Name)}})
	}
	rows = append(rows, []inlineButton{{Text: "➕ Добавить роутер", CallbackData: "add_router_help"}})
	rows = append(rows, []inlineButton{{Text: "🔄 Обновить", CallbackData: "routers"}, {Text: "⬅️ Назад", CallbackData: "menu"}})
	return inlineKeyboard{InlineKeyboard: rows}
}

func (s *Server) routerGroupKeyboard(group string) inlineKeyboard {
	group = routerGroupKey(group)
	s.mu.Lock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id, rt := range s.cfg.Routers {
		if rt != nil && routerGroupKey(rt.Group) == group {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	rows := [][]inlineButton{}
	for _, id := range ids {
		rt := s.cfg.Routers[id]
		text := id
		if rt != nil && strings.TrimSpace(rt.Name) != "" {
			text = rt.Name
		}
		if rt != nil {
			dot, _ := onlineState(rt.LastSeen)
			text = dot + " " + text
		}
		rows = append(rows, []inlineButton{{Text: text, CallbackData: "router:" + id}})
	}
	s.mu.Unlock()
	rows = append(rows, []inlineButton{{Text: "➕ Добавить в группу", CallbackData: "add-router-group:" + encodeRouterGroupCallback(group)}})
	rows = append(rows, []inlineButton{{Text: "🔄 Обновить", CallbackData: "router-group:" + encodeRouterGroupCallback(group)}})
	rows = append(rows, []inlineButton{{Text: "⬅️ Группы", CallbackData: "routers"}, {Text: "🏠 Главное меню", CallbackData: "menu"}})
	return inlineKeyboard{InlineKeyboard: rows}
}
