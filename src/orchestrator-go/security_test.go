package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// newTestServer returns a server plus an admin session opened with the
// recovery key (not subject to the 2FA enrollment gate).
func newTestServer(t *testing.T, mxURL string, bound int) (*Server, *Store, string) {
	a, store := newTestAuth(t, mxURL, bound)
	a.SetRecoveryKey("rec-key")
	tok, code := a.Login("rec-key", "", "")
	if code != "" {
		t.Fatal(code)
	}
	return &Server{store: store, auth: a, guard: NewHostGuard("127.0.0.1:8443")}, store, tok
}

func call(t *testing.T, h http.HandlerFunc, tok, body string) (int, map[string]any) {
	t.Helper()
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
	r.RemoteAddr = "127.0.0.1:5000"
	if tok != "" {
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: tok})
	}
	w := httptest.NewRecorder()
	h(w, r)
	var m map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &m)
	return w.Code, m
}

// route sends a request through the full router including the HostGuard.
func route(t *testing.T, s *Server, method, path, tok, body string) (int, map[string]any) {
	t.Helper()
	r := httptest.NewRequest(method, "https://127.0.0.1:8443"+path, strings.NewReader(body))
	r.RemoteAddr = "127.0.0.1:5000"
	if method != http.MethodGet {
		r.Header.Set("Origin", "https://127.0.0.1:8443")
	}
	if tok != "" {
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: tok})
	}
	w := httptest.NewRecorder()
	s.Routes(http.NotFoundHandler()).ServeHTTP(w, r)
	var m map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &m)
	return w.Code, m
}

func readSetupCode(t *testing.T, a *Auth) string {
	t.Helper()
	b, err := os.ReadFile(a.SetupCodePath())
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

func TestSetupGetHasNoSecrets(t *testing.T) {
	s, _, _ := newTestServer(t, "http://127.0.0.1:8080", 0)
	code := readSetupCode(t, s.auth)
	st, m := route(t, s, "GET", "/api/setup", "", "")
	if st != 200 || m["setupMode"] != true || m["bound"] != nil || m["setupCodePath"] != s.auth.SetupCodePath() {
		t.Fatalf("setup: %d %v", st, m)
	}
	b, _ := json.Marshal(m)
	if strings.Contains(string(b), code) {
		t.Fatal("setup code leaked")
	}
}

func TestWrongSetupCodeRateLimited(t *testing.T) {
	srv := fakeWhoami(t)
	s, _, _ := newTestServer(t, srv.URL, 0)
	for i := 0; i < loginFailLimit; i++ {
		if st, m := route(t, s, "POST", "/api/login", "", `{"key":"dev7","setupCode":"AAAA-AAAA-AAAA"}`); st != 401 || m["error"] != "invalid_setup_code" {
			t.Fatalf("attempt %d: %d %v", i, st, m)
		}
	}
	good := readSetupCode(t, s.auth)
	if st, _ := route(t, s, "POST", "/api/login", "", `{"key":"dev7","setupCode":"`+good+`"}`); st != 429 {
		t.Fatalf("not rate limited: %d", st)
	}
	// Pre-login URL changes have a budget of their own, so failed sign-ins
	// do not block them (and vice versa).
	if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:9","setupCode":"`+good+`"}`); st != 200 {
		t.Fatalf("setup url: %d %v", st, m)
	}
}

func TestSetupURLFailuresDoNotBlockLogin(t *testing.T) {
	srv := fakeWhoami(t)
	s, _, _ := newTestServer(t, srv.URL, 0)
	for i := 0; i < loginFailLimit; i++ {
		if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:9","setupCode":"AAAA-AAAA-AAAA"}`); st != 403 || m["error"] != "invalid_setup_code" {
			t.Fatalf("attempt %d: %d %v", i, st, m)
		}
	}
	if st, _ := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:9","setupCode":"AAAA-AAAA-AAAA"}`); st != 429 {
		t.Fatalf("setup url not rate limited: %d", st)
	}
	if st, m := route(t, s, "POST", "/api/login", "", `{"key":"dev7","setupCode":"`+readSetupCode(t, s.auth)+`"}`); st != 200 {
		t.Fatalf("login blocked by setup url failures: %d %v", st, m)
	}
}

func TestSetupModeLoginViaHTTP(t *testing.T) {
	srv := fakeWhoami(t)
	s, _, _ := newTestServer(t, srv.URL, 0)
	if st, m := route(t, s, "POST", "/api/login", "", `{"key":"dev7"}`); st != 401 || m["error"] != "setup_code_required" {
		t.Fatalf("no setup code: %d %v", st, m)
	}
	r := httptest.NewRequest("POST", "https://127.0.0.1:8443/api/login", strings.NewReader(`{"key":"dev7","setupCode":"`+readSetupCode(t, s.auth)+`"}`))
	r.RemoteAddr = "127.0.0.1:5000"
	r.Header.Set("Origin", "https://127.0.0.1:8443")
	w := httptest.NewRecorder()
	s.Routes(http.NotFoundHandler()).ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("login: %d %s", w.Code, w.Body.String())
	}
	var tok string
	for _, c := range w.Result().Cookies() {
		if c.Name == sessionCookie {
			tok = c.Value
		}
	}
	if st, m := route(t, s, "GET", "/api/me", tok, ""); st != 200 || m["mustEnroll2FA"] != true || m["loginKind"] != "mxlore" {
		t.Fatalf("me: %d %v", st, m)
	}
}

func TestPreLoginURLSetupMode(t *testing.T) {
	s, store, _ := newTestServer(t, "", 0)
	code := readSetupCode(t, s.auth)
	if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:8080"}`); st != 403 || m["error"] != "setup_code_required" {
		t.Fatalf("no code: %d %v", st, m)
	}
	if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:8080","setupCode":"BBBB-BBBB-BBBB"}`); st != 403 || m["error"] != "invalid_setup_code" {
		t.Fatalf("wrong code: %d %v", st, m)
	}
	if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://lore.example.com","setupCode":"`+code+`"}`); st != 400 || m["error"] != "invalid_mxlore_url" {
		t.Fatalf("http remote: %d %v", st, m)
	}
	if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"https://lore.example.com/","setupCode":"`+code+`"}`); st != 200 {
		t.Fatalf("https remote: %d %v", st, m)
	}
	var u string
	store.View(func(c *Config) { u = c.MxLoreURL })
	if u != "https://lore.example.com" {
		t.Fatalf("stored %q", u)
	}
	// Without a matching Origin the HostGuard rejects it.
	r := httptest.NewRequest("POST", "https://127.0.0.1:8443/api/setup/mxlore-url", strings.NewReader(`{}`))
	w := httptest.NewRecorder()
	s.Routes(http.NotFoundHandler()).ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("no origin: %d", w.Code)
	}
}

func TestPreLoginURLBoundNeedsKeyAndTOTP(t *testing.T) {
	srv := fakeWhoami(t)
	s, store, rec := newTestServer(t, srv.URL, 7)
	mx, code := s.auth.Login("dev7", nextCode(t, s.auth, testSecret), "")
	if code != "" {
		t.Fatal(code)
	}
	if _, err := os.Stat(s.auth.SetupCodePath()); !os.IsNotExist(err) {
		t.Fatal("setup code file exists while bound")
	}
	if st, m := route(t, s, "GET", "/api/setup", "", ""); m["setupMode"] != false || m["setupCodePath"] != "" {
		t.Fatalf("setup get: %d %v", st, m)
	}
	if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:9","setupCode":"x"}`); st != 403 || m["error"] != "key_and_totp_required" {
		t.Fatalf("no totp: %d %v", st, m)
	}
	// A TOTP code alone is not enough.
	if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:9","totp":"`+nextCode(t, s.auth, testSecret)+`"}`); st != 403 || m["error"] != "key_and_totp_required" {
		t.Fatalf("totp only: %d %v", st, m)
	}
	// Wrong or foreign keys never reach the TOTP check (no global TOTP failures).
	for _, k := range []string{"wrong", "dev9"} {
		if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:9","key":"`+k+`","totp":"000000"}`); st != 403 || m["error"] != "invalid_key" {
			t.Fatalf("key %s: %d %v", k, st, m)
		}
	}
	s.auth.mu.Lock()
	nf := len(s.auth.totpFails)
	s.auth.mu.Unlock()
	if nf != 0 {
		t.Fatalf("totp failures counted without a valid key: %d", nf)
	}
	if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:9","key":"dev7","totp":"000000"}`); st != 403 || m["error"] != "invalid_totp" {
		t.Fatalf("bad totp: %d %v", st, m)
	}
	if st, m := route(t, s, "POST", "/api/setup/mxlore-url", "", `{"url":"http://127.0.0.1:9","key":"dev7","totp":"`+nextCode(t, s.auth, testSecret)+`"}`); st != 200 {
		t.Fatalf("change: %d %v", st, m)
	}
	var id int
	var u string
	store.View(func(c *Config) { id, u = c.MxLoreDeveloperID, c.MxLoreURL })
	if id != 0 || u != "http://127.0.0.1:9" {
		t.Fatalf("after change: %d %q", id, u)
	}
	if _, ok := s.auth.sessions[tokenHash(mx)]; ok {
		t.Fatal("mxlore session kept")
	}
	if _, ok := s.auth.sessions[tokenHash(rec)]; !ok {
		t.Fatal("recovery session dropped")
	}
	if readSetupCode(t, s.auth) == "" {
		t.Fatal("no setup code after unbinding")
	}
}

func TestEnrollGateBlocksTabAPIs(t *testing.T) {
	srv := fakeWhoami(t)
	s, store, _ := newTestServer(t, srv.URL, 0)
	tok, code := s.auth.Login("dev7", "", readSetupCode(t, s.auth))
	if code != "" {
		t.Fatal(code)
	}
	for _, p := range []string{"/api/tabs", "/api/projects", "/api/security", "/ws/tabs/x"} {
		if st, m := route(t, s, "GET", p, tok, ""); st != 403 || m["error"] != "enroll_2fa_required" {
			t.Fatalf("%s: %d %v", p, st, m)
		}
	}
	if st, m := route(t, s, "GET", "/api/me", tok, ""); st != 200 || m["authenticated"] != true {
		t.Fatalf("me: %d %v", st, m)
	}
	st, m := route(t, s, "POST", "/api/security/totp/start", tok, `{}`)
	secret, _ := m["secret"].(string)
	if st != 200 || secret == "" {
		t.Fatalf("start: %d %v", st, m)
	}
	if st, m := route(t, s, "POST", "/api/security/totp/confirm", tok, `{"code":"`+nextCode(t, s.auth, secret)+`"}`); st != 200 {
		t.Fatalf("confirm: %d %v", st, m)
	}
	if st, m := route(t, s, "GET", "/api/security", tok, ""); st != 200 {
		t.Fatalf("after enroll: %d %v", st, m)
	}
	// 2FA cannot be turned off while bound.
	if st, m := route(t, s, "POST", "/api/security/totp/disable", tok, `{"code":"`+nextCode(t, s.auth, secret)+`"}`); st != 409 || m["error"] != "totp_mandatory" {
		t.Fatalf("disable while bound: %d %v", st, m)
	}
	var on bool
	store.View(func(c *Config) { on = c.TOTPSecret != "" })
	if !on {
		t.Fatal("2FA off")
	}
	if st, _ := route(t, s, "POST", "/api/logout", tok, ``); st != 200 {
		t.Fatalf("logout: %d", st)
	}
}

func TestSecurityURLAndUnbind(t *testing.T) {
	srv := fakeWhoami(t)
	s, store, tok := newTestServer(t, srv.URL, 7)
	if st, m := call(t, s.handleSecurityURL, tok, `{"url":"http://lore.example.com"}`); st != 400 || m["error"] != "invalid_mxlore_url" {
		t.Fatalf("http remote: %d %v", st, m)
	}
	if st, _ := call(t, s.handleSecurityURL, tok, `{"url":"`+srv.URL+`/"}`); st != 200 {
		t.Fatalf("same url: %d", st)
	}
	if st, m := call(t, s.handleSecurityURL, tok, `{"url":"https://lore.example.com"}`); st != 403 || m["error"] != "totp_required" {
		t.Fatalf("change without code: %d %v", st, m)
	}
	if st, m := call(t, s.handleSecurityURL, tok, `{"url":"https://lore.example.com","totp":"`+nextCode(t, s.auth, testSecret)+`"}`); st != 200 {
		t.Fatalf("change: %d %v", st, m)
	}
	var id int
	store.View(func(c *Config) { id = c.MxLoreDeveloperID })
	if id != 0 || readSetupCode(t, s.auth) == "" {
		t.Fatalf("not back in setup mode: %d", id)
	}
	// Unbind from a bound state.
	store.Update(func(c *Config) error { c.MxLoreDeveloperID = 7; return nil })
	s.auth.leaveSetupMode()
	if st, m := call(t, s.handleSecurityUnbind, tok, `{}`); st != 403 || m["error"] != "totp_required" {
		t.Fatalf("unbind without code: %d %v", st, m)
	}
	if st, m := call(t, s.handleSecurityUnbind, tok, `{"totp":"`+nextCode(t, s.auth, testSecret)+`"}`); st != 200 {
		t.Fatalf("unbind: %d %v", st, m)
	}
	store.View(func(c *Config) { id = c.MxLoreDeveloperID })
	if id != 0 || readSetupCode(t, s.auth) == "" {
		t.Fatalf("unbind did not return to setup mode: %d", id)
	}
}

func TestSecurityTestEndpointRemoved(t *testing.T) {
	s, _, tok := newTestServer(t, "", 0)
	if st, _ := route(t, s, "POST", "/api/security/mxlore-test", tok, `{"key":"dev7"}`); st != 404 {
		t.Fatalf("mxlore-test still routed: %d", st)
	}
}

func TestLegacyLocalSessionDroppedOnLoad(t *testing.T) {
	dir := t.TempDir()
	exp := time.Now().Add(time.Hour)
	m := map[string]*sessionEntry{
		tokenHash("legacy"): {CreatedAt: time.Now(), LastSeen: time.Now(), ExpiresAt: exp},
		tokenHash("rec"):    {CreatedAt: time.Now(), LastSeen: time.Now(), ExpiresAt: exp, Kind: "recovery"},
	}
	if err := writeSessions(dir, m); err != nil {
		t.Fatal(err)
	}
	store, err := LoadStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	a, err := NewAuth(store, dir)
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{store: store, auth: a, guard: NewHostGuard("127.0.0.1:8443")}
	if st, m := route(t, s, "GET", "/api/projects", "legacy", ""); st != 401 {
		t.Fatalf("legacy session: %d %v", st, m)
	}
	if _, ok := a.sessions[tokenHash("rec")]; !ok {
		t.Fatal("recovery entry dropped")
	}
}

func TestInAppUnbindSignsOutCallerAndStaleSessions(t *testing.T) {
	srv := fakeWhoami(t)
	s, store, _ := newTestServer(t, srv.URL, 7)
	mx, code := s.auth.Login("dev7", nextCode(t, s.auth, testSecret), "")
	if code != "" {
		t.Fatal(code)
	}
	st, m := route(t, s, "POST", "/api/security/mxlore-unbind", mx, `{"totp":"`+nextCode(t, s.auth, testSecret)+`"}`)
	if st != 200 || m["signedOut"] != true {
		t.Fatalf("unbind: %d %v", st, m)
	}
	if st, _ := route(t, s, "GET", "/api/projects", mx, ""); st != 401 {
		t.Fatalf("caller session kept: %d", st)
	}
	// A session of a developer who is no longer bound is void.
	stale, code := s.auth.Login("dev7", nextCode(t, s.auth, testSecret), readSetupCode(t, s.auth))
	if code != "" {
		t.Fatal(code)
	}
	store.Update(func(c *Config) error { c.MxLoreDeveloperID, c.MxLoreDeveloperName = 9, "Bob"; return nil })
	if st, _ := route(t, s, "GET", "/api/projects", stale, ""); st != 401 {
		t.Fatalf("stale developer session accepted: %d", st)
	}
}

func TestUnbindConflict(t *testing.T) {
	s, _, _ := newTestServer(t, "", 0)
	if err := s.unbindDeveloper(7, false, ""); !errors.Is(err, errSecurityConflict) {
		t.Fatalf("expected conflict, got %v", err)
	}
}

func TestPrivateFileWrite(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.txt")
	for _, v := range []string{"one", "two"} {
		if err := writePrivateFile(p, []byte(v)); err != nil {
			t.Fatal(err)
		}
		if b, _ := os.ReadFile(p); string(b) != v {
			t.Fatalf("got %q", b)
		}
	}
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("temp file left behind")
	}
}

func TestTOTPEnrollWhileUnbound(t *testing.T) {
	s, store, tok := newTestServer(t, "", 0)
	other, _ := s.auth.Login("rec-key", "", "")
	if st, m := call(t, s.handleTOTPConfirm, tok, `{"code":"123456"}`); st != 409 || m["error"] != "totp_not_started" {
		t.Fatalf("confirm without start: %d %v", st, m)
	}
	st, m := call(t, s.handleTOTPStart, tok, `{}`)
	secret, _ := m["secret"].(string)
	if st != 200 || secret == "" || !strings.HasPrefix(m["qr"].(string), "data:image/png;base64,") {
		t.Fatalf("start: %d %v", st, m)
	}
	if st, m := call(t, s.handleTOTPConfirm, tok, `{"code":"000000"}`); st != 403 || m["error"] != "invalid_totp" {
		t.Fatalf("bad code: %d %v", st, m)
	}
	code := nextCode(t, s.auth, secret)
	if st, m := call(t, s.handleTOTPConfirm, tok, `{"code":"`+code+`"}`); st != 200 {
		t.Fatalf("confirm: %d %v", st, m)
	}
	if _, ok := s.auth.sessions[tokenHash(other)]; ok {
		t.Fatal("other session kept")
	}
	if st, m := call(t, s.handleTOTPDisable, tok, `{"code":"`+code+`"}`); st != 403 || m["error"] != "invalid_totp" {
		t.Fatalf("replayed code: %d %v", st, m)
	}
	if st, m := call(t, s.handleTOTPDisable, tok, `{"code":"`+nextCode(t, s.auth, secret)+`"}`); st != 200 {
		t.Fatalf("disable: %d %v", st, m)
	}
	var stored string
	store.View(func(c *Config) { stored = c.TOTPSecret })
	if stored != "" {
		t.Fatal("secret not removed")
	}
}

func TestHostGuardProxyHosts(t *testing.T) {
	g := NewHostGuard("127.0.0.1:8443", "Erp.Tailnet.ts.net.")
	for h, want := range map[string]bool{
		"erp.tailnet.ts.net": true, "erp.tailnet.ts.net:443": true, "127.0.0.1:8443": true,
		"erp.tailnet.ts.net:8443": false, "evil.ts.net": false, "127.0.0.1:9000": false,
	} {
		if got := g.hostOK(h); got != want {
			t.Errorf("hostOK(%q) = %v, want %v", h, got, want)
		}
	}
}
