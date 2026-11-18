package main

import (
	"net/http/httptest"
	"testing"
)

// The stored proxy key may stand in for a typed key only when the peer is this
// machine and no reverse proxy is configured.
func TestLocalClientOffBehindReverseProxy(t *testing.T) {
	local := httptest.NewRequest("POST", "/api/login", nil)
	local.RemoteAddr = "127.0.0.1:5555"
	remote := httptest.NewRequest("POST", "/api/login", nil)
	remote.RemoteAddr = "192.168.1.20:5555"

	direct := &Server{guard: NewHostGuard("127.0.0.1:8443")}
	proxied := &Server{guard: NewHostGuard("127.0.0.1:8443", "erp.tailnet.ts.net")}

	if !direct.localClient(local) {
		t.Error("direct loopback client must be local")
	}
	if direct.localClient(remote) {
		t.Error("remote peer must not be local")
	}
	if proxied.localClient(local) {
		t.Error("loopback peer behind a configured reverse proxy must not be local")
	}
}

func TestRecoverySessionHasAbsoluteCap(t *testing.T) {
	s, _, _ := newTestServer(t, "", 0)
	s.auth.SetRecoveryKey("rec-key")
	tok, code := s.auth.LoginFrom("rec-key", "", "", false)
	if code != "" {
		t.Fatal(code)
	}
	e := s.auth.sessions[tokenHash(tok)]
	if e == nil || e.Kind != "recovery" {
		t.Fatalf("no recovery session: %+v", e)
	}
	if e.MaxExpiresAt.IsZero() || e.ExpiresAt.After(e.MaxExpiresAt) {
		t.Fatalf("recovery session not capped: expires %v max %v", e.ExpiresAt, e.MaxExpiresAt)
	}
}
