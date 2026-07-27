package main

import (
	"fmt"
	"strings"
)

func normalizeSelector(selector string) string {
	selector = strings.TrimSpace(selector)
	if selector == "" {
		return "first"
	}
	if selector == "first" || strings.HasPrefix(selector, "index:") {
		return selector
	}
	allDigits := true
	for _, r := range selector {
		if r < '0' || r > '9' {
			allDigits = false
			break
		}
	}
	if allDigits {
		return "index:" + selector
	}
	return selector
}

func agentServerURL(listen string) string {
	listen = strings.TrimSpace(listen)
	if listen == "" {
		return "https://<server-ip>:18090"
	}
	if strings.HasPrefix(listen, "http://") || strings.HasPrefix(listen, "https://") {
		return strings.TrimRight(listen, "/")
	}
	host := listen
	port := "18090"
	if strings.HasPrefix(host, ":") {
		port = strings.TrimPrefix(host, ":")
		host = "<server-ip>"
	} else if h, p, ok := strings.Cut(host, ":"); ok {
		host = h
		port = p
	}
	if host == "" || host == "0.0.0.0" || host == "::" || host == "[::]" {
		host = "<server-ip>"
	}
	if port == "" {
		port = "18090"
	}
	return "https://" + host + ":" + port
}

func addRouterDoneMessage(routerID, name, token, serverURL string) string {
	if strings.TrimSpace(name) == "" {
		name = routerID
	}
	return fmt.Sprintf(`✅ Роутер добавлен

📡 %s
ID: %s

Agent token:
%s

Server URL:
%s

Открой меню роутера и нажми 📦 Установка агента.`, name, routerID, token, serverURL)
}
