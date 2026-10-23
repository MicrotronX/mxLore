package main

import "testing"

// The default project start is a new session only after /clear or exit; a crash
// (no marker) keeps the resume of the last session.
func TestMarkProjectEndDecidesDefaultStart(t *testing.T) {
	store, err := LoadStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Update(func(c *Config) error {
		c.Projects = []Project{{ID: "p1", Name: "Demo", Path: t.TempDir()}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	m := &TabManager{store: store}
	lastEnd := func() string {
		var end string
		store.View(func(c *Config) { end = c.Projects[0].LastEnd })
		return end
	}

	m.markProjectEnd("p1", "clear")
	if lastEnd() != "clear" {
		t.Fatalf("clear not stored: %q", lastEnd())
	}
	m.markProjectEnd("p1", "exit")
	if lastEnd() != "exit" {
		t.Fatalf("exit not stored: %q", lastEnd())
	}
	m.markProjectEnd("p1", "")
	if lastEnd() != "" {
		t.Fatalf("new start did not reset: %q", lastEnd())
	}
	m.markProjectEnd("unknown", "clear")
	if lastEnd() != "" {
		t.Fatal("marker applied to another project")
	}
}
