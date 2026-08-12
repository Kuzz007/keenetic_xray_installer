package awgconfig

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

// RenderSetConf returns a validated configuration suitable for `awg setconf`.
// Address, DNS and MTU belong to wg-quick-style interface management and are
// deliberately omitted because the router supervisor applies them itself.
// endpoint must already contain a numeric IP address so the statically linked
// AWG configurator never depends on target-libc hostname resolution.
func RenderSetConf(raw, endpoint string) (string, error) {
	profile, err := ParseNativeConfig(raw)
	if err != nil {
		return "", err
	}
	host, portText, err := net.SplitHostPort(strings.TrimSpace(endpoint))
	if err != nil || net.ParseIP(host) == nil {
		return "", fmt.Errorf("%w: runtime endpoint must use a numeric IP", ErrInvalidNativeConfig)
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 || uint16(port) != profile.EndpointPort {
		return "", fmt.Errorf("%w: runtime endpoint port does not match the profile", ErrInvalidNativeConfig)
	}

	var output strings.Builder
	section := ""
	for _, sourceLine := range strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n") {
		trimmed := strings.TrimSpace(sourceLine)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			section = strings.ToLower(strings.TrimSpace(trimmed[1 : len(trimmed)-1]))
			output.WriteString(sourceLine)
			output.WriteByte('\n')
			continue
		}
		key, _, hasValue := strings.Cut(trimmed, "=")
		key = strings.ToLower(strings.TrimSpace(key))
		if section == "interface" && hasValue && (key == "address" || key == "dns" || key == "mtu") {
			continue
		}
		if section == "peer" && hasValue && key == "endpoint" {
			output.WriteString("Endpoint = ")
			output.WriteString(endpoint)
			output.WriteByte('\n')
			continue
		}
		if trimmed == "" && output.Len() == 0 {
			continue
		}
		output.WriteString(sourceLine)
		output.WriteByte('\n')
	}
	return strings.TrimSpace(output.String()) + "\n", nil
}
