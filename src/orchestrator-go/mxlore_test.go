package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pquerna/otp/totp"
)

// fakeWhoami serves /api/whoami: key "dev7" -> developer 7, "dev9" -> 9, else 401.
func fakeWhoami(t *testing.T) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/whoami" || r.Method != http.MethodGet {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.Header.Get("Authorization") {
		case "Bearer dev7":
			w.Write([]byte(`{"developer_id":7,"name":"Alice","role":"admin"}`))
		case "Bearer dev9":
			w.Write([]byte(`{"developer_id":9,"name":"Bob","role":"developer"}`))
		case "Bearer redirect":
			http.Redirect(w, r, "http://example.invalid/", http.StatusFound)
		default:
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`{"error":"unauthorized"}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

const testSecret = "JBSWY3DPEHPK3PXP"

// newTestAuth returns an auth whose store points at mxURL; bound > 0 binds
// that developer (with 2FA on, as required once bound), else setup mode.
func newTestAuth(t *testing.T, mxURL string, bound int) (*Auth, *Store) {
	dir := t.TempDir()
	store, err := LoadStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Update(func(c *Config) error {
		c.MxLoreURL = mxURL
		if bound > 0 {
			c.MxLoreDeveloperID, c.MxLoreDeveloperName, c.TOTPSecret = bound, "Alice", testSecret
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	a, err := NewAuth(store, dir)
	if err != nil {
		t.Fatal(err)
	}
	a.proxyKey = func() string { return "" }
	if bound == 0 {
		a.enterSetupMode()
	}
	return a, store
}

// nextCode returns a TOTP code for the step after the last accepted one.
func nextCode(t *testing.T, a *Auth, secret string) string {
	a.mu.Lock()
	step := a.lastTOTPStep
	a.mu.Unlock()
	now := time.Now().Unix() / totpPeriod
	if step >= now-1 {
		now = step + 1
	} else {
		now = now - 1
	}
	if now > time.Now().Unix()/totpPeriod+1 {
		t.Fatal("no fresh TOTP step left")
	}
	c, err := totp.GenerateCode(secret, time.Unix(now*totpPeriod, 0))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestMxLoreLoginBoundRejectsOthers(t *testing.T) {
	srv := fakeWhoami(t)
	a, _ := newTestAuth(t, srv.URL, 7)
	if _, code := a.Login("wrong", "", ""); code != "invalid_key" {
		t.Fatalf("wrong key: got %q", code)
	}
	if _, code := a.Login("dev7", "", ""); code != "totp_required" {
		t.Fatalf("no totp: got %q", code)
	}
	tok, code := a.Login("dev7", nextCode(t, a, testSecret), "")
	if code != "" {
		t.Fatalf("dev7: got %q", code)
	}
	e := a.sessions[tokenHash(tok)]
	if e.Kind != "mxlore" || e.DeveloperID != 7 || e.DeveloperName != "Alice" {
		t.Fatalf("session entry = %+v", e)
	}
	if e.ExpiresAt.Sub(e.CreatedAt) > a.store.SessionTTL() {
		t.Fatalf("mxlore session expiry exceeds cap: %v", e.ExpiresAt.Sub(e.CreatedAt))
	}
	if _, code := a.Login("dev9", "", ""); code != "key_wrong_account" {
		t.Fatalf("other developer: got %q", code)
	}
	if _, code := a.Login("redirect", "", ""); code != "mxlore_unreachable" {
		t.Fatalf("redirect: got %q", code)
	}
}

func TestLocalKeyGone(t *testing.T) {
	a, store := newTestAuth(t, "", 0)
	store.Update(func(c *Config) error { c.KeyHash = "pbkdf2-sha256$1$AAAA$AAAA"; return nil })
	if _, code := a.Login("local-key", "", ""); code != "mxlore_not_configured" {
		t.Fatalf("got %q", code)
	}
}

func TestMxLoreUnreachable(t *testing.T) {
	srv := fakeWhoami(t)
	url := srv.URL
	srv.Close()
	a, _ := newTestAuth(t, url, 7)
	if _, code := a.Login("dev7", "", ""); code != "mxlore_unreachable" {
		t.Fatalf("got %q", code)
	}
}

func TestSetupModeLoginNeedsSetupCode(t *testing.T) {
	srv := fakeWhoami(t)
	a, store := newTestAuth(t, srv.URL, 0)
	raw, err := os.ReadFile(a.SetupCodePath())
	if err != nil {
		t.Fatal(err)
	}
	setupCode := strings.TrimSpace(string(raw))
	if _, code := a.Login("dev7", "", ""); code != "setup_code_required" {
		t.Fatalf("no setup code: got %q", code)
	}
	if _, code := a.Login("dev7", "", "AAAA-AAAA-AAAA"); code != "invalid_setup_code" {
		t.Fatalf("wrong setup code: got %q", code)
	}
	if _, code := a.Login("wrong", "", setupCode); code != "invalid_key" {
		t.Fatalf("wrong key: got %q", code)
	}
	tok, code := a.Login("dev7", "", strings.ToLower(strings.ReplaceAll(setupCode, "-", "")))
	if code != "" {
		t.Fatalf("login: got %q", code)
	}
	var bound int
	store.View(func(c *Config) { bound = c.MxLoreDeveloperID })
	if bound != 7 {
		t.Fatalf("binding = %d, want 7", bound)
	}
	if _, err := os.Stat(a.SetupCodePath()); !os.IsNotExist(err) {
		t.Fatalf("setup code file kept: %v", err)
	}
	if a.checkSetupCode(setupCode) {
		t.Fatal("setup code still valid after binding")
	}
	s := &Server{store: store, auth: a}
	if !s.mustEnroll(*a.sessions[tokenHash(tok)]) {
		t.Fatal("first login not flagged for 2FA enrollment")
	}
	if _, code := a.Login("dev9", "", setupCode); code != "key_wrong_account" {
		t.Fatalf("second developer: got %q", code)
	}
}

func TestRecoveryKeyOnlyInProcess(t *testing.T) {
	a, store := newTestAuth(t, "", 7)
	a.SetRecoveryKey("rec-key")
	tok, code := a.Login("rec-key", "", "")
	if code != "" || a.sessions[tokenHash(tok)].Kind != "recovery" {
		t.Fatalf("recovery login: %q", code)
	}
	if _, code := a.Login("rec-key2", "", ""); code == "" {
		t.Fatal("other key accepted")
	}
	// A new process (new Auth on the same data) does not know the key.
	b, err := NewAuth(store, a.dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, code := b.Login("rec-key", "", ""); code == "" {
		t.Fatal("recovery key survived a restart")
	}
	if _, ok := b.sessions[tokenHash(tok)]; !ok {
		t.Fatal("recovery session not persisted")
	}
}

func TestSlideExpiryCap(t *testing.T) {
	now := time.Now()
	e := &sessionEntry{MaxExpiresAt: now.Add(time.Hour)}
	if got := e.slideExpiry(now, 7*24*time.Hour); !got.Equal(e.MaxExpiresAt) {
		t.Fatalf("not capped: %v", got)
	}
	e = &sessionEntry{}
	if got := e.slideExpiry(now, time.Hour); !got.Equal(now.Add(time.Hour)) {
		t.Fatalf("uncapped wrong: %v", got)
	}
}

func TestValidateMxLoreURL(t *testing.T) {
	for _, ok := range []string{"http://127.0.0.1:8080", "http://localhost:8080/", "http://[::1]:8080", "https://lore.example.com/"} {
		if _, err := validateMxLoreURL(ok); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	for _, bad := range []string{"ftp://x", "127.0.0.1:8080", "http://u:p@x", "http://x/?a=1", "", "http://lore.example.com", "http://10.0.0.1:8080", "http://localhost.evil.com"} {
		if _, err := validateMxLoreURL(bad); err == nil {
			t.Errorf("%s accepted", bad)
		}
	}
}

func TestProxyKeyAutoLogin(t *testing.T) {
	srv := fakeWhoami(t)
	a, _ := newTestAuth(t, srv.URL, 7)
	var logs []string
	a.logf = func(f string, v ...any) { logs = append(logs, fmt.Sprintf(f, v...)) }
	// No proxy key: an empty key is invalid.
	if _, code := a.Login("", "", ""); code != "invalid_key" {
		t.Fatalf("no proxy key: got %q", code)
	}
	a.proxyKey = func() string { return "dev7" }
	if _, code := a.Login("", "", ""); code != "totp_required" {
		t.Fatalf("proxy key, no totp: got %q", code)
	}
	if _, code := a.Login("", nextCode(t, a, testSecret), ""); code != "" {
		t.Fatalf("proxy key + totp: got %q", code)
	}
	a.proxyKey = func() string { return "dev9" }
	if _, code := a.Login("", nextCode(t, a, testSecret), ""); code != "key_wrong_account" {
		t.Fatalf("foreign proxy key: got %q", code)
	}
	all := strings.Join(logs, " | ")
	for _, w := range []string{"empty key", "bound=7 got=9", hostOf(srv.URL)} {
		if !strings.Contains(all, w) {
			t.Fatalf("log lacks %q: %s", w, all)
		}
	}
	if strings.Contains(all, "dev7") || strings.Contains(all, "dev9") {
		t.Fatalf("log leaks a key: %s", all)
	}
}

func TestProxyKeyNotUsedWithoutTOTPOrInSetupMode(t *testing.T) {
	srv := fakeWhoami(t)
	a, store := newTestAuth(t, srv.URL, 7)
	a.proxyKey = func() string { return "dev7" }
	store.Update(func(c *Config) error { c.TOTPSecret = ""; return nil })
	if _, code := a.Login("", "", ""); code != "invalid_key" {
		t.Fatalf("no totp configured: got %q", code)
	}
	b, _ := newTestAuth(t, srv.URL, 0)
	b.proxyKey = func() string { return "dev7" }
	if _, code := b.Login("", "", ""); code != "invalid_key" {
		t.Fatalf("setup mode: got %q", code)
	}
}

func TestParseProxyKey(t *testing.T) {
	p := filepath.Join(t.TempDir(), "p.ini")
	os.WriteFile(p, []byte("[Other]\nApiKey=no\n[Server]\nUrl=http://x\nApiKey = abc123 \n"), 0o600)
	if got := parseProxyKey(p); got != "abc123" {
		t.Fatalf("got %q", got)
	}
	if parseProxyKey(p+".missing") != "" {
		t.Fatal("missing file")
	}
}

func TestWhoamiSendsDeviceID(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LOCALAPPDATA", dir)
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv("HOME", dir)
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get("X-Device-Id")
		w.Write([]byte(`{"developer_id":7,"name":"A","role":"x"}`))
	}))
	defer srv.Close()
	mxLoreWhoami(srv.URL, "k")
	if got != "" {
		t.Fatalf("header without file: %q", got)
	}
	p := deviceIDPath()
	os.MkdirAll(filepath.Dir(p), 0o700)
	os.WriteFile(p, []byte("0a1b2c3d-1111-4222-8333-444455556666\n"), 0o600)
	mxLoreWhoami(srv.URL, "k")
	if got != "0a1b2c3d-1111-4222-8333-444455556666" {
		t.Fatalf("header = %q", got)
	}
}
