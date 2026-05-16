package main

import (
	"fmt"
	"strings"
	"time"
)

const routerOnlineTTL = 15 * time.Second

func onlineState(lastSeen time.Time) (string, string) {
	if !lastSeen.IsZero() && time.Since(lastSeen) < routerOnlineTTL {
		return "🟢", "online"
	}
	return "⚫", "offline"
}

func heartbeatAge(lastSeen time.Time) string {
	if lastSeen.IsZero() {
		return "нет данных"
	}
	age := time.Since(lastSeen)
	if age < 0 {
		age = 0
	}
	if age < time.Minute {
		return fmt.Sprintf("%d сек назад", int(age.Seconds()))
	}
	if age < time.Hour {
		return fmt.Sprintf("%d мин назад", int(age.Minutes()))
	}
	return fmt.Sprintf("%d ч назад", int(age.Hours()))
}

func prettyMainMenuText() string {
	return strings.TrimSpace(`🧭 Главное меню

Выберите действие для управления роутерами и failover.`)
}

func prettyRouterListHeader(total, online int) string {
	return fmt.Sprintf("📡 Роутеры\n\n🟢 online: %d  •  ⚫ offline: %d  •  всего: %d", online, total-online, total)
}

func prettyRouterListItem(name string, lastSeen time.Time, status string) string {
	dot, state := onlineState(lastSeen)
	lines := []string{fmt.Sprintf("%s %s — %s, heartbeat %s", dot, name, state, heartbeatAge(lastSeen))}
	for _, part := range importantStatusParts(status) {
		lines = append(lines, "   "+part)
	}
	return strings.Join(lines, "\n")
}

func prettyRouterCard(rt *Router) string {
	if rt == nil {
		return "unknown router"
	}
	dot, state := onlineState(rt.LastSeen)
	lines := []string{
		fmt.Sprintf("📡 %s", rt.Name),
		fmt.Sprintf("%s %s", dot, state),
		fmt.Sprintf("heartbeat: %s", heartbeatAge(rt.LastSeen)),
		"",
	}
	parts := importantStatusParts(rt.Status)
	if len(parts) == 0 {
		lines = append(lines, "status: нет данных")
	} else {
		for _, part := range parts {
			lines = append(lines, "• "+part)
		}
	}
	if !rt.LastSeen.IsZero() {
		lines = append(lines, "", "Последнее обновление: "+rt.LastSeen.Format("15:04:05"))
	}
	return strings.Join(lines, "\n")
}

func prettyResultMessage(routerName string, res Result) string {
	statusIcon := "✅"
	statusText := "OK"
	if !res.OK {
		statusIcon = "❌"
		statusText = "FAIL"
	}
	out := normalizeResultOutput(res.Output)
	return fmt.Sprintf("%s %s: %s %s\n\n%s", statusIcon, routerName, statusText, res.CommandID, limit(out, 3500))
}

func prettyResults(rt *Router) string {
	if rt == nil {
		return "unknown router"
	}
	if len(rt.Results) == 0 {
		return "📬 Результатов пока нет"
	}
	items := []string{}
	for _, r := range rt.Results {
		icon := "✅"
		if !r.OK {
			icon = "❌"
		}
		items = append(items, fmt.Sprintf("%s [%s] %s\n%s", icon, r.At, r.CommandID, limit(normalizeResultOutput(r.Output), 900)))
	}
	return "📬 Последние события: " + rt.Name + "\n\n" + strings.Join(items, "\n---\n")
}

func normalizeResultOutput(s string) string {
	s = strings.ReplaceAll(s, "\\n", "\n")
	s = strings.ReplaceAll(s, "\\t", "  ")
	s = strings.ReplaceAll(s, "\r", "")
	lines := []string{}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimRight(line, " \t")
		if strings.TrimSpace(line) == "" {
			if len(lines) == 0 || lines[len(lines)-1] == "" {
				continue
			}
			lines = append(lines, "")
			continue
		}
		lines = append(lines, line)
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func importantStatusParts(status string) []string {
	status = strings.TrimSpace(status)
	if status == "" {
		return nil
	}
	seen := map[string]bool{}
	out := []string{}
	for _, part := range strings.Split(status, ";") {
		p := strings.TrimSpace(part)
		if p == "" || strings.HasPrefix(p, "features:") || strings.HasPrefix(p, "capabilities:") || seen[p] {
			continue
		}
		seen[p] = true
		out = append(out, decorateStatusPart(p))
	}
	return out
}

func decorateStatusPart(part string) string {
	lower := strings.ToLower(part)
	switch {
	case strings.Contains(lower, "health: ok"):
		return "💚 " + part
	case strings.Contains(lower, "health:"):
		return "❤️ " + part
	case strings.Contains(lower, "active slot") || strings.Contains(lower, "active:") || strings.Contains(lower, "активный слот"):
		return "🔀 " + part
	case strings.Contains(lower, "cron: running") || strings.Contains(lower, "crond: running"):
		return "⏱ " + part
	case strings.Contains(lower, "cron:") || strings.Contains(lower, "crond:"):
		return "⚠️ " + part
	case strings.Contains(lower, "agent:"):
		return "🤖 " + part
	case strings.Contains(lower, "hourly recovery"):
		return "♻️ " + part
	default:
		return part
	}
}
