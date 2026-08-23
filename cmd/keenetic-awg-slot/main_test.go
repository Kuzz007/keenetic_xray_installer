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

	encoded, socks, err := buildAWGXrayConfig(original, "awgx0", 51820)
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

func TestRulePlanConflictsWithTableMarkOrPriority(t *testing.T) {
	plan := networkPlan{Table: 200, Mark: 51820, RulePref: 18020}
	for name, rules := range map[string]string{
		"table":       "100: from all lookup 200\n",
		"hex mark":    "100: from all fwmark 0xca6c lookup 201\n",
		"masked mark": "100: from all fwmark 0xca00/0xff00 lookup 201\n",
		"priority":    "18020: from all lookup 201\n",
	} {
		t.Run(name, func(t *testing.T) {
			if !rulePlanConflicts([]byte(rules), plan) {
				t.Fatalf("rules %q did not conflict with %#v", rules, plan)
			}
		})
	}
	if rulePlanConflicts([]byte("100: from all fwmark 0xffffaaa lookup 4096\n"), plan) {
		t.Fatal("unrelated Keenetic rule was reported as a conflict")
	}
}

func TestNetworkPlanFromStateSupportsLegacyCleanup(t *testing.T) {
	legacy := networkPlanFromState(runtimeState{})
	if legacy.Table != 51820 || legacy.Mark != 51820 || legacy.RulePref != 18020 {
		t.Fatalf("legacy plan = %#v", legacy)
	}
	current := networkPlanFromState(runtimeState{RouteTable: 200, RouteMark: 51821, RulePref: 18021})
	if current.Table != 200 || current.Mark != 51821 || current.RulePref != 18021 {
		t.Fatalf("current plan = %#v", current)
	}
}

func TestChooseNetworkPlanSkipsConflicts(t *testing.T) {
	inspected := make([]uint32, 0)
	plan, err := chooseNetworkPlan(
		[]byte("18020: from all lookup 199\n"),
		nil,
		func(ipv6 bool, table uint32) (bool, error) {
			inspected = append(inspected, table)
			return !ipv6 && table == 201, nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Table != 202 || plan.Mark != 51822 || plan.RulePref != 18022 {
		t.Fatalf("selected plan = %#v, want the third candidate", plan)
	}
	if len(inspected) != 3 || inspected[0] != 201 || inspected[1] != 202 || inspected[2] != 202 {
		t.Fatalf("inspected tables = %v", inspected)
	}
}

func TestLoadStateRejectsIncompleteNetworkPlan(t *testing.T) {
	opts := options{dir: t.TempDir()}
	state := runtimeState{
		Schema: stateSchema, Runtime: "/opt/libexec/amneziawg-go", Tools: "/opt/bin/awg", Interface: "awgx0",
		RouteTable: 200,
	}
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath(opts), data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadState(opts); err == nil || !strings.Contains(err.Error(), "incomplete network plan") {
		t.Fatalf("loadState error = %v, want incomplete network plan", err)
	}
}

func TestNetworkCleanupCommandsDeleteOnlyOwnedRoutes(t *testing.T) {
	state := runtimeState{
		Interface: "awgx0", RouteTable: 200, RouteMark: 51820, RulePref: 18020,
		RoutePrefixes: []string{"0.0.0.0/0", "::/0"},
	}
	commands := networkCleanupCommands(state)
	joined := make([]string, 0, len(commands))
	for _, command := range commands {
		joined = append(joined, strings.Join(command, " "))
	}
	result := strings.Join(joined, "\n")
	if strings.Contains(result, "route flush") {
		t.Fatalf("current cleanup flushes a whole table:\n%s", result)
	}
	for _, expected := range []string{
		"route del 0.0.0.0/0 dev awgx0 table 200",
		"-6 route del ::/0 dev awgx0 table 200",
	} {
		if !strings.Contains(result, expected) {
			t.Fatalf("cleanup commands do not contain %q:\n%s", expected, result)
		}
	}
}

func TestNetworkCleanupCommandsSupportLegacyState(t *testing.T) {
	commands := networkCleanupCommands(runtimeState{Interface: "awgx0"})
	joined := make([]string, 0, len(commands))
	for _, command := range commands {
		joined = append(joined, strings.Join(command, " "))
	}
	result := strings.Join(joined, "\n")
	if !strings.Contains(result, "route flush table 51820") || !strings.Contains(result, "-6 route flush table 51820") {
		t.Fatalf("legacy cleanup lost its fixed-table fallback:\n%s", result)
	}
}

func TestCleanupTreatsMissingBusyBoxDeviceAsAlreadyRemoved(t *testing.T) {
	for _, output := range []string{
		"ip: can't find device 'awgx0'\n",
		`Device "awgx0" does not exist.`,
		"RTNETLINK answers: No such process\n",
	} {
		if commandExistsForCleanup(nil, []byte(output)) {
			t.Fatalf("missing resource was treated as a cleanup failure: %q", output)
		}
	}
	for _, output := range []string{
		"RTNETLINK answers: Operation not permitted\n",
		"ip: invalid argument '200' to 'table'\n",
	} {
		if !commandExistsForCleanup(nil, []byte(output)) {
			t.Fatalf("material cleanup error was ignored: %q", output)
		}
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
