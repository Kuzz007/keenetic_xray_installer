package main

import "strings"

type routerFeatures map[string]bool

func featuresFromStatus(status string) routerFeatures {
	features := routerFeatures{}
	idx := strings.Index(status, "features:")
	if idx < 0 {
		// Backward compatibility: old agents did not report features,
		// so keep showing the full menu.
		features["legacy_full_menu"] = true
		return features
	}
	rest := status[idx+len("features:"):]
	if stop := strings.Index(rest, ";"); stop >= 0 {
		rest = rest[:stop]
	}
	for _, item := range strings.Split(rest, ",") {
		item = strings.TrimSpace(item)
		if item != "" {
			features[item] = true
		}
	}
	return features
}

func (f routerFeatures) has(name string) bool {
	if f["legacy_full_menu"] {
		return true
	}
	return f[name]
}

func routerKeyboardForStatus(routerID, status string) inlineKeyboard {
	f := featuresFromStatus(status)
	rows := [][]inlineButton{}

	statusRow := []inlineButton{}
	if f.has("status") {
		statusRow = append(statusRow, inlineButton{Text: "Статус", CallbackData: "act:status:" + routerID})
	}
	if f.has("doctor") {
		statusRow = append(statusRow, inlineButton{Text: "Doctor", CallbackData: "act:doctor:" + routerID})
	}
	if len(statusRow) > 0 {
		rows = append(rows, statusRow)
	}

	if f.has("switch") {
		rows = append(rows, []inlineButton{
			{Text: "Primary", CallbackData: "act:switch_primary:" + routerID},
			{Text: "Backup", CallbackData: "act:switch_backup:" + routerID},
		})
	}

	if f.has("source_update") {
		rows = append(rows, []inlineButton{{Text: "Источники", CallbackData: "sources:" + routerID}})
	}

	if f.has("recovery") {
		rows = append(rows, []inlineButton{
			{Text: "Recovery status", CallbackData: "act:recover_status:" + routerID},
			{Text: "Recover now", CallbackData: "act:recover:" + routerID},
		})
	}

	logRow := []inlineButton{}
	if f.has("history") {
		logRow = append(logRow, inlineButton{Text: "History", CallbackData: "act:history:" + routerID})
	}
	if f.has("watchdog") {
		logRow = append(logRow, inlineButton{Text: "Watchdog log", CallbackData: "act:watchdog:" + routerID})
	}
	if len(logRow) > 0 {
		rows = append(rows, logRow)
	}

	if f.has("recovery") {
		rows = append(rows, []inlineButton{
			{Text: "Recovery log", CallbackData: "act:recoverylog:" + routerID},
			{Text: "Results", CallbackData: "act:results:" + routerID},
		})
	} else {
		rows = append(rows, []inlineButton{{Text: "Results", CallbackData: "act:results:" + routerID}})
	}

	rows = append(rows, []inlineButton{{Text: "Удалить роутер", CallbackData: "delete-router:" + routerID}})
	rows = append(rows, []inlineButton{
		{Text: "Назад", CallbackData: "routers"},
		{Text: "Главное меню", CallbackData: "menu"},
	})
	return inlineKeyboard{InlineKeyboard: rows}
}
