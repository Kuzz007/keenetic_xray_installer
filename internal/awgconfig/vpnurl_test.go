package awgconfig

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestParseVPNURLSelfHostedAWG2(t *testing.T) {
	privateKey := testKey(1)
	publicKey := testKey(2)
	presharedKey := testKey(3)
	native := fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = 10.8.0.2/32, fd00::2/128
DNS = 1.1.1.1, 2606:4700:4700::1111
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 12
S2 = 34
S3 = 56
S4 = 78
H1 = 100-200
H2 = 300-400
H3 = 500-600
H4 = 700-800

[Peer]
PublicKey = %s
PresharedKey = %s
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = [2001:db8::1]:443
PersistentKeepalive = 25
`, privateKey, publicKey, presharedKey)
	link := makeVPNLink(t, guestEnvelope(t, native), true)

	profile, err := ParseVPNURL(link)
	if err != nil {
		t.Fatal(err)
	}
	if profile.Name != "Home AWG" || profile.HostName != "vpn.example.com" {
		t.Fatalf("unexpected identity: %#v", profile)
	}
	if profile.Container != "amnezia-awg2" || profile.AWGVersion != "2" {
		t.Fatalf("unexpected AWG type: %#v", profile)
	}
	if profile.EndpointHost != "2001:db8::1" || profile.EndpointPort != 443 {
		t.Fatalf("unexpected endpoint: %#v", profile)
	}
	if strings.Join(profile.Addresses, ",") != "10.8.0.2/32,fd00::2/128" {
		t.Fatalf("unexpected addresses: %v", profile.Addresses)
	}
	if strings.Join(profile.AllowedIPs, ",") != "0.0.0.0/0,::/0" {
		t.Fatalf("unexpected allowed IPs: %v", profile.AllowedIPs)
	}
	if profile.MTU != 1280 || !strings.Contains(profile.NativeConfig(), "PrivateKey = "+privateKey) {
		t.Fatal("validated native config was not retained")
	}

	publicJSON, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(publicJSON, []byte(privateKey)) || strings.Contains(profile.String(), privateKey) || strings.Contains(fmt.Sprintf("%#v", profile), privateKey) {
		t.Fatal("profile formatting leaked the private key")
	}
}

func TestParseVPNURLAllowsUncompressedJSONAndObjectLastConfig(t *testing.T) {
	native := validNativeConfig(t, "I1 = <r 4>")
	root := guestEnvelope(t, native)
	container := root["containers"].([]any)[0].(map[string]any)
	awg := container["awg"].(map[string]any)
	var lastConfig any
	if err := json.Unmarshal([]byte(awg["last_config"].(string)), &lastConfig); err != nil {
		t.Fatal(err)
	}
	awg["last_config"] = lastConfig

	link := makeVPNLink(t, root, false)
	profile, err := ParseVPNURL(link)
	if err != nil {
		t.Fatal(err)
	}
	if profile.AWGVersion != "1.5" {
		t.Fatalf("AWG version = %q, want 1.5", profile.AWGVersion)
	}
}

func TestParseVPNURLRejectsOutOfScopeConfigs(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(map[string]any)
		want   error
	}{
		{
			name: "premium api",
			mutate: func(root map[string]any) {
				root["api_config"] = map[string]any{"service_type": "premium"}
			},
			want: ErrPremiumConfig,
		},
		{
			name: "managed config version",
			mutate: func(root map[string]any) {
				root["config_version"] = 4
			},
			want: ErrPremiumConfig,
		},
		{
			name: "full access credentials",
			mutate: func(root map[string]any) {
				root["userName"] = "root"
				root["password"] = "do-not-log-this"
				root["port"] = 22
			},
			want: ErrFullAccess,
		},
		{
			name: "not awg",
			mutate: func(root map[string]any) {
				root["defaultContainer"] = "amnezia-xray"
				root["containers"] = []any{map[string]any{"container": "amnezia-xray"}}
			},
			want: ErrNotSelfHosted,
		},
		{
			name: "multiple containers",
			mutate: func(root map[string]any) {
				containers := root["containers"].([]any)
				root["containers"] = append(containers, containers[0])
			},
			want: ErrNotSelfHosted,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := guestEnvelope(t, validNativeConfig(t, "S3 = 56"))
			test.mutate(root)
			_, err := ParseVPNURL(makeVPNLink(t, root, true))
			if !errors.Is(err, test.want) {
				t.Fatalf("error = %v, want %v", err, test.want)
			}
			if strings.Contains(fmt.Sprint(err), "do-not-log-this") {
				t.Fatal("error leaked input credentials")
			}
		})
	}
}

func TestParseVPNURLRejectsOversizedQtPayload(t *testing.T) {
	payload := make([]byte, 6)
	binary.BigEndian.PutUint32(payload[:4], maxDecodedSize+1)
	link := "vpn://" + base64.RawURLEncoding.EncodeToString(payload)
	if _, err := ParseVPNURL(link); !errors.Is(err, ErrInvalidVPNLink) {
		t.Fatalf("error = %v, want invalid vpn link", err)
	}
}

func guestEnvelope(t *testing.T, native string) map[string]any {
	t.Helper()
	client, err := json.Marshal(map[string]any{"config": native})
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{
		"description":      "Home AWG",
		"hostName":         "vpn.example.com",
		"defaultContainer": "amnezia-awg2",
		"containers": []any{
			map[string]any{
				"container": "amnezia-awg2",
				"awg": map[string]any{
					"protocol_version": "2",
					"last_config":      string(client),
				},
			},
		},
	}
}

func validNativeConfig(t *testing.T, awgLine string) string {
	t.Helper()
	return fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = 10.8.0.2/32
%s

[Peer]
PublicKey = %s
AllowedIPs = 0.0.0.0/0
Endpoint = vpn.example.com:443
`, testKey(1), awgLine, testKey(2))
}

func makeVPNLink(t *testing.T, root map[string]any, compressed bool) string {
	t.Helper()
	payload, err := json.Marshal(root)
	if err != nil {
		t.Fatal(err)
	}
	if compressed {
		var buffer bytes.Buffer
		if err := binary.Write(&buffer, binary.BigEndian, uint32(len(payload))); err != nil {
			t.Fatal(err)
		}
		writer, err := zlib.NewWriterLevel(&buffer, 8)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(payload); err != nil {
			t.Fatal(err)
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		payload = buffer.Bytes()
	}
	return "vpn://" + base64.RawURLEncoding.EncodeToString(payload)
}

func testKey(value byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{value}, 32))
}
