package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

// claudeProjectDir returns %USERPROFILE%/.claude/projects/<encoded project path>.
func claudeProjectDir(projectPath string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	var b strings.Builder
	for _, r := range projectPath {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	return filepath.Join(home, ".claude", "projects", b.String())
}

// claudeSessions returns session id -> modification time of the project's .jsonl files.
func claudeSessions(projectPath string) map[string]time.Time {
	out := map[string]time.Time{}
	dir := claudeProjectDir(projectPath)
	if dir == "" {
		return out
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return out
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		id := strings.TrimSuffix(e.Name(), ".jsonl")
		if !sessionIDRe.MatchString(id) {
			continue
		}
		if info, err := e.Info(); err == nil {
			out[id] = info.ModTime()
		}
	}
	return out
}

// lastClaudeSession returns the newest session id not contained in exclude.
func lastClaudeSession(projectPath string, exclude map[string]bool) (string, time.Time) {
	var best string
	var bestT time.Time
	for id, t := range claudeSessions(projectPath) {
		if exclude[id] {
			continue
		}
		if t.After(bestT) {
			best, bestT = id, t
		}
	}
	return best, bestT
}

// currentSession returns the newest session file in projectPath that was written
// after started and is not in exclude, or "" when none was. A session a tab resumed
// but never wrote to has no such file and does not move the tab.
func currentSession(projectPath string, started time.Time, exclude map[string]bool) string {
	var best string
	var bestT time.Time
	for id, t := range claudeSessions(projectPath) {
		if exclude[id] || !t.After(started) {
			continue
		}
		if t.After(bestT) {
			best, bestT = id, t
		}
	}
	return best
}
