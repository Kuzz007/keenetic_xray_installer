package main

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestAgentBootstrapReturnsRequestedChannelAndTLSProfile(t *testing.T) {
	s := &Server{cfg: Config{
		Listen:          "127.0.0.1:18090",
		CertFingerprint: strings.Repeat("a", 64),
		Routers: map[string]*Router{
			"home": {ID: "home", Token: "secret", RequestedAgentChannel: "dev"},
		},
	}}
	req := httptest.NewRequest(http.MethodGet, "/agent/bootstrap", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	s.handleAgentBootstrap(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	for _, want := range []string{
		"channel=dev",
		"server_url=https://127.0.0.1:18090",
		"server_fingerprint=" + strings.Repeat("a", 64),
	} {
		if !strings.Contains(rec.Body.String(), want) {
			t.Fatalf("response missing %q:\n%s", want, rec.Body.String())
		}
	}
}

func TestAgentBootstrapRequiresRouterAuthentication(t *testing.T) {
	s := &Server{cfg: Config{Routers: map[string]*Router{"home": {ID: "home", Token: "secret"}}}}
	req := httptest.NewRequest(http.MethodGet, "/agent/bootstrap", nil)
	rec := httptest.NewRecorder()
	s.handleAgentBootstrap(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d", rec.Code)
	}
}

func TestLegacyAgentChannelUpdateQueuesAutomaticUpdate(t *testing.T) {
	s := &Server{cfg: Config{StateFile: filepath.Join(t.TempDir(), "state.json"), Routers: map[string]*Router{"home": {ID: "home"}}}}
	id, err := s.enqueueLegacyAgentChannelUpdate("home", "dev")
	if err != nil {
		t.Fatal(err)
	}
	rt := s.cfg.Routers["home"]
	if rt.RequestedAgentChannel != "dev" {
		t.Fatalf("requested channel=%q", rt.RequestedAgentChannel)
	}
	if len(rt.Queue) != 1 || rt.Queue[0].Action != "update_agent" || rt.Queue[0].Channel != "dev" {
		t.Fatalf("queue=%+v", rt.Queue)
	}
	if !strings.HasPrefix(id, "update_agent-") {
		t.Fatalf("id=%q", id)
	}
}

func TestSafeAgentCheckAutomaticallyQueuesApply(t *testing.T) {
	sha := strings.Repeat("b", 64)
	s := &Server{
		cfg: Config{StateFile: filepath.Join(t.TempDir(), "state.json"), Routers: map[string]*Router{"home": {ID: "home"}}},
		activeMenus: map[string]ActiveMenu{
			"home": {ChatID: 1, MessageID: 2, RouterID: "home", Kind: "agent-update"},
		},
	}
	res := Result{
		CommandID: "agent_update_check-1",
		OK:        true,
		Output:    "channel: dev\ntarget_version: dev-abc\ntarget_sha256: " + sha + "\nupdate_available: yes",
	}
	_ = s.editActiveAgentUpdateResult("home", res)
	queue := s.cfg.Routers["home"].Queue
	if len(queue) != 1 || queue[0].Action != "agent_update_apply" || queue[0].Channel != "dev" || queue[0].ExpectedSHA256 != sha {
		t.Fatalf("queue=%+v", queue)
	}
}
