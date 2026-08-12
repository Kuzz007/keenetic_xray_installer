package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestBuildAWGXrayConfigPreservesSocksAndReplacesOutbounds(t *testing.T) {
	original := []byte(`{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "socks-in",
    "listen": "0.0.0.0",
    "port": 10808,
    "protocol": "socks",
    "settings": {
      "auth": "password",
      "accounts": [{"user": "router", "pass": "secret"}],
      "udp": true
    }
  }],
  "outbounds": [
    {"tag": "vless-out", "protocol": "vless", "settings": {"private": "old-profile"}},
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {"rules": [{"outboundTag": "vless-out"}]}
}`)

	encoded, socks, err := buildAWGXrayConfig(original, "awgx0")
	if err != nil {
		t.Fatal(err)
	}
	if socks.Address != "127.0.0.1" || socks.Port != 10808 || socks.Username != "router" || socks.Password != "secret" {
		t.Fatalf("SOCKS endpoint = %#v", socks)
	}
	var config map[string]any
	if err := json.Unmarshal(encoded, &config); err != nil {
		t.Fatal(err)
	}
	if _, exists := config["routing"]; exists {
		t.Fatal("old VLESS routing was retained")
	}
	outbounds := config["outbounds"].([]any)
	if len(outbounds) != 2 {
		t.Fatalf("outbound count = %d, want 2", len(outbounds))
	}
	awgOutbound := outbounds[0].(map[string]any)
	if awgOutbound["protocol"] != "freedom" || awgOutbound["tag"] != "awg-out" {
		t.Fatalf("unexpected AWG outbound: %#v", awgOutbound)
	}
	sockopt := awgOutbound["streamSettings"].(map[string]any)["sockopt"].(map[string]any)
	if sockopt["interface"] != "awgx0" || sockopt["mark"] != float64(51820) && sockopt["mark"] != 51820 {
		t.Fatalf("unexpected AWG sockopt: %#v", sockopt)
	}
	if !strings.Contains(string(encoded), `"pass": "secret"`) || strings.Contains(string(encoded), "old-profile") {
		t.Fatal("SOCKS settings were lost or old VLESS outbound was retained")
	}
}

func TestWriteFileAtomicUsesPrivateMode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows does not expose Unix permission bits; router and CI targets are Linux")
	}
	directory := filepath.Join(t.TempDir(), "awg")
	path := filepath.Join(directory, "single.conf")
	if err := ensurePrivateDir(directory); err != nil {
		t.Fatal(err)
	}
	if err := writeFileAtomic(path, []byte("private\n"), 0600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("profile mode = %04o, want 0600", info.Mode().Perm())
	}
	dirInfo, err := os.Stat(directory)
	if err != nil {
		t.Fatal(err)
	}
	if dirInfo.Mode().Perm() != 0700 {
		t.Fatalf("state directory mode = %04o, want 0700", dirInfo.Mode().Perm())
	}
}

func TestParseHealthURLIsFailClosed(t *testing.T) {
	for _, value := range []string{"https://example.com/", "http://user:pass@example.com/", "file:///etc/passwd", "http://example.com:99999/"} {
		if _, err := parseHealthURL(value); err == nil {
			t.Fatalf("parseHealthURL(%q) unexpectedly succeeded", value)
		}
	}
	if _, err := parseHealthURL("http://example.com/generate_204"); err != nil {
		t.Fatal(err)
	}
}

func TestFindSocksEndpointRejectsMissingInbound(t *testing.T) {
	if _, err := findSocksEndpoint(map[string]any{"inbounds": []any{}}); err == nil {
		t.Fatal("missing SOCKS inbound must fail")
	}
}

func TestAvailableMemoryKB(t *testing.T) {
	path := filepath.Join(t.TempDir(), "meminfo")
	if err := os.WriteFile(path, []byte("MemFree: 100 kB\nBuffers: 20 kB\nCached: 30 kB\nMemAvailable: 24000 kB\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := availableMemoryKB(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != 24000 {
		t.Fatalf("available memory = %d, want 24000", got)
	}
}

func TestValidateOptionsRejectsUnsafeInterfaceAndRelativeExecutables(t *testing.T) {
	opts := options{
		dir:           "/opt/etc/xray/awg",
		runtime:       "/opt/libexec/amneziawg-go",
		tools:         "/opt/bin/awg",
		interfaceName: "-help",
		xrayConfig:    "/opt/etc/xray/config.json",
		xrayInit:      "/opt/etc/init.d/S24xray",
	}
	if err := validateOptions(opts); err == nil {
		t.Fatal("option-like interface name must be rejected")
	}
	opts.interfaceName = "awgx0"
	opts.runtime = "amneziawg-go"
	if err := validateOptions(opts); err == nil {
		t.Fatal("relative runtime path must be rejected")
	}
}
