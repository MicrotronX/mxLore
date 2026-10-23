package main

import "testing"

func TestProgramStatusScanner(t *testing.T) {
	var s programStatusScanner
	if p, st := s.scan([]byte("hello \x1b]7501;?\x1b\\ world")); !p || st != "" {
		t.Fatalf("probe: got %v %q", p, st)
	}
	if _, st := s.scan([]byte("x\x1b]7501;state=working:app=claude-code\x07y")); st != "working" {
		t.Fatalf("working: got %q", st)
	}
	// Split across reads, including inside the prefix.
	if _, st := s.scan([]byte("abc\x1b]75")); st != "" {
		t.Fatalf("split 1: got %q", st)
	}
	if _, st := s.scan([]byte("01;state=blo")); st != "" {
		t.Fatalf("split 2: got %q", st)
	}
	if _, st := s.scan([]byte("cked:kind=permission\x1b\\")); st != "blocked" {
		t.Fatalf("split 3: got %q", st)
	}
	if _, st := s.scan([]byte("\x1b]7501;state=working:app=claude-code\x07\x1b]7501;state=idle:app=claude-code\x07")); st != "idle" {
		t.Fatalf("last wins: got %q", st)
	}
	if _, st := s.scan([]byte("\x1b[31mplain\x1b[0m")); st != "" {
		t.Fatalf("plain: got %q", st)
	}
}
