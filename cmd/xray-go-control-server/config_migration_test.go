package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadConfigEnablesLegacyHTTPForExistingConfig(t *testing.T) {
	path := writeMigrationTestConfig(t, "")
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.AllowLegacyHTTP {
		t.Fatal("existing config without ALLOW_LEGACY_HTTP must keep old agents reachable")
	}
}

func TestLoadConfigCanDisableLegacyHTTP(t *testing.T) {
	path := writeMigrationTestConfig(t, "ALLOW_LEGACY_HTTP=\"0\"\n")
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AllowLegacyHTTP {
		t.Fatal("ALLOW_LEGACY_HTTP=0 was ignored")
	}

	s := &Server{cfg: cfg}
	if err := s.persistConfigLocked(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "ALLOW_LEGACY_HTTP=\"0\"") {
		t.Fatalf("disabled migration mode was not persisted:\n%s", data)
	}
}

func writeMigrationTestConfig(t *testing.T, extra string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "control.conf")
	content := "LISTEN=\":18090\"\n" + extra + "BOT_TOKEN=\"bot-token\"\nADMIN_USER_ID=\"1\"\nROUTERS=\"home:router-token:Home\"\n"
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}
