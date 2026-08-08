package awgconfig

import (
	"bufio"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

const maxNativeConfigSize = 256 << 10

var ErrInvalidNativeConfig = errors.New("invalid AmneziaWG native config")

type NativeProfile struct {
	AWGVersion   string
	EndpointHost string
	EndpointPort uint16
	Addresses    []string
	AllowedIPs   []string
	DNS          []string
	MTU          int
}

var awgKeys = map[string]struct{}{
	"jc": {}, "jmin": {}, "jmax": {},
	"s1": {}, "s2": {}, "s3": {}, "s4": {},
	"h1": {}, "h2": {}, "h3": {}, "h4": {},
	"i1": {}, "i2": {}, "i3": {}, "i4": {}, "i5": {},
	"headerprotectionkey": {}, "contentpaddingaddition": {},
	"rekeyaftertime": {}, "rekeytimeout": {}, "rejectaftertime": {},
	"keepalivetimeout": {}, "maxhandshakeattempts": {},
}

func ParseNativeConfig(raw string) (NativeProfile, error) {
	if strings.TrimSpace(raw) == "" || len(raw) > maxNativeConfigSize {
		return NativeProfile{}, fmt.Errorf("%w: empty or oversized input", ErrInvalidNativeConfig)
	}
	sections, err := parseINI(raw)
	if err != nil {
		return NativeProfile{}, err
	}
	iface := sections["interface"]
	peer := sections["peer"]
	if iface == nil || peer == nil {
		return NativeProfile{}, fmt.Errorf("%w: exactly one Interface and one Peer section are required", ErrInvalidNativeConfig)
	}
	if err := validateKey(iface["privatekey"]); err != nil {
		return NativeProfile{}, fmt.Errorf("%w: invalid Interface private key", ErrInvalidNativeConfig)
	}
	if err := validateKey(peer["publickey"]); err != nil {
		return NativeProfile{}, fmt.Errorf("%w: invalid Peer public key", ErrInvalidNativeConfig)
	}
	if psk := peer["presharedkey"]; psk != "" {
		if err := validateKey(psk); err != nil {
			return NativeProfile{}, fmt.Errorf("%w: invalid Peer preshared key", ErrInvalidNativeConfig)
		}
	}

	addresses, err := parsePrefixes(iface["address"], true)
	if err != nil {
		return NativeProfile{}, fmt.Errorf("%w: invalid Interface address", ErrInvalidNativeConfig)
	}
	allowed, err := parsePrefixes(peer["allowedips"], true)
	if err != nil {
		return NativeProfile{}, fmt.Errorf("%w: invalid Peer allowed IPs", ErrInvalidNativeConfig)
	}
	dns, err := parseAddresses(iface["dns"])
	if err != nil {
		return NativeProfile{}, fmt.Errorf("%w: invalid Interface DNS", ErrInvalidNativeConfig)
	}

	host, portText, err := net.SplitHostPort(strings.TrimSpace(peer["endpoint"]))
	if err != nil || !validEndpointHost(host) {
		return NativeProfile{}, fmt.Errorf("%w: invalid Peer endpoint", ErrInvalidNativeConfig)
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 {
		return NativeProfile{}, fmt.Errorf("%w: invalid Peer endpoint port", ErrInvalidNativeConfig)
	}

	mtu := 0
	if value := strings.TrimSpace(iface["mtu"]); value != "" {
		mtu, err = strconv.Atoi(value)
		if err != nil || mtu < 576 || mtu > 65535 {
			return NativeProfile{}, fmt.Errorf("%w: invalid Interface MTU", ErrInvalidNativeConfig)
		}
	}
	version := inferAWGVersion(iface, peer)
	if version == "" {
		return NativeProfile{}, fmt.Errorf("%w: no AmneziaWG parameters found", ErrInvalidNativeConfig)
	}

	return NativeProfile{
		AWGVersion:   version,
		EndpointHost: host,
		EndpointPort: uint16(port),
		Addresses:    addresses,
		AllowedIPs:   allowed,
		DNS:          dns,
		MTU:          mtu,
	}, nil
}

func parseINI(raw string) (map[string]map[string]string, error) {
	sections := make(map[string]map[string]string)
	var current map[string]string
	scanner := bufio.NewScanner(strings.NewReader(raw))
	scanner.Buffer(make([]byte, 4096), maxNativeConfigSize)
	for lineNo := 1; scanner.Scan(); lineNo++ {
		line := strings.TrimSpace(strings.TrimSuffix(scanner.Text(), "\r"))
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			name := strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			if name != "interface" && name != "peer" {
				return nil, fmt.Errorf("%w: unsupported section on line %d", ErrInvalidNativeConfig, lineNo)
			}
			if _, exists := sections[name]; exists {
				return nil, fmt.Errorf("%w: duplicate section on line %d", ErrInvalidNativeConfig, lineNo)
			}
			current = make(map[string]string)
			sections[name] = current
			continue
		}
		if current == nil {
			return nil, fmt.Errorf("%w: value outside a section on line %d", ErrInvalidNativeConfig, lineNo)
		}
		key, value, ok := strings.Cut(line, "=")
		key = strings.ToLower(strings.TrimSpace(key))
		value = stripInlineComment(strings.TrimSpace(value))
		if !ok || key == "" || value == "" {
			return nil, fmt.Errorf("%w: malformed value on line %d", ErrInvalidNativeConfig, lineNo)
		}
		if _, exists := current[key]; exists {
			return nil, fmt.Errorf("%w: duplicate key on line %d", ErrInvalidNativeConfig, lineNo)
		}
		current[key] = value
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("%w: cannot read config", ErrInvalidNativeConfig)
	}
	return sections, nil
}

func stripInlineComment(value string) string {
	for _, marker := range []string{" #", " ;"} {
		if index := strings.Index(value, marker); index >= 0 {
			value = value[:index]
		}
	}
	return strings.TrimSpace(value)
}

func validateKey(value string) error {
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value, " \t\r\n") {
		return errors.New("missing key")
	}
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		decoded, err = base64.RawStdEncoding.DecodeString(value)
	}
	if err != nil || len(decoded) != 32 {
		return errors.New("key must encode 32 bytes")
	}
	return nil
}

func parsePrefixes(value string, required bool) ([]string, error) {
	parts := splitList(value)
	if required && len(parts) == 0 {
		return nil, errors.New("missing prefixes")
	}
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		prefix, err := netip.ParsePrefix(part)
		if err != nil {
			return nil, err
		}
		result = append(result, prefix.String())
	}
	return result, nil
}

func parseAddresses(value string) ([]string, error) {
	parts := splitList(value)
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		address, err := netip.ParseAddr(part)
		if err != nil {
			return nil, err
		}
		result = append(result, address.String())
	}
	return result, nil
}

func splitList(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if part = strings.TrimSpace(part); part != "" {
			result = append(result, part)
		}
	}
	return result
}

func validEndpointHost(host string) bool {
	host = strings.TrimSuffix(strings.TrimSpace(host), ".")
	if host == "" || len(host) > 253 || strings.ContainsAny(host, " \t\r\n/\\@") {
		return false
	}
	if _, err := netip.ParseAddr(host); err == nil {
		return true
	}
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 || !isHostAlphaNumeric(label[0]) || !isHostAlphaNumeric(label[len(label)-1]) {
			return false
		}
		for index := 1; index < len(label)-1; index++ {
			character := label[index]
			if !isHostAlphaNumeric(character) && character != '-' && character != '_' {
				return false
			}
		}
	}
	return true
}

func isHostAlphaNumeric(character byte) bool {
	return character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9'
}

func inferAWGVersion(sections ...map[string]string) string {
	values := make(map[string]string)
	for _, section := range sections {
		for key, value := range section {
			if _, ok := awgKeys[key]; ok {
				values[key] = value
			}
		}
	}
	if len(values) == 0 {
		return ""
	}
	for _, key := range []string{"headerprotectionkey", "contentpaddingaddition", "rekeyaftertime", "rekeytimeout", "rejectaftertime", "keepalivetimeout", "maxhandshakeattempts"} {
		if values[key] != "" {
			return "3"
		}
	}
	if values["s3"] != "" || values["s4"] != "" || strings.Contains(values["h1"], "-") || strings.Contains(values["h2"], "-") || strings.Contains(values["h3"], "-") || strings.Contains(values["h4"], "-") {
		return "2"
	}
	for _, key := range []string{"i1", "i2", "i3", "i4", "i5"} {
		if values[key] != "" {
			return "1.5"
		}
	}
	return "1"
}
