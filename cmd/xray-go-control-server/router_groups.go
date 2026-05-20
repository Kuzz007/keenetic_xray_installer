package main

import (
	"encoding/base64"
	"fmt"
	"sort"
	"strings"
)

const ungroupedRouterGroup = "Без группы"
const ungroupedRouterGroupCallback = "_"

func normalizeRouterGroup(group string) string { return strings.TrimSpace(group) }
func routerGroupKey(group string) string { return normalizeRouterGroup(group) }
func routerGroupLabel(group string) string { group = normalizeRouterGroup(group); if group == "" { return ungroupedRouterGroup }; return group }

func validRouterGroupName(group string) bool {
	group = normalizeRouterGroup(group)
	if group == "" || group == ungroupedRouterGroup || len([]rune(group)) > 40 { return false }
	return !strings.ContainsAny(group, ",=|\n\r\t")
}

func encodeRouterGroupCallback(group string) string {
	group = routerGroupKey(group)
	if group == "" { return ungroupedRouterGroupCallback }
	return base64.RawURLEncoding.EncodeToString([]byte(group))
}

func decodeRouterGroupCallback(data string) (string, bool) { return decodeRouterGroupValue(data, "router-group:") }
func decodeAddRouterGroupCallback(data string) (string, bool) { return decodeRouterGroupValue(data, "add-router-group:") }
func decodeGroupRenameCallback(data string) (string, bool) { return decodeRouterGroupValue(data, "group-rename:") }
func decodeGroupDeleteCallback(data string) (string, bool) { return decodeRouterGroupValue(data, "group-delete:") }
func decodeGroupDeleteConfirmCallback(data string) (string, bool) { return decodeRouterGroupValue(data, "confirm-delete-group:") }
func decodeGroupAddExistingCallback(data string) (string, bool) { return decodeRouterGroupValue(data, "group-add-existing:") }

func decodeRouterGroupValue(data, prefix string) (string, bool) {
	encoded := strings.TrimPrefix(data, prefix)
	if encoded == data || encoded == "" { return "", false }
	if encoded == ungroupedRouterGroupCallback { return "", true }
	b, err := base64.RawURLEncoding.DecodeString(encoded); if err != nil { return "", false }
	return routerGroupKey(string(b)), true
}

func parseGroupSetCallback(data string) (string, string, bool) {
	parts := strings.SplitN(strings.TrimPrefix(data, "group-set:"), ":", 2)
	if len(parts) != 2 || parts[0] == "" { return "", "", false }
	group, ok := decodeRouterGroupValue("router-group:"+parts[1], "router-group:")
	return parts[0], group, ok
}

func parseRouterGroupAssignments(value string) map[string]string {
	groups := map[string]string{}
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item); if item == "" { continue }
		id, group, ok := strings.Cut(item, "="); if !ok { continue }
		id = strings.TrimSpace(id); group = normalizeRouterGroup(group)
		if id == "" || group == "" { continue }
		groups[id] = group
	}
	return groups
}

func formatRouterGroupAssignments(routers map[string]*Router) string {
	ids := make([]string, 0, len(routers))
	for id, rt := range routers { if rt != nil && normalizeRouterGroup(rt.Group) != "" { ids = append(ids, id) } }
	sort.Strings(ids)
	items := make([]string, 0, len(ids))
	for _, id := range ids { items = append(items, id+"="+normalizeRouterGroup(routers[id].Group)) }
	return strings.Join(items, ",")
}

func parseRouterGroupNames(value string) []string {
	seen := map[string]bool{}
	groups := []string{}
	for _, item := range strings.Split(value, ",") {
		group := normalizeRouterGroup(item)
		if group == "" || seen[group] { continue }
		seen[group] = true; groups = append(groups, group)
	}
	sort.Slice(groups, func(i, j int) bool { return strings.ToLower(groups[i]) < strings.ToLower(groups[j]) })
	return groups
}

func formatRouterGroupNames(groups []string) string {
	seen := map[string]bool{}
	out := []string{}
	for _, group := range groups {
		group = normalizeRouterGroup(group)
		if group == "" || seen[group] { continue }
		seen[group] = true; out = append(out, group)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i]) < strings.ToLower(out[j]) })
	return strings.Join(out, ",")
}

type routerGroupSummary struct { Name string; Total int; Online int }

func (s *Server) routerGroupSummariesLocked() []routerGroupSummary {
	byGroup := map[string]*routerGroupSummary{}
	for _, group := range s.cfg.Groups { group = routerGroupKey(group); if group != "" { byGroup[group] = &routerGroupSummary{Name: group} } }
	for _, rt := range s.cfg.Routers {
		if rt == nil { continue }
		group := routerGroupKey(rt.Group)
		summary := byGroup[group]
		if summary == nil { summary = &routerGroupSummary{Name: group}; byGroup[group] = summary }
		summary.Total++
		_, state := onlineState(rt.LastSeen); if state == "online" { summary.Online++ }
	}
	groups := make([]routerGroupSummary, 0, len(byGroup))
	for _, summary := range byGroup { groups = append(groups, *summary) }
	sort.Slice(groups, func(i, j int) bool {
		if groups[i].Name == "" { return false }
		if groups[j].Name == "" { return true }
		return strings.ToLower(groups[i].Name) < strings.ToLower(groups[j].Name)
	})
	return groups
}

func (s *Server) ensureRouterGroupLocked(group string) {
	group = routerGroupKey(group); if group == "" { return }
	for _, existing := range s.cfg.Groups { if routerGroupKey(existing) == group { return } }
	s.cfg.Groups = append(s.cfg.Groups, group)
}

func (s *Server) routerGroupsList() string {
	s.mu.Lock(); defer s.mu.Unlock()
	groups := s.routerGroupSummariesLocked(); total, online := 0, 0
	for _, group := range groups { total += group.Total; online += group.Online }
	lines := []string{prettyRouterListHeader(total, online), "", "Группы:"}
	if len(groups) == 0 { return strings.Join(lines, "\n") }
	for _, group := range groups { lines = append(lines, fmt.Sprintf("• %s — %d/%d online", routerGroupLabel(group.Name), group.Online, group.Total)) }
	lines = append(lines, "", "Откройте группу, чтобы выбрать конкретный роутер.")
	return strings.Join(lines, "\n")
}

func (s *Server) routerGroupView(group string) (string, inlineKeyboard) {
	group = routerGroupKey(group)
	s.mu.Lock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id, rt := range s.cfg.Routers { if rt != nil && routerGroupKey(rt.Group) == group { ids = append(ids, id) } }
	sort.Strings(ids); online := 0; items := []string{}
	for _, id := range ids {
		rt := s.cfg.Routers[id]; if rt == nil { continue }
		_, state := onlineState(rt.LastSeen); if state == "online" { online++ }
		name := id; if strings.TrimSpace(rt.Name) != "" { name = rt.Name }
		items = append(items, prettyRouterListItem(name, rt.LastSeen, rt.Status))
	}
	s.mu.Unlock()
	lines := []string{fmt.Sprintf("📁 %s", routerGroupLabel(group)), fmt.Sprintf("Роутеры: %d/%d online", online, len(ids))}
	if len(items) == 0 { lines = append(lines, "", "В этой группе пока нет роутеров.") } else { lines = append(lines, ""); lines = append(lines, items...) }
	return strings.Join(lines, "\n\n"), s.routerGroupKeyboard(group)
}

func (s *Server) routerGroupsKeyboard() inlineKeyboard {
	s.mu.Lock(); groups := s.routerGroupSummariesLocked(); s.mu.Unlock()
	rows := [][]inlineButton{}
	for _, group := range groups {
		text := fmt.Sprintf("📁 %s %d/%d", routerGroupLabel(group.Name), group.Online, group.Total)
		rows = append(rows, []inlineButton{{Text: text, CallbackData: "router-group:" + encodeRouterGroupCallback(group.Name)}})
	}
	rows = append(rows, []inlineButton{{Text: "➕ Создать группу", CallbackData: "group-create"}})
	rows = append(rows, []inlineButton{{Text: "➕ Добавить роутер", CallbackData: "add_router_help"}})
	rows = append(rows, []inlineButton{{Text: "🔄 Обновить", CallbackData: "routers"}, {Text: "⬅️ Назад", CallbackData: "menu"}})
	return inlineKeyboard{InlineKeyboard: rows}
}

func (s *Server) routerGroupKeyboard(group string) inlineKeyboard {
	group = routerGroupKey(group)
	s.mu.Lock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id, rt := range s.cfg.Routers { if rt != nil && routerGroupKey(rt.Group) == group { ids = append(ids, id) } }
	sort.Strings(ids); rows := [][]inlineButton{}
	for _, id := range ids {
		rt := s.cfg.Routers[id]; text := id
		if rt != nil && strings.TrimSpace(rt.Name) != "" { text = rt.Name }
		if rt != nil { dot, _ := onlineState(rt.LastSeen); text = dot + " " + text }
		rows = append(rows, []inlineButton{{Text: text, CallbackData: "router:" + id}})
	}
	s.mu.Unlock()
	encoded := encodeRouterGroupCallback(group)
	rows = append(rows, []inlineButton{{Text: "➕ Добавить новый", CallbackData: "add-router-group:" + encoded}, {Text: "📥 Добавить существующий", CallbackData: "group-add-existing:" + encoded}})
	if group != "" { rows = append(rows, []inlineButton{{Text: "✏️ Переименовать", CallbackData: "group-rename:" + encoded}, {Text: "🗑 Удалить группу", CallbackData: "group-delete:" + encoded}}) }
	rows = append(rows, []inlineButton{{Text: "🔄 Обновить", CallbackData: "router-group:" + encoded}})
	rows = append(rows, []inlineButton{{Text: "⬅️ Группы", CallbackData: "routers"}, {Text: "🏠 Главное меню", CallbackData: "menu"}})
	return inlineKeyboard{InlineKeyboard: rows}
}

func (s *Server) routerGroupMoveView(group string) (string, inlineKeyboard) {
	group = routerGroupKey(group)
	s.mu.Lock()
	ids := make([]string, 0, len(s.cfg.Routers))
	for id, rt := range s.cfg.Routers { if rt != nil && routerGroupKey(rt.Group) != group { ids = append(ids, id) } }
	sort.Strings(ids); rows := [][]inlineButton{}
	for _, id := range ids {
		rt := s.cfg.Routers[id]; text := id
		if rt != nil && strings.TrimSpace(rt.Name) != "" { text = rt.Name }
		if rt != nil { text += " → " + routerGroupLabel(rt.Group) }
		rows = append(rows, []inlineButton{{Text: text, CallbackData: "group-set:" + id + ":" + encodeRouterGroupCallback(group)}})
	}
	s.mu.Unlock()
	encoded := encodeRouterGroupCallback(group)
	if len(rows) == 0 { rows = append(rows, []inlineButton{{Text: "Нет доступных роутеров", CallbackData: "router-group:" + encoded}}) }
	rows = append(rows, []inlineButton{{Text: "⬅️ Назад", CallbackData: "router-group:" + encoded}, {Text: "🏠 Главное меню", CallbackData: "menu"}})
	text := "📥 Добавить существующий роутер\n\nГруппа: " + routerGroupLabel(group) + "\n\nВыберите роутер для перемещения."
	return text, inlineKeyboard{InlineKeyboard: rows}
}

func (s *Server) setRouterGroup(chatID int64, messageID int, routerID, group string) {
	group = routerGroupKey(group)
	s.mu.Lock()
	rt := s.cfg.Routers[routerID]
	if rt == nil { s.mu.Unlock(); s.editOrSendMessageWithKeyboard(chatID, messageID, "⚠️ Роутер не найден: "+routerID, s.routersKeyboardWithUpdateScripts()); return }
	old := rt.Group; rt.Group = group; s.ensureRouterGroupLocked(group)
	err := s.persistConfigLocked(); if err != nil { rt.Group = old }
	s.mu.Unlock()
	if err != nil { s.editOrSendMessageWithKeyboard(chatID, messageID, "❌ Не удалось сохранить группу:\n"+err.Error(), s.routersKeyboardWithUpdateScripts()); return }
	text, kb := s.routerGroupView(group)
	s.editOrSendMessageWithKeyboard(chatID, messageID, "✅ Роутер перемещён\n\n"+text, kb)
}

func (s *Server) deleteRouterGroupConfirm(chatID int64, messageID int, group string) {
	group = routerGroupKey(group)
	if group == "" { s.editOrSendMessageWithKeyboard(chatID, messageID, "Группу Без группы удалить нельзя.", s.routersKeyboardWithUpdateScripts()); return }
	encoded := encodeRouterGroupCallback(group)
	kb := inlineKeyboard{InlineKeyboard: [][]inlineButton{{{Text: "✅ Удалить", CallbackData: "confirm-delete-group:" + encoded}, {Text: "⬅️ Отмена", CallbackData: "router-group:" + encoded}}}}
	s.editOrSendMessageWithKeyboard(chatID, messageID, "🗑 Удалить группу \""+group+"\"?\n\nРоутеры не будут удалены. Они будут перенесены в \"Без группы\".", kb)
}

func (s *Server) deleteRouterGroup(chatID int64, messageID int, group string) {
	group = routerGroupKey(group)
	if group == "" { s.editOrSendMessageWithKeyboard(chatID, messageID, "Группу Без группы удалить нельзя.", s.routersKeyboardWithUpdateScripts()); return }
	s.mu.Lock()
	oldGroups := append([]string(nil), s.cfg.Groups...)
	oldRouterGroups := map[string]string{}
	for id, rt := range s.cfg.Routers { if rt != nil { oldRouterGroups[id] = rt.Group; if routerGroupKey(rt.Group) == group { rt.Group = "" } } }
	newGroups := []string{}
	for _, existing := range s.cfg.Groups { if routerGroupKey(existing) != group { newGroups = append(newGroups, existing) } }
	s.cfg.Groups = newGroups
	err := s.persistConfigLocked()
	if err != nil { s.cfg.Groups = oldGroups; for id, old := range oldRouterGroups { if rt := s.cfg.Routers[id]; rt != nil { rt.Group = old } } }
	s.mu.Unlock()
	if err != nil { s.editOrSendMessageWithKeyboard(chatID, messageID, "❌ Не удалось удалить группу:\n"+err.Error(), s.routersKeyboardWithUpdateScripts()); return }
	s.editOrSendMessageWithKeyboard(chatID, messageID, "✅ Группа удалена. Роутеры перенесены в \"Без группы\".\n\n"+s.routerGroupsList(), s.routersKeyboardWithUpdateScripts())
}
