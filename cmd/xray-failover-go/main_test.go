package main

import (
	"encoding/base64"
	"testing"
)

const sampleVLESS = "vless://11111111-1111-1111-1111-111111111111@example.com:443?type=tcp&security=reality&pbk=publickey&sid=abcd&fp=chrome&sni=example.com&encryption=none#Sample"

func TestExtractVLESSLinksFromPlainSubscription(t *testing.T) {
	links := extractVLESSLinks([]byte("# comment\n" + sampleVLESS + "\n"))
	if len(links) != 1 {
		t.Fatalf("expected 1 link, got %d", len(links))
	}
	if links[0] != sampleVLESS {
		t.Fatalf("unexpected link: %s", links[0])
	}
}

func TestExtractVLESSLinksFromBase64Subscription(t *testing.T) {
	payload := base64.StdEncoding.EncodeToString([]byte(sampleVLESS + "\n"))
	links := extractVLESSLinks([]byte(payload))
	if len(links) != 1 {
		t.Fatalf("expected 1 link, got %d", len(links))
	}
	if links[0] != sampleVLESS {
		t.Fatalf("unexpected link: %s", links[0])
	}
}

func TestParseVLESS(t *testing.T) {
	profile, err := parseVLESS(sampleVLESS)
	if err != nil {
		t.Fatalf("parseVLESS failed: %v", err)
	}
	if profile.UUID != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("unexpected UUID: %s", profile.UUID)
	}
	if profile.Server != "example.com" {
		t.Fatalf("unexpected server: %s", profile.Server)
	}
	if profile.Port != 443 {
		t.Fatalf("unexpected port: %d", profile.Port)
	}
	if profile.Params["security"] != "reality" {
		t.Fatalf("unexpected security: %s", profile.Params["security"])
	}
}

func TestBuildXrayConfigRejectsRealityWithoutPublicKey(t *testing.T) {
	profile, err := parseVLESS("vless://11111111-1111-1111-1111-111111111111@example.com:443?type=tcp&security=reality&encryption=none#Broken")
	if err != nil {
		t.Fatalf("parseVLESS failed: %v", err)
	}

	_, err = buildXrayConfig(profile, cliOptions{listenHost: "127.0.0.1", listenPort: 10808, profileName: "vless-out"})
	if err == nil {
		t.Fatal("expected REALITY profile without pbk to fail")
	}
}

func TestBuildXrayConfigForReality(t *testing.T) {
	profile, err := parseVLESS(sampleVLESS)
	if err != nil {
		t.Fatalf("parseVLESS failed: %v", err)
	}

	cfg, err := buildXrayConfig(profile, cliOptions{listenHost: "127.0.0.1", listenPort: 10808, profileName: "vless-out"})
	if err != nil {
		t.Fatalf("buildXrayConfig failed: %v", err)
	}

	outbounds := cfg["outbounds"].([]interface{})
	first := outbounds[0].(map[string]interface{})
	stream := first["streamSettings"].(map[string]interface{})
	if stream["security"] != "reality" {
		t.Fatalf("unexpected security: %v", stream["security"])
	}
	if _, ok := stream["realitySettings"]; !ok {
		t.Fatal("missing realitySettings")
	}
}
