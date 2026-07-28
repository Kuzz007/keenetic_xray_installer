package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func newAuthTestServer() *Server {
	return &Server{cfg: Config{Routers: map[string]*Router{
		"home":  {ID: "home", Token: "correct-token"},
		"dacha": {ID: "dacha", Token: "a-much-longer-token-value"},
	}}}
}

func authRequest(bearer string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/agent/poll", nil)
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	return r
}

func TestAuthRouterMatchesCorrectToken(t *testing.T) {
	s := newAuthTestServer()
	rt := s.authRouter(authRequest("correct-token"))
	if rt == nil || rt.ID != "home" {
		t.Fatalf("expected router 'home', got %+v", rt)
	}
}

func TestAuthRouterRejectsWrongToken(t *testing.T) {
	s := newAuthTestServer()
	if rt := s.authRouter(authRequest("wrong-token")); rt != nil {
		t.Fatalf("expected no match, got %+v", rt)
	}
}

func TestAuthRouterRejectsDifferentLengthToken(t *testing.T) {
	// crypto/subtle.ConstantTimeCompare returns 0 immediately on length
	// mismatch rather than panicking - confirm that still behaves as a
	// normal rejection here, since admin-entered tokens aren't a fixed
	// length like the auto-generated ones.
	s := newAuthTestServer()
	if rt := s.authRouter(authRequest("short")); rt != nil {
		t.Fatalf("expected no match for a shorter token, got %+v", rt)
	}
	if rt := s.authRouter(authRequest("correct-token-with-extra-suffix")); rt != nil {
		t.Fatalf("expected no match for a longer token, got %+v", rt)
	}
}

func TestAuthRouterRejectsEmptyAuthorizationHeader(t *testing.T) {
	s := newAuthTestServer()
	if rt := s.authRouter(authRequest("")); rt != nil {
		t.Fatalf("expected no match for missing Authorization header, got %+v", rt)
	}
}

func TestAuthRouterMatchesAmongMultipleRouters(t *testing.T) {
	s := newAuthTestServer()
	rt := s.authRouter(authRequest("a-much-longer-token-value"))
	if rt == nil || rt.ID != "dacha" {
		t.Fatalf("expected router 'dacha', got %+v", rt)
	}
}
