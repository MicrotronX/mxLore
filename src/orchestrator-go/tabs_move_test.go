package main

import "testing"

func TestTabMovePersistsOrder(t *testing.T) {
	store, err := LoadStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	m := NewTabManager(store)
	m.tabs = []*Tab{{ID: "a", ProjectID: "pa"}, {ID: "b", ProjectID: "pb"}, {ID: "c", ProjectID: "pc"}}
	order := func() string {
		s := ""
		for _, x := range m.tabs {
			s += x.ID
		}
		return s
	}
	for _, c := range []struct {
		id    string
		index int
		want  string
	}{{"c", 0, "cab"}, {"c", 99, "abc"}, {"a", 1, "bac"}, {"b", -5, "bac"}} {
		if !m.Move(c.id, c.index) {
			t.Fatalf("move %s failed", c.id)
		}
		if got := order(); got != c.want {
			t.Fatalf("move %s to %d: got %s, want %s", c.id, c.index, got, c.want)
		}
	}
	if m.Move("x", 0) {
		t.Fatal("unknown tab moved")
	}
	ws := ""
	store.View(func(c *Config) {
		for _, e := range c.Workspace {
			ws += e.ProjectID
		}
	})
	if ws != "pbpapc" {
		t.Fatalf("workspace order %s, want pbpapc", ws)
	}
}
