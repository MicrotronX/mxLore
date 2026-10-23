package main

import "testing"

func TestRunningBySession(t *testing.T) {
	m := &TabManager{tabs: []*Tab{
		{ID: "a", Mode: "resume", SessionID: "s1", Running: true},
		{ID: "b", Mode: "resume", SessionID: "s2", Running: false},
		{ID: "c", Mode: "new", SessionID: "", Running: true},
	}}
	if got := m.RunningBySession(""); got != nil {
		t.Errorf("empty id: got tab %s, want nil (no session)", got.ID)
	}
	if got := m.RunningBySession("s1"); got == nil || got.ID != "a" {
		t.Errorf("running session s1: got %v, want tab a", got)
	}
	if got := m.RunningBySession("s2"); got != nil {
		t.Errorf("exited session s2: got tab %s, want nil", got.ID)
	}
	if got := m.RunningBySession("s3"); got != nil {
		t.Errorf("unknown session s3: got tab %s, want nil", got.ID)
	}
}
