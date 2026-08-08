package main

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const protocolDetectTimeout = 10 * time.Second

// serveControlServer keeps legacy http:// agents reachable during the TLS
// migration. New agents still receive an https:// URL and pin the certificate.
// Once every router reports HTTPS, ALLOW_LEGACY_HTTP=0 restores TLS-only mode.
func serveControlServer(cfg Config, handler http.Handler) error {
	if !cfg.AllowLegacyHTTP {
		return http.ListenAndServeTLS(cfg.Listen, cfg.CertFile, cfg.KeyFile, handler)
	}
	cert, err := tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
	if err != nil {
		return fmt.Errorf("load TLS key pair: %w", err)
	}
	base, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return err
	}
	mixed := newMixedProtocolListener(
		base,
		&tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		},
	)
	server := &http.Server{Handler: handler}
	return server.Serve(mixed)
}

// mixedProtocolListener detects a TLS ClientHello before handing the
// connection to net/http. TLS and plaintext HTTP can therefore share the
// legacy port without a reverse proxy or a second firewall rule.
type mixedProtocolListener struct {
	net.Listener
	tlsConfig *tls.Config
	startOnce sync.Once
	closeOnce sync.Once
	ready     chan protocolAcceptResult
	done      chan struct{}
}

type protocolAcceptResult struct {
	conn net.Conn
	err  error
}

func newMixedProtocolListener(base net.Listener, tlsConfig *tls.Config) *mixedProtocolListener {
	return &mixedProtocolListener{
		Listener:  base,
		tlsConfig: tlsConfig,
		ready:     make(chan protocolAcceptResult),
		done:      make(chan struct{}),
	}
}

func (l *mixedProtocolListener) Accept() (net.Conn, error) {
	l.startOnce.Do(func() { go l.acceptLoop() })
	select {
	case result := <-l.ready:
		return result.conn, result.err
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *mixedProtocolListener) acceptLoop() {
	for {
		conn, err := l.Listener.Accept()
		if err != nil {
			l.deliver(protocolAcceptResult{err: err})
			return
		}
		go l.classifyAndDeliver(conn)
	}
}

func (l *mixedProtocolListener) classifyAndDeliver(conn net.Conn) {
	classified, err := l.classify(conn)
	if err != nil {
		_ = conn.Close()
		return
	}
	if !l.deliver(protocolAcceptResult{conn: classified}) {
		_ = classified.Close()
	}
}

func (l *mixedProtocolListener) deliver(result protocolAcceptResult) bool {
	select {
	case l.ready <- result:
		return true
	case <-l.done:
		return false
	}
}

func (l *mixedProtocolListener) Close() error {
	l.closeOnce.Do(func() { close(l.done) })
	return l.Listener.Close()
}

func (l *mixedProtocolListener) classify(conn net.Conn) (net.Conn, error) {
	if err := conn.SetReadDeadline(time.Now().Add(protocolDetectTimeout)); err != nil {
		return nil, err
	}
	reader := bufio.NewReader(conn)
	first, err := reader.Peek(1)
	_ = conn.SetReadDeadline(time.Time{})
	if err != nil {
		return nil, err
	}
	buffered := &bufferedConn{Conn: conn, reader: reader}
	if first[0] == 0x16 { // TLS handshake record (ClientHello)
		return tls.Server(buffered, l.tlsConfig.Clone()), nil
	}
	return buffered, nil
}

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	return c.reader.Read(p)
}

func requestTransport(r *http.Request) string {
	if r != nil && r.TLS != nil {
		return "https"
	}
	return "http (legacy)"
}

func parseConfigBool(value string, fallback bool) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}
