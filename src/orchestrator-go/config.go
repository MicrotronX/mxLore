package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Project is one registered folder that tabs can be opened in.
type Project struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Path      string `json:"path"`
	CreatedAt string `json:"createdAt"`
	Pinned    bool   `json:"pinned,omitempty"`
	Order     int    `json:"order,omitempty"`
	GroupID   string `json:"groupId,omitempty"`
	// LastEnd is how the last Claude session of this project ended: "clear" (/clear
	// inside a tab) or "exit" (Claude exited with code 0). Empty after a new start
	// or after a crash. A non-empty value makes the default start a new session.
	LastEnd string `json:"lastEnd,omitempty"`
}

// WorkspaceEntry records one open tab so the workspace can be restored later.
type WorkspaceEntry struct {
	ProjectID string `json:"projectId"`
	Mode      string `json:"mode,omitempty"`
	SessionID string `json:"sessionId,omitempty"`
}

// Config is persisted as orchestrator.json in the data directory.
type Config struct {
	Listen     string           `json:"listen"`
	KeyHash    string           `json:"keyHash"`
	TOTPSecret string           `json:"totpSecret,omitempty"`
	Projects   []Project        `json:"projects"`
	Groups     []Group          `json:"groups"`
	Workspace  []WorkspaceEntry `json:"workspace"`

	SavePrompt         string `json:"savePrompt,omitempty"`
	SaveIdleSeconds    int    `json:"saveIdleSeconds,omitempty"`
	SaveTimeoutMinutes int    `json:"saveTimeoutMinutes,omitempty"`
	ClaudeCommand      string `json:"claudeCommand,omitempty"`
	SessionDays        int    `json:"sessionDays,omitempty"`

	// QuickActions are user-defined status bar buttons: each step is typed into
	// the Claude session and the next one waits until the output went quiet.
	QuickActions []QuickAction `json:"quickActions,omitempty"`

	// CloseOnClaudeExit starts Claude tabs without -NoExit and closes a tab
	// when Claude ends with exit code 0.
	CloseOnClaudeExit bool `json:"closeOnClaudeExit,omitempty"`

	// mxLore login. A browser session may only set a loopback URL (security API);
	// a remote URL is CLI-only, so a session cannot send the next login key elsewhere.
	MxLoreURL           string `json:"mxLoreUrl,omitempty"`
	MxLoreDeveloperID   int    `json:"mxLoreDeveloperId,omitempty"` // 0 = not bound yet
	MxLoreDeveloperName string `json:"mxLoreDeveloperName,omitempty"`

	// Auto-restore after a restart. Stored inverted so a missing value means on.
	NoAutoRestore          bool `json:"noAutoRestore,omitempty"`
	AutoRestoreAfterReboot bool `json:"autoRestoreAfterReboot,omitempty"`
	// CleanShutdownAt is set by the fast-close path and cleared at the next start;
	// only a clean shutdown triggers auto-restore (a crash loop must not reopen tabs).
	CleanShutdownAt string `json:"cleanShutdownAt,omitempty"`
}

type QuickAction struct {
	Name  string   `json:"name"`
	Steps []string `json:"steps"`
}

// QuickActionList returns a copy of the configured quick actions.
func (s *Store) QuickActionList() []QuickAction {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]QuickAction, len(s.cfg.QuickActions))
	for i, a := range s.cfg.QuickActions {
		out[i] = QuickAction{Name: a.Name, Steps: append([]string(nil), a.Steps...)}
	}
	return out
}

// SessionTTL returns the sliding login session lifetime (default 7 days).
func (s *Store) SessionTTL() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.cfg.SessionDays
	if d <= 0 {
		d = 7
	}
	return time.Duration(d) * 24 * time.Hour
}

// SaveSettings controls the graceful save & close sequence.
type SaveSettings struct {
	Prompt  string
	Idle    time.Duration
	Timeout time.Duration
}

// SaveSettings returns the save settings with defaults for missing values.
func (s *Store) SaveSettings() SaveSettings {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := SaveSettings{Prompt: s.cfg.SavePrompt, Idle: time.Duration(s.cfg.SaveIdleSeconds) * time.Second,
		Timeout: time.Duration(s.cfg.SaveTimeoutMinutes) * time.Minute}
	if r.Prompt == "" {
		r.Prompt = "/mxSave"
	}
	if r.Idle <= 0 {
		r.Idle = 8 * time.Second
	}
	if r.Timeout <= 0 {
		r.Timeout = 10 * time.Minute
	}
	return r
}

// ClaudeCmd returns the command used to start Claude Code (default "claude").
func (s *Store) ClaudeCmd() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cfg.ClaudeCommand == "" {
		return "claude"
	}
	return s.cfg.ClaudeCommand
}

// CloseOnClaudeExit reports whether new Claude tabs close when Claude exits cleanly.
func (s *Store) CloseOnClaudeExit() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cfg.CloseOnClaudeExit
}

// Store guards the config and writes it atomically on every change.
type Store struct {
	mu   sync.Mutex
	path string
	cfg  Config
}

const defaultListen = "127.0.0.1:8443"

func LoadStore(dataDir string) (*Store, error) {
	s := &Store{path: filepath.Join(dataDir, "orchestrator.json")}
	b, err := os.ReadFile(s.path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		s.cfg = Config{Listen: defaultListen}
	} else if err := json.Unmarshal(b, &s.cfg); err != nil {
		return nil, err
	}
	if s.cfg.Listen == "" {
		s.cfg.Listen = defaultListen
	}
	if s.cfg.Projects == nil {
		s.cfg.Projects = []Project{}
	}
	if s.cfg.Groups == nil {
		s.cfg.Groups = []Group{}
	}
	if s.cfg.Workspace == nil {
		s.cfg.Workspace = []WorkspaceEntry{}
	}
	return s, nil
}

// Update runs fn under the lock and persists the result.
func (s *Store) Update(fn func(c *Config) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := fn(&s.cfg); err != nil {
		return err
	}
	return s.saveLocked()
}

// View runs fn under the lock without saving.
func (s *Store) View(fn func(c *Config)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fn(&s.cfg)
}

func (s *Store) saveLocked() error {
	b, err := json.MarshalIndent(&s.cfg, "", "  ")
	if err != nil {
		return err
	}
	return writePrivateFile(s.path, b)
}

func (s *Store) Project(id string) (Project, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.cfg.Projects {
		if p.ID == id {
			return p, true
		}
	}
	return Project{}, false
}
