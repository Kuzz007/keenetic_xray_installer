package main

import (
	"fmt"
	"strings"
	"time"
)

func onlineState(lastSeen time.Time) (string, string) {
	if !lastSeen.IsZero() && time.Since(lastSeen) < 30*time.Second {
		return "🟢", "online"
	}
	return "⚫", "offline"
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
	lines := []string{fmt.Sprintf("%s %s — %s", dot, name, state)}
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
		"",
	}
	parts := importantStatusParts(rt.Status)
	if len(parts) == 0 {
		lines = append(lines, "heartbeat: нет данных")
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
	out := []string{"📬 Последние события: " + rt.Name, ""}
	for _, r := range rt.Results {
		icon := "✅"
		if !r.OK {
			icon = "❌"
		}
		out = append(out, fmt.Sprintf("%s [%s] %s\n%s", icon, r.At, r.CommandID, limit(normalizeResultOutput(r.Output), 900)))
	}
	return strings.Join(out, "\n---\n")
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
		if p == "" || strings.HasPrefix(p, "features:") || seen[p] {
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
	case strings.Contains(lower, "active slot") || strings.Contains(lower, "активный слот"):
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