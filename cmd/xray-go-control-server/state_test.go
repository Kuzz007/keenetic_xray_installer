package main

import (
	"os"
	"path/filepath"
	"testing"
)

func newTestServer(t *testing.T, stateFile string) *Server {
	t.Helper()
	return &Server{cfg: Config{
		StateFile: stateFile,
		Routers: map[string]*Router{
			"home": {ID: "home", Name: "Home"},
		},
	}}
}

func TestPersistAndLoadStateRoundTrip(t *testing.T) {
	stateFile := filepath.Join(t.TempDir(), "state.json")
	s := newTestServer(t, stateFile)
	rt := s.cfg.Routers["home"]
	rt.Queue = []Command{{ID: "agent_update_apply-1", Action: "agent_update_apply", Channel: "dev", ExpectedVersion: "dev-abc", ExpectedSHA256: "abc123"}}
	rt.Results = []Result{{CommandID: "agent_start", RouterID: "home", OK: true, Output: "started"}}

	s.persistStateLocked()

	if _, err := os.Stat(stateFile); err != nil {
		t.Fatalf("expected state file to exist after persist: %v", err)
	}

	restored := newTestServer(t, stateFile)
	restored.loadStateLocked()

	rrt := restored.cfg.Routers["home"]
	if len(rrt.Queue) != 1 || rrt.Queue[0].ID != "agent_update_apply-1" || rrt.Queue[0].Channel != "dev" || rrt.Queue[0].ExpectedVersion != "dev-abc" || rrt.Queue[0].ExpectedSHA256 != "abc123" {
		t.Fatalf("queue not restored correctly: %+v", rrt.Queue)
	}
	if len(rrt.Results) != 1 || rrt.Results[0].Output != "started" {
		t.Fatalf("results not restored correctly: %+v", rrt.Results)
	}
}

func TestLoadStateMissingFileIsNotAnError(t *testing.T) {
	stateFile := filepath.Join(t.TempDir(), "does-not-exist.json")
	s := newTestServer(t, stateFile)

	s.loadStateLocked() // must not panic on a fresh install with no state.json yet

	rt := s.cfg.Routers["home"]
	if len(rt.Queue) != 0 || len(rt.Results) != 0 {
		t.Fatalf("expected untouched router state, got: %+v", rt)
	}
}

func TestLoadStateCorruptFileIsIgnored(t *testing.T) {
	stateFile := filepath.Join(t.TempDir(), "state.json")
	if err := os.WriteFile(stateFile, []byte("{not valid json"), 0600); err != nil {
		t.Fatalf("setup: %v", err)
	}
	s := newTestServer(t, stateFile)

	s.loadStateLocked() // must not panic or leave the router map in a bad state

	rt := s.cfg.Routers["home"]
	if len(rt.Queue) != 0 || len(rt.Results) != 0 {
		t.Fatalf("expected untouched router state after corrupt file, got: %+v", rt)
	}
}

func TestLoadStateUnknownRouterIDIsIgnored(t *testing.T) {
	stateFile := filepath.Join(t.TempDir(), "state.json")
	s := newTestServer(t, stateFile)
	s.cfg.Routers["gone"] = &Router{ID: "gone"}
	s.cfg.Routers["gone"].Queue = []Command{{ID: "x", Action: "status"}}
	s.persistStateLocked()

	// Simulate the admin having removed "gone" from the config between the
	// persisted state and this restart.
	restored := newTestServer(t, stateFile)
	restored.loadStateLocked() // must not panic on a state entry with no matching router

	if _, exists := restored.cfg.Routers["gone"]; exists {
		t.Fatalf("router removed from config reappeared from state file")
	}
}

func TestPersistStateSkipsEmptyRouters(t *testing.T) {
	stateFile := filepath.Join(t.TempDir(), "state.json")
	s := newTestServer(t, stateFile)
	s.cfg.Routers["idle"] = &Router{ID: "idle"} // no queue, no results

	s.persistStateLocked()

	data, err := os.ReadFile(stateFile)
	if err != nil {
		t.Fatalf("read state file: %v", err)
	}
	if string(data) != "{}" {
		t.Fatalf("expected empty state object for routers with nothing pending, got: %s", data)
	}
}
