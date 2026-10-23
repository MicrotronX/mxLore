package main

import (
	"net/http"
	"os"
	"sync"
	"time"
)

// Updater notices when a new build replaces the running EXE on disk (the running
// file was renamed and a new one put at its path) and flags it for the browser.
// The restart only happens on an explicit request from the UI: an idle Claude tab
// waiting for input counts as idle, so an automatic restart would close it.
type Updater struct {
	path    string
	started os.FileInfo
	tabs    *TabManager
	store   *Store
	logf    func(string, ...any)

	mu      sync.Mutex
	pending bool
	once    sync.Once
}

func NewUpdater(tabs *TabManager, store *Store) *Updater {
	u := &Updater{tabs: tabs, store: store, logf: func(string, ...any) {}}
	if exe, err := os.Executable(); err == nil {
		if fi, err := os.Stat(exe); err == nil {
			u.path, u.started = exe, fi
		}
	}
	return u
}

func (u *Updater) Pending() bool {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.pending
}

// Run polls for a replaced EXE and marks it pending. It does not restart: the
// browser shows the banner and handleUpdateRestart does the restart on request.
func (u *Updater) Run() {
	if u.started == nil {
		return
	}
	for range time.Tick(5 * time.Second) {
		// Not os.SameFile: on Windows it resolves the file id lazily via the path,
		// which by then names the new file.
		fi, err := os.Stat(u.path)
		if err != nil || (fi.Size() == u.started.Size() && fi.ModTime().Equal(u.started.ModTime())) {
			continue
		}
		u.mu.Lock()
		u.pending = true
		u.mu.Unlock()
		u.logf("update: new build found at %s, waiting for a restart from the UI", u.path)
		return
	}
}

// Restart fast-closes every tab and exits so the service manager starts the new build.
func (u *Updater) Restart(reason string) {
	u.once.Do(func() {
		u.logf("update: restarting (%s)", reason)
		u.tabs.FastCloseAll(4 * time.Second)
		os.Exit(0)
	})
}

func (s *Server) handleUpdateGet(w http.ResponseWriter, r *http.Request) {
	busy := []string{}
	pending := s.update.Pending()
	if pending {
		busy = s.tabs.Busy(s.store.SaveSettings().Idle)
	}
	writeJSON(w, http.StatusOK, map[string]any{"pending": pending, "busy": busy})
}

func (s *Server) handleUpdateRestart(w http.ResponseWriter, r *http.Request) {
	if !s.update.Pending() {
		apiErr(w, http.StatusConflict, "no_update")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"ok": true})
	go func() {
		time.Sleep(300 * time.Millisecond)
		s.update.Restart("forced from the UI")
	}()
}
