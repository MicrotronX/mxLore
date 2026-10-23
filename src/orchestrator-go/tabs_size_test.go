package main

import (
	"encoding/json"
	"fmt"
	"testing"
)

type gridFrame struct {
	Type  string
	Cols  int
	Rows  int
	Owner bool
	Owned bool
}

func lastGrid(t *testing.T, v *viewer) gridFrame {
	t.Helper()
	var last viewerMsg
	for n := len(v.ch); n > 0; n-- {
		last = <-v.ch
	}
	var g gridFrame
	if err := json.Unmarshal(last.data, &g); err != nil || g.Type != "size" {
		t.Fatalf("no grid frame: got %q (%v)", last.data, err)
	}
	return g
}

func TestGridOwner(t *testing.T) {
	tab := &Tab{viewers: map[*viewer]struct{}{}, cols: defaultCols, rows: defaultRows}
	phone, _, _, _ := tab.attach()
	desk, _, _, grid := tab.attach()
	size := func() string { return fmt.Sprintf("%dx%d", tab.cols, tab.rows) }

	var g gridFrame
	if err := json.Unmarshal(grid.data, &g); err != nil || g.Type != "size" || g.Cols != defaultCols || g.Rows != defaultRows || g.Owner || g.Owned {
		t.Fatalf("attach grid frame: got %s (%v)", grid.data, err)
	}

	tab.resizeFrom(phone, 47, 37, false)
	if size() != "47x37" || tab.sizeOwner != phone {
		t.Fatalf("first size makes the owner: got %s", size())
	}
	if g := lastGrid(t, desk); g.Cols != 47 || g.Owner || !g.Owned {
		t.Fatalf("non-owner learns the grid and that it is owned: got %+v", g)
	}
	tab.resizeFrom(desk, 80, 24, false)
	if size() != "47x37" {
		t.Fatalf("non-owner must not change the grid: got %s", size())
	}
	tab.resizeFrom(desk, 80, 24, true)
	if size() != "80x24" || tab.sizeOwner != desk {
		t.Fatalf("explicit claim takes the grid: got %s", size())
	}
	if g := lastGrid(t, phone); g.Cols != 80 || g.Owner || !g.Owned {
		t.Fatalf("former owner learns it lost the grid: got %+v", g)
	}
	tab.detach(desk)
	if size() != "80x24" || tab.sizeOwner != nil {
		t.Fatalf("owner gone: grid stays, nobody owns it; got %s owner=%v", size(), tab.sizeOwner != nil)
	}
	if g := lastGrid(t, phone); g.Owned {
		t.Fatalf("remaining viewer learns nobody owns the grid: got %+v", g)
	}
	tab.resizeFrom(phone, 47, 16, false)
	if size() != "47x16" || tab.sizeOwner != phone {
		t.Fatalf("next client to send a size becomes owner: got %s", size())
	}
	tab.resizeFrom(desk, 120, 40, true)
	if size() != "47x16" {
		t.Fatalf("detached client must not change the grid, even with claim: got %s", size())
	}
}

func TestRestartRefusedWhileSaving(t *testing.T) {
	for _, st := range []string{"saving", "exiting"} {
		tab := &Tab{ID: "x", State: st, viewers: map[*viewer]struct{}{}}
		m := &TabManager{tabs: []*Tab{tab}}
		if _, err := m.Restart("x"); err != errBusy {
			t.Errorf("state %s: got %v, want errBusy", st, err)
		}
	}
}
