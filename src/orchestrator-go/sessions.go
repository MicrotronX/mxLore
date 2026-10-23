package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// sessionEntry is one persisted login session. Only the SHA-256 of the
// session token is stored, never the token itself.
type sessionEntry struct {
	CreatedAt time.Time `json:"createdAt"`
	LastSeen  time.Time `json:"lastSeen"`
	ExpiresAt time.Time `json:"expiresAt"`
	// Kind is "mxlore" (mxLore key) or "recovery" (--recovery key). "" was the
	// removed local key login; such entries are dropped on load.
	Kind          string `json:"kind,omitempty"`
	DeveloperID   int    `json:"developerId,omitempty"`
	DeveloperName string `json:"developerName,omitempty"`
	// MaxExpiresAt is an absolute cap the sliding expiry never passes (zero = none).
	MaxExpiresAt time.Time `json:"maxExpiresAt,omitempty"`
}

// slideExpiry returns the next expiry: now+ttl, capped at MaxExpiresAt.
func (e *sessionEntry) slideExpiry(now time.Time, ttl time.Duration) time.Time {
	t := now.Add(ttl)
	if !e.MaxExpiresAt.IsZero() && t.After(e.MaxExpiresAt) {
		t = e.MaxExpiresAt
	}
	return t
}

const (
	sessionsFile     = "sessions.json"
	sessionTouchStep = time.Minute // min interval between expiry extensions / lastSeen writes
)

func tokenHash(tok string) string {
	h := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(h[:])
}

func loadSessions(dir string) (map[string]*sessionEntry, error) {
	m := map[string]*sessionEntry{}
	if dir == "" {
		return m, nil
	}
	b, err := os.ReadFile(filepath.Join(dir, sessionsFile))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return m, nil
		}
		return nil, err
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	now := time.Now()
	for k, e := range m {
		// Kind "" sessions came from the removed local key login: drop them.
		if e == nil || now.After(e.ExpiresAt) || e.Kind == "" {
			delete(m, k)
		}
	}
	return m, nil
}

// writeSessions atomically writes the session map (temp file + rename).
func writeSessions(dir string, m map[string]*sessionEntry) error {
	if dir == "" {
		return nil
	}
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return writePrivateFile(filepath.Join(dir, sessionsFile), b)
}

// clearSessions removes all persisted sessions (used by --reset-key and the 2FA switches).
func clearSessions(dir string) error {
	return writeSessions(dir, map[string]*sessionEntry{})
}
