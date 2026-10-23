package main

import (
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// setupCodeFile holds the setup code while no developer is bound. It is
// readable only by the current user, SYSTEM and Administrators.
const setupCodeFile = "setup-code.txt"

// newSetupCode returns a random code like "K7QF-2M9X-HT4P" (60 bits).
func newSetupCode() string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var b strings.Builder
	for i := 0; i < 12; i++ {
		if i > 0 && i%4 == 0 {
			b.WriteByte('-')
		}
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		if err != nil {
			panic(err)
		}
		b.WriteByte(alphabet[n.Int64()])
	}
	return b.String()
}

// normalizeSetupCode ignores case, spaces and dashes.
func normalizeSetupCode(s string) string {
	s = strings.ToUpper(s)
	return strings.Map(func(r rune) rune {
		if r == '-' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, s)
}

// SetupCodePath returns where the setup code is written ("" without a data dir).
func (a *Auth) SetupCodePath() string {
	if a.dir == "" {
		return ""
	}
	return filepath.Join(a.dir, setupCodeFile)
}

// enterSetupMode creates a fresh setup code and writes it to the setup code
// file. Callers changing the binding hold a.bindMu.
func (a *Auth) enterSetupMode() {
	code := newSetupCode()
	a.mu.Lock()
	a.setupCode = code
	a.mu.Unlock()
	p := a.SetupCodePath()
	if p == "" {
		return
	}
	if err := writePrivateFile(p, []byte(code+"\r\n")); err != nil {
		a.logf("setup: writing the setup code file failed: %v", err)
		return
	}
	a.logf("setup: no developer is bound; the setup code is in %s", p)
}

// leaveSetupMode forgets the setup code and deletes its file.
func (a *Auth) leaveSetupMode() {
	a.mu.Lock()
	a.setupCode = ""
	a.mu.Unlock()
	if p := a.SetupCodePath(); p != "" {
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			a.logf("setup: removing the setup code file failed: %v", err)
		}
	}
}

// checkSetupCode compares code with the current setup code in constant time.
func (a *Auth) checkSetupCode(code string) bool {
	a.mu.Lock()
	want := a.setupCode
	a.mu.Unlock()
	if want == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(normalizeSetupCode(code)), []byte(normalizeSetupCode(want))) == 1
}

// SetRecoveryKey activates a one-time recovery key valid until process exit.
func (a *Auth) SetRecoveryKey(key string) {
	a.mu.Lock()
	a.recoveryKey = key
	a.mu.Unlock()
}

func (a *Auth) isRecoveryKey(key string) bool {
	a.mu.Lock()
	want := a.recoveryKey
	a.mu.Unlock()
	return want != "" && subtle.ConstantTimeCompare([]byte(strings.TrimSpace(key)), []byte(want)) == 1
}

// unbindDeveloper clears the binding (and optionally sets a new mxLore URL),
// signs out all mxLore sessions and returns to setup mode. It fails with
// errSecurityConflict when the binding is no longer expectID.
func (s *Server) unbindDeveloper(expectID int, setURL bool, url string) error {
	s.auth.bindMu.Lock()
	defer s.auth.bindMu.Unlock()
	if err := s.store.Update(func(c *Config) error {
		if c.MxLoreDeveloperID != expectID {
			return errSecurityConflict
		}
		if setURL {
			c.MxLoreURL = url
		}
		c.MxLoreDeveloperID, c.MxLoreDeveloperName = 0, ""
		return nil
	}); err != nil {
		return err
	}
	s.auth.dropSessions("", func(e *sessionEntry) bool { return e.Kind == "mxlore" })
	s.auth.enterSetupMode()
	return nil
}

// mustEnroll reports whether session e has to set up 2FA before using the app:
// 2FA is mandatory for mxLore sessions once a developer is bound.
func (s *Server) mustEnroll(e sessionEntry) bool {
	if e.Kind != "mxlore" {
		return false
	}
	var on bool
	s.store.View(func(c *Config) { on = c.TOTPSecret != "" })
	return !on
}

// requireEnrolled is requireSession plus the mandatory 2FA gate.
func (s *Server) requireEnrolled(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		e, ok := s.auth.Session(w, r)
		if !ok {
			apiErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		if s.mustEnroll(e) {
			apiErr(w, http.StatusForbidden, "enroll_2fa_required")
			return
		}
		h(w, r)
	}
}

// handleSetupGet reports the pre-login state. It carries no secrets.
func (s *Server) handleSetupGet(w http.ResponseWriter, r *http.Request) {
	var c Config
	s.store.View(func(cfg *Config) { c = *cfg })
	setup := c.MxLoreDeveloperID == 0
	var bound any
	if !setup {
		bound = map[string]any{"name": c.MxLoreDeveloperName}
	}
	path := ""
	if setup {
		path = s.auth.SetupCodePath()
	}
	writeJSON(w, http.StatusOK, map[string]any{"setupMode": setup, "mxLoreUrl": c.MxLoreURL, "bound": bound,
		"totpEnabled": c.TOTPSecret != "", "setupCodePath": path})
}

// handleSetupURL changes the mxLore address before sign-in. In setup mode the
// setup code is required. Once bound, the mxLore key of the bound developer
// (checked against the current server) and a current 2FA code are required,
// and the change unbinds the developer. Failures count toward a per-IP budget
// of their own, so this endpoint cannot exhaust the sign-in budget.
func (s *Server) handleSetupURL(w http.ResponseWriter, r *http.Request) {
	ip := "setup-url|" + clientIP(r)
	at, ok := s.auth.reserveAttempt(ip)
	if !ok {
		apiErr(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	var req struct {
		URL       string `json:"url"`
		SetupCode string `json:"setupCode"`
		Key       string `json:"key"`
		TOTP      string `json:"totp"`
	}
	if err := readJSON(r, &req); err != nil {
		s.auth.releaseAttempt(ip, at)
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	u, err := validateMxLoreURL(req.URL)
	if err != nil {
		s.auth.releaseAttempt(ip, at)
		apiErr(w, http.StatusBadRequest, "invalid_mxlore_url")
		return
	}
	var boundID int
	var secret string
	s.store.View(func(c *Config) { boundID, secret = c.MxLoreDeveloperID, c.TOTPSecret })
	if boundID == 0 {
		if strings.TrimSpace(req.SetupCode) == "" {
			s.auth.releaseAttempt(ip, at)
			apiErr(w, http.StatusForbidden, "setup_code_required")
			return
		}
		if !s.auth.checkSetupCode(req.SetupCode) {
			apiErr(w, http.StatusForbidden, "invalid_setup_code")
			return
		}
	} else {
		if secret == "" {
			// Bound without 2FA (older setup): only the recovery key can change it.
			s.auth.releaseAttempt(ip, at)
			apiErr(w, http.StatusForbidden, "use_recovery")
			return
		}
		if strings.TrimSpace(req.Key) == "" || strings.TrimSpace(req.TOTP) == "" {
			s.auth.releaseAttempt(ip, at)
			apiErr(w, http.StatusForbidden, "key_and_totp_required")
			return
		}
		// The TOTP check (and its global failure budget) is only reachable with
		// the bound developer's key.
		d, code, st := s.whoamiFor(req.Key)
		if code == "" && d.ID != boundID {
			code, st = "invalid_key", http.StatusForbidden
		}
		if code != "" {
			if code == "invalid_key" {
				st = http.StatusForbidden
			} else {
				s.auth.releaseAttempt(ip, at)
			}
			apiErr(w, st, code)
			return
		}
		if c := s.auth.checkTOTP(strings.TrimSpace(req.TOTP), secret); c != "" {
			apiErr(w, totpStatus(c), c)
			return
		}
	}
	s.auth.releaseAttempt(ip, at)
	if boundID == 0 {
		if err := s.store.Update(func(c *Config) error {
			if c.MxLoreDeveloperID != 0 {
				return errSecurityConflict
			}
			c.MxLoreURL = u
			return nil
		}); err != nil {
			if errors.Is(err, errSecurityConflict) {
				apiErr(w, http.StatusConflict, "conflict")
				return
			}
			apiErr(w, http.StatusInternalServerError, "save_failed")
			return
		}
		s.auth.logf("mxlore: server address set before sign-in")
	} else {
		if err := s.unbindDeveloper(boundID, true, u); err != nil {
			if errors.Is(err, errSecurityConflict) {
				apiErr(w, http.StatusConflict, "conflict")
				return
			}
			apiErr(w, http.StatusInternalServerError, "save_failed")
			return
		}
		s.auth.logf("mxlore: server address changed before sign-in; developer binding removed")
	}
	writeJSON(w, http.StatusOK, map[string]string{"mxLoreUrl": u})
}
