package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

func TestOtpLabel(t *testing.T) {
	h, _ := os.Hostname()
	if h == "" {
		h = "localhost"
	}
	if got := otpLabel(""); got != "admin@"+h {
		t.Fatalf("empty name: %q", got)
	}
	if got := otpLabel("  "); got != "admin@"+h {
		t.Fatalf("blank name: %q", got)
	}
	if got := otpLabel("Alice"); got != "Alice@"+h {
		t.Fatalf("name: %q", got)
	}
}

func TestProxyModeEmptyTOTPDoesNotCallWhoami(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write([]byte(`{"developer_id":7,"name":"Alice"}`))
	}))
	defer srv.Close()
	a, _ := newTestAuth(t, srv.URL, 7)
	a.proxyKey = func() string { return "dev7" }
	if _, code := a.Login("", "", ""); code != "totp_required" {
		t.Fatalf("got %q", code)
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("whoami called %d times", n)
	}
}

func TestNonLoopbackEmptyKeyIsInvalid(t *testing.T) {
	srv := fakeWhoami(t)
	a, _ := newTestAuth(t, srv.URL, 7)
	a.proxyKey = func() string { return "dev7" }
	if _, code := a.LoginFrom("", nextCode(t, a, testSecret), "", false); code != "invalid_key" {
		t.Fatalf("got %q", code)
	}
	if _, code := a.LoginFrom("", nextCode(t, a, testSecret), "", true); code != "" {
		t.Fatalf("loopback: got %q", code)
	}
}

func TestSetupGetProxyKeyAvailable(t *testing.T) {
	get := func(s *Server, remote string) map[string]any {
		r := httptest.NewRequest(http.MethodGet, "/api/setup", nil)
		r.RemoteAddr = remote
		w := httptest.NewRecorder()
		s.handleSetupGet(w, r)
		var m map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &m); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(w.Body.String(), "secret-proxy-key") {
			t.Fatal("proxy key leaked")
		}
		return m
	}
	mk := func(bound int, key string) *Server {
		s, _, _ := newTestServer(t, "http://127.0.0.1:8080", bound)
		s.auth.proxyKey = func() string { return key }
		return s
	}
	const lo = "127.0.0.1:5000"
	if get(mk(0, "secret-proxy-key"), lo)["proxyKeyAvailable"] != false {
		t.Error("setup mode")
	}
	s := mk(7, "secret-proxy-key")
	s.store.Update(func(c *Config) error { c.TOTPSecret = ""; return nil })
	if get(s, lo)["proxyKeyAvailable"] != false {
		t.Error("no totp")
	}
	if get(mk(7, ""), lo)["proxyKeyAvailable"] != false {
		t.Error("no key")
	}
	s = mk(7, "secret-proxy-key")
	if get(s, "192.168.1.5:5000")["proxyKeyAvailable"] != false {
		t.Error("non-loopback")
	}
	if get(s, lo)["proxyKeyAvailable"] != true {
		t.Error("v4 loopback")
	}
	if get(s, "[::1]:5000")["proxyKeyAvailable"] != true {
		t.Error("v6 loopback")
	}
}
