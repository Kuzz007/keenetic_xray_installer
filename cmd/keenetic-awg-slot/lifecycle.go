package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Kuzz007/keenetic_xray_installer/internal/awgconfig"
)

const (
	routeTable = "51820"
	routeMark  = "51820"
	rulePref   = "18020"
)

type socksEndpoint struct {
	Address  string
	Port     uint16
	Username string
	Password string
}

func activate(opts options) error {
	if _, err := os.Stat(statePath(opts)); err == nil {
		return errors.New("AWG slot already has runtime state; deactivate or recover it first")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if _, err := os.Stat(rollbackPath(opts)); err == nil {
		return errors.New("AWG rollback file already exists; run recover before activation")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := acquireVLESSLock("keenetic-awg-slot:activate"); err != nil {
		return err
	}
	defer releaseVLESSLock()
	return activateSlot(opts)
}

func activateSlot(opts options) (resultErr error) {
	if os.Geteuid() != 0 {
		return errors.New("AWG activation must run as root")
	}
	availableKB, err := availableMemoryKB("/proc/meminfo")
	if err != nil {
		return err
	}
	if availableKB < opts.minAvailableKB {
		return fmt.Errorf("available memory %d KB is below the AWG safety floor %d KB", availableKB, opts.minAvailableKB)
	}
	if err := requireExecutable(opts.runtime, "amneziawg-go"); err != nil {
		return err
	}
	if err := requireExecutable(opts.tools, "awg configurator"); err != nil {
		return err
	}
	for _, command := range []string{"ip"} {
		if _, err := exec.LookPath(command); err != nil {
			return fmt.Errorf("required command not found: %s", command)
		}
	}
	if err := checkNetworkAvailable(opts.interfaceName); err != nil {
		return err
	}
	xrayBinary, err := findXrayBinary(opts.xrayBinary)
	if err != nil {
		return err
	}
	if err := requireExecutable(opts.xrayInit, "Xray init script"); err != nil {
		return err
	}
	rawProfile, err := os.ReadFile(profilePath(opts))
	if err != nil {
		return fmt.Errorf("read AWG profile: %w", err)
	}
	profile, err := awgconfig.ParseNativeConfig(string(rawProfile))
	if err != nil {
		return errors.New("stored AWG profile is invalid")
	}
	if profile.AWGVersion == "3" {
		return errors.New("AWG 3 profiles remain experimental; use a self-hosted AWG 1/1.5/2 guest link")
	}
	if !hasDefaultIPv4(profile.AllowedIPs) {
		return errors.New("single AWG slot requires AllowedIPs to include 0.0.0.0/0")
	}
	if err := ensurePrivateDir(opts.dir); err != nil {
		return err
	}
	currentConfig, readErr := os.ReadFile(opts.xrayConfig)
	if readErr != nil {
		return fmt.Errorf("read current Xray config: %w", readErr)
	}
	if err := writeFileAtomic(rollbackPath(opts), currentConfig, 0600); err != nil {
		return fmt.Errorf("store Xray rollback config: %w", err)
	}
	state := runtimeState{
		Phase:     "starting",
		Runtime:   opts.runtime,
		Tools:     opts.tools,
		Interface: opts.interfaceName,
	}
	if err := saveState(opts, state); err != nil {
		return err
	}
	defer func() {
		if resultErr == nil {
			return
		}
		if rollbackErr := rollback(opts, state, true); rollbackErr != nil {
			resultErr = fmt.Errorf("%w; rollback failed: %v", resultErr, rollbackErr)
		}
	}()
	rollbackConfig, err := os.ReadFile(rollbackPath(opts))
	if err != nil {
		return fmt.Errorf("read Xray rollback config: %w", err)
	}
	awgXrayConfig, socks, err := buildAWGXrayConfig(rollbackConfig, opts.interfaceName)
	if err != nil {
		return err
	}
	if len(opts.healthURLs) == 0 {
		return errors.New("at least one SOCKS health URL is required")
	}
	for _, healthURL := range opts.healthURLs {
		if _, err := parseHealthURL(healthURL); err != nil {
			return err
		}
	}
	state.PausedServices = pauseVLESSServices()
	if err := saveState(opts, state); err != nil {
		return err
	}

	endpoint, err := resolveEndpoint(profile.EndpointHost, profile.EndpointPort)
	if err != nil {
		return err
	}
	setConf, err := awgconfig.RenderSetConf(string(rawProfile), endpoint)
	if err != nil {
		return errors.New("prepare AWG runtime config failed")
	}
	setConfPath := filepath.Join(opts.dir, ".runtime.conf")
	if err := writeFileAtomic(setConfPath, []byte(setConf), 0600); err != nil {
		return errors.New("write AWG runtime config failed")
	}
	defer os.Remove(setConfPath)

	logFile, err := os.OpenFile(runtimeLogPath(opts), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return fmt.Errorf("open AWG runtime log: %w", err)
	}
	runtimeCommand := exec.Command(opts.runtime, "-f", opts.interfaceName)
	runtimeCommand.Stdout = logFile
	runtimeCommand.Stderr = logFile
	runtimeCommand.Env = append(os.Environ(), "LOG_LEVEL=error")
	detachProcess(runtimeCommand)
	if err := runtimeCommand.Start(); err != nil {
		_ = logFile.Close()
		return errors.New("start amneziawg-go failed")
	}
	_ = logFile.Close()
	state.PID = runtimeCommand.Process.Pid
	if err := saveState(opts, state); err != nil {
		_ = runtimeCommand.Process.Kill()
		return err
	}
	if err := waitForRuntime(state, opts.startupTimeout); err != nil {
		return err
	}
	if err := configureInterface(opts, profile, setConfPath); err != nil {
		return err
	}
	if err := configurePolicyRoutes(opts.interfaceName, profile.AllowedIPs); err != nil {
		return err
	}
	if err := validateXrayConfig(xrayBinary, awgXrayConfig, opts.dir); err != nil {
		return err
	}
	if err := writeFileAtomic(opts.xrayConfig, awgXrayConfig, 0600); err != nil {
		return fmt.Errorf("activate AWG Xray config: %w", err)
	}
	if err := restartXray(opts.xrayInit); err != nil {
		return err
	}
	if err := waitForAWGHealth(opts, socks, state); err != nil {
		return err
	}
	state.Phase = "active"
	state.ActivatedAt = time.Now().UTC().Format(time.RFC3339)
	if err := saveState(opts, state); err != nil {
		return err
	}
	fmt.Printf("AWG slot active: interface=%s socks=%s:%d\n", opts.interfaceName, socks.Address, socks.Port)
	fmt.Println("The original Xray/VLESS configuration is saved for transactional rollback.")
	return nil
}

func deactivate(opts options) error {
	if err := acquireVLESSLock("keenetic-awg-slot:deactivate"); err != nil {
		return err
	}
	defer releaseVLESSLock()
	state, err := loadState(opts)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return errors.New("AWG slot is not active; use recover if cleanup is required")
		}
		return err
	}
	if err := rollback(opts, state, true); err != nil {
		return err
	}
	fmt.Println("AWG slot stopped; the previous Xray/VLESS configuration was restored.")
	return nil
}

func recoverSlot(opts options) error {
	if err := acquireVLESSLock("keenetic-awg-slot:recover"); err != nil {
		return err
	}
	defer releaseVLESSLock()
	state, err := loadState(opts)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return errors.New("AWG runtime state is invalid; refusing PID-based recovery")
		}
		if _, rollbackErr := os.Stat(rollbackPath(opts)); rollbackErr != nil {
			if errors.Is(rollbackErr, os.ErrNotExist) {
				return errors.New("no AWG recovery state or Xray rollback config exists")
			}
			return rollbackErr
		}
		state = runtimeState{}
	}
	if err := rollback(opts, state, true); err != nil {
		return err
	}
	fmt.Println("AWG recovery completed; the stored VLESS configuration is active.")
	return nil
}

func acquireVLESSLock(owner string) error {
	lockPath := "/opt/var/run/vless-go.lock"
	if err := os.MkdirAll(filepath.Dir(lockPath), 0755); err != nil {
		return errors.New("create VLESS lock parent failed")
	}
	for attempt := 0; attempt < 30; attempt++ {
		if err := os.Mkdir(lockPath, 0700); err == nil {
			_ = os.WriteFile(filepath.Join(lockPath, "pid"), []byte(strconv.Itoa(os.Getpid())+"\n"), 0600)
			_ = os.WriteFile(filepath.Join(lockPath, "owner"), []byte(owner+"\n"), 0600)
			_ = os.WriteFile(filepath.Join(lockPath, "created_at"), []byte(time.Now().Format("2006-01-02 15:04:05")+"\n"), 0600)
			return nil
		} else if !errors.Is(err, os.ErrExist) {
			return errors.New("create VLESS operation lock failed")
		}
		pidData, _ := os.ReadFile(filepath.Join(lockPath, "pid"))
		pid, _ := strconv.Atoi(strings.TrimSpace(string(pidData)))
		if pid <= 1 || !processAlive(pid) {
			_ = os.RemoveAll(lockPath)
			continue
		}
		time.Sleep(time.Second)
	}
	return errors.New("VLESS operation lock is busy")
}

func releaseVLESSLock() {
	lockPath := "/opt/var/run/vless-go.lock"
	pidData, _ := os.ReadFile(filepath.Join(lockPath, "pid"))
	if strings.TrimSpace(string(pidData)) == strconv.Itoa(os.Getpid()) {
		_ = os.RemoveAll(lockPath)
	}
}

func processAlive(pid int) bool {
	if pid <= 1 {
		return false
	}
	process, err := os.FindProcess(pid)
	return err == nil && process.Signal(syscall.Signal(0)) == nil
}

func bootStop(opts options) error {
	state, err := loadState(opts)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	var failures []string
	if err := stopRuntime(state); err != nil {
		failures = append(failures, err.Error())
	}
	if err := removeNetwork(state.Interface); err != nil {
		failures = append(failures, err.Error())
	}
	_ = os.Remove(statePath(opts))
	if len(failures) > 0 {
		return errors.New(strings.Join(failures, "; "))
	}
	return nil
}

func bootRecover(opts options) error {
	if _, err := os.Stat(rollbackPath(opts)); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	if err := acquireVLESSLock("keenetic-awg-slot:boot-recover"); err != nil {
		return err
	}
	defer releaseVLESSLock()
	rollbackConfig, err := os.ReadFile(rollbackPath(opts))
	if err != nil {
		return errors.New("read boot rollback config failed")
	}
	if err := writeFileAtomic(opts.xrayConfig, rollbackConfig, 0600); err != nil {
		return errors.New("restore VLESS config during boot failed")
	}
	state, stateErr := loadState(opts)
	if stateErr != nil {
		state = runtimeState{}
	}
	_ = stopRuntime(state)
	if state.Interface != "" {
		if err := removeNetwork(state.Interface); err != nil {
			return err
		}
	}
	_ = os.Remove(statePath(opts))
	_ = os.Remove(rollbackPath(opts))
	return nil
}

func rollback(opts options, state runtimeState, restart bool) error {
	var failures []string
	if rollbackConfig, err := os.ReadFile(rollbackPath(opts)); err == nil {
		if err := writeFileAtomic(opts.xrayConfig, rollbackConfig, 0600); err != nil {
			failures = append(failures, "restore Xray config: "+err.Error())
		} else if restart {
			if err := restartXray(opts.xrayInit); err != nil {
				failures = append(failures, err.Error())
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		failures = append(failures, "read rollback config: "+err.Error())
	}
	if err := stopRuntime(state); err != nil {
		failures = append(failures, err.Error())
	}
	if state.Interface != "" {
		if err := removeNetwork(state.Interface); err != nil {
			failures = append(failures, err.Error())
		}
	}
	if err := resumeServices(state.PausedServices); err != nil {
		failures = append(failures, err.Error())
	}
	if len(failures) == 0 {
		for _, path := range []string{statePath(opts), rollbackPath(opts)} {
			_ = os.Remove(path)
		}
	}
	if len(failures) > 0 {
		return errors.New(strings.Join(failures, "; "))
	}
	return nil
}

func pauseVLESSServices() []string {
	var paused []string
	for _, service := range []string{
		"/opt/etc/init.d/S25xray-minimal-go-failover",
		"/opt/etc/init.d/S26vless-go-watchdog",
	} {
		if requireExecutable(service, "service") != nil || exec.Command(service, "status").Run() != nil {
			continue
		}
		if exec.Command(service, "stop").Run() == nil {
			paused = append(paused, service)
		}
	}
	return paused
}

func resumeServices(services []string) error {
	var failures []string
	for _, service := range services {
		if service != "/opt/etc/init.d/S25xray-minimal-go-failover" && service != "/opt/etc/init.d/S26vless-go-watchdog" {
			failures = append(failures, "refusing unexpected service path in AWG state")
			continue
		}
		if err := exec.Command(service, "start").Run(); err != nil {
			failures = append(failures, fmt.Sprintf("restart paused service failed: %s", service))
		}
	}
	if len(failures) > 0 {
		return errors.New(strings.Join(failures, "; "))
	}
	return nil
}

func requireExecutable(path, label string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("%s not found: %s", label, path)
	}
	if info.IsDir() || info.Mode()&0111 == 0 {
		return fmt.Errorf("%s is not executable: %s", label, path)
	}
	return nil
}

func findXrayBinary(requested string) (string, error) {
	if requested != "" {
		if err := requireExecutable(requested, "Xray binary"); err != nil {
			return "", err
		}
		return requested, nil
	}
	for _, path := range []string{"/opt/sbin/xray", "/opt/bin/xray"} {
		if err := requireExecutable(path, "Xray binary"); err == nil {
			return path, nil
		}
	}
	return "", errors.New("Xray binary not found in /opt/sbin or /opt/bin")
}

func resolveEndpoint(host string, port uint16) (string, error) {
	resolveContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	addresses, err := net.DefaultResolver.LookupIPAddr(resolveContext, host)
	if err != nil || len(addresses) == 0 {
		return "", errors.New("resolve AWG endpoint failed")
	}
	for _, address := range addresses {
		if address.IP.To4() != nil {
			return net.JoinHostPort(address.IP.String(), strconv.Itoa(int(port))), nil
		}
	}
	return net.JoinHostPort(addresses[0].IP.String(), strconv.Itoa(int(port))), nil
}

func waitForRuntime(state runtimeState, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	socket := filepath.Join("/var/run/amneziawg", state.Interface+".sock")
	for time.Now().Before(deadline) {
		if !processMatches(state.PID, state.Runtime) {
			return errors.New("amneziawg-go exited before opening UAPI")
		}
		if info, err := os.Stat(socket); err == nil && info.Mode()&os.ModeSocket != 0 {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("timed out waiting for amneziawg-go UAPI")
}

func configureInterface(opts options, profile awgconfig.NativeProfile, setConfPath string) error {
	if _, err := exec.Command(opts.tools, "setconf", opts.interfaceName, setConfPath).CombinedOutput(); err != nil {
		return errors.New("apply AWG config failed; imported keys and AWG parameters were not logged")
	}
	if profile.MTU > 0 {
		if err := runQuiet("ip", "link", "set", "dev", opts.interfaceName, "mtu", strconv.Itoa(profile.MTU)); err != nil {
			return err
		}
	}
	for _, address := range profile.Addresses {
		family := ipFamily(address)
		args := []string{"address", "add", address, "dev", opts.interfaceName}
		if family == "-6" {
			args = append([]string{"-6"}, args...)
		}
		if err := runQuiet("ip", args...); err != nil {
			return err
		}
	}
	return runQuiet("ip", "link", "set", "dev", opts.interfaceName, "up")
}

func configurePolicyRoutes(interfaceName string, allowedIPs []string) error {
	hasV4 := false
	hasV6 := false
	for _, prefix := range allowedIPs {
		family := ipFamily(prefix)
		args := []string{"route", "replace", prefix, "dev", interfaceName, "table", routeTable}
		if family == "-6" {
			hasV6 = true
			args = append([]string{"-6"}, args...)
		} else {
			hasV4 = true
		}
		if err := runQuiet("ip", args...); err != nil {
			return err
		}
	}
	if hasV4 {
		if err := runQuiet("ip", "rule", "add", "pref", rulePref, "fwmark", routeMark, "table", routeTable); err != nil {
			return err
		}
	}
	if hasV6 {
		if err := runQuiet("ip", "-6", "rule", "add", "pref", rulePref, "fwmark", routeMark, "table", routeTable); err != nil {
			return err
		}
	}
	return nil
}

func checkNetworkAvailable(interfaceName string) error {
	if err := exec.Command("ip", "link", "show", interfaceName).Run(); err == nil {
		return fmt.Errorf("AWG interface already exists: %s", interfaceName)
	}
	if _, err := os.Stat(filepath.Join("/var/run/amneziawg", interfaceName+".sock")); err == nil {
		return fmt.Errorf("AWG UAPI socket already exists for interface %s", interfaceName)
	} else if !errors.Is(err, os.ErrNotExist) {
		return errors.New("cannot inspect AWG UAPI socket")
	}
	if output, _ := exec.Command("ip", "rule", "show").CombinedOutput(); bytes.Contains(output, []byte("lookup "+routeTable)) || bytes.Contains(output, []byte(rulePref+":")) {
		return errors.New("routing table 51820 is already managed by another IPv4 rule")
	}
	if output, _ := exec.Command("ip", "-6", "rule", "show").CombinedOutput(); bytes.Contains(output, []byte("lookup "+routeTable)) || bytes.Contains(output, []byte(rulePref+":")) {
		return errors.New("routing table 51820 is already managed by another IPv6 rule")
	}
	if output, _ := exec.Command("ip", "route", "show", "table", routeTable).CombinedOutput(); len(bytes.TrimSpace(output)) != 0 {
		return errors.New("routing table 51820 already contains IPv4 routes")
	}
	if output, _ := exec.Command("ip", "-6", "route", "show", "table", routeTable).CombinedOutput(); len(bytes.TrimSpace(output)) != 0 {
		return errors.New("routing table 51820 already contains IPv6 routes")
	}
	return nil
}

func removeNetwork(interfaceName string) error {
	var failures []string
	for _, args := range [][]string{
		{"rule", "del", "pref", rulePref, "fwmark", routeMark, "table", routeTable},
		{"-6", "rule", "del", "pref", rulePref, "fwmark", routeMark, "table", routeTable},
		{"route", "flush", "table", routeTable},
		{"-6", "route", "flush", "table", routeTable},
		{"link", "delete", interfaceName},
	} {
		if output, err := exec.Command("ip", args...).CombinedOutput(); err != nil && commandExistsForCleanup(args, output) {
			failures = append(failures, fmt.Sprintf("ip %s failed", strings.Join(args, " ")))
		}
	}
	_ = os.Remove(filepath.Join("/var/run/amneziawg", interfaceName+".sock"))
	if len(failures) > 0 {
		return errors.New(strings.Join(failures, "; "))
	}
	return nil
}

func commandExistsForCleanup(_ []string, output []byte) bool {
	text := strings.ToLower(string(output))
	return !strings.Contains(text, "no such") && !strings.Contains(text, "not found") && !strings.Contains(text, "cannot find") && !strings.Contains(text, "no such process")
}

func stopRuntime(state runtimeState) error {
	if state.PID <= 1 || !processMatches(state.PID, state.Runtime) {
		return nil
	}
	process, err := os.FindProcess(state.PID)
	if err != nil {
		return nil
	}
	_ = process.Signal(syscall.SIGTERM)
	for attempt := 0; attempt < 20; attempt++ {
		if !processMatches(state.PID, state.Runtime) {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = process.Kill()
	return nil
}

func processMatches(pid int, executable string) bool {
	if pid <= 1 || executable == "" {
		return false
	}
	runningPath, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
	if err != nil {
		return false
	}
	wantedPath, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return false
	}
	return filepath.Clean(strings.TrimSuffix(runningPath, " (deleted)")) == filepath.Clean(wantedPath)
}

func runQuiet(name string, args ...string) error {
	if output, err := exec.Command(name, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("%s %s failed: %s", name, strings.Join(args, " "), redactedCommandError(output))
	}
	return nil
}

func redactedCommandError(output []byte) string {
	text := strings.TrimSpace(string(output))
	if text == "" {
		return "no diagnostic output"
	}
	if len(text) > 240 {
		text = text[:240]
	}
	return strings.Map(func(character rune) rune {
		if character < 0x20 && character != '\t' {
			return ' '
		}
		return character
	}, text)
}

func hasDefaultIPv4(prefixes []string) bool {
	for _, value := range prefixes {
		if value == "0.0.0.0/0" {
			return true
		}
	}
	return false
}

func availableMemoryKB(path string) (uint64, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, errors.New("read available memory failed")
	}
	values := make(map[string]uint64)
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		key := strings.TrimSuffix(fields[0], ":")
		if key != "MemAvailable" && key != "MemFree" && key != "Buffers" && key != "Cached" {
			continue
		}
		value, parseErr := strconv.ParseUint(fields[1], 10, 64)
		if parseErr == nil {
			values[key] = value
		}
	}
	if values["MemAvailable"] > 0 {
		return values["MemAvailable"], nil
	}
	fallback := values["MemFree"] + values["Buffers"] + values["Cached"]
	if fallback == 0 {
		return 0, errors.New("available memory is unavailable")
	}
	return fallback, nil
}

func ipFamily(value string) string {
	prefix, err := netip.ParsePrefix(value)
	if err == nil && prefix.Addr().Is6() {
		return "-6"
	}
	return ""
}

func restartXray(initPath string) error {
	if output, err := exec.Command(initPath, "restart").CombinedOutput(); err != nil {
		if startOutput, startErr := exec.Command(initPath, "start").CombinedOutput(); startErr != nil {
			return fmt.Errorf("restart Xray failed: %s; start failed: %s", redactedCommandError(output), redactedCommandError(startOutput))
		}
	}
	return nil
}

func validateXrayConfig(binary string, config []byte, dir string) error {
	path := filepath.Join(dir, ".xray-awg.json")
	if err := writeFileAtomic(path, config, 0600); err != nil {
		return err
	}
	defer os.Remove(path)
	if output, err := exec.Command(binary, "run", "-test", "-config", path).CombinedOutput(); err == nil {
		return nil
	} else if fallback, fallbackErr := exec.Command(binary, "test", "-config", path).CombinedOutput(); fallbackErr != nil {
		return fmt.Errorf("Xray rejected AWG config: %s; %s", redactedCommandError(output), redactedCommandError(fallback))
	}
	return nil
}

func buildAWGXrayConfig(raw []byte, interfaceName string) ([]byte, socksEndpoint, error) {
	var config map[string]any
	if err := json.Unmarshal(raw, &config); err != nil {
		return nil, socksEndpoint{}, errors.New("current Xray config is invalid JSON")
	}
	socks, err := findSocksEndpoint(config)
	if err != nil {
		return nil, socksEndpoint{}, err
	}
	config["outbounds"] = []any{
		map[string]any{
			"tag":      "awg-out",
			"protocol": "freedom",
			"settings": map[string]any{"domainStrategy": "UseIP"},
			"streamSettings": map[string]any{
				"sockopt": map[string]any{"interface": interfaceName, "mark": 51820},
			},
		},
		map[string]any{"tag": "block", "protocol": "blackhole"},
	}
	delete(config, "routing")
	encoded, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return nil, socksEndpoint{}, errors.New("encode AWG Xray config failed")
	}
	return append(encoded, '\n'), socks, nil
}

func findSocksEndpoint(config map[string]any) (socksEndpoint, error) {
	inbounds, ok := config["inbounds"].([]any)
	if !ok {
		return socksEndpoint{}, errors.New("current Xray config has no inbounds")
	}
	for _, rawInbound := range inbounds {
		inbound, ok := rawInbound.(map[string]any)
		if !ok || !strings.EqualFold(stringField(inbound, "protocol"), "socks") {
			continue
		}
		port, ok := numberAsPort(inbound["port"])
		if !ok {
			return socksEndpoint{}, errors.New("SOCKS inbound has an invalid port")
		}
		address := strings.TrimSpace(stringField(inbound, "listen"))
		switch address {
		case "", "0.0.0.0":
			address = "127.0.0.1"
		case "::", "[::]":
			address = "::1"
		}
		endpoint := socksEndpoint{Address: address, Port: port}
		if settings, ok := inbound["settings"].(map[string]any); ok {
			if accounts, ok := settings["accounts"].([]any); ok && len(accounts) > 0 {
				if account, ok := accounts[0].(map[string]any); ok {
					endpoint.Username = stringField(account, "user")
					endpoint.Password = stringField(account, "pass")
				}
			}
		}
		return endpoint, nil
	}
	return socksEndpoint{}, errors.New("current Xray config has no SOCKS inbound")
}

func stringField(value map[string]any, key string) string {
	text, _ := value[key].(string)
	return text
}

func numberAsPort(value any) (uint16, bool) {
	switch number := value.(type) {
	case float64:
		if number >= 1 && number <= 65535 && number == float64(uint16(number)) {
			return uint16(number), true
		}
	case json.Number:
		parsed, err := strconv.ParseUint(number.String(), 10, 16)
		return uint16(parsed), err == nil && parsed > 0
	}
	return 0, false
}

func waitForAWGHealth(opts options, socks socksEndpoint, state runtimeState) error {
	deadline := time.Now().Add(opts.handshakeTimeout)
	var lastError error
	for time.Now().Before(deadline) {
		if !processMatches(state.PID, state.Runtime) {
			return errors.New("amneziawg-go stopped during health check")
		}
		for _, healthURL := range opts.healthURLs {
			if err := socksHTTPCheck(socks, healthURL, 5*time.Second); err == nil {
				if hasRecentHandshake(state.Tools, state.Interface) {
					return nil
				}
				lastError = errors.New("SOCKS works but AWG handshake was not reported")
			} else {
				lastError = err
			}
		}
		time.Sleep(time.Second)
	}
	if lastError == nil {
		lastError = errors.New("no health result")
	}
	return fmt.Errorf("AWG handshake/SOCKS health check failed: %w", lastError)
}

func hasRecentHandshake(tools, interfaceName string) bool {
	output, err := exec.Command(tools, "show", interfaceName, "latest-handshakes").Output()
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		seconds, err := strconv.ParseInt(fields[len(fields)-1], 10, 64)
		if err == nil && seconds > 0 && time.Since(time.Unix(seconds, 0)) < 3*time.Minute {
			return true
		}
	}
	return false
}

func parseHealthURL(raw string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "http" || parsed.Hostname() == "" || parsed.User != nil {
		return nil, fmt.Errorf("health URL must be plain http without credentials: %q", raw)
	}
	if parsed.Port() != "" {
		port, err := strconv.ParseUint(parsed.Port(), 10, 16)
		if err != nil || port == 0 {
			return nil, fmt.Errorf("health URL has an invalid port: %q", raw)
		}
	}
	return parsed, nil
}

func socksHTTPCheck(proxy socksEndpoint, rawURL string, timeout time.Duration) error {
	target, err := parseHealthURL(rawURL)
	if err != nil {
		return err
	}
	connection, err := net.DialTimeout("tcp", net.JoinHostPort(proxy.Address, strconv.Itoa(int(proxy.Port))), timeout)
	if err != nil {
		return errors.New("SOCKS endpoint is unavailable")
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(timeout))
	methods := []byte{0x00}
	if proxy.Username != "" || proxy.Password != "" {
		methods = append(methods, 0x02)
	}
	request := append([]byte{0x05, byte(len(methods))}, methods...)
	if _, err := connection.Write(request); err != nil {
		return errors.New("SOCKS greeting failed")
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(connection, reply); err != nil || reply[0] != 0x05 || reply[1] == 0xff {
		return errors.New("SOCKS authentication method negotiation failed")
	}
	if reply[1] == 0x02 {
		if err := socksAuthenticate(connection, proxy.Username, proxy.Password); err != nil {
			return err
		}
	} else if reply[1] != 0x00 {
		return errors.New("SOCKS selected an unsupported authentication method")
	}
	host := target.Hostname()
	if len(host) > 255 {
		return errors.New("health URL hostname is too long")
	}
	port := uint16(80)
	if target.Port() != "" {
		parsedPort, _ := strconv.ParseUint(target.Port(), 10, 16)
		port = uint16(parsedPort)
	}
	connect := []byte{0x05, 0x01, 0x00, 0x03, byte(len(host))}
	connect = append(connect, []byte(host)...)
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, port)
	connect = append(connect, portBytes...)
	if _, err := connection.Write(connect); err != nil {
		return errors.New("SOCKS connect request failed")
	}
	if err := readSocksReply(connection); err != nil {
		return err
	}
	path := target.RequestURI()
	if path == "" {
		path = "/"
	}
	requestText := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nUser-Agent: keenetic-awg-health/1\r\n\r\n", path, target.Host)
	if _, err := io.WriteString(connection, requestText); err != nil {
		return errors.New("health HTTP request failed")
	}
	statusLine, err := bufio.NewReader(connection).ReadString('\n')
	if err != nil {
		return errors.New("health HTTP response failed")
	}
	fields := strings.Fields(statusLine)
	if len(fields) < 2 {
		return errors.New("health HTTP response is invalid")
	}
	status, err := strconv.Atoi(fields[1])
	if err != nil || status < 200 || status >= 400 {
		return fmt.Errorf("health HTTP status is %s", fields[1])
	}
	return nil
}

func socksAuthenticate(connection net.Conn, username, password string) error {
	if len(username) > 255 || len(password) > 255 {
		return errors.New("SOCKS credentials are too long")
	}
	request := []byte{0x01, byte(len(username))}
	request = append(request, []byte(username)...)
	request = append(request, byte(len(password)))
	request = append(request, []byte(password)...)
	if _, err := connection.Write(request); err != nil {
		return errors.New("SOCKS authentication request failed")
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(connection, reply); err != nil || reply[1] != 0x00 {
		return errors.New("SOCKS authentication failed")
	}
	return nil
}

func readSocksReply(connection net.Conn) error {
	header := make([]byte, 4)
	if _, err := io.ReadFull(connection, header); err != nil || header[0] != 0x05 || header[1] != 0x00 {
		return errors.New("SOCKS connect failed")
	}
	length := 0
	switch header[3] {
	case 0x01:
		length = 4
	case 0x04:
		length = 16
	case 0x03:
		size := []byte{0}
		if _, err := io.ReadFull(connection, size); err != nil {
			return errors.New("SOCKS reply is truncated")
		}
		length = int(size[0])
	default:
		return errors.New("SOCKS reply address type is unsupported")
	}
	remaining := make([]byte, length+2)
	if _, err := io.ReadFull(connection, remaining); err != nil {
		return errors.New("SOCKS reply is truncated")
	}
	return nil
}
