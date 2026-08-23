package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Kuzz007/keenetic_xray_installer/internal/awgconfig"
)

const (
	profileSchema  = "keenetic-vpn.awg-profile.v1"
	stateSchema    = "keenetic-vpn.awg-state.v1"
	maxImportBytes = (2 << 20) + 1
)

var slotVersion = "dev"

type options struct {
	dir              string
	profileSlot      string
	input            string
	runtime          string
	tools            string
	interfaceName    string
	xrayConfig       string
	xrayInit         string
	xrayBinary       string
	healthURLs       []string
	startupTimeout   time.Duration
	handshakeTimeout time.Duration
	jsonOutput       bool
	minAvailableKB   uint64
}

type storedProfile struct {
	Schema       string   `json:"schema"`
	Name         string   `json:"name,omitempty"`
	Container    string   `json:"container"`
	AWGVersion   string   `json:"awg_version"`
	Addresses    []string `json:"addresses"`
	AllowedIPs   []string `json:"allowed_ips"`
	EndpointPort uint16   `json:"endpoint_port"`
	ImportedAt   string   `json:"imported_at"`
}

type runtimeState struct {
	Schema         string   `json:"schema"`
	Phase          string   `json:"phase"`
	ProfileSlot    string   `json:"profile_slot,omitempty"`
	PID            int      `json:"pid,omitempty"`
	Runtime        string   `json:"runtime"`
	Tools          string   `json:"tools"`
	Interface      string   `json:"interface"`
	RouteTable     uint32   `json:"route_table,omitempty"`
	RouteMark      uint32   `json:"route_mark,omitempty"`
	RulePref       uint32   `json:"rule_pref,omitempty"`
	RoutePrefixes  []string `json:"route_prefixes,omitempty"`
	PausedServices []string `json:"paused_services,omitempty"`
	ActivatedAt    string   `json:"activated_at,omitempty"`
}

type statusOutput struct {
	Version       string `json:"version"`
	SelectedSlot  string `json:"selected_slot"`
	ActiveSlot    string `json:"active_slot,omitempty"`
	Profile       string `json:"profile"`
	AWGVersion    string `json:"awg_version,omitempty"`
	AddressCount  int    `json:"address_count,omitempty"`
	AllowedCount  int    `json:"allowed_ip_count,omitempty"`
	Phase         string `json:"phase"`
	Runtime       string `json:"runtime"`
	InterfaceName string `json:"interface,omitempty"`
	RouteTable    uint32 `json:"route_table,omitempty"`
	RouteMark     uint32 `json:"route_mark,omitempty"`
	RulePref      uint32 `json:"rule_pref,omitempty"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 1 && (args[0] == "-version" || args[0] == "--version") {
		fmt.Println(slotVersion)
		return nil
	}
	command := "status"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		command = args[0]
		args = args[1:]
	}
	if command == "help" {
		usage()
		return nil
	}

	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	opts := options{}
	flags.StringVar(&opts.dir, "dir", "/opt/etc/xray/awg", "AWG profile and runtime state directory")
	flags.StringVar(&opts.profileSlot, "slot", "single", "AWG profile slot: single, primary or backup")
	flags.StringVar(&opts.input, "input", "-", "vpn:// input file, or - for stdin")
	flags.StringVar(&opts.runtime, "runtime", "/opt/libexec/amneziawg-go", "amneziawg-go executable")
	flags.StringVar(&opts.tools, "tools", "/opt/bin/awg", "AmneziaWG configurator executable")
	flags.StringVar(&opts.interfaceName, "interface", "awgx0", "managed AWG interface")
	flags.StringVar(&opts.xrayConfig, "xray-config", "/opt/etc/xray/config.json", "active Xray configuration")
	flags.StringVar(&opts.xrayInit, "xray-init", "/opt/etc/init.d/S24xray", "Xray init script")
	flags.StringVar(&opts.xrayBinary, "xray-bin", "", "Xray executable; auto-detected when empty")
	healthURLs := flags.String("health-urls", "http://connectivitycheck.gstatic.com/generate_204,http://cp.cloudflare.com/generate_204,http://www.gstatic.com/generate_204", "comma-separated SOCKS health URLs")
	startupSeconds := flags.Int("startup-timeout", 15, "runtime/Xray startup timeout in seconds")
	handshakeSeconds := flags.Int("handshake-timeout", 30, "AWG handshake timeout in seconds")
	minAvailableKB := flags.Uint64("min-available-kb", 24576, "minimum MemAvailable required before activation")
	flags.BoolVar(&opts.jsonOutput, "json", false, "machine-readable status output")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			usage()
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected argument %q", flags.Arg(0))
	}
	if *startupSeconds < 1 || *startupSeconds > 120 || *handshakeSeconds < 1 || *handshakeSeconds > 180 {
		return errors.New("timeouts are outside the supported range")
	}
	opts.startupTimeout = time.Duration(*startupSeconds) * time.Second
	opts.handshakeTimeout = time.Duration(*handshakeSeconds) * time.Second
	opts.minAvailableKB = *minAvailableKB
	if opts.minAvailableKB < 16384 || opts.minAvailableKB > 1048576 {
		return errors.New("minimum available memory must be between 16384 and 1048576 KB")
	}
	for _, rawURL := range strings.Split(*healthURLs, ",") {
		if value := strings.TrimSpace(rawURL); value != "" {
			opts.healthURLs = append(opts.healthURLs, value)
		}
	}
	if err := validateOptions(opts); err != nil {
		return err
	}
	if command != "status" && command != "version" {
		release, err := acquireLock(opts)
		if err != nil {
			return err
		}
		defer release()
	}

	switch command {
	case "import":
		return importProfile(opts)
	case "status":
		return printStatus(opts)
	case "activate":
		return activate(opts)
	case "deactivate":
		return deactivate(opts)
	case "recover":
		return recoverSlot(opts)
	case "delete":
		return deleteProfile(opts)
	case "boot-recover":
		return bootRecover(opts)
	case "boot-stop":
		return bootStop(opts)
	case "version":
		fmt.Printf("keenetic-awg-slot %s\n", slotVersion)
		return nil
	default:
		usage()
		return fmt.Errorf("unknown command %q", command)
	}
}

func validateOptions(opts options) error {
	if opts.dir == "" || !filepath.IsAbs(opts.dir) || opts.xrayConfig == "" || !filepath.IsAbs(opts.xrayConfig) {
		return errors.New("state and Xray config paths must be absolute")
	}
	for label, path := range map[string]string{
		"AWG runtime": opts.runtime,
		"AWG tools":   opts.tools,
		"Xray init":   opts.xrayInit,
	} {
		if path == "" || !filepath.IsAbs(path) {
			return fmt.Errorf("%s path must be absolute", label)
		}
	}
	if opts.xrayBinary != "" && !filepath.IsAbs(opts.xrayBinary) {
		return errors.New("Xray binary path must be absolute")
	}
	if !validProfileSlot(opts.profileSlot) {
		return errors.New("AWG profile slot must be single, primary or backup")
	}
	if opts.interfaceName == "" || len(opts.interfaceName) > 15 {
		return errors.New("AWG interface must contain 1..15 characters")
	}
	if !isInterfaceAlphaNumeric(opts.interfaceName[0]) || !isInterfaceAlphaNumeric(opts.interfaceName[len(opts.interfaceName)-1]) {
		return errors.New("AWG interface must start and end with an ASCII letter or digit")
	}
	for _, character := range opts.interfaceName {
		if !(character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || strings.ContainsRune("_.-", character)) {
			return errors.New("AWG interface contains unsupported characters")
		}
	}
	return nil
}

func validProfileSlot(slot string) bool {
	switch slot {
	case "single", "primary", "backup":
		return true
	default:
		return false
	}
}

func isInterfaceAlphaNumeric(character byte) bool {
	return character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9'
}

func importProfile(opts options) error {
	if _, err := os.Stat(statePath(opts)); err == nil {
		return errors.New("AWG slot has runtime state; deactivate or recover it before replacing the profile")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, path := range []string{rollbackPath(opts)} {
		if _, err := os.Stat(path); err == nil {
			return errors.New("AWG slot is enabled or has rollback state; deactivate or recover it before replacing the profile")
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}

	reader := io.Reader(os.Stdin)
	var input *os.File
	if opts.input != "-" {
		file, err := os.Open(opts.input)
		if err != nil {
			return fmt.Errorf("open vpn input: %w", err)
		}
		defer file.Close()
		input = file
		reader = file
	}
	data, err := io.ReadAll(io.LimitReader(reader, maxImportBytes))
	if err != nil {
		return errors.New("read vpn input failed")
	}
	if len(data) == 0 || len(data) >= maxImportBytes {
		return errors.New("vpn input is empty or too large")
	}
	profile, err := awgconfig.ParseVPNURL(string(data))
	if err != nil {
		return err
	}
	if input != nil {
		_ = input.Close()
	}
	if err := ensurePrivateDir(filepath.Dir(profilePath(opts))); err != nil {
		return err
	}
	if err := writeFileAtomic(profilePath(opts), []byte(profile.NativeConfig()), 0600); err != nil {
		return fmt.Errorf("store AWG profile: %w", err)
	}
	metadata := storedProfile{
		Schema:       profileSchema,
		Name:         cleanLabel(profile.Name),
		Container:    profile.Container,
		AWGVersion:   profile.AWGVersion,
		Addresses:    profile.Addresses,
		AllowedIPs:   profile.AllowedIPs,
		EndpointPort: profile.EndpointPort,
		ImportedAt:   time.Now().UTC().Format(time.RFC3339),
	}
	encoded, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return errors.New("encode AWG profile metadata failed")
	}
	encoded = append(encoded, '\n')
	if err := writeFileAtomic(metadataPath(opts), encoded, 0600); err != nil {
		return fmt.Errorf("store AWG profile metadata: %w", err)
	}
	fmt.Printf("AWG profile imported: version=%s addresses=%d allowed_ips=%d\n", profile.AWGVersion, len(profile.Addresses), len(profile.AllowedIPs))
	fmt.Println("The active VPN slot and Xray configuration were not changed.")
	return nil
}

func printStatus(opts options) error {
	status := statusOutput{Version: slotVersion, SelectedSlot: opts.profileSlot, Profile: "not-configured", Phase: "inactive", Runtime: "stopped"}
	if raw, err := os.ReadFile(profilePath(opts)); err == nil {
		profile, parseErr := awgconfig.ParseNativeConfig(string(raw))
		if parseErr != nil {
			status.Profile = "invalid"
		} else {
			status.Profile = "configured"
			status.AWGVersion = profile.AWGVersion
			status.AddressCount = len(profile.Addresses)
			status.AllowedCount = len(profile.AllowedIPs)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read AWG profile: %w", err)
	}
	if state, err := loadState(opts); err == nil {
		status.Phase = state.Phase
		status.ActiveSlot = normalizedProfileSlot(state.ProfileSlot)
		status.InterfaceName = state.Interface
		status.RouteTable = state.RouteTable
		status.RouteMark = state.RouteMark
		status.RulePref = state.RulePref
		if state.PID > 0 && processMatches(state.PID, state.Runtime) {
			status.Runtime = "running"
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if opts.jsonOutput {
		return json.NewEncoder(os.Stdout).Encode(status)
	}
	fmt.Printf("AWG_SLOT_PROFILE=%s\n", status.Profile)
	if status.AWGVersion != "" {
		fmt.Printf("AWG_SLOT_VERSION=%s\n", status.AWGVersion)
		fmt.Printf("AWG_SLOT_ADDRESSES=%d\n", status.AddressCount)
		fmt.Printf("AWG_SLOT_ALLOWED_IPS=%d\n", status.AllowedCount)
	}
	fmt.Printf("AWG_SLOT_PHASE=%s\n", status.Phase)
	fmt.Printf("AWG_SLOT_RUNTIME=%s\n", status.Runtime)
	if status.InterfaceName != "" {
		fmt.Printf("AWG_SLOT_INTERFACE=%s\n", status.InterfaceName)
	}
	if status.RouteTable != 0 {
		fmt.Printf("AWG_SLOT_ROUTE_TABLE=%d\n", status.RouteTable)
		fmt.Printf("AWG_SLOT_ROUTE_MARK=%d\n", status.RouteMark)
		fmt.Printf("AWG_SLOT_RULE_PREF=%d\n", status.RulePref)
	}
	fmt.Printf("AWG_SLOT_SELECTED=%s\n", status.SelectedSlot)
	if status.ActiveSlot != "" {
		fmt.Printf("AWG_SLOT_ACTIVE=%s\n", status.ActiveSlot)
	}
	return nil
}

func deleteProfile(opts options) error {
	if _, err := os.Stat(statePath(opts)); err == nil {
		return errors.New("AWG slot is active or needs recovery; deactivate or recover it first")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if _, err := os.Stat(rollbackPath(opts)); err == nil {
		return errors.New("AWG rollback state exists; run recover before deleting the profile")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, path := range []string{profilePath(opts), metadataPath(opts)} {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("delete AWG profile: %w", err)
		}
	}
	fmt.Println("AWG profile deleted. Active VPN state was not changed.")
	return nil
}

func profilePath(opts options) string {
	if opts.profileSlot == "single" {
		return filepath.Join(opts.dir, "single.conf")
	}
	return filepath.Join(opts.dir, "profiles", opts.profileSlot+".conf")
}

func metadataPath(opts options) string {
	if opts.profileSlot == "single" {
		return filepath.Join(opts.dir, "single.json")
	}
	return filepath.Join(opts.dir, "profiles", opts.profileSlot+".json")
}
func statePath(opts options) string    { return filepath.Join(opts.dir, "runtime.json") }
func rollbackPath(opts options) string { return filepath.Join(opts.dir, "xray.rollback.json") }
func runtimeLogPath(opts options) string {
	return filepath.Join(opts.dir, "runtime.log")
}

func cleanLabel(value string) string {
	value = strings.Map(func(character rune) rune {
		if character < 0x20 || character == 0x7f {
			return -1
		}
		return character
	}, strings.TrimSpace(value))
	if len(value) > 128 {
		value = value[:128]
	}
	return value
}

func normalizedProfileSlot(slot string) string {
	if slot == "" {
		return "single"
	}
	if validProfileSlot(slot) {
		return slot
	}
	return ""
}

func usage() {
	fmt.Println(`keenetic-awg-slot - isolated self-hosted AmneziaWG slot

Usage:
  keenetic-awg-slot import --slot single|primary|backup --input FILE|-
  keenetic-awg-slot status --slot single|primary|backup [--json]
  keenetic-awg-slot activate --slot single|primary|backup [runtime options]
  keenetic-awg-slot deactivate
  keenetic-awg-slot recover
  keenetic-awg-slot delete
  keenetic-awg-slot version

The legacy single profile remains available. Named primary/backup profiles are
used by the mixed failover layer. Activation keeps the existing SOCKS inbound
and replaces only the current outbound. Any failed runtime, handshake or SOCKS
check restores the previous Xray configuration.`)
}
