package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	agentChannelManifestSchema = "keenetic-vpn.agent-channel.v1"
	agentUpdateStateSchema     = "keenetic-vpn.agent-update-state.v1"
	agentUpdateMaxBinarySize   = int64(32 * 1024 * 1024)
	agentUpdateMaxManifestSize = int64(64 * 1024)
)

var (
	agentReleaseBaseURL = "https://github.com/Kuzz007/keenetic_xray_installer/releases/download"
	agentReleaseClient  = &http.Client{Timeout: 90 * time.Second}
	agentUpdatePathsFn  = defaultAgentUpdatePaths
)

type agentChannelManifest struct {
	Schema      string                          `json:"schema"`
	Channel     string                          `json:"channel"`
	Version     string                          `json:"version"`
	Commit      string                          `json:"commit"`
	PublishedAt string                          `json:"published_at"`
	Artifacts   map[string]agentReleaseArtifact `json:"artifacts"`
}

type agentReleaseArtifact struct {
	Asset  string `json:"asset"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type agentSlotState struct {
	Valid       bool   `json:"valid"`
	Version     string `json:"version,omitempty"`
	Channel     string `json:"channel,omitempty"`
	Commit      string `json:"commit,omitempty"`
	SHA256      string `json:"sha256,omitempty"`
	InstalledAt string `json:"installed_at,omitempty"`
}

type agentUpdateState struct {
	Schema     string                    `json:"schema"`
	Status     string                    `json:"status"`
	ActiveSlot string                    `json:"active_slot,omitempty"`
	PendingTX  string                    `json:"pending_tx,omitempty"`
	LastError  string                    `json:"last_error,omitempty"`
	UpdatedAt  string                    `json:"updated_at"`
	Slots      map[string]agentSlotState `json:"slots"`
}

type agentUpdatePending struct {
	TXID          string
	PreviousSlot  string
	TargetSlot    string
	TargetSHA256  string
	TargetVersion string
	TargetChannel string
}

type agentUpdatePaths struct {
	RootDir      string
	StateFile    string
	PendingFile  string
	HealthyFile  string
	ResultFile   string
	TargetBinary string
	AgentInit    string
	Runner       string
	RecoveryInit string
	LogFile      string
}

func defaultAgentUpdatePaths() agentUpdatePaths {
	root := "/opt/libexec/xray-go-agent-update"
	return agentUpdatePaths{
		RootDir:      root,
		StateFile:    "/opt/etc/xray/agent-update-state.json",
		PendingFile:  "/opt/var/run/xray-go-agent-update.pending",
		HealthyFile:  "/opt/var/run/xray-go-agent-update.healthy",
		ResultFile:   "/opt/var/run/xray-go-agent-update.result",
		TargetBinary: "/opt/bin/xray-go-agent",
		AgentInit:    "/opt/etc/init.d/S28xray-go-agent",
		Runner:       filepath.Join(root, "update-runner.sh"),
		RecoveryInit: "/opt/etc/init.d/S27xray-go-agent-update-recovery",
		LogFile:      "/opt/var/log/xray-go-agent-release-update.log",
	}
}

func normalizeAgentReleaseChannel(channel string) (string, error) {
	channel = strings.ToLower(strings.TrimSpace(channel))
	switch channel {
	case "latest", "dev":
		return channel, nil
	default:
		return "", fmt.Errorf("unsupported agent update channel: %q", channel)
	}
}

func validateAgentChannelManifest(m agentChannelManifest, requestedChannel, arch string) (agentReleaseArtifact, error) {
	if m.Schema != agentChannelManifestSchema {
		return agentReleaseArtifact{}, fmt.Errorf("unsupported channel manifest schema: %q", m.Schema)
	}
	if m.Channel != requestedChannel {
		return agentReleaseArtifact{}, fmt.Errorf("channel manifest mismatch: requested=%s got=%s", requestedChannel, m.Channel)
	}
	if !validAgentReleaseLabel(m.Version) {
		return agentReleaseArtifact{}, errors.New("channel manifest version contains unsupported characters")
	}
	if len(m.Commit) < 7 || len(m.Commit) > 64 {
		return agentReleaseArtifact{}, errors.New("channel manifest commit length is invalid")
	}
	if !validHexLabel(m.Commit) {
		return agentReleaseArtifact{}, errors.New("channel manifest commit must be hexadecimal")
	}
	if _, err := time.Parse(time.RFC3339, m.PublishedAt); err != nil {
		return agentReleaseArtifact{}, errors.New("channel manifest published_at must be RFC3339")
	}
	a, ok := m.Artifacts[arch]
	if !ok {
		return agentReleaseArtifact{}, fmt.Errorf("channel %s has no agent artifact for %s", requestedChannel, arch)
	}
	expectedAsset := "xray-go-agent-linux-" + arch
	if a.Asset != expectedAsset || filepath.Base(a.Asset) != a.Asset {
		return agentReleaseArtifact{}, fmt.Errorf("unexpected agent asset for %s: %q", arch, a.Asset)
	}
	a.SHA256 = strings.ToLower(strings.TrimSpace(a.SHA256))
	if len(a.SHA256) != 64 {
		return agentReleaseArtifact{}, errors.New("agent artifact sha256 must contain 64 hexadecimal characters")
	}
	if _, err := hex.DecodeString(a.SHA256); err != nil {
		return agentReleaseArtifact{}, fmt.Errorf("invalid agent artifact sha256: %w", err)
	}
	if a.Size <= 0 || a.Size > agentUpdateMaxBinarySize {
		return agentReleaseArtifact{}, fmt.Errorf("agent artifact size is outside the allowed range: %d", a.Size)
	}
	return a, nil
}

func validAgentReleaseLabel(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '+' || r == '-' {
			continue
		}
		return false
	}
	return true
}

func validHexLabel(value string) bool {
	for _, r := range value {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F') {
			continue
		}
		return false
	}
	return value != ""
}

func fetchAgentChannel(channel string) (agentChannelManifest, agentReleaseArtifact, error) {
	channel, err := normalizeAgentReleaseChannel(channel)
	if err != nil {
		return agentChannelManifest{}, agentReleaseArtifact{}, err
	}
	url := strings.TrimRight(agentReleaseBaseURL, "/") + "/" + channel + "/agent-channel.json"
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return agentChannelManifest{}, agentReleaseArtifact{}, err
	}
	req.Header.Set("Cache-Control", "no-cache")
	resp, err := agentReleaseClient.Do(req)
	if err != nil {
		return agentChannelManifest{}, agentReleaseArtifact{}, fmt.Errorf("download channel manifest: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return agentChannelManifest{}, agentReleaseArtifact{}, fmt.Errorf("download channel manifest: HTTP %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, agentUpdateMaxManifestSize+1))
	if err != nil {
		return agentChannelManifest{}, agentReleaseArtifact{}, err
	}
	if int64(len(data)) > agentUpdateMaxManifestSize {
		return agentChannelManifest{}, agentReleaseArtifact{}, errors.New("channel manifest is too large")
	}
	var manifest agentChannelManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return agentChannelManifest{}, agentReleaseArtifact{}, fmt.Errorf("parse channel manifest: %w", err)
	}
	artifact, err := validateAgentChannelManifest(manifest, channel, runtime.GOARCH)
	if err != nil {
		return agentChannelManifest{}, agentReleaseArtifact{}, err
	}
	return manifest, artifact, nil
}

func checkAgentRelease(channel string) (bool, string) {
	manifest, artifact, err := fetchAgentChannel(channel)
	if err != nil {
		return false, "agent update check failed: " + err.Error()
	}
	currentSHA, _ := currentAgentBinarySHA(agentUpdatePathsFn())
	available := currentSHA == "" || !strings.EqualFold(currentSHA, artifact.SHA256)
	return true, strings.Join([]string{
		"schema: " + agentChannelManifestSchema,
		"channel: " + manifest.Channel,
		"current_version: " + agentVersion,
		"target_version: " + manifest.Version,
		"target_commit: " + manifest.Commit,
		"target_sha256: " + artifact.SHA256,
		"architecture: " + runtime.GOARCH,
		"size_bytes: " + strconv.FormatInt(artifact.Size, 10),
		"update_available: " + yesNo(available),
		"sha256_verified: pending download",
	}, "\n")
}

func agentReleaseUpdateStatus() (bool, string) {
	paths := agentUpdatePathsFn()
	_, _ = reconcileAgentUpdateState()
	state, err := loadAgentUpdateState(paths)
	if err != nil && !os.IsNotExist(err) {
		return false, "agent update state: " + err.Error()
	}
	currentSHA, _ := currentAgentBinarySHA(paths)
	currentVersion := agentVersion
	currentChannel := "unknown"
	rollbackVersion := "none"
	rollbackAvailable := false
	status := "idle"
	lastError := ""
	activeSlot := "unmanaged"
	if err == nil {
		status = firstNonEmpty(state.Status, "idle")
		lastError = state.LastError
		activeSlot = firstNonEmpty(state.ActiveSlot, "unmanaged")
		if active := state.Slots[state.ActiveSlot]; active.Valid {
			currentVersion = firstNonEmpty(active.Version, currentVersion)
			currentChannel = firstNonEmpty(active.Channel, currentChannel)
		}
		other := otherAgentSlot(state.ActiveSlot)
		if rollback := state.Slots[other]; rollback.Valid && !strings.EqualFold(rollback.SHA256, currentSHA) {
			rollbackAvailable = true
			rollbackVersion = firstNonEmpty(rollback.Version, "unknown")
		}
	}
	lines := []string{
		"schema: " + agentUpdateStateSchema,
		"status: " + status,
		"current_version: " + currentVersion,
		"current_channel: " + currentChannel,
		"architecture: " + runtime.GOARCH,
		"active_slot: " + activeSlot,
		"rollback_available: " + yesNo(rollbackAvailable),
		"rollback_version: " + rollbackVersion,
	}
	if currentSHA != "" {
		lines = append(lines, "current_sha256: "+currentSHA)
	}
	if lastError != "" {
		lines = append(lines, "last_error: "+sanitizeStateText(lastError))
	}
	return true, strings.Join(lines, "\n")
}

func scheduleAgentRelease(channel, expectedVersion, expectedSHA256 string) (bool, string) {
	channel, err := normalizeAgentReleaseChannel(channel)
	if err != nil {
		return false, err.Error()
	}
	paths := agentUpdatePathsFn()
	if _, err := os.Stat(paths.AgentInit); err != nil {
		return false, "agent init service not found: " + paths.AgentInit
	}
	if _, err := os.Stat(paths.TargetBinary); err != nil {
		return false, "installed agent binary not found: " + paths.TargetBinary
	}
	if _, err := os.Stat(paths.PendingFile); err == nil {
		return false, "another agent update transaction is already pending"
	}

	manifest, artifact, err := fetchAgentChannel(channel)
	if err != nil {
		return false, "agent update check failed: " + err.Error()
	}
	expectedVersion = strings.TrimSpace(expectedVersion)
	expectedSHA256 = strings.ToLower(strings.TrimSpace(expectedSHA256))
	if err := validateAgentUpdateExpectation(manifest, artifact, expectedVersion, expectedSHA256); err != nil {
		return false, err.Error()
	}
	currentSHA, err := currentAgentBinarySHA(paths)
	if err != nil {
		return false, "hash current agent: " + err.Error()
	}
	if strings.EqualFold(currentSHA, artifact.SHA256) {
		return true, "agent is already up to date\nchannel: " + channel + "\nversion: " + manifest.Version
	}

	state, err := ensureAgentUpdateState(paths, currentSHA)
	if err != nil {
		return false, "prepare A/B slots: " + err.Error()
	}
	targetSlot := otherAgentSlot(state.ActiveSlot)
	targetPath := agentSlotBinaryPath(paths, targetSlot)
	if err := downloadAgentArtifact(channel, artifact, targetPath); err != nil {
		return false, "stage agent update: " + err.Error()
	}
	probedVersion, err := probeAgentBinary(targetPath)
	if err != nil {
		_ = os.Remove(targetPath)
		return false, "new agent preflight failed: " + err.Error()
	}

	tx, err := newAgentUpdateTX()
	if err != nil {
		return false, err.Error()
	}
	pending := agentUpdatePending{
		TXID:          tx,
		PreviousSlot:  state.ActiveSlot,
		TargetSlot:    targetSlot,
		TargetSHA256:  artifact.SHA256,
		TargetVersion: firstNonEmpty(probedVersion, manifest.Version),
		TargetChannel: channel,
	}
	state.Status = "scheduled"
	state.PendingTX = tx
	state.LastError = ""
	state.UpdatedAt = nowUTC()
	state.Slots[targetSlot] = agentSlotState{
		Valid:       true,
		Version:     pending.TargetVersion,
		Channel:     channel,
		Commit:      manifest.Commit,
		SHA256:      artifact.SHA256,
		InstalledAt: nowUTC(),
	}
	if err := writeAgentUpdateState(paths, state); err != nil {
		return false, err.Error()
	}
	_ = os.Remove(paths.HealthyFile)
	_ = os.Remove(paths.ResultFile)
	if err := writeAgentUpdatePending(paths, pending); err != nil {
		recordAgentUpdateError(paths, "failed to write update transaction: "+err.Error())
		return false, err.Error()
	}
	if err := installAgentUpdateHelpers(paths); err != nil {
		_ = os.Remove(paths.PendingFile)
		recordAgentUpdateError(paths, "failed to install recovery helpers: "+err.Error())
		return false, err.Error()
	}
	if err := startAgentUpdateRunner(paths, tx); err != nil {
		_ = os.Remove(paths.PendingFile)
		recordAgentUpdateError(paths, "failed to start update runner: "+err.Error())
		return false, err.Error()
	}
	return true, strings.Join([]string{
		"agent update scheduled",
		"channel: " + channel,
		"target_version: " + pending.TargetVersion,
		"target_slot: " + targetSlot,
		"rollback_slot: " + pending.PreviousSlot,
		"transaction: " + tx,
		"automatic_rollback: armed",
	}, "\n")
}

func validateAgentUpdateExpectation(manifest agentChannelManifest, artifact agentReleaseArtifact, expectedVersion, expectedSHA256 string) error {
	expectedVersion = strings.TrimSpace(expectedVersion)
	expectedSHA256 = strings.ToLower(strings.TrimSpace(expectedSHA256))
	if expectedVersion == "" || expectedSHA256 == "" {
		return errors.New("agent update requires a fresh channel preview")
	}
	if manifest.Version != expectedVersion || !strings.EqualFold(artifact.SHA256, expectedSHA256) {
		return errors.New("agent update channel changed after preview; check the channel again before installing")
	}
	return nil
}

func scheduleAgentRollback() (bool, string) {
	paths := agentUpdatePathsFn()
	if _, err := os.Stat(paths.PendingFile); err == nil {
		return false, "another agent update transaction is already pending"
	}
	state, err := loadAgentUpdateState(paths)
	if err != nil {
		return false, "agent rollback is not available: " + err.Error()
	}
	previous := state.ActiveSlot
	target := otherAgentSlot(previous)
	targetState := state.Slots[target]
	if !targetState.Valid {
		return false, "agent rollback is not available: inactive slot is empty"
	}
	if activeState := state.Slots[previous]; activeState.Valid && strings.EqualFold(activeState.SHA256, targetState.SHA256) {
		return false, "agent rollback is not available: both slots contain the same build"
	}
	actualSHA, err := fileSHA256(agentSlotBinaryPath(paths, target))
	if err != nil || !strings.EqualFold(actualSHA, targetState.SHA256) {
		return false, "agent rollback slot failed integrity check"
	}
	if _, err := probeAgentBinary(agentSlotBinaryPath(paths, target)); err != nil {
		return false, "agent rollback preflight failed: " + err.Error()
	}
	tx, err := newAgentUpdateTX()
	if err != nil {
		return false, err.Error()
	}
	pending := agentUpdatePending{
		TXID:          tx,
		PreviousSlot:  previous,
		TargetSlot:    target,
		TargetSHA256:  targetState.SHA256,
		TargetVersion: targetState.Version,
		TargetChannel: targetState.Channel,
	}
	state.Status = "rollback_scheduled"
	state.PendingTX = tx
	state.LastError = ""
	state.UpdatedAt = nowUTC()
	if err := writeAgentUpdateState(paths, state); err != nil {
		return false, err.Error()
	}
	_ = os.Remove(paths.HealthyFile)
	_ = os.Remove(paths.ResultFile)
	if err := writeAgentUpdatePending(paths, pending); err != nil {
		recordAgentUpdateError(paths, "failed to write rollback transaction: "+err.Error())
		return false, err.Error()
	}
	if err := installAgentUpdateHelpers(paths); err != nil {
		_ = os.Remove(paths.PendingFile)
		recordAgentUpdateError(paths, "failed to install recovery helpers: "+err.Error())
		return false, err.Error()
	}
	if err := startAgentUpdateRunner(paths, tx); err != nil {
		_ = os.Remove(paths.PendingFile)
		recordAgentUpdateError(paths, "failed to start rollback runner: "+err.Error())
		return false, err.Error()
	}
	return true, strings.Join([]string{
		"agent rollback scheduled",
		"target_version: " + firstNonEmpty(targetState.Version, "unknown"),
		"target_slot: " + target,
		"transaction: " + tx,
	}, "\n")
}

func downloadAgentArtifact(channel string, artifact agentReleaseArtifact, target string) error {
	url := strings.TrimRight(agentReleaseBaseURL, "/") + "/" + channel + "/" + artifact.Asset
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Cache-Control", "no-cache")
	resp, err := agentReleaseClient.Do(req)
	if err != nil {
		return fmt.Errorf("download binary: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("download binary: HTTP %s", resp.Status)
	}
	if resp.ContentLength > 0 && resp.ContentLength != artifact.Size {
		return fmt.Errorf("binary size mismatch: manifest=%d response=%d", artifact.Size, resp.ContentLength)
	}
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return err
	}
	tmp := target + ".download"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0755)
	if err != nil {
		return err
	}
	h := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, agentUpdateMaxBinarySize+1))
	closeErr := f.Close()
	if copyErr != nil {
		_ = os.Remove(tmp)
		return copyErr
	}
	if closeErr != nil {
		_ = os.Remove(tmp)
		return closeErr
	}
	if n != artifact.Size {
		_ = os.Remove(tmp)
		return fmt.Errorf("binary size mismatch: manifest=%d downloaded=%d", artifact.Size, n)
	}
	got := hex.EncodeToString(h.Sum(nil))
	if !strings.EqualFold(got, artifact.SHA256) {
		_ = os.Remove(tmp)
		return fmt.Errorf("binary sha256 mismatch: expected=%s got=%s", artifact.SHA256, got)
	}
	if err := os.Chmod(tmp, 0755); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, target); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func probeAgentBinary(path string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "-version")
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return "", errors.New("version probe timed out")
	}
	if err != nil {
		return "", fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
	}
	line := strings.TrimSpace(string(out))
	if !strings.HasPrefix(line, "xray-go-agent ") {
		return "", fmt.Errorf("unexpected version output: %q", line)
	}
	return strings.TrimSpace(strings.TrimPrefix(line, "xray-go-agent ")), nil
}

func ensureAgentUpdateState(paths agentUpdatePaths, currentSHA string) (agentUpdateState, error) {
	if state, err := loadAgentUpdateState(paths); err == nil {
		if state.ActiveSlot != "a" && state.ActiveSlot != "b" {
			return agentUpdateState{}, errors.New("invalid active agent slot in state")
		}
		activePath := agentSlotBinaryPath(paths, state.ActiveSlot)
		activeSHA, hashErr := fileSHA256(activePath)
		activeState := state.Slots[state.ActiveSlot]
		if hashErr != nil || currentSHA == "" || !strings.EqualFold(activeSHA, currentSHA) || !strings.EqualFold(activeState.SHA256, currentSHA) {
			if currentSHA == "" {
				var currentErr error
				currentSHA, currentErr = currentAgentBinarySHA(paths)
				if currentErr != nil {
					return agentUpdateState{}, currentErr
				}
			}
			if err := copyFileAtomic(paths.TargetBinary, activePath, 0755); err != nil {
				return agentUpdateState{}, fmt.Errorf("refresh active rollback slot: %w", err)
			}
			state.Slots[state.ActiveSlot] = agentSlotState{
				Valid:       true,
				Version:     agentVersion,
				Channel:     "unknown",
				SHA256:      currentSHA,
				InstalledAt: nowUTC(),
			}
			state.Status = "idle"
			state.PendingTX = ""
			state.LastError = ""
			if err := writeAgentUpdateState(paths, state); err != nil {
				return agentUpdateState{}, err
			}
		}
		return state, nil
	} else if !os.IsNotExist(err) {
		return agentUpdateState{}, err
	}
	if err := os.MkdirAll(filepath.Join(paths.RootDir, "slots", "a"), 0755); err != nil {
		return agentUpdateState{}, err
	}
	if err := os.MkdirAll(filepath.Join(paths.RootDir, "slots", "b"), 0755); err != nil {
		return agentUpdateState{}, err
	}
	initial := agentSlotBinaryPath(paths, "a")
	if err := copyFileAtomic(paths.TargetBinary, initial, 0755); err != nil {
		return agentUpdateState{}, err
	}
	if currentSHA == "" {
		var err error
		currentSHA, err = fileSHA256(initial)
		if err != nil {
			return agentUpdateState{}, err
		}
	}
	state := agentUpdateState{
		Schema:     agentUpdateStateSchema,
		Status:     "idle",
		ActiveSlot: "a",
		UpdatedAt:  nowUTC(),
		Slots: map[string]agentSlotState{
			"a": {Valid: true, Version: agentVersion, Channel: "unknown", SHA256: currentSHA, InstalledAt: nowUTC()},
			"b": {},
		},
	}
	if err := writeAgentUpdateState(paths, state); err != nil {
		return agentUpdateState{}, err
	}
	return state, nil
}

func loadAgentUpdateState(paths agentUpdatePaths) (agentUpdateState, error) {
	data, err := os.ReadFile(paths.StateFile)
	if err != nil {
		return agentUpdateState{}, err
	}
	var state agentUpdateState
	if err := json.Unmarshal(data, &state); err != nil {
		return agentUpdateState{}, err
	}
	if state.Schema != agentUpdateStateSchema {
		return agentUpdateState{}, fmt.Errorf("unsupported agent update state schema: %q", state.Schema)
	}
	if state.Slots == nil {
		state.Slots = map[string]agentSlotState{}
	}
	return state, nil
}

func writeAgentUpdateState(paths agentUpdatePaths, state agentUpdateState) error {
	state.Schema = agentUpdateStateSchema
	state.UpdatedAt = nowUTC()
	if state.Slots == nil {
		state.Slots = map[string]agentSlotState{}
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(paths.StateFile, append(data, '\n'), 0600)
}

func recordAgentUpdateError(paths agentUpdatePaths, message string) {
	state, err := loadAgentUpdateState(paths)
	if err != nil {
		return
	}
	state.Status = "failed"
	state.PendingTX = ""
	state.LastError = sanitizeStateText(message)
	_ = writeAgentUpdateState(paths, state)
}

func writeAgentUpdatePending(paths agentUpdatePaths, p agentUpdatePending) error {
	if !validAgentSlot(p.PreviousSlot) || !validAgentSlot(p.TargetSlot) || p.PreviousSlot == p.TargetSlot {
		return errors.New("invalid agent update slot transaction")
	}
	if !validAgentUpdateTX(p.TXID) {
		return errors.New("invalid agent update transaction id")
	}
	if _, err := normalizeAgentReleaseChannel(p.TargetChannel); err != nil && p.TargetChannel != "unknown" {
		return err
	}
	lines := []string{
		"TX_ID=" + p.TXID,
		"PREVIOUS_SLOT=" + p.PreviousSlot,
		"TARGET_SLOT=" + p.TargetSlot,
		"TARGET_SHA256=" + strings.ToLower(p.TargetSHA256),
		"TARGET_VERSION=" + sanitizeStateText(p.TargetVersion),
		"TARGET_CHANNEL=" + sanitizeStateText(p.TargetChannel),
	}
	return writeFileAtomic(paths.PendingFile, []byte(strings.Join(lines, "\n")+"\n"), 0600)
}

func readAgentUpdatePending(paths agentUpdatePaths) (agentUpdatePending, error) {
	values, err := readStateLines(paths.PendingFile)
	if err != nil {
		return agentUpdatePending{}, err
	}
	p := agentUpdatePending{
		TXID:          values["TX_ID"],
		PreviousSlot:  values["PREVIOUS_SLOT"],
		TargetSlot:    values["TARGET_SLOT"],
		TargetSHA256:  values["TARGET_SHA256"],
		TargetVersion: values["TARGET_VERSION"],
		TargetChannel: values["TARGET_CHANNEL"],
	}
	if !validAgentUpdateTX(p.TXID) || !validAgentSlot(p.PreviousSlot) || !validAgentSlot(p.TargetSlot) || p.PreviousSlot == p.TargetSlot {
		return agentUpdatePending{}, errors.New("invalid pending agent update transaction")
	}
	return p, nil
}

func markAgentUpdateHealthy() (bool, error) {
	paths := agentUpdatePathsFn()
	pending, err := readAgentUpdatePending(paths)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	exe, err := os.Executable()
	if err != nil {
		return false, err
	}
	got, err := fileSHA256(exe)
	if err != nil {
		return false, err
	}
	if !strings.EqualFold(got, pending.TargetSHA256) {
		return false, fmt.Errorf("running agent sha256 does not match pending target")
	}
	state, err := loadAgentUpdateState(paths)
	if err != nil {
		return false, err
	}
	state.ActiveSlot = pending.TargetSlot
	state.Status = "healthy"
	state.PendingTX = ""
	state.LastError = ""
	if err := writeAgentUpdateState(paths, state); err != nil {
		return false, err
	}
	if err := writeFileAtomic(paths.HealthyFile, []byte(pending.TXID+"\n"), 0600); err != nil {
		return false, err
	}
	return true, nil
}

func reconcileAgentUpdateState() (bool, string) {
	paths := agentUpdatePathsFn()
	values, err := readStateLines(paths.ResultFile)
	if err != nil {
		return false, ""
	}
	if values["STATUS"] != "rolled_back" {
		_ = os.Remove(paths.ResultFile)
		return false, ""
	}
	reason := firstNonEmpty(values["REASON"], "new agent did not confirm control-server connectivity")
	pending, pendingErr := readAgentUpdatePending(paths)
	state, stateErr := loadAgentUpdateState(paths)
	if pendingErr == nil && stateErr == nil {
		state.ActiveSlot = pending.PreviousSlot
		state.Status = "rolled_back"
		state.PendingTX = ""
		state.LastError = reason
		target := state.Slots[pending.TargetSlot]
		target.Valid = false
		state.Slots[pending.TargetSlot] = target
		_ = writeAgentUpdateState(paths, state)
	}
	_ = os.Remove(paths.PendingFile)
	_ = os.Remove(paths.HealthyFile)
	_ = os.Remove(paths.ResultFile)
	return pendingErr == nil && stateErr == nil, reason
}

func installAgentUpdateHelpers(paths agentUpdatePaths) error {
	if err := os.MkdirAll(paths.RootDir, 0755); err != nil {
		return err
	}
	if err := writeFileAtomic(paths.Runner, []byte(agentUpdateRunnerScript(paths)), 0755); err != nil {
		return err
	}
	if err := writeFileAtomic(paths.RecoveryInit, []byte(agentUpdateRecoveryScript(paths)), 0755); err != nil {
		return err
	}
	return nil
}

func startAgentUpdateRunner(paths agentUpdatePaths, tx string) error {
	shell := scriptShell()
	if shell == "" {
		return errors.New("no shell available to run agent update")
	}
	if err := os.MkdirAll(filepath.Dir(paths.LogFile), 0755); err != nil {
		return err
	}
	logFile, err := os.OpenFile(paths.LogFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	cmd := exec.Command(shell, paths.Runner, tx)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return err
	}
	_ = logFile.Close()
	return nil
}

func agentUpdateRunnerScript(paths agentUpdatePaths) string {
	return fmt.Sprintf(`#!/bin/sh
set -u

PENDING=%s
HEALTHY=%s
RESULT=%s
TARGET=%s
SLOTS=%s
INIT=%s
TX_EXPECTED="${1:-}"

get_value() { sed -n "s/^$1=//p" "$PENDING" 2>/dev/null | tail -n 1; }
valid_slot() { case "$1" in a|b) return 0 ;; *) return 1 ;; esac; }
write_result() {
    tmp="$RESULT.$$"
    {
        echo "STATUS=rolled_back"
        echo "TX_ID=$TX_EXPECTED"
        echo "REASON=$1"
    } >"$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$RESULT"
}
switch_to() {
    slot="$1"
    bin="$SLOTS/$slot/xray-go-agent"
    [ -x "$bin" ] || return 1
    link="$TARGET.update.$$"
    rm -f "$link"
    ln -s "$bin" "$link" || return 1
    mv -f "$link" "$TARGET"
}

sleep 5
[ -s "$PENDING" ] || exit 1
tx="$(get_value TX_ID)"
previous="$(get_value PREVIOUS_SLOT)"
target_slot="$(get_value TARGET_SLOT)"
[ "$tx" = "$TX_EXPECTED" ] || exit 1
valid_slot "$previous" || exit 1
valid_slot "$target_slot" || exit 1

rm -f "$HEALTHY"
if ! switch_to "$target_slot"; then
    write_result "failed to activate target slot"
    exit 1
fi

"$INIT" restart >/dev/null 2>&1 || "$INIT" start >/dev/null 2>&1 || true
i=0
while [ "$i" -lt 45 ]; do
    if [ "$(sed -n '1p' "$HEALTHY" 2>/dev/null)" = "$TX_EXPECTED" ]; then
        rm -f "$PENDING" "$HEALTHY"
        echo "agent update committed: tx=$TX_EXPECTED slot=$target_slot"
        exit 0
    fi
    sleep 2
    i=$((i + 1))
done

switch_to "$previous" || true
write_result "new agent did not confirm control-server connectivity"
"$INIT" restart >/dev/null 2>&1 || "$INIT" start >/dev/null 2>&1 || true
echo "agent update rolled back: tx=$TX_EXPECTED slot=$previous"
exit 1
`, shellQuote(paths.PendingFile), shellQuote(paths.HealthyFile), shellQuote(paths.ResultFile), shellQuote(paths.TargetBinary), shellQuote(filepath.Join(paths.RootDir, "slots")), shellQuote(paths.AgentInit))
}

func agentUpdateRecoveryScript(paths agentUpdatePaths) string {
	return fmt.Sprintf(`#!/bin/sh

PENDING=%s
HEALTHY=%s
RESULT=%s
TARGET=%s
SLOTS=%s

get_value() { sed -n "s/^$1=//p" "$PENDING" 2>/dev/null | tail -n 1; }

case "${1:-start}" in
start)
    [ -s "$PENDING" ] || exit 0
    tx="$(get_value TX_ID)"
    previous="$(get_value PREVIOUS_SLOT)"
    case "$previous" in a|b) ;; *) exit 1 ;; esac
    if [ "$(sed -n '1p' "$HEALTHY" 2>/dev/null)" = "$tx" ]; then
        rm -f "$PENDING" "$HEALTHY"
        exit 0
    fi
    bin="$SLOTS/$previous/xray-go-agent"
    [ -x "$bin" ] || exit 1
    link="$TARGET.recovery.$$"
    rm -f "$link"
    ln -s "$bin" "$link" || exit 1
    mv -f "$link" "$TARGET"
    tmp="$RESULT.$$"
    {
        echo "STATUS=rolled_back"
        echo "TX_ID=$tx"
        echo "REASON=router restarted before update health confirmation"
    } >"$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$RESULT"
    ;;
esac

exit 0
`, shellQuote(paths.PendingFile), shellQuote(paths.HealthyFile), shellQuote(paths.ResultFile), shellQuote(paths.TargetBinary), shellQuote(filepath.Join(paths.RootDir, "slots")))
}

func currentAgentBinarySHA(paths agentUpdatePaths) (string, error) {
	if _, err := os.Stat(paths.TargetBinary); err == nil {
		return fileSHA256(paths.TargetBinary)
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return fileSHA256(exe)
}

func agentSlotBinaryPath(paths agentUpdatePaths, slot string) string {
	return filepath.Join(paths.RootDir, "slots", slot, "xray-go-agent")
}

func otherAgentSlot(slot string) string {
	if slot == "b" {
		return "a"
	}
	return "b"
}

func validAgentSlot(slot string) bool {
	return slot == "a" || slot == "b"
}

func newAgentUpdateTX() (string, error) {
	buf := make([]byte, 12)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func validAgentUpdateTX(tx string) bool {
	if len(tx) != 24 {
		return false
	}
	_, err := hex.DecodeString(tx)
	return err == nil
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func copyFileAtomic(source, target string, mode os.FileMode) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return err
	}
	tmp := target + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if copyErr != nil {
		_ = os.Remove(tmp)
		return copyErr
	}
	if closeErr != nil {
		_ = os.Remove(tmp)
		return closeErr
	}
	if err := os.Chmod(tmp, mode); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, target); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	if err := os.Chmod(tmp, mode); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func readStateLines(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	values := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok || key == "" {
			continue
		}
		values[key] = strings.TrimSpace(value)
	}
	return values, nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func sanitizeStateText(value string) string {
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	value = strings.ReplaceAll(value, "=", "-")
	return strings.TrimSpace(value)
}

func yesNo(v bool) string {
	if v {
		return "yes"
	}
	return "no"
}

func nowUTC() string {
	return time.Now().UTC().Format(time.RFC3339)
}
