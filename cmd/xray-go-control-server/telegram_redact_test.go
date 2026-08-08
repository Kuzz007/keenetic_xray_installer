package main

import (
	"errors"
	"strings"
	"testing"
)

func TestRedactTelegramErrorHidesBotToken(t *testing.T) {
	token := "123456:secret-token"
	err := errors.New(`Get "https://api.telegram.org/bot` + token + `/getUpdates": timeout`)
	got := redactTelegramError(err, token)
	if strings.Contains(got, token) {
		t.Fatalf("token leaked in redacted error: %s", got)
	}
	if !strings.Contains(got, "<redacted>") {
		t.Fatalf("redaction marker missing: %s", got)
	}
}
