package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

const localSocksProxy = "127.0.0.1:10808"

func downloadURLWithFallback(url string, maxBytes int64) ([]byte, string, error) {
	errors := []string{}

	if body, err := downloadURLHTTP(url, maxBytes); err == nil {
		return body, "go-http-direct", nil
	} else {
		errors = append(errors, "go-http-direct: "+err.Error())
	}

	if body, err := downloadURLCurl(url, "", maxBytes); err == nil {
		return body, "curl-direct", nil
	} else {
		errors = append(errors, "curl-direct: "+err.Error())
	}

	if body, err := downloadURLCurl(url, localSocksProxy, maxBytes); err == nil {
		return body, "curl-socks5h-"+localSocksProxy, nil
	} else {
		errors = append(errors, "curl-socks5h-"+localSocksProxy+": "+err.Error())
	}

	return nil, "", fmt.Errorf(strings.Join(errors, "; "))
}

func downloadURLHTTP(url string, maxBytes int64) ([]byte, error) {
	client := &http.Client{Timeout: 25 * time.Second}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Cache-Control", "no-cache")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %s", resp.Status)
	}

	return readLimited(resp.Body, maxBytes)
}

func downloadURLCurl(url, socksProxy string, maxBytes int64) ([]byte, error) {
	curl, err := findCurl()
	if err != nil {
		return nil, err
	}

	tmp, err := os.CreateTemp("/opt/tmp", "xray-go-agent-download-*.tmp")
	if err != nil {
		return nil, err
	}
	tmpPath := tmp.Name()
	_ = tmp.Close()
	defer os.Remove(tmpPath)

	args := []string{"-fsSL", "--connect-timeout", "10", "--max-time", "60", "-H", "Cache-Control: no-cache", "-o", tmpPath}
	if socksProxy != "" {
		args = append(args, "--socks5-hostname", socksProxy)
	}
	args = append(args, url)

	cmd := exec.Command(curl, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf(msg)
	}

	f, err := os.Open(tmpPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return readLimited(f, maxBytes)
}

func readLimited(r io.Reader, maxBytes int64) ([]byte, error) {
	if maxBytes <= 0 {
		maxBytes = 1024 * 1024
	}
	body, err := io.ReadAll(io.LimitReader(r, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > maxBytes {
		return nil, fmt.Errorf("download too large: >%d bytes", maxBytes)
	}
	return body, nil
}

func findCurl() (string, error) {
	for _, path := range []string{"/opt/bin/curl", "/usr/bin/curl", "/bin/curl"} {
		if exists(path) {
			return path, nil
		}
	}
	if path, err := exec.LookPath("curl"); err == nil {
		return path, nil
	}
	return "", fmt.Errorf("curl not found")
}
