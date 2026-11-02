package main

import "testing"

// A timed-out save clears once Claude reports the end of its turn; other reports
// and other tab states stay as they are.
func TestNoteClaudeStateClearsSaveTimeout(t *testing.T) {
	cases := []struct {
		name, state, report, want string
	}{
		{"timeout, idle", "save_timeout", "idle", "running"},
		{"timeout, done", "save_timeout", "done", "running"},
		{"timeout, error", "save_timeout", "error", "running"},
		{"timeout, working", "save_timeout", "working", "save_timeout"},
		{"timeout, blocked", "save_timeout", "blocked", "save_timeout"},
		{"saving, idle", "saving", "idle", "saving"},
		{"exited, idle", "exited", "idle", "exited"},
	}
	for _, c := range cases {
		tab := &Tab{State: c.state, gen: 1}
		tab.noteClaudeState(c.report, 1)
		if tab.State != c.want || tab.claudeState != c.report || tab.stateSeq != 1 {
			t.Errorf("%s: state=%q claudeState=%q seq=%d, want state %q", c.name, tab.State, tab.claudeState, tab.stateSeq, c.want)
		}
	}
	old := &Tab{State: "save_timeout", gen: 2}
	old.noteClaudeState("idle", 1)
	if old.State != "save_timeout" || old.stateSeq != 0 {
		t.Errorf("old generation report applied: state=%q seq=%d", old.State, old.stateSeq)
	}
}

// A quick action that ran out of time leaves the tab usable, never red.
func TestEndSaving(t *testing.T) {
	cases := []struct {
		state   string
		running bool
		want    string
	}{
		{"saving", true, "running"},
		{"saving", false, "saving"},
		{"exited", false, "exited"},
	}
	for _, c := range cases {
		tab := &Tab{State: c.state, Running: c.running}
		tab.endSaving()
		if tab.State != c.want {
			t.Errorf("%s/%v: got %q, want %q", c.state, c.running, tab.State, c.want)
		}
	}
}
