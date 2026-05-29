package main

import (
	"fmt"
	"sort"
	"strings"
)

const defaultRouterGroup = "Без группы"

func cleanRouterGroup(group string) string {
	group = strings.TrimSpace(group)
	group = strings.ReplaceAll(group, ":", "-")
	group = strings.ReplaceAll(group, ",", " ")
	group = strings.Join(strings.Fields(group), " ")
	if group == "" {
		return defaultRouterGroup
	}
	if len([]rune(group)) > 32 {
		runes := []rune(group)
		group = string(runes[:32])
	}
	return group
}

func routerGroupName(rt *Router) string {
	if rt == nil {
		return defaultRouterGroup
	}
	return cleanRouterGroup(rt.Group)
}

func routerDisplayName(id string, rt *Router) string {
	if rt == nil || strings.TrimSpace(rt.Name) == "" {
		return id
	}
	return rt.Name
}

func (s *Server) routerGroupsSnapshot() map[string][]*Router {
	s.mu.Lock()
	defer s.mu.Unlock()
	groups := map[string][]*Router{}
	for _, rt := range s.cfg.Routers {
		if rt == nil {
			continue
		}
		group := routerGroupName(rt)
		groups[group] = append(groups[group], rt)
	}
	for group := range groups {
		sort.Slice(groups[group], func(i, j int) bool { return groups[group][i].ID < groups[group][j].ID })
	}
	return groups
}

func (s *Server) routerGroupNames() []string {
	groups := s.routerGroupsSnapshot()
	names := make([]string, 0, len(groups))
	for group := range groups {
		names = append(names, group)
	}
	sort.Slice(names, func(i, j int) bool {
		if names[i] == defaultRouterGroup {
			return false
		}
		if names[j] == defaultRouterGroup {
			return true
		}
		return strings.ToLower(names[i]) < strings.ToLower(names[j])
	})
	return names
}

func (s *Server) groupedRouterList() string {
	groups := s.routerGroupsSnapshot()
	names := make([]string, 0, len(groups))
	total := 0
	online := 0
	for group, routers := range groups {
		names = append(names, group)
		for _, rt := range routers {
			total++
			_, state := onlineState(rt.LastSeen)
			if state == "online" {
				online++
			}
		}
	}
	if total == 0 {
		return "📡 Роутеры\n\nРоутеров пока нет."
	}
	sort.Slice(names, func(i, j int) bool {
		if names[i] == defaultRouterGroup {
			return false
		}
		if names[j] == defaultRouterGroup {
			return true
		}
		return strings.ToLower(names[i]) < strings.ToLower(names[j])
	})
	lines := []string{prettyRouterListHeader(total, online), "", "📁 Группы:"}
	for _, group := range names {
		groupOnline := 0
		for _, rt := range groups[group] {
			_, state := onlineState(rt.LastSeen)
			if state == "online" {
				groupOnline++
			}
		}
		lines = append(lines, fmt.Sprintf("• %s — 🟢 %d / всего %d", group, groupOnline, len(groups[group])))
	}
	return strings.Join(lines, "\n")
}

func (s *Server) routerGroupsKeyboard() inlineKeyboard {
	groups := s.routerGroupsSnapshot()
	names := s.routerGroupNames()
	rows := [][]inlineButton{}
	for _, group := range names {
		label := fmt.Sprintf("📁 %s (%d)", group, len(groups[group]))
		rows = append(rows, []inlineButton{{Text: label, CallbackData: "group:" + group}})
	}
	rows = append(rows, []inlineButton{{Text: "🔄 Обновить", CallbackData: "routers"}, {Text: "⬅️ Назад", CallbackData: "menu"}})
	return inlineKeyboard{InlineKeyboard: rows}
}

func (s *Server) routerGroupView(group string) (string, inlineKeyboard) {
	group = cleanRouterGroup(group)
	groups := s.routerGroupsSnapshot()
	routers := groups[group]
	if len(routers) == 0 {
		return "📁 " + group + "\n\nВ этой группе пока нет роутеров.", s.routerGroupsKeyboard()
	}
	online := 0
	lines := []string{"📁 " + group, ""}
	for _, rt := range routers {
		_, state := onlineState(rt.LastSeen)
		if state == "online" {
			online++
		}
	}
	lines = append(lines, fmt.Sprintf("🟢 online: %d  •  ⚫ offline: %d  •  всего: %d", online, len(routers)-online, len(routers)), "")
	for _, rt := range routers {
		lines = append(lines, prettyRouterListItem(routerDisplayName(rt.ID, rt), rt.LastSeen, rt.Status))
	}
	return strings.Join(lines, "\n"), s.routersInGroupKeyboard(group)
}

func (s *Server) routersInGroupKeyboard(group string) inlineKeyboard {
	group = cleanRouterGroup(group)
	groups := s.routerGroupsSnapshot()
	routers := groups[group]
	rows := [][]inlineButton{}
	for _, rt := range routers {
		text := routerDisplayName(rt.ID, rt)
		dot, _ := onlineState(rt.LastSeen)
		rows = append(rows, []inlineButton{{Text: dot + " " + text, CallbackData: "router:" + rt.ID}})
	}
	rows = append(rows, []inlineButton{{Text: "🔄 Обновить", CallbackData: "group:" + group}, {Text: "⬅️ К группам", CallbackData: "routers"}})
	rows = append(rows, []inlineButton{{Text: "🏠 Главное меню", CallbackData: "menu"}})
	return inlineKeyboard{InlineKeyboard: rows}
}
