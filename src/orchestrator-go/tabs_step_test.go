package main

import (
	"testing"
	"time"
)

// A quick-action step ends on a fresh OSC 7501 idle/done/error report, stops on a
// fresh blocked report, and without a fresh report falls back to output-then-quiet.
func TestWaitStep(t *testing.T) {
	past := time.Now().Add(-time.Second) // deadline already passed: one loop pass, no waiting
	old := time.Now().Add(-5 * time.Second)
	cases := []struct {
		name        string
		running     bool
		seq         int64 // stateSeq; smark is 1, so 2 = fresh report
		state       string
		out         int64 // outCount; mark is 10
		last        time.Time
		ok, blocked bool
	}{
		{"process exited", false, 1, "working", 10, time.Now(), true, false},
		{"fresh blocked", true, 2, "blocked", 11, time.Now(), false, true},
		{"fresh idle, quiet", true, 2, "idle", 11, old, true, false},
		{"fresh done, quiet", true, 2, "done", 11, old, true, false},
		{"fresh error, quiet", true, 2, "error", 11, old, true, false},
		{"fresh idle, output still flowing", true, 2, "idle", 11, time.Now(), false, false},
		{"fresh working", true, 2, "working", 11, old, false, false},
		{"no report, output then quiet", true, 1, "", 11, old, true, false},
		{"stale idle, output then quiet", true, 1, "idle", 11, old, true, false},
		{"stale working, quiet", true, 1, "working", 11, old, false, false},
		{"no report, no new output", true, 1, "", 10, old, false, false},
	}
	for _, c := range cases {
		tab := &Tab{Running: c.running, stateSeq: c.seq, claudeState: c.state, outCount: c.out, lastOut: c.last}
		ok, blocked := tab.waitStep(0, 10, 1, 500*time.Millisecond, past)
		if ok != c.ok || blocked != c.blocked {
			t.Errorf("%s: got ok=%v blocked=%v, want ok=%v blocked=%v", c.name, ok, blocked, c.ok, c.blocked)
		}
	}
}

// Cancel returns the tab to "running" at once, ends the waits of the canceled
// sequence without a timeout, and leaves a sequence started afterwards alone.
func TestCancelSave(t *testing.T) {
	m := &TabManager{}
	tab := &Tab{ID: "a", Mode: "new", Running: true, State: "running", lastOut: time.Now()}
	m.tabs = []*Tab{tab}
	gen, ok := tab.beginSave()
	if !ok || tab.State != "saving" {
		t.Fatalf("beginSave: ok=%v state=%q", ok, tab.State)
	}
	if _, err := m.CancelSave("a"); err != nil || tab.State != "running" {
		t.Fatalf("cancel: err=%v state=%q", err, tab.State)
	}
	if _, err := m.CancelSave("a"); err == nil {
		t.Error("second cancel: want error, tab is not saving")
	}
	far := time.Now().Add(time.Hour)
	if tab.waitQuiet(gen, 0, time.Hour, far) {
		t.Error("waitQuiet: canceled sequence reported done")
	}
	if ok, blocked := tab.waitStep(gen, 0, 0, time.Hour, far); ok || blocked {
		t.Errorf("waitStep: canceled sequence got ok=%v blocked=%v", ok, blocked)
	}
	gen2, ok := tab.beginSave()
	if !ok || gen2 == gen {
		t.Fatalf("second beginSave: ok=%v gen=%d", ok, gen2)
	}
	tab.endSaving(gen)
	if tab.State != "saving" {
		t.Errorf("endSaving of the canceled sequence changed the new one: %q", tab.State)
	}
	tab.endSaving(gen2)
	if tab.State != "running" {
		t.Errorf("endSaving: got %q, want running", tab.State)
	}
}
