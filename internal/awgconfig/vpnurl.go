package awgconfig

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

const (
	maxEncodedSize = 2 << 20
	maxDecodedSize = 1 << 20
)

var (
	ErrPremiumConfig  = errors.New("Amnezia Premium/API vpn:// configs are not supported")
	ErrFullAccess     = errors.New("full-access vpn:// configs are not accepted; export a guest AmneziaWG connection")
	ErrNotSelfHosted  = errors.New("vpn:// config is not a self-hosted AmneziaWG guest connection")
	ErrInvalidVPNLink = errors.New("invalid vpn:// config")
)

// Profile is a validated self-hosted AmneziaWG guest profile. The original
// native config remains private so ordinary formatting and JSON encoding do
// not accidentally expose its WireGuard private key.
type Profile struct {
	Name         string   `json:"name"`
	HostName     string   `json:"host_name"`
	Container    string   `json:"container"`
	AWGVersion   string   `json:"awg_version"`
	EndpointHost string   `json:"endpoint_host"`
	EndpointPort uint16   `json:"endpoint_port"`
	Addresses    []string `json:"addresses"`
	AllowedIPs   []string `json:"allowed_ips"`
	DNS          []string `json:"dns,omitempty"`
	MTU          int      `json:"mtu,omitempty"`

	nativeConfig string
}

// NativeConfig returns the validated secret-bearing AmneziaWG configuration.
// Callers must store it with mode 0600 and must never include it in logs.
func (p Profile) NativeConfig() string {
	return p.nativeConfig
}

func (p Profile) String() string {
	return fmt.Sprintf("AmneziaWG %s %s:%d (%s)", p.AWGVersion, p.EndpointHost, p.EndpointPort, p.Container)
}

// GoString keeps %#v formatting redacted too.
func (p Profile) GoString() string {
	return p.String()
}

type vpnEnvelope struct {
	Description      string          `json:"description"`
	HostName         string          `json:"hostName"`
	DefaultContainer string          `json:"defaultContainer"`
	UserName         string          `json:"userName"`
	Password         string          `json:"password"`
	Port             json.RawMessage `json:"port"`
	APIConfig        json.RawMessage `json:"api_config"`
	ConfigVersion    json.RawMessage `json:"config_version"`
	Containers       []vpnContainer  `json:"containers"`
}

type vpnContainer struct {
	Container string          `json:"container"`
	AWG       json.RawMessage `json:"awg"`
}

type awgEnvelope struct {
	LastConfig      json.RawMessage `json:"last_config"`
	ProtocolVersion string          `json:"protocol_version"`
}

type awgClientConfig struct {
	Config string `json:"config"`
}

// ParseVPNURL decodes and validates a supported AmneziaWG guest vpn:// link.
// It deliberately rejects managed/Premium and full-access server envelopes.
// Direct native links contain no ownership metadata, so callers must limit
// those otherwise-valid guest client profiles to their self-hosted service.
func ParseVPNURL(raw string) (Profile, error) {
	payload, err := decodeVPNURL(raw)
	if err != nil {
		return Profile{}, err
	}
	if !json.Valid(payload) {
		return profileFromNativeVPNPayload(payload)
	}

	var envelope vpnEnvelope
	if err := json.Unmarshal(payload, &envelope); err != nil {
		return Profile{}, fmt.Errorf("%w: decoded payload is not valid JSON", ErrInvalidVPNLink)
	}
	if presentJSONValue(envelope.APIConfig) || presentJSONValue(envelope.ConfigVersion) {
		return Profile{}, ErrPremiumConfig
	}
	if strings.TrimSpace(envelope.UserName) != "" || strings.TrimSpace(envelope.Password) != "" || nonZeroJSONValue(envelope.Port) {
		return Profile{}, ErrFullAccess
	}
	if strings.TrimSpace(envelope.HostName) == "" || len(envelope.Containers) != 1 {
		return Profile{}, ErrNotSelfHosted
	}

	container := envelope.Containers[0]
	if container.Container != "amnezia-awg" && container.Container != "amnezia-awg2" {
		return Profile{}, ErrNotSelfHosted
	}
	if envelope.DefaultContainer != "" && envelope.DefaultContainer != container.Container {
		return Profile{}, ErrNotSelfHosted
	}

	var awg awgEnvelope
	if len(container.AWG) == 0 || json.Unmarshal(container.AWG, &awg) != nil {
		return Profile{}, fmt.Errorf("%w: missing AWG container data", ErrInvalidVPNLink)
	}
	clientJSON, err := decodeNestedJSON(awg.LastConfig)
	if err != nil {
		return Profile{}, err
	}
	var client awgClientConfig
	if err := json.Unmarshal(clientJSON, &client); err != nil || strings.TrimSpace(client.Config) == "" {
		return Profile{}, fmt.Errorf("%w: missing native AWG client config", ErrInvalidVPNLink)
	}

	native, err := ParseNativeConfig(client.Config)
	if err != nil {
		return Profile{}, fmt.Errorf("%w: %v", ErrInvalidVPNLink, err)
	}
	name := strings.TrimSpace(envelope.Description)
	if name == "" {
		name = strings.TrimSpace(envelope.HostName)
	}
	version := native.AWGVersion
	if version == "" {
		version = strings.TrimSpace(awg.ProtocolVersion)
	}

	return Profile{
		Name:         name,
		HostName:     strings.TrimSpace(envelope.HostName),
		Container:    container.Container,
		AWGVersion:   version,
		EndpointHost: native.EndpointHost,
		EndpointPort: native.EndpointPort,
		Addresses:    native.Addresses,
		AllowedIPs:   native.AllowedIPs,
		DNS:          native.DNS,
		MTU:          native.MTU,
		nativeConfig: strings.TrimSpace(client.Config) + "\n",
	}, nil
}

func profileFromNativeVPNPayload(payload []byte) (Profile, error) {
	raw := strings.TrimSpace(string(payload))
	native, err := ParseNativeConfig(raw)
	if err != nil {
		return Profile{}, fmt.Errorf("%w: %v", ErrInvalidVPNLink, err)
	}
	return Profile{
		Name:         "Native AWG guest",
		HostName:     native.EndpointHost,
		Container:    "amnezia-awg-native",
		AWGVersion:   native.AWGVersion,
		EndpointHost: native.EndpointHost,
		EndpointPort: native.EndpointPort,
		Addresses:    native.Addresses,
		AllowedIPs:   native.AllowedIPs,
		DNS:          native.DNS,
		MTU:          native.MTU,
		nativeConfig: raw + "\n",
	}, nil
}

func decodeVPNURL(raw string) ([]byte, error) {
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(raw, "vpn://") {
		return nil, fmt.Errorf("%w: expected vpn:// prefix", ErrInvalidVPNLink)
	}
	encoded := strings.TrimPrefix(raw, "vpn://")
	if encoded == "" || len(encoded) > maxEncodedSize || strings.ContainsAny(encoded, " \t\r\n") {
		return nil, fmt.Errorf("%w: invalid encoded payload", ErrInvalidVPNLink)
	}

	compressed, err := decodeVPNBase64(encoded)
	if err != nil {
		return nil, fmt.Errorf("%w: invalid base64 payload", ErrInvalidVPNLink)
	}
	if len(compressed) > maxDecodedSize && json.Valid(compressed) {
		return nil, fmt.Errorf("%w: decoded payload is too large", ErrInvalidVPNLink)
	}
	if json.Valid(compressed) {
		return compressed, nil
	}
	if looksLikeNativeConfig(compressed) {
		return compressed, nil
	}
	if len(compressed) < 6 {
		return nil, fmt.Errorf("%w: truncated Qt compressed payload", ErrInvalidVPNLink)
	}

	expected := uint64(binary.BigEndian.Uint32(compressed[:4]))
	if expected == 0 || expected > maxDecodedSize {
		return nil, fmt.Errorf("%w: decoded payload size is invalid", ErrInvalidVPNLink)
	}
	reader, err := zlib.NewReader(bytes.NewReader(compressed[4:]))
	if err != nil {
		return nil, fmt.Errorf("%w: invalid Qt compressed payload", ErrInvalidVPNLink)
	}
	decoded, readErr := io.ReadAll(io.LimitReader(reader, maxDecodedSize+1))
	closeErr := reader.Close()
	if readErr != nil || closeErr != nil || uint64(len(decoded)) != expected || len(decoded) > maxDecodedSize {
		return nil, fmt.Errorf("%w: decompressed payload size mismatch", ErrInvalidVPNLink)
	}
	if !json.Valid(decoded) {
		return nil, fmt.Errorf("%w: decoded payload is not valid JSON", ErrInvalidVPNLink)
	}
	return decoded, nil
}

func decodeVPNBase64(encoded string) ([]byte, error) {
	encoded = strings.TrimRight(encoded, "=")
	decoded, urlErr := base64.RawURLEncoding.DecodeString(encoded)
	if urlErr == nil {
		return decoded, nil
	}
	decoded, stdErr := base64.RawStdEncoding.DecodeString(encoded)
	if stdErr == nil {
		return decoded, nil
	}
	return nil, urlErr
}

func looksLikeNativeConfig(payload []byte) bool {
	trimmed := strings.TrimSpace(string(payload))
	if len(trimmed) == 0 || len(trimmed) > maxNativeConfigSize {
		return false
	}
	firstLine, _, _ := strings.Cut(trimmed, "\n")
	return strings.EqualFold(strings.TrimSpace(strings.TrimSuffix(firstLine, "\r")), "[Interface]")
}

func decodeNestedJSON(raw json.RawMessage) ([]byte, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("%w: missing AWG client data", ErrInvalidVPNLink)
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) > 0 && trimmed[0] == '{' {
		return trimmed, nil
	}
	var encoded string
	if err := json.Unmarshal(trimmed, &encoded); err != nil || !json.Valid([]byte(encoded)) {
		return nil, fmt.Errorf("%w: invalid AWG client data", ErrInvalidVPNLink)
	}
	return []byte(encoded), nil
}

func presentJSONValue(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	return len(trimmed) != 0 && !bytes.Equal(trimmed, []byte("null"))
}

func nonZeroJSONValue(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) || bytes.Equal(trimmed, []byte("0")) || bytes.Equal(trimmed, []byte(`""`)) || bytes.Equal(trimmed, []byte(`"0"`)) {
		return false
	}
	return true
}
