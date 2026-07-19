package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const userAgent = "Keenetic-Xray-Failover-Go/0.1"

var version = "0.1.4-go-xhttp"

type cliOptions struct {
	input          string
	output         string
	listenHost     string
	listenPort     int
	profileName    string
	nonInteractive bool
	listOnly       bool
	selectIndex    int
	selectName     string
	privateOutput  bool
	jsonOutput     bool
	showVersion    bool
}

type vlessProfile struct {
	Raw    string
	Name   string
	UUID   string
	Server string
	Port   int
	Params map[string]string
}

type profileInfo struct {
	Index     int    `json:"index"`
	Name      string `json:"name"`
	Server    string `json:"server,omitempty"`
	Port      int    `json:"port,omitempty"`
	Transport string `json:"transport"`
	Security  string `json:"security"`
}

type cliJSON struct {
	Version      string        `json:"version"`
	ProfileCount int           `json:"profile_count"`
	Profiles     []profileInfo `json:"profiles,omitempty"`
	Selected     *profileInfo  `json:"selected,omitempty"`
	Output       string        `json:"output,omitempty"`
	Listen       string        `json:"listen,omitempty"`
	Port         int           `json:"port,omitempty"`
}

func main() {
	var opts cliOptions
	flag.StringVar(&opts.input, "input", "", "vless:// link or http(s) subscription URL")
	flag.StringVar(&opts.output, "output", "/opt/etc/xray/config.json", "output Xray config path")
	flag.StringVar(&opts.listenHost, "listen", "0.0.0.0", "SOCKS inbound listen address")
	flag.IntVar(&opts.listenPort, "port", 10808, "SOCKS inbound listen port")
	flag.StringVar(&opts.profileName, "profile", "vless-out", "Xray outbound tag")
	flag.BoolVar(&opts.nonInteractive, "first", false, "choose first profile without prompting")
	flag.BoolVar(&opts.listOnly, "list", false, "list available profiles and exit without writing a config")
	flag.IntVar(&opts.selectIndex, "select-index", 0, "choose 1-based profile index without prompting")
	flag.StringVar(&opts.selectName, "select-name", "", "choose profile by exact name, or unique case-insensitive substring")
	flag.BoolVar(&opts.privateOutput, "private", false, "hide server/domain details in human and JSON output")
	flag.BoolVar(&opts.jsonOutput, "json", false, "emit machine-readable JSON status/list output")
	flag.BoolVar(&opts.showVersion, "version", false, "print version and exit")
	flag.Parse()

	if opts.showVersion {
		fmt.Println(version)
		return
	}

	if strings.TrimSpace(opts.input) == "" {
		fail("missing -input. Use vless:// link or http(s) subscription URL")
	}
	if opts.selectIndex < 0 {
		fail("-select-index must be zero or a positive 1-based index")
	}
	if opts.selectIndex > 0 && strings.TrimSpace(opts.selectName) != "" {
		fail("use only one selector: -select-index or -select-name")
	}
	if opts.nonInteractive && (opts.selectIndex > 0 || strings.TrimSpace(opts.selectName) != "") {
		fail("use only one selector: -first, -select-index, or -select-name")
	}

	profiles, err := resolveProfiles(opts.input)
	if err != nil {
		fail(err.Error())
	}
	if len(profiles) == 0 {
		fail("no vless:// profiles found")
	}

	if !opts.jsonOutput {
		fmt.Fprintf(os.Stderr, "Found VLESS profiles: %d\n", len(profiles))
		for i, profile := range profiles {
			fmt.Fprintf(os.Stderr, "%d. %s\n", i+1, profile.Label(opts.privateOutput))
		}
	}

	if opts.listOnly {
		if opts.jsonOutput {
			writeMachineJSON(cliJSON{Version: version, ProfileCount: len(profiles), Profiles: profilesInfo(profiles, opts.privateOutput)})
		}
		return
	}

	selected, selectedIndex, err := selectProfile(profiles, opts)
	if err != nil {
		fail(err.Error())
	}

	cfg, err := buildXrayConfig(selected, opts)
	if err != nil {
		fail(err.Error())
	}

	if err := writeJSON(opts.output, cfg); err != nil {
		fail(err.Error())
	}

	selectedInfo := selected.Info(selectedIndex+1, opts.privateOutput)
	if opts.jsonOutput {
		writeMachineJSON(cliJSON{
			Version:      version,
			ProfileCount: len(profiles),
			Selected:     &selectedInfo,
			Output:       opts.output,
			Listen:       opts.listenHost,
			Port:         opts.listenPort,
		})
		return
	}

	fmt.Printf("Created config: %s\n", opts.output)
	fmt.Printf("Profile: %s\n", selected.Label(opts.privateOutput))
	if opts.privateOutput {
		fmt.Printf("Server: <hidden>\n")
	} else {
		fmt.Printf("Server: %s\n", selected.Server)
	}
	fmt.Printf("Port: %d\n", selected.Port)
	fmt.Printf("Transport: %s\n", normalizedNetwork(selected.Params))
	fmt.Printf("Security: %s\n", valueOrDefault(selected.Params["security"], "none"))
	fmt.Printf("SOCKS5: %s:%d\n", opts.listenHost, opts.listenPort)
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "ERROR:", msg)
	os.Exit(1)
}

func writeMachineJSON(value cliJSON) {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		fail(err.Error())
	}
}

func selectProfile(profiles []vlessProfile, opts cliOptions) (vlessProfile, int, error) {
	if len(profiles) == 0 {
		return vlessProfile{}, 0, errors.New("no profiles found")
	}

	if opts.selectIndex > 0 {
		if opts.selectIndex > len(profiles) {
			return vlessProfile{}, 0, fmt.Errorf("-select-index %d out of range [1-%d]", opts.selectIndex, len(profiles))
		}
		idx := opts.selectIndex - 1
		return profiles[idx], idx, nil
	}

	if name := strings.TrimSpace(opts.selectName); name != "" {
		idx, err := findProfileByName(profiles, name)
		if err != nil {
			return vlessProfile{}, 0, err
		}
		return profiles[idx], idx, nil
	}

	if len(profiles) > 1 && !opts.nonInteractive {
		idx, err := promptChoice(len(profiles))
		if err != nil {
			return vlessProfile{}, 0, err
		}
		return profiles[idx], idx, nil
	}

	return profiles[0], 0, nil
}

func findProfileByName(profiles []vlessProfile, needle string) (int, error) {
	for i, profile := range profiles {
		if profile.Name == needle {
			return i, nil
		}
	}

	needleLower := strings.ToLower(needle)
	matches := make([]int, 0, 1)
	for i, profile := range profiles {
		if strings.Contains(strings.ToLower(profile.Name), needleLower) {
			matches = append(matches, i)
		}
	}

	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return 0, fmt.Errorf("-select-name %q did not match any profile", needle)
	default:
		return 0, fmt.Errorf("-select-name %q is ambiguous: %d profiles matched", needle, len(matches))
	}
}

func resolveProfiles(input string) ([]vlessProfile, error) {
	input = strings.TrimSpace(input)
	if strings.HasPrefix(input, "vless://") {
		profile, err := parseVLESS(input)
		if err != nil {
			return nil, err
		}
		return []vlessProfile{profile}, nil
	}

	u, err := url.Parse(input)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return nil, errors.New("input must be vless:// or http(s) subscription URL")
	}

	payload, err := download(input)
	if err != nil {
		return nil, err
	}

	links := extractVLESSLinks(payload)
	profiles := make([]vlessProfile, 0, len(links))
	seen := make(map[string]bool)
	for _, link := range links {
		if seen[link] {
			continue
		}
		seen[link] = true
		profile, err := parseVLESS(link)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Skip invalid VLESS profile: %v\n", err)
			continue
		}
		profiles = append(profiles, profile)
	}

	return profiles, nil
}

func download(rawURL string) ([]byte, error) {
	client := &http.Client{Timeout: 25 * time.Second}
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "text/plain,*/*")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to download subscription: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("subscription download returned HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024))
	if err != nil {
		return nil, err
	}
	return body, nil
}

func extractVLESSLinks(payload []byte) []string {
	variants := decodeVariants(payload)
	re := regexp.MustCompile(`vless://[^\s\r\n<>"']+`)
	var links []string
	seen := make(map[string]bool)

	for _, text := range variants {
		matches := re.FindAllString(text, -1)
		for _, match := range matches {
			match = strings.TrimSpace(match)
			if match == "" || seen[match] {
				continue
			}
			seen[match] = true
			links = append(links, match)
		}
	}

	return links
}

func decodeVariants(payload []byte) []string {
	variants := []string{string(payload)}
	compact := regexp.MustCompile(`\s+`).ReplaceAll(payload, nil)
	if len(compact) == 0 {
		return variants
	}

	padded := make([]byte, len(compact))
	copy(padded, compact)
	if rem := len(padded) % 4; rem != 0 {
		padded = append(padded, []byte(strings.Repeat("=", 4-rem))...)
	}

	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.URLEncoding} {
		decoded, err := enc.DecodeString(string(padded))
		if err == nil && len(decoded) > 0 {
			variants = append(variants, string(decoded))
		}
	}

	return variants
}

func parseVLESS(raw string) (vlessProfile, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return vlessProfile{}, err
	}
	if u.Scheme != "vless" {
		return vlessProfile{}, errors.New("only vless:// profiles are supported")
	}

	uuid := u.User.Username()
	if uuid == "" {
		return vlessProfile{}, errors.New("missing UUID")
	}

	host := u.Hostname()
	if host == "" {
		return vlessProfile{}, errors.New("missing server host")
	}

	port := 443
	if rawPort := u.Port(); rawPort != "" {
		parsed, err := strconv.Atoi(rawPort)
		if err != nil || parsed <= 0 || parsed > 65535 {
			return vlessProfile{}, fmt.Errorf("invalid port: %s", rawPort)
		}
		port = parsed
	}

	params := make(map[string]string)
	for key, values := range u.Query() {
		if len(values) > 0 {
			params[key] = values[0]
		}
	}

	name, _ := url.QueryUnescape(u.Fragment)
	name = strings.TrimSpace(name)
	if name == "" {
		name = host
	}

	return vlessProfile{Raw: raw, Name: name, UUID: uuid, Server: host, Port: port, Params: params}, nil
}

func (p vlessProfile) Label(private bool) string {
	transport := normalizedNetwork(p.Params)
	security := valueOrDefault(p.Params["security"], "none")
	server := p.Server
	if private {
		server = "<hidden>"
	}
	return fmt.Sprintf("%s (%s:%d, %s/%s)", p.Name, server, p.Port, transport, security)
}

func (p vlessProfile) Info(index int, private bool) profileInfo {
	info := profileInfo{
		Index:     index,
		Name:      p.Name,
		Port:      p.Port,
		Transport: normalizedNetwork(p.Params),
		Security:  valueOrDefault(p.Params["security"], "none"),
	}
	if !private {
		info.Server = p.Server
	}
	return info
}

func profilesInfo(profiles []vlessProfile, private bool) []profileInfo {
	out := make([]profileInfo, 0, len(profiles))
	for i, profile := range profiles {
		out = append(out, profile.Info(i+1, private))
	}
	return out
}

func promptChoice(count int) (int, error) {
	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Fprintf(os.Stderr, "Choose profile number [1-%d]: ", count)
		line, err := reader.ReadString('\n')
		if err != nil && !errors.Is(err, io.EOF) {
			return 0, err
		}
		line = strings.TrimSpace(line)
		choice, err := strconv.Atoi(line)
		if err == nil && choice >= 1 && choice <= count {
			return choice - 1, nil
		}
		fmt.Fprintln(os.Stderr, "Invalid choice.")
	}
}

func buildXrayConfig(profile vlessProfile, opts cliOptions) (map[string]interface{}, error) {
	network := normalizedNetwork(profile.Params)
	security := valueOrDefault(profile.Params["security"], "none")
	encryption := valueOrDefault(profile.Params["encryption"], "none")

	user := map[string]interface{}{
		"id":         profile.UUID,
		"encryption": encryption,
	}
	if flow := profile.Params["flow"]; flow != "" {
		user["flow"] = flow
	}

	stream := map[string]interface{}{
		"network":  network,
		"security": security,
	}

	switch security {
	case "tls":
		settings := map[string]interface{}{
			"serverName":    valueOrDefault(profile.Params["sni"], profile.Server),
			"allowInsecure": truthy(profile.Params["allowInsecure"]),
		}
		if alpn := splitCSV(profile.Params["alpn"]); len(alpn) > 0 {
			settings["alpn"] = alpn
		}
		stream["tlsSettings"] = settings
	case "reality":
		pbk := profile.Params["pbk"]
		if pbk == "" {
			return nil, errors.New("REALITY profile requires pbk parameter")
		}
		stream["realitySettings"] = map[string]interface{}{
			"serverName":  valueOrDefault(profile.Params["sni"], profile.Server),
			"fingerprint": valueOrDefault(profile.Params["fp"], "chrome"),
			"publicKey":   pbk,
			"shortId":     profile.Params["sid"],
			"spiderX":     valueOrDefault(profile.Params["spx"], "/"),
		}
	case "none", "":
		stream["security"] = "none"
	}

	switch network {
	case "ws":
		headers := map[string]string{}
		if host := profile.Params["host"]; host != "" {
			headers["Host"] = host
		}
		stream["wsSettings"] = map[string]interface{}{
			"path":    valueOrDefault(profile.Params["path"], "/"),
			"headers": headers,
		}
	case "grpc":
		stream["grpcSettings"] = map[string]interface{}{
			"serviceName": profile.Params["serviceName"],
			"multiMode":   profile.Params["mode"] == "multi",
		}
	case "tcp":
		if headerType := profile.Params["headerType"]; headerType != "" && headerType != "none" {
			stream["tcpSettings"] = map[string]interface{}{
				"header": map[string]string{"type": headerType},
			}
		}
	case "httpupgrade":
		stream["httpupgradeSettings"] = map[string]interface{}{
			"path": valueOrDefault(profile.Params["path"], "/"),
			"host": valueOrDefault(profile.Params["host"], profile.Server),
		}
	case "xhttp":
		settings, err := buildXHTTPSettings(profile)
		if err != nil {
			return nil, err
		}
		stream["xhttpSettings"] = settings
	}

	return map[string]interface{}{
		"log": map[string]string{"loglevel": "warning"},
		"inbounds": []interface{}{
			map[string]interface{}{
				"tag":      "socks-in",
				"listen":   opts.listenHost,
				"port":     opts.listenPort,
				"protocol": "socks",
				"settings": map[string]interface{}{"auth": "noauth", "udp": true},
				"sniffing": map[string]interface{}{"enabled": true, "destOverride": []string{"http", "tls", "quic"}},
			},
		},
		"outbounds": []interface{}{
			map[string]interface{}{
				"tag":      opts.profileName,
				"protocol": "vless",
				"settings": map[string]interface{}{
					"vnext": []interface{}{
						map[string]interface{}{
							"address": profile.Server,
							"port":    profile.Port,
							"users":   []interface{}{user},
						},
					},
				},
				"streamSettings": stream,
			},
			map[string]string{"tag": "direct", "protocol": "freedom"},
			map[string]string{"tag": "block", "protocol": "blackhole"},
		},
	}, nil
}

func buildXHTTPSettings(profile vlessProfile) (map[string]interface{}, error) {
	settings := map[string]interface{}{
		"path": valueOrDefault(profile.Params["path"], "/"),
		"mode": valueOrDefault(profile.Params["mode"], "auto"),
	}

	if host := profile.Params["host"]; host != "" {
		settings["host"] = host
	}

	if extraRaw := strings.TrimSpace(profile.Params["extra"]); extraRaw != "" {
		var extra interface{}
		if err := json.Unmarshal([]byte(extraRaw), &extra); err != nil {
			return nil, fmt.Errorf("invalid xhttp extra JSON: %w", err)
		}
		settings["extra"] = extra
	}

	return settings, nil
}

func writeJSON(path string, value interface{}) error {
	if err := os.MkdirAll(parentDir(path), 0755); err != nil {
		return err
	}
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()

	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func parentDir(path string) string {
	idx := strings.LastIndex(path, "/")
	if idx <= 0 {
		return "."
	}
	return path[:idx]
}

func normalizedNetwork(params map[string]string) string {
	network := valueOrDefault(params["type"], "tcp")
	switch strings.ToLower(network) {
	case "splithttp":
		return "xhttp"
	default:
		return network
	}
}

func valueOrDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func truthy(value string) bool {
	switch strings.ToLower(value) {
	case "1", "true", "yes", "y", "on":
		return true
	default:
		return false
	}
}

func splitCSV(value string) []string {
	if value == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	sort.Strings(out)
	return out
}
