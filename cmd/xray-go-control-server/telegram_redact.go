package main

import "strings"

func redactTelegramError(err error, token string) string {
	if err == nil {
		return ""
	}
	message := err.Error()
	if token == "" {
		return message
	}
	return strings.ReplaceAll(message, token, "<redacted>")
}
