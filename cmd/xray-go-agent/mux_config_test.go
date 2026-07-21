package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// xhttpOutbound builds an outbound that is complete apart from its network name,
// so the network gate is the only thing that can reject it.
func xhttpOutbound(network string) map[string]interface{} {
	return map[string]interface{}{
		"tag":      "vless-out",
		"protocol": "vless",
		"streamSettings": map[string]interface{}{
			"network":       network,
			"xhttpSettings": map[string]interface{}{"extra": map[string]interface{}{}},
		},
	}
}

// bareOutbound carries nothing below streamSettings, for exercising creation.
func bareOutbound(network string) map[string]interface{} {
	return map[string]interface{}{
		"tag":      "vless-out",
		"protocol": "vless",
		"streamSettings": map[string]interface{}{
			"network": network,
		},
	}
}

func TestParseMuxPayloadDefaults(t *testing.T) {
	payload, err := parseMuxPayload("", "")
	if err != nil {
		t.Fatalf("parseMuxPayload failed: %v", err)
	}
	if payload.MaxConcurrency != 4 {
		t.Fatalf("expected default maxConcurrency 4, got %d", payload.MaxConcurrency)
	}
	if payload.XUDPConcurrency != -1 {
		t.Fatalf("expected xudpConcurrency -1 (off), got %d", payload.XUDPConcurrency)
	}
	if payload.XUDPProxyUDP443 != "skip" {
		t.Fatalf("expected xudpProxyUDP443 skip, got %q", payload.XUDPProxyUDP443)
	}
	if payload.ConfigPath != muxConfigPath {
		t.Fatalf("expected default config path %q, got %q", muxConfigPath, payload.ConfigPath)
	}
}

func TestParseMuxPayloadNumericSourceSetsMaxConcurrency(t *testing.T) {
	payload, err := parseMuxPayload("", "16")
	if err != nil {
		t.Fatalf("parseMuxPayload failed: %v", err)
	}
	if payload.MaxConcurrency != 16 {
		t.Fatalf("expected maxConcurrency 16, got %d", payload.MaxConcurrency)
	}
}

func TestParseMuxPayloadNonNumericSourceIsOutboundTag(t *testing.T) {
	payload, err := parseMuxPayload("", "proxy-out")
	if err != nil {
		t.Fatalf("parseMuxPayload failed: %v", err)
	}
	if payload.OutboundTag != "proxy-out" {
		t.Fatalf("expected outbound tag proxy-out, got %q", payload.OutboundTag)
	}
}

// Legacy bot payloads send {"concurrency": N}; it must map onto maxConcurrency.
func TestParseMuxPayloadMapsLegacyConcurrency(t *testing.T) {
	payload, err := parseMuxPayload("", `{"concurrency": 8}`)
	if err != nil {
		t.Fatalf("parseMuxPayload failed: %v", err)
	}
	if payload.MaxConcurrency != 8 {
		t.Fatalf("expected legacy concurrency to become maxConcurrency 8, got %d", payload.MaxConcurrency)
	}
	if !payload.legacyConcurrency {
		t.Fatal("expected legacyConcurrency flag to be set")
	}
}

func TestParseMuxPayloadMaxConcurrencyWinsOverLegacy(t *testing.T) {
	payload, err := parseMuxPayload("", `{"concurrency": 8, "maxConcurrency": 16}`)
	if err != nil {
		t.Fatalf("parseMuxPayload failed: %v", err)
	}
	if payload.MaxConcurrency != 16 {
		t.Fatalf("expected maxConcurrency 16 to win, got %d", payload.MaxConcurrency)
	}
	if payload.legacyConcurrency {
		t.Fatal("legacyConcurrency must stay false when maxConcurrency is explicit")
	}
}

// A payload that only tunes XUDP must not silently reset the existing XMUX width.
func TestParseMuxPayloadXUDPOnlySetsPreserveMax(t *testing.T) {
	payload, err := parseMuxPayload("", `{"xudpConcurrency": 8}`)
	if err != nil {
		t.Fatalf("parseMuxPayload failed: %v", err)
	}
	if !payload.preserveMax {
		t.Fatal("expected preserveMax when only xudpConcurrency is supplied")
	}
}

func TestParseMuxPayloadRejectsInvalidJSON(t *testing.T) {
	if _, err := parseMuxPayload("", `{"concurrency":`); err == nil {
		t.Fatal("expected malformed JSON payload to fail")
	}
}

func TestNormalizeMuxPayloadRejectsOutOfRange(t *testing.T) {
	cases := map[string]muxPayload{
		"maxConcurrency too high":  {MaxConcurrency: 2048},
		"xudpConcurrency too high": {XUDPConcurrency: 2048},
		"xudpConcurrency invalid":  {XUDPConcurrency: -7},
	}
	for name, payload := range cases {
		if _, err := normalizeMuxPayload(payload); err == nil {
			t.Fatalf("%s: expected validation error", name)
		}
	}
}

func TestResolveMuxPayloadKeepsCurrentMaxWhenPreserving(t *testing.T) {
	outbound := xhttpOutbound("xhttp")
	ss := outbound["streamSettings"].(map[string]interface{})
	ss["xhttpSettings"] = map[string]interface{}{
		"extra": map[string]interface{}{
			"xmux": map[string]interface{}{"maxConcurrency": float64(32)},
		},
	}

	payload, err := parseMuxPayload("", `{"xudpConcurrency": 8}`)
	if err != nil {
		t.Fatalf("parseMuxPayload failed: %v", err)
	}
	resolved := resolveMuxPayloadForOutbound(payload, outbound)
	if resolved.MaxConcurrency != 32 {
		t.Fatalf("expected existing maxConcurrency 32 to be preserved, got %d", resolved.MaxConcurrency)
	}
}

func TestXhttpExtraMapsRequiresXhttpNetwork(t *testing.T) {
	for _, network := range []string{"tcp", "ws", "grpc", ""} {
		// The outbound is otherwise complete, so only the network can reject it.
		_, _, _, _, err := xhttpExtraMaps(xhttpOutbound(network), false)
		if err == nil {
			t.Fatalf("network %q: expected XMUX to be rejected", network)
		}
		if !strings.Contains(err.Error(), "streamSettings.network") {
			t.Fatalf("network %q: expected the network gate to reject it, got %v", network, err)
		}
	}
}

func TestXhttpExtraMapsReportsMissingXhttpSettings(t *testing.T) {
	_, _, _, _, err := xhttpExtraMaps(bareOutbound("xhttp"), false)
	if err == nil {
		t.Fatal("expected missing xhttpSettings to be reported")
	}
	if !strings.Contains(err.Error(), "xhttpSettings") {
		t.Fatalf("expected an xhttpSettings error, got %v", err)
	}
}

func TestXhttpExtraMapsAcceptsXhttpAndSplithttp(t *testing.T) {
	for _, network := range []string{"xhttp", "splithttp", "XHTTP"} {
		outbound := xhttpOutbound(network)
		if _, _, _, _, err := xhttpExtraMaps(outbound, true); err != nil {
			t.Fatalf("network %q: unexpected error: %v", network, err)
		}
	}
}

func TestXhttpExtraMapsCreatesNestedMaps(t *testing.T) {
	outbound := bareOutbound("xhttp")
	_, xh, extra, _, err := xhttpExtraMaps(outbound, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if xh == nil || extra == nil {
		t.Fatal("expected xhttpSettings and extra to be created")
	}

	extra["xmux"] = muxMapFromPayload(muxPayload{MaxConcurrency: 8})
	ss := outbound["streamSettings"].(map[string]interface{})
	got := ss["xhttpSettings"].(map[string]interface{})["extra"].(map[string]interface{})
	if _, ok := got["xmux"]; !ok {
		t.Fatal("expected created maps to be wired into the outbound")
	}
}

func TestRemoveXmuxDropsEmptyExtra(t *testing.T) {
	outbound := xhttpOutbound("xhttp")
	_, _, extra, err := ensureXhttpExtraMaps(outbound)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	extra["xmux"] = muxMapFromPayload(muxPayload{MaxConcurrency: 4})

	removeXmux(outbound)

	xh := outbound["streamSettings"].(map[string]interface{})["xhttpSettings"].(map[string]interface{})
	if _, ok := xh["extra"]; ok {
		t.Fatal("expected empty extra to be removed alongside xmux")
	}
}

func TestRemoveXmuxKeepsExtraWithOtherKeys(t *testing.T) {
	outbound := xhttpOutbound("xhttp")
	_, _, extra, err := ensureXhttpExtraMaps(outbound)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	extra["xmux"] = muxMapFromPayload(muxPayload{MaxConcurrency: 4})
	extra["headers"] = map[string]interface{}{"Host": "example.com"}

	removeXmux(outbound)

	xh := outbound["streamSettings"].(map[string]interface{})["xhttpSettings"].(map[string]interface{})
	kept, ok := mapValue(xh["extra"])
	if !ok {
		t.Fatal("expected extra to survive when it still holds other keys")
	}
	if _, ok := kept["xmux"]; ok {
		t.Fatal("expected xmux to be removed")
	}
	if _, ok := kept["headers"]; !ok {
		t.Fatal("expected unrelated extra keys to be preserved")
	}
}

func TestApplyXUDPRoundTrip(t *testing.T) {
	outbound := xhttpOutbound("xhttp")
	payload, err := normalizeMuxPayload(muxPayload{MaxConcurrency: 8, XUDPConcurrency: 16, XUDPProxyUDP443: "skip"})
	if err != nil {
		t.Fatalf("normalizeMuxPayload failed: %v", err)
	}

	applyXUDP(outbound, payload)
	if !xudpMatches(outbound, payload) {
		t.Fatalf("expected applied XUDP to match payload, got %#v", outbound["mux"])
	}
}

func TestApplyXUDPRemovesMuxWhenDisabled(t *testing.T) {
	outbound := xhttpOutbound("xhttp")
	outbound["mux"] = map[string]interface{}{"enabled": true}

	payload, err := normalizeMuxPayload(muxPayload{MaxConcurrency: 8, XUDPConcurrency: -1})
	if err != nil {
		t.Fatalf("normalizeMuxPayload failed: %v", err)
	}
	applyXUDP(outbound, payload)

	if _, ok := outbound["mux"]; ok {
		t.Fatal("expected mux block to be removed when XUDP is off")
	}
	if !xudpMatches(outbound, payload) {
		t.Fatal("expected xudpMatches to accept an absent mux block when XUDP is off")
	}
}

func TestMuxMatchesComparesMaxConcurrency(t *testing.T) {
	payload := muxPayload{MaxConcurrency: 8}
	if !muxMatches(map[string]interface{}{"maxConcurrency": float64(8)}, payload) {
		t.Fatal("expected JSON float maxConcurrency to match")
	}
	if muxMatches(map[string]interface{}{"maxConcurrency": float64(4)}, payload) {
		t.Fatal("expected differing maxConcurrency to not match")
	}
	if muxMatches(map[string]interface{}{}, payload) {
		t.Fatal("expected missing maxConcurrency to not match")
	}
}

func TestFindMuxOutboundHonoursRequestedTag(t *testing.T) {
	cfg := map[string]interface{}{"outbounds": []interface{}{
		map[string]interface{}{"tag": "direct", "protocol": "freedom"},
		map[string]interface{}{"tag": "second", "protocol": "vless"},
	}}
	_, tag, protocol, err := findMuxOutbound(cfg, "second")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tag != "second" || protocol != "vless" {
		t.Fatalf("unexpected outbound: %s (%s)", tag, protocol)
	}
}

func TestFindMuxOutboundPrefersVLESSOverOrder(t *testing.T) {
	cfg := map[string]interface{}{"outbounds": []interface{}{
		map[string]interface{}{"tag": "shadow", "protocol": "shadowsocks"},
		map[string]interface{}{"tag": "proxy", "protocol": "vless"},
	}}
	_, tag, _, err := findMuxOutbound(cfg, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tag != "proxy" {
		t.Fatalf("expected vless outbound to win, got %q", tag)
	}
}

func TestFindMuxOutboundSkipsFreedomAndBlackhole(t *testing.T) {
	cfg := map[string]interface{}{"outbounds": []interface{}{
		map[string]interface{}{"tag": "direct", "protocol": "freedom"},
		map[string]interface{}{"tag": "block", "protocol": "blackhole"},
		map[string]interface{}{"tag": "proxy", "protocol": "trojan"},
	}}
	_, tag, _, err := findMuxOutbound(cfg, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tag != "proxy" {
		t.Fatalf("expected freedom/blackhole to be skipped, got %q", tag)
	}
}

func TestFindMuxOutboundErrors(t *testing.T) {
	if _, _, _, err := findMuxOutbound(map[string]interface{}{}, ""); err == nil {
		t.Fatal("expected missing outbounds to fail")
	}

	onlyDirect := map[string]interface{}{"outbounds": []interface{}{
		map[string]interface{}{"tag": "direct", "protocol": "freedom"},
	}}
	if _, _, _, err := findMuxOutbound(onlyDirect, ""); err == nil {
		t.Fatal("expected config without a proxy outbound to fail")
	}
	if _, _, _, err := findMuxOutbound(onlyDirect, "missing"); err == nil {
		t.Fatal("expected unknown requested tag to fail")
	}
}

// Backup reasons end up in a filename, so path separators must not survive.
func TestSafeBackupReasonStripsPathCharacters(t *testing.T) {
	got := safeBackupReason("../../etc/passwd")
	if strings.ContainsAny(got, `./\`) {
		t.Fatalf("expected path characters to be stripped, got %q", got)
	}
	if safeBackupReason("") != "manual" {
		t.Fatal("expected empty reason to fall back to manual")
	}
	if safeBackupReason("///") != "manual" {
		t.Fatal("expected fully stripped reason to fall back to manual")
	}
	if safeBackupReason("pre-xmux_1") != "pre-xmux_1" {
		t.Fatal("expected safe characters to be preserved")
	}
}

func TestIntValueAcceptsJSONNumberForms(t *testing.T) {
	cases := []interface{}{int(8), int64(8), float64(8), json.Number("8")}
	for _, value := range cases {
		got, ok := intValue(value)
		if !ok || got != 8 {
			t.Fatalf("value %#v: expected 8, got %d (ok=%v)", value, got, ok)
		}
	}
	if _, ok := intValue("8"); ok {
		t.Fatal("expected string to be rejected")
	}
}

func TestMuxReapplyAllowedWithoutInterval(t *testing.T) {
	if !muxReapplyAllowed(0) {
		t.Fatal("expected non-positive interval to always allow reapply")
	}
}
