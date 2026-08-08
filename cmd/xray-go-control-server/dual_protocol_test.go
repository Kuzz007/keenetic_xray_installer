package main

import (
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"testing"
	"time"
)

func TestMixedProtocolListenerServesHTTPAndHTTPSOnSamePort(t *testing.T) {
	dir := t.TempDir()
	certFile := filepath.Join(dir, "server.crt")
	keyFile := filepath.Join(dir, "server.key")
	if _, err := ensureTLSCert(certFile, keyFile); err != nil {
		t.Fatal(err)
	}
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		t.Fatal(err)
	}
	base, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listener := newMixedProtocolListener(base, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, requestTransport(r))
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })

	// A health checker or port scanner can connect and close before sending a
	// protocol byte. That malformed connection must not stop the listener.
	empty, err := net.Dial("tcp", base.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = empty.Close()
	slow, err := net.Dial("tcp", base.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer slow.Close()

	client := &http.Client{Timeout: 3 * time.Second}
	assertTransportResponse(t, client, "http://"+base.Addr().String(), "http (legacy)")

	tlsClient := &http.Client{
		Timeout: 3 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true, // test-only self-signed certificate
			MinVersion:         tls.VersionTLS12,
		}},
	}
	assertTransportResponse(t, tlsClient, "https://"+base.Addr().String(), "https")
}

func assertTransportResponse(t *testing.T, client *http.Client, url, want string) {
	t.Helper()
	resp, err := client.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != want {
		t.Fatalf("transport response=%q want=%q", body, want)
	}
}
