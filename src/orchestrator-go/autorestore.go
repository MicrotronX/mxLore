package main

import (
	"time"

	"golang.org/x/sys/windows"
)

var procGetTickCount64 = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetTickCount64")

// bootTime is when Windows last started.
func bootTime() time.Time {
	ms, _, _ := procGetTickCount64.Call()
	return time.Now().Add(-time.Duration(ms) * time.Millisecond)
}

// autoRestore reopens the workspace at startup if the previous run ended with a
// clean fast-close. The marker is cleared first, so a crash right after the
// restore does not reopen the tabs again on the next start.
func (s *Server) autoRestore(logf func(string, ...any)) {
	var marker string
	var on, afterReboot bool
	_ = s.store.Update(func(c *Config) error {
		marker, on, afterReboot = c.CleanShutdownAt, !c.NoAutoRestore, c.AutoRestoreAfterReboot
		c.CleanShutdownAt = ""
		return nil
	})
	if marker == "" {
		logf("auto-restore: skipped, previous run did not shut down cleanly")
		return
	}
	if !on {
		logf("auto-restore: off in settings")
		return
	}
	at, err := time.Parse(time.RFC3339, marker)
	if err != nil {
		return
	}
	if bootTime().After(at) && !afterReboot {
		logf("auto-restore: skipped after a Windows restart (enable in settings)")
		return
	}
	opened, skipped := s.restoreWorkspace()
	logf("auto-restore: opened %d tab(s), skipped %d", len(opened), len(skipped))
}
