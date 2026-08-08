package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestNormalizeAgentReleaseChannel(t *testing.T) {
	for _, input := range []string{"latest", "LATEST", " dev "} {
		if _, err := normalizeAgentReleaseChannel(input); err != nil {
			t.Fatalf("normalizeAgentReleaseChannel(%q): %v", input, err)
		}
	}
	for _, input := range []string{"", "main", "stable", "dev/../../x"} {
		if _, err := normalizeAgentReleaseChannel(input); err == nil {
			t.Fatalf("normalizeAgentReleaseChannel(%q) unexpectedly succeeded", input)
		}
	}
}

func TestValidateAgentChannelManifest(t *testing.T) {
	sha := strings.Repeat("a", 64)
	manifest := agentChannelManifest{
		Schema:      agentChannelManifestSchema,
		Channel:     "dev",
		Version:     "dev-123",
		Commit:      "1234567890abcdef",
		PublishedAt: "2026-08-07T12:00:00Z",
		Artifacts: map[string]agentReleaseArtifact{
			"mipsle": {Asset: "xray-go-agent-linux-mipsle", SHA256: sha, Size: 1024},
		},
	}
	artifact, err := validateAgentChannelManifest(manifest, "dev", "mipsle")
	if err != nil {
		t.Fatalf("validateAgentChannelManifest: %v", err)
	}
	if artifact.SHA256 != sha {
		t.Fatalf("sha256=%q, want %q", artifact.SHA256, sha)
	}

	bad := manifest
	bad.Artifacts = map[string]agentReleaseArtifact{
		"mipsle": {Asset: "../xray-go-agent-linux-mipsle", SHA256: sha, Size: 1024},
	}
	if _, err := validateAgentChannelManifest(bad, "dev", "mipsle"); err == nil {
		t.Fatal("path-traversal asset unexpectedly accepted")
	}

	bad = manifest
	bad.Channel = "latest"
	if _, err := validateAgentChannelManifest(bad, "dev", "mipsle"); err == nil {
		t.Fatal("channel mismatch unexpectedly accepted")
	}

	bad = manifest
	bad.Version = "dev\nforged: value"
	if _, err := validateAgentChannelManifest(bad, "dev", "mipsle"); err == nil {
		t.Fatal("unsafe version label unexpectedly accepted")
	}
}

func TestValidateAgentUpdateExpectationPinsVersionAndSHA(t *testing.T) {
	sha := strings.Repeat("a", 64)
	manifest := agentChannelManifest{Version: "dev-123"}
	artifact := agentReleaseArtifact{SHA256: sha}
	if err := validateAgentUpdateExpectation(manifest, artifact, "dev-123", sha); err != nil {
		t.Fatalf("matching expectation failed: %v", err)
	}
	if err := validateAgentUpdateExpectation(manifest, artifact, "dev-124", sha); err == nil {
		t.Fatal("changed version unexpectedly accepted")
	}
	if err := validateAgentUpdateExpectation(manifest, artifact, "dev-123", strings.Repeat("b", 64)); err == nil {
		t.Fatal("changed sha unexpectedly accepted")
	}
	if err := validateAgentUpdateExpectation(manifest, artifact, "", ""); err == nil {
		t.Fatal("missing preview unexpectedly accepted")
	}
}

func TestFetchAgentChannelAndDownloadArtifact(t *testing.T) {
	binary := []byte("test-agent-binary")
	sum := sha256.Sum256(binary)
	sha := hex.EncodeToString(sum[:])
	manifest := agentChannelManifest{
		Schema:      agentChannelManifestSchema,
		Channel:     "dev",
		Version:     "dev-test",
		Commit:      "abcdef123456",
		PublishedAt: time.Now().UTC().Format(time.RFC3339),
		Artifacts: map[string]agentReleaseArtifact{
			runtime.GOARCH: {
				Asset:  "xray-go-agent-linux-" + runtime.GOARCH,
				SHA256: sha,
				Size:   int64(len(binary)),
			},
		},
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/dev/agent-channel.json":
			_ = json.NewEncoder(w).Encode(manifest)
		case "/dev/xray-go-agent-linux-" + runtime.GOARCH:
			w.Header().Set("Content-Length", "17")
			_, _ = w.Write(binary)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	oldBase, oldClient := agentReleaseBaseURL, agentReleaseClient
	agentReleaseBaseURL, agentReleaseClient = server.URL, server.Client()
	defer func() {
		agentReleaseBaseURL, agentReleaseClient = oldBase, oldClient
	}()

	gotManifest, artifact, err := fetchAgentChannel("dev")
	if err != nil {
		t.Fatalf("fetchAgentChannel: %v", err)
	}
	if gotManifest.Version != manifest.Version {
		t.Fatalf("version=%q, want %q", gotManifest.Version, manifest.Version)
	}
	target := filepath.Join(t.TempDir(), "slots", "b", "xray-go-agent")
	if err := downloadAgentArtifact("dev", artifact, target); err != nil {
		t.Fatalf("downloadAgentArtifact: %v", err)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(binary) {
		t.Fatalf("downloaded binary=%q, want %q", got, binary)
	}
}

func TestEnsureAgentUpdateStateCreatesInitialSlot(t *testing.T) {
	paths := testAgentUpdatePaths(t)
	if err := os.MkdirAll(filepath.Dir(paths.TargetBinary), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.TargetBinary, []byte("working-agent"), 0755); err != nil {
		t.Fatal(err)
	}
	currentSHA, err := fileSHA256(paths.TargetBinary)
	if err != nil {
		t.Fatal(err)
	}
	state, err := ensureAgentUpdateState(paths, currentSHA)
	if err != nil {
		t.Fatalf("ensureAgentUpdateState: %v", err)
	}
	if state.ActiveSlot != "a" || !state.Slots["a"].Valid || state.Slots["b"].Valid {
		t.Fatalf("unexpected initial state: %#v", state)
	}
	if got, err := fileSHA256(agentSlotBinaryPath(paths, "a")); err != nil || got != currentSHA {
		t.Fatalf("initial slot sha=%q err=%v, want %q", got, err, currentSHA)
	}
}

func TestEnsureAgentUpdateStateRefreshesSlotAfterLegacyReplacement(t *testing.T) {
	paths := testAgentUpdatePaths(t)
	if err := os.MkdirAll(filepath.Dir(paths.TargetBinary), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.TargetBinary, []byte("new-working-agent"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(agentSlotBinaryPath(paths, "a")), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(agentSlotBinaryPath(paths, "a"), []byte("old-slot-agent"), 0755); err != nil {
		t.Fatal(err)
	}
	oldSHA, _ := fileSHA256(agentSlotBinaryPath(paths, "a"))
	state := agentUpdateState{
		Schema:     agentUpdateStateSchema,
		Status:     "healthy",
		ActiveSlot: "a",
		Slots: map[string]agentSlotState{
			"a": {Valid: true, Version: "old", SHA256: oldSHA},
			"b": {},
		},
	}
	if err := writeAgentUpdateState(paths, state); err != nil {
		t.Fatal(err)
	}
	currentSHA, _ := fileSHA256(paths.TargetBinary)
	refreshed, err := ensureAgentUpdateState(paths, currentSHA)
	if err != nil {
		t.Fatalf("ensureAgentUpdateState: %v", err)
	}
	if refreshed.Slots["a"].SHA256 != currentSHA || refreshed.Slots["a"].Version != agentVersion {
		t.Fatalf("active slot was not refreshed: %#v", refreshed.Slots["a"])
	}
	if got, _ := fileSHA256(agentSlotBinaryPath(paths, "a")); got != currentSHA {
		t.Fatalf("refreshed slot sha=%q, want %q", got, currentSHA)
	}
}

func TestMarkAgentUpdateHealthyCommitsMatchingExecutable(t *testing.T) {
	paths := testAgentUpdatePaths(t)
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	sha, err := fileSHA256(exe)
	if err != nil {
		t.Fatal(err)
	}
	state := agentUpdateState{
		Schema:     agentUpdateStateSchema,
		Status:     "scheduled",
		ActiveSlot: "a",
		PendingTX:  strings.Repeat("a", 24),
		Slots: map[string]agentSlotState{
			"a": {Valid: true, Version: "old", SHA256: strings.Repeat("b", 64)},
			"b": {Valid: true, Version: "new", Channel: "dev", SHA256: sha},
		},
	}
	if err := writeAgentUpdateState(paths, state); err != nil {
		t.Fatal(err)
	}
	pending := agentUpdatePending{
		TXID:          strings.Repeat("a", 24),
		PreviousSlot:  "a",
		TargetSlot:    "b",
		TargetSHA256:  sha,
		TargetVersion: "new",
		TargetChannel: "dev",
	}
	if err := writeAgentUpdatePending(paths, pending); err != nil {
		t.Fatal(err)
	}
	withAgentUpdatePaths(t, paths)
	committedOK, err := markAgentUpdateHealthy()
	if err != nil {
		t.Fatalf("markAgentUpdateHealthy: %v", err)
	}
	if !committedOK {
		t.Fatal("markAgentUpdateHealthy did not report a commit")
	}
	committed, err := loadAgentUpdateState(paths)
	if err != nil {
		t.Fatal(err)
	}
	if committed.ActiveSlot != "b" || committed.Status != "healthy" || committed.PendingTX != "" {
		t.Fatalf("unexpected committed state: %#v", committed)
	}
	marker, err := os.ReadFile(paths.HealthyFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(marker)) != pending.TXID {
		t.Fatalf("health marker=%q, want %q", marker, pending.TXID)
	}
}

func TestReconcileAgentUpdateStateInvalidatesFailedSlot(t *testing.T) {
	paths := testAgentUpdatePaths(t)
	tx := strings.Repeat("c", 24)
	state := agentUpdateState{
		Schema:     agentUpdateStateSchema,
		Status:     "scheduled",
		ActiveSlot: "a",
		PendingTX:  tx,
		Slots: map[string]agentSlotState{
			"a": {Valid: true, Version: "old", SHA256: strings.Repeat("a", 64)},
			"b": {Valid: true, Version: "bad", SHA256: strings.Repeat("b", 64)},
		},
	}
	if err := writeAgentUpdateState(paths, state); err != nil {
		t.Fatal(err)
	}
	if err := writeAgentUpdatePending(paths, agentUpdatePending{
		TXID: tx, PreviousSlot: "a", TargetSlot: "b", TargetSHA256: strings.Repeat("b", 64), TargetVersion: "bad", TargetChannel: "dev",
	}); err != nil {
		t.Fatal(err)
	}
	if err := writeFileAtomic(paths.ResultFile, []byte("STATUS=rolled_back\nTX_ID="+tx+"\nREASON=health check failed\n"), 0600); err != nil {
		t.Fatal(err)
	}
	withAgentUpdatePaths(t, paths)
	rolledBackOK, _ := reconcileAgentUpdateState()
	if !rolledBackOK {
		t.Fatal("reconcileAgentUpdateState did not report rollback")
	}
	rolledBack, err := loadAgentUpdateState(paths)
	if err != nil {
		t.Fatal(err)
	}
	if rolledBack.ActiveSlot != "a" || rolledBack.Status != "rolled_back" || rolledBack.Slots["b"].Valid {
		t.Fatalf("unexpected rollback state: %#v", rolledBack)
	}
	if !strings.Contains(rolledBack.LastError, "health check failed") {
		t.Fatalf("last_error=%q", rolledBack.LastError)
	}
}

func TestAgentUpdateScriptsContainBootAndLiveRollback(t *testing.T) {
	paths := testAgentUpdatePaths(t)
	runner := agentUpdateRunnerScript(paths)
	recovery := agentUpdateRecoveryScript(paths)
	for _, needle := range []string{"agent update rolled back", "switch_to", "new agent did not confirm", paths.PendingFile, paths.AgentInit} {
		if !strings.Contains(runner, needle) {
			t.Fatalf("runner missing %q", needle)
		}
	}
	for _, needle := range []string{"router restarted before update health confirmation", paths.PendingFile, paths.TargetBinary} {
		if !strings.Contains(recovery, needle) {
			t.Fatalf("recovery script missing %q", needle)
		}
	}
}

func testAgentUpdatePaths(t *testing.T) agentUpdatePaths {
	t.Helper()
	root := t.TempDir()
	updateRoot := filepath.Join(root, "opt", "libexec", "xray-go-agent-update")
	return agentUpdatePaths{
		RootDir:      updateRoot,
		StateFile:    filepath.Join(root, "opt", "etc", "xray", "agent-update-state.json"),
		PendingFile:  filepath.Join(root, "opt", "var", "run", "xray-go-agent-update.pending"),
		HealthyFile:  filepath.Join(root, "opt", "var", "run", "xray-go-agent-update.healthy"),
		ResultFile:   filepath.Join(root, "opt", "var", "run", "xray-go-agent-update.result"),
		TargetBinary: filepath.Join(root, "opt", "bin", "xray-go-agent"),
		AgentInit:    filepath.Join(root, "opt", "etc", "init.d", "S28xray-go-agent"),
		Runner:       filepath.Join(updateRoot, "update-runner.sh"),
		RecoveryInit: filepath.Join(root, "opt", "etc", "init.d", "S27xray-go-agent-update-recovery"),
		LogFile:      filepath.Join(root, "opt", "var", "log", "xray-go-agent-release-update.log"),
	}
}

func withAgentUpdatePaths(t *testing.T, paths agentUpdatePaths) {
	t.Helper()
	old := agentUpdatePathsFn
	agentUpdatePathsFn = func() agentUpdatePaths { return paths }
	t.Cleanup(func() { agentUpdatePathsFn = old })
}
