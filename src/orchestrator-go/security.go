package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"image/png"
	"net/http"
	"strings"
	"time"

	"github.com/pquerna/otp/totp"
)

// totpPendingTTL bounds how long a browser 2FA enrollment may stay unconfirmed.
const totpPendingTTL = 10 * time.Minute

var errSecurityConflict = errors.New("security: conflict")

// sessionToken returns the session token of r ("" if none).
func sessionToken(r *http.Request) string {
	if c, err := r.Cookie(sessionCookie); err == nil {
		return c.Value
	}
	return ""
}

// dropSessions deletes every session except keep for which match returns true.
func (a *Auth) dropSessions(keep string, match func(e *sessionEntry) bool) {
	kh := tokenHash(keep)
	a.mu.Lock()
	defer a.mu.Unlock()
	n := 0
	for k, e := range a.sessions {
		if k != kh && match(e) {
			delete(a.sessions, k)
			n++
		}
	}
	if n > 0 {
		a.saveLocked()
	}
}

// startTOTP creates a pending secret kept in memory only.
func (a *Auth) startTOTP() (string, string, []byte, error) {
	k, err := totp.Generate(totp.GenerateOpts{Issuer: "mxLoreOrchestrator", AccountName: "admin"})
	if err != nil {
		return "", "", nil, err
	}
	img, err := k.Image(200, 200)
	if err != nil {
		return "", "", nil, err
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return "", "", nil, err
	}
	a.mu.Lock()
	a.pendingTOTP, a.pendingTOTPExp = k.Secret(), time.Now().Add(totpPendingTTL)
	a.mu.Unlock()
	return k.Secret(), k.URL(), buf.Bytes(), nil
}

func (a *Auth) takePendingTOTP() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.pendingTOTP == "" || time.Now().After(a.pendingTOTPExp) {
		a.pendingTOTP = ""
		return ""
	}
	return a.pendingTOTP
}

func (a *Auth) clearPendingTOTP() {
	a.mu.Lock()
	a.pendingTOTP = ""
	a.mu.Unlock()
}

// totpStatus maps a checkTOTP result to an HTTP status (never 401, which the UI treats as signed out).
func totpStatus(code string) int {
	if code == "totp_locked" {
		return http.StatusTooManyRequests
	}
	return http.StatusForbidden
}

// requireCurrentTOTP checks code against the active secret when 2FA is on.
// It returns "" when 2FA is off or the code is valid.
func (s *Server) requireCurrentTOTP(code string) string {
	var secret string
	s.store.View(func(c *Config) { secret = c.TOTPSecret })
	if secret == "" {
		return ""
	}
	code = strings.TrimSpace(code)
	if code == "" {
		return "totp_required"
	}
	return s.auth.checkTOTP(code, secret)
}

func (s *Server) handleSecurityGet(w http.ResponseWriter, r *http.Request) {
	var c Config
	s.store.View(func(cfg *Config) { c = *cfg })
	var dev any
	if c.MxLoreDeveloperID != 0 {
		dev = map[string]any{"id": c.MxLoreDeveloperID, "name": c.MxLoreDeveloperName}
	}
	writeJSON(w, http.StatusOK, map[string]any{"mxLoreUrl": c.MxLoreURL, "developer": dev, "totpEnabled": c.TOTPSecret != ""})
}

func (s *Server) handleSecurityURL(w http.ResponseWriter, r *http.Request) {
	var req struct {
		URL  string `json:"url"`
		TOTP string `json:"totp"`
	}
	if err := readJSON(r, &req); err != nil {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	u, err := validateMxLoreURL(req.URL)
	if err != nil {
		apiErr(w, http.StatusBadRequest, "invalid_mxlore_url")
		return
	}
	var cur string
	var boundID int
	s.store.View(func(c *Config) { cur, boundID = c.MxLoreURL, c.MxLoreDeveloperID })
	if u == cur {
		writeJSON(w, http.StatusOK, map[string]string{"mxLoreUrl": u})
		return
	}
	// A different server unlinks the bound developer; with 2FA on that needs a code.
	if c := s.requireCurrentTOTP(req.TOTP); c != "" {
		apiErr(w, totpStatus(c), c)
		return
	}
	if !s.unbindOrFail(w, boundID, true, u) {
		return
	}
	s.auth.logf("mxlore: server address changed from the web; developer binding removed")
	writeJSON(w, http.StatusOK, map[string]any{"mxLoreUrl": u, "signedOut": !s.auth.Valid(nil, r)})
}

// whoamiFor checks key against the configured mxLore server. It returns the
// developer or an error code with its HTTP status.
func (s *Server) whoamiFor(key string) (mxLoreDeveloper, string, int) {
	var base string
	s.store.View(func(c *Config) { base = c.MxLoreURL })
	if base == "" {
		return mxLoreDeveloper{}, "mxlore_not_configured", http.StatusConflict
	}
	if strings.TrimSpace(key) == "" {
		return mxLoreDeveloper{}, "invalid_key", http.StatusBadRequest
	}
	d, err := mxLoreWhoami(base, key)
	switch {
	case errors.Is(err, errMxLoreUnreachable):
		return d, "mxlore_unreachable", http.StatusBadGateway
	case err != nil:
		return d, "invalid_key", http.StatusBadRequest
	}
	return d, "", 0
}

func (s *Server) handleSecurityUnbind(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TOTP string `json:"totp"`
	}
	if err := readJSON(r, &req); err != nil {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	if c := s.requireCurrentTOTP(req.TOTP); c != "" {
		apiErr(w, totpStatus(c), c)
		return
	}
	var boundID int
	s.store.View(func(c *Config) { boundID = c.MxLoreDeveloperID })
	if !s.unbindOrFail(w, boundID, false, "") {
		return
	}
	s.auth.logf("mxlore: developer binding removed from the web")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true, "signedOut": !s.auth.Valid(nil, r)})
}

// unbindOrFail runs unbindDeveloper and writes the error response on failure.
func (s *Server) unbindOrFail(w http.ResponseWriter, expectID int, setURL bool, u string) bool {
	err := s.unbindDeveloper(expectID, setURL, u)
	switch {
	case errors.Is(err, errSecurityConflict):
		apiErr(w, http.StatusConflict, "conflict")
	case err != nil:
		apiErr(w, http.StatusInternalServerError, "save_failed")
	default:
		return true
	}
	return false
}

func (s *Server) handleTOTPStart(w http.ResponseWriter, r *http.Request) {
	var on bool
	s.store.View(func(c *Config) { on = c.TOTPSecret != "" })
	if on {
		apiErr(w, http.StatusConflict, "totp_already_enabled")
		return
	}
	secret, uri, img, err := s.auth.startTOTP()
	if err != nil {
		apiErr(w, http.StatusInternalServerError, "totp_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"secret": secret, "uri": uri,
		"qr": "data:image/png;base64," + base64.StdEncoding.EncodeToString(img)})
}

func (s *Server) handleTOTPConfirm(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	if err := readJSON(r, &req); err != nil {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	pending := s.auth.takePendingTOTP()
	if pending == "" {
		apiErr(w, http.StatusConflict, "totp_not_started")
		return
	}
	if strings.TrimSpace(req.Code) == "" {
		apiErr(w, http.StatusForbidden, "totp_required")
		return
	}
	if c := s.auth.checkTOTP(strings.TrimSpace(req.Code), pending); c != "" {
		apiErr(w, totpStatus(c), c)
		return
	}
	err := s.store.Update(func(c *Config) error {
		if c.TOTPSecret != "" {
			return errSecurityConflict
		}
		c.TOTPSecret = pending
		return nil
	})
	if errors.Is(err, errSecurityConflict) {
		apiErr(w, http.StatusConflict, "totp_already_enabled")
		return
	}
	if err != nil {
		apiErr(w, http.StatusInternalServerError, "save_failed")
		return
	}
	s.auth.clearPendingTOTP()
	s.auth.dropSessions(sessionToken(r), func(*sessionEntry) bool { return true })
	s.auth.logf("2fa: enabled from the web; other sessions signed out")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleTOTPDisable(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	if err := readJSON(r, &req); err != nil {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	var secret string
	var boundID int
	s.store.View(func(c *Config) { secret, boundID = c.TOTPSecret, c.MxLoreDeveloperID })
	if secret == "" {
		apiErr(w, http.StatusConflict, "totp_not_enabled")
		return
	}
	if boundID != 0 {
		// Two-factor sign-in is mandatory while a developer is bound.
		apiErr(w, http.StatusConflict, "totp_mandatory")
		return
	}
	if c := s.requireCurrentTOTP(req.Code); c != "" {
		apiErr(w, totpStatus(c), c)
		return
	}
	if err := s.store.Update(func(c *Config) error { c.TOTPSecret = ""; return nil }); err != nil {
		apiErr(w, http.StatusInternalServerError, "save_failed")
		return
	}
	s.auth.logf("2fa: disabled from the web")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
