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
		ok, blocked := tab.waitStep(10, 1, 500*time.Millisecond, past)
		if ok != c.ok || blocked != c.blocked {
			t.Errorf("%s: got ok=%v blocked=%v, want ok=%v blocked=%v", c.name, ok, blocked, c.ok, c.blocked)
		}
	}
}
