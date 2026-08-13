package main

import (
	"strings"
	"testing"
)

func TestParseAgentChannelCallback(t *testing.T) {
	channel, routerID, ok := parseAgentChannelCallback("agent-check:dev:home-1", "agent-check")
	if !ok || channel != "dev" || routerID != "home-1" {
		t.Fatalf("unexpected parse result: channel=%q router=%q ok=%v", channel, routerID, ok)
	}
	for _, input := range []string{
		"agent-check:main:home",
		"agent-check:dev:bad/router",
		"agent-apply:dev:home",
		"agent-check:dev",
	} {
		if _, _, ok := parseAgentChannelCallback(input, "agent-check"); ok {
			t.Fatalf("parseAgentChannelCallback(%q) unexpectedly succeeded", input)
		}
	}
}

func TestRouterKeyboardUsesSafeAgentMenuWhenCapabilityPresent(t *testing.T) {
	status := "agent: go version=1.2.3; capabilities: agent_update_status; features: status,update_agent,agent_release_update"
	kb := routerKeyboardForStatus("home", status)
	if !keyboardHasCallback(kb, "agent-update:home") {
		t.Fatal("safe Agent menu button is missing")
	}
	if keyboardHasCallback(kb, "act:update_agent:home") {
		t.Fatal("legacy direct-update button should be hidden when safe updater is supported")
	}
}

func TestRouterKeyboardOffersBootstrapMenuForLegacyAgent(t *testing.T) {
	status := "agent: go version=1.2.3; capabilities: update_agent; features: status,update_agent"
	kb := routerKeyboardForStatus("home", status)
	if !keyboardHasCallback(kb, "agent-update:home") {
		t.Fatal("bootstrap Agent menu is missing for an old agent")
	}
	if keyboardHasCallback(kb, "act:update_agent:home") {
		t.Fatal("legacy direct-update action should be hidden behind the bootstrap menu")
	}
}

func TestBuildAgentInstallCommandForDevIsQuoted(t *testing.T) {
	command := buildAgentInstallCommandForChannel("https://vps:18090", "home", "Dacha's router", "abc123", "deadbeef", "dev")
	for _, want := range []string{"TAG='dev'", "--router-name 'Dacha'\"'\"'s router'", "--agent-token 'abc123'"} {
		if !strings.Contains(command, want) {
			t.Fatalf("bootstrap command missing %q:\n%s", want, command)
		}
	}
}

func TestBuildAgentInstallCommandFitsKeeneticShellLineLimit(t *testing.T) {
	command := buildAgentInstallCommandForChannel(
		"https://185.252.177.2:18090",
		"bubadom",
		"Бубадом",
		strings.Repeat("a", 64),
		strings.Repeat("b", 64),
		"latest",
	)
	lines := strings.Split(command, "\n")
	if len(lines) != 4 {
		t.Fatalf("bootstrap line count = %d, want 4:\n%s", len(lines), command)
	}
	for index, line := range lines {
		if len(line) >= 512 {
			t.Fatalf("bootstrap line %d is %d bytes, must stay below Keenetic's 512-byte input limit", index+1, len(line))
		}
	}
	if !strings.Contains(lines[1], "_XRAY_AGENT_INSTALL_READY=1") {
		t.Fatal("download line does not arm the guarded install")
	}
	if !strings.HasPrefix(lines[2], `[ "${_XRAY_AGENT_INSTALL_READY:-}" = 1 ] && TAG='latest' `) {
		t.Fatalf("install line is not guarded by a successful download:\n%s", lines[2])
	}
}

func TestFormatAgentUpdateCheckResult(t *testing.T) {
	res := Result{
		CommandID: "agent_update_check-1",
		OK:        true,
		Output: strings.Join([]string{
			"channel: dev",
			"current_version: 1.0.0",
			"target_version: dev-abc",
			"target_commit: abcdef",
			"target_sha256: " + strings.Repeat("a", 64),
			"update_available: yes",
		}, "\n"),
	}
	got := formatAgentUpdateResult(res)
	for _, want := range []string{"Проверка канала завершена", "Канал: dev", "Доступная версия: dev-abc", "Обновление доступно: yes"} {
		if !strings.Contains(got, want) {
			t.Fatalf("formatted result missing %q:\n%s", want, got)
		}
	}
}

func TestLastAgentCheckPreviewUsesMatchingChannel(t *testing.T) {
	s := &Server{cfg: Config{Routers: map[string]*Router{
		"home": {
			ID:   "home",
			Name: "Home",
			Results: []Result{
				{CommandID: "agent_update_check-1", OK: true, Output: "channel: latest\ntarget_version: 1.0.0"},
				{CommandID: "agent_update_check-2", OK: true, Output: "channel: dev\ncurrent_version: 1.0.0\ntarget_version: dev-2\ntarget_commit: abc\nsize_bytes: 1048576"},
			},
		},
	}}}
	preview := s.lastAgentCheckPreview("home", "dev")
	for _, want := range []string{"Канал: DEV", "Новая версия: dev-2", "Размер: 1.0 МБ"} {
		if !strings.Contains(preview, want) {
			t.Fatalf("preview missing %q:\n%s", want, preview)
		}
	}
}

func TestLastAgentCheckExpectationPinsPreviewedArtifact(t *testing.T) {
	sha := strings.Repeat("d", 64)
	s := &Server{cfg: Config{Routers: map[string]*Router{
		"home": {
			ID: "home",
			Results: []Result{{
				CommandID: "agent_update_check-1",
				OK:        true,
				Output:    "channel: dev\ntarget_version: dev-2\ntarget_sha256: " + sha + "\nupdate_available: yes",
			}},
		},
	}}}
	version, gotSHA, ok := s.lastAgentCheckExpectation("home", "dev")
	if !ok || version != "dev-2" || gotSHA != sha {
		t.Fatalf("version=%q sha=%q ok=%v", version, gotSHA, ok)
	}
	if _, _, ok := s.lastAgentCheckExpectation("home", "latest"); ok {
		t.Fatal("expectation unexpectedly crossed channels")
	}
}

func TestAgentVersionFromRouterStatus(t *testing.T) {
	status := "active: primary; agent: go version=0.4.0-dev; capabilities=status; features=status"
	if got := agentVersionFromRouterStatus(status); got != "0.4.0-dev" {
		t.Fatalf("version=%q", got)
	}
}

func keyboardHasCallback(kb inlineKeyboard, callback string) bool {
	for _, row := range kb.InlineKeyboard {
		for _, button := range row {
			if button.CallbackData == callback {
				return true
			}
		}
	}
	return false
}
