package awgconfig

import (
	"errors"
	"fmt"
	"testing"
)

func TestParseNativeConfigAWG3(t *testing.T) {
	config := fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = 10.0.0.2/32
HeaderProtectionKey = %s
ContentPaddingAddition = 8-16

[Peer]
PublicKey = %s
AllowedIPs = 0.0.0.0/0
Endpoint = example.com:585
`, testKey(1), testKey(4), testKey(2))
	profile, err := ParseNativeConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	if profile.AWGVersion != "3" || profile.EndpointPort != 585 {
		t.Fatalf("unexpected profile: %#v", profile)
	}
}

func TestParseNativeConfigRejectsPlainWireGuardAndAmbiguity(t *testing.T) {
	plain := fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = 10.0.0.2/32

[Peer]
PublicKey = %s
AllowedIPs = 0.0.0.0/0
Endpoint = example.com:443
`, testKey(1), testKey(2))
	if _, err := ParseNativeConfig(plain); !errors.Is(err, ErrInvalidNativeConfig) {
		t.Fatalf("plain WireGuard error = %v", err)
	}

	duplicatePeer := plain + "\n[Peer]\nPublicKey = " + testKey(3) + "\n"
	if _, err := ParseNativeConfig(duplicatePeer); !errors.Is(err, ErrInvalidNativeConfig) {
		t.Fatalf("duplicate Peer error = %v", err)
	}
}

func TestParseNativeConfigRejectsUnsafeEndpointHost(t *testing.T) {
	config := fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = 10.0.0.2/32
Jc = 4

[Peer]
PublicKey = %s
AllowedIPs = 0.0.0.0/0
Endpoint = $(command):443
`, testKey(1), testKey(2))
	if _, err := ParseNativeConfig(config); !errors.Is(err, ErrInvalidNativeConfig) {
		t.Fatalf("unsafe endpoint error = %v", err)
	}
}
