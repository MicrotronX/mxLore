package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/pquerna/otp"
	"github.com/pquerna/otp/totp"
)

const (
	pbkdf2Iter     = 210000
	sessionCookie  = "mxo_session"
	loginFailLimit = 5
	loginWindow    = time.Minute
)

func randomToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// Auth holds in-memory sessions and the login rate limiter.
type Auth struct {
	store    *Store
	mu       sync.Mutex
	dir      string                   // data dir holding sessions.json ("" = memory only)
	sessions map[string]*sessionEntry // key: sha256(token) hex
	dirty    bool                     // unsaved lastSeen/expiry changes
	lastSave time.Time
	logf     func(string, ...any)
	fails    map[string][]time.Time
	// lastTOTPStep is the highest accepted TOTP time step; codes at or below it
	// are rejected so a captured code cannot be replayed.
	lastTOTPStep int64
	// totpFails counts global TOTP failures after a correct key (all IPs).
	totpFails []time.Time
	// loginSem caps concurrent PBKDF2 verifications.
	loginSem chan struct{}
	// pendingTOTP is a 2FA secret being enrolled from the browser; memory only.
	pendingTOTP    string
	pendingTOTPExp time.Time
	// recoveryKey is the one-time key from --recovery; memory only, "" = none.
	recoveryKey string
	// setupCode guards binding while no developer is bound; "" = not in setup mode.
	setupCode string
	// bindMu serialises binding changes together with the setup-code transition.
	bindMu sync.Mutex
}

const (
	totpFailLimit  = 10
	totpFailWindow = 15 * time.Minute
	totpPeriod     = 30
)

// NewAuth creates the authenticator and loads persisted sessions from dir.
func NewAuth(store *Store, dir string) (*Auth, error) {
	m, err := loadSessions(dir)
	if err != nil {
		return nil, err
	}
	return &Auth{store: store, dir: dir, sessions: m, fails: map[string][]time.Time{},
		loginSem: make(chan struct{}, 3), logf: func(string, ...any) {}}, nil
}

// saveLocked persists the sessions. Caller holds a.mu.
func (a *Auth) saveLocked() {
	if err := writeSessions(a.dir, a.sessions); err != nil {
		a.logf("sessions: save failed: %v", err)
		a.dirty = true
		return
	}
	a.dirty = false
	a.lastSave = time.Now()
}

// SessionCookie builds the cookie for tok, expiring with its session entry.
func (a *Auth) SessionCookie(tok string) *http.Cookie {
	exp := time.Now().Add(a.store.SessionTTL())
	a.mu.Lock()
	if e, ok := a.sessions[tokenHash(tok)]; ok {
		exp = e.ExpiresAt
	}
	a.mu.Unlock()
	return a.sessionCookieUntil(tok, exp)
}

// sessionCookieUntil builds the session cookie for tok expiring at exp.
func (a *Auth) sessionCookieUntil(tok string, exp time.Time) *http.Cookie {
	return &http.Cookie{Name: sessionCookie, Value: tok, Path: "/", HttpOnly: true, Secure: true,
		SameSite: http.SameSiteStrictMode, MaxAge: int(time.Until(exp).Round(time.Second) / time.Second), Expires: exp}
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// reserveAttempt atomically checks the per-ip failure budget and, if there is
// room, records an attempt up front (so parallel requests cannot all pass the
// check). It returns the reservation timestamp, or ok=false when rate limited.
func (a *Auth) reserveAttempt(ip string) (time.Time, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	cut := now.Add(-loginWindow)
	list := a.fails[ip][:0]
	for _, t := range a.fails[ip] {
		if t.After(cut) {
			list = append(list, t)
		}
	}
	if len(list) >= loginFailLimit {
		a.fails[ip] = list
		return time.Time{}, false
	}
	a.fails[ip] = append(list, now)
	return now, true
}

// releaseAttempt removes a reservation that did not turn out to be a failure.
func (a *Auth) releaseAttempt(ip string, at time.Time) {
	a.mu.Lock()
	defer a.mu.Unlock()
	l := a.fails[ip]
	for i, t := range l {
		if t.Equal(at) {
			a.fails[ip] = append(l[:i], l[i+1:]...)
			return
		}
	}
}

// totpLocked reports whether the global TOTP failure budget is exhausted. Caller holds a.mu.
func (a *Auth) totpLockedLocked(now time.Time) bool {
	cut := now.Add(-totpFailWindow)
	l := a.totpFails[:0]
	for _, t := range a.totpFails {
		if t.After(cut) {
			l = append(l, t)
		}
	}
	a.totpFails = l
	return len(l) >= totpFailLimit
}

// checkTOTP validates code with +-1 step skew and rejects replays of an
// already accepted (or older) time step.
func (a *Auth) checkTOTP(code, secret string) string {
	now := time.Now()
	a.mu.Lock()
	locked := a.totpLockedLocked(now)
	a.mu.Unlock()
	if locked {
		return "totp_locked"
	}
	step := now.Unix() / totpPeriod
	matched := int64(-1)
	for _, d := range []int64{-1, 0, 1} {
		c, err := totp.GenerateCodeCustom(secret, time.Unix((step+d)*totpPeriod, 0), totp.ValidateOpts{
			Period: totpPeriod, Digits: otp.DigitsSix, Algorithm: otp.AlgorithmSHA1})
		if err == nil && subtle.ConstantTimeCompare([]byte(c), []byte(code)) == 1 {
			matched = step + d
		}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if matched < 0 || matched <= a.lastTOTPStep {
		a.totpFails = append(a.totpFails, now)
		return "invalid_totp"
	}
	a.lastTOTPStep = matched
	return ""
}

// Login checks an mxLore key (or the in-memory recovery key) plus TOTP when
// enabled. The key is checked against mxLore's /api/whoami and must belong to
// the bound developer. While no developer is bound (setup mode) the setup code
// is required as well and the first successful login binds the developer.
// Returns a session token or an error code.
func (a *Auth) Login(key, code, setupCode string) (string, string) {
	a.loginSem <- struct{}{}
	defer func() { <-a.loginSem }()
	now := time.Now()
	if a.isRecoveryKey(key) {
		e := &sessionEntry{CreatedAt: now, LastSeen: now, Kind: "recovery"}
		e.ExpiresAt = e.slideExpiry(now, a.store.SessionTTL())
		a.logf("login: signed in with the recovery key")
		return a.addSession(e), ""
	}
	var secret, mxURL string
	var boundID int
	a.store.View(func(c *Config) {
		secret, mxURL, boundID = c.TOTPSecret, c.MxLoreURL, c.MxLoreDeveloperID
	})
	if mxURL == "" {
		return "", "mxlore_not_configured"
	}
	if strings.TrimSpace(key) == "" {
		return "", "invalid_key"
	}
	d, err := mxLoreWhoami(mxURL, key)
	switch {
	case errors.Is(err, errMxLoreUnreachable):
		return "", "mxlore_unreachable"
	case err != nil:
		return "", "invalid_key"
	case boundID != 0 && d.ID != boundID:
		return "", "invalid_key"
	}
	if boundID == 0 {
		if strings.TrimSpace(setupCode) == "" {
			return "", "setup_code_required"
		}
		if !a.checkSetupCode(setupCode) {
			return "", "invalid_setup_code"
		}
	}
	if secret != "" {
		if strings.TrimSpace(code) == "" {
			return "", "totp_required"
		}
		if r := a.checkTOTP(strings.TrimSpace(code), secret); r != "" {
			return "", r
		}
	}
	if r := a.bindDeveloper(&d); r != "" {
		return "", r
	}
	// Absolute cap = the configured session length, measured from login: the
	// session slides within it, and a key revoked in mxLore stops working here
	// no later than that.
	e := &sessionEntry{CreatedAt: now, LastSeen: now, Kind: "mxlore", DeveloperID: d.ID, DeveloperName: d.Name,
		MaxExpiresAt: now.Add(a.store.SessionTTL())}
	e.ExpiresAt = e.slideExpiry(now, a.store.SessionTTL())
	return a.addSession(e), ""
}

// addSession stores e under a fresh token and returns the token.
func (a *Auth) addSession(e *sessionEntry) string {
	tok := randomToken(32)
	a.mu.Lock()
	a.sessions[tokenHash(tok)] = e
	a.saveLocked()
	a.mu.Unlock()
	return tok
}

// bindDeveloper binds the orchestrator to dev on the first mxLore login and
// re-checks the binding under the store lock (a concurrent login may have won).
func (a *Auth) bindDeveloper(dev *mxLoreDeveloper) string {
	a.bindMu.Lock()
	defer a.bindMu.Unlock()
	bound := false
	err := a.store.Update(func(c *Config) error {
		if c.MxLoreDeveloperID == 0 {
			c.MxLoreDeveloperID = dev.ID
			c.MxLoreDeveloperName = dev.Name
			bound = true
			return nil
		}
		if c.MxLoreDeveloperID != dev.ID {
			return errMxLoreUnauthorized
		}
		c.MxLoreDeveloperName = dev.Name
		return nil
	})
	if errors.Is(err, errMxLoreUnauthorized) {
		return "invalid_key"
	}
	if err != nil {
		a.logf("mxlore: saving the developer binding failed: %v", err)
		return "save_failed"
	}
	if bound {
		a.leaveSetupMode()
		a.logf("mxlore: orchestrator bound to developer %d (%s)", dev.ID, dev.Name)
	}
	return ""
}

func (a *Auth) Logout(tok string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	h := tokenHash(tok)
	if _, ok := a.sessions[h]; ok {
		delete(a.sessions, h)
		a.saveLocked()
	}
}

// Valid reports whether r carries a live session. It slides the expiry
// (throttled to once per sessionTouchStep) and then refreshes the cookie on w.
func (a *Auth) Valid(w http.ResponseWriter, r *http.Request) bool {
	_, ok := a.Session(w, r)
	return ok
}

// Session is Valid that also returns a copy of the session entry.
func (a *Auth) Session(w http.ResponseWriter, r *http.Request) (sessionEntry, bool) {
	c, err := r.Cookie(sessionCookie)
	if err != nil || c.Value == "" {
		return sessionEntry{}, false
	}
	h := tokenHash(c.Value)
	now := time.Now()
	var boundID int
	a.store.View(func(cfg *Config) { boundID = cfg.MxLoreDeveloperID })
	a.mu.Lock()
	defer a.mu.Unlock()
	e, ok := a.sessions[h]
	if !ok {
		return sessionEntry{}, false
	}
	if e.Kind == "mxlore" && e.DeveloperID != boundID {
		// The developer is no longer the bound one: the session is void.
		delete(a.sessions, h)
		a.saveLocked()
		return sessionEntry{}, false
	}
	if now.After(e.ExpiresAt) {
		delete(a.sessions, h)
		a.saveLocked()
		return sessionEntry{}, false
	}
	if now.Sub(e.LastSeen) >= sessionTouchStep {
		e.LastSeen = now
		e.ExpiresAt = e.slideExpiry(now, a.store.SessionTTL())
		a.dirty = true
		if now.Sub(a.lastSave) >= sessionTouchStep {
			a.saveLocked()
		}
		if w != nil {
			http.SetCookie(w, a.sessionCookieUntil(c.Value, e.ExpiresAt))
		}
	}
	return *e, true
}

// sweep periodically drops expired sessions and stale failure records.
func (a *Auth) sweep() {
	for range time.Tick(sessionTouchStep) {
		now := time.Now()
		a.mu.Lock()
		for k, e := range a.sessions {
			if now.After(e.ExpiresAt) {
				delete(a.sessions, k)
				a.dirty = true
			}
		}
		if a.dirty {
			a.saveLocked()
		}
		for ip, l := range a.fails {
			if len(l) == 0 || now.Sub(l[len(l)-1]) > loginWindow {
				delete(a.fails, ip)
			}
		}
		a.mu.Unlock()
	}
}

// HostGuard enforces DNS-rebinding protection (Host header) on every request and
// a same-origin check on state-changing requests and WebSocket upgrades.
type HostGuard struct {
	port  string
	hosts map[string]bool
	proxy map[string]bool // proxied names, matched without port or with :443
}

// requireLoopback rejects any listen address that is reachable from outside this machine.
// The tabs are shells with the user's rights, so remote exposure is not supported.
func requireLoopback(listen string) error {
	host, _, err := net.SplitHostPort(listen)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("%q is not a loopback address (use 127.0.0.1:<port>)", listen)
	}
	return nil
}

func NewHostGuard(listen string, allowed ...string) *HostGuard {
	_, port, _ := net.SplitHostPort(listen)
	g := &HostGuard{port: port, hosts: map[string]bool{"localhost": true, "127.0.0.1": true, "::1": true}, proxy: map[string]bool{}}
	for _, h := range allowed {
		if h = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(h), ".")); h != "" {
			g.proxy[h] = true
		}
	}
	return g
}

func (g *HostGuard) hostOK(hostport string) bool {
	if hp := strings.ToLower(hostport); g.proxy[hp] || g.proxy[strings.TrimSuffix(hp, ":443")] {
		return true
	}
	h, p, err := net.SplitHostPort(hostport)
	if err != nil {
		return false
	}
	return p == g.port && g.hosts[strings.ToLower(h)]
}

func (g *HostGuard) originOK(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" {
		return false
	}
	u, err := url.Parse(o)
	if err != nil || u.Scheme != "https" {
		return false
	}
	return strings.EqualFold(u.Host, r.Host)
}

func (g *HostGuard) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !g.hostOK(r.Host) {
			http.Error(w, "invalid host", http.StatusMisdirectedRequest)
			return
		}
		isWS := strings.EqualFold(r.Header.Get("Upgrade"), "websocket")
		if (r.Method != http.MethodGet && r.Method != http.MethodHead) || isWS {
			if !g.originOK(r) {
				writeJSON(w, http.StatusForbidden, map[string]string{"error": "bad_origin"})
				return
			}
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; connect-src 'self' wss:; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}
