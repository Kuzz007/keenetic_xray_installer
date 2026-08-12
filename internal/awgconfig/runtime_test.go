package awgconfig

import (
	"fmt"
	"strings"
	"testing"
)

func TestRenderSetConfRemovesSupervisorFieldsAndPinsEndpoint(t *testing.T) {
	raw := fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = 10.8.0.2/32
DNS = 1.1.1.1
MTU = 1280
Jc = 4

[Peer]
PublicKey = %s
AllowedIPs = 0.0.0.0/0
Endpoint = vpn.example.com:443
`, testKey(1), testKey(2))

	got, err := RenderSetConf(raw, "203.0.113.7:443")
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"Address =", "DNS =", "MTU =", "vpn.example.com"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("runtime config retained %q:\n%s", forbidden, got)
		}
	}
	if !strings.Contains(got, "PrivateKey = "+testKey(1)) || !strings.Contains(got, "Endpoint = 203.0.113.7:443") {
		t.Fatalf("runtime config lost required data:\n%s", got)
	}
}

func TestRenderSetConfRejectsHostnameAndPortChange(t *testing.T) {
	raw := validNativeConfig(t, "Jc = 4")
	for _, endpoint := range []string{"vpn.example.com:443", "203.0.113.7:444"} {
		if _, err := RenderSetConf(raw, endpoint); err == nil {
			t.Fatalf("RenderSetConf(%q) unexpectedly succeeded", endpoint)
		}
	}
}

func TestParseNativeConfigRejectsUnmanagedHooks(t *testing.T) {
	raw := strings.Replace(validNativeConfig(t, "Jc = 4"), "Address = 10.8.0.2/32", "Address = 10.8.0.2/32\nPostUp = curl https://example.com", 1)
	if _, err := ParseNativeConfig(raw); err == nil {
		t.Fatal("PostUp must not be accepted from an imported profile")
	}
}
