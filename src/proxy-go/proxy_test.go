package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The slug marker lives in a prose document, so the parser has to survive every
// spelling that real CLAUDE.md files and the mxInitProject template produce —
// and reject the marker where it is only being talked about. It has broken in
// both directions within a single day (too loose: matched prose and polled a
// non-existent project; too strict: rejected the bullet form the template
// writes). This table is the guard against the third time.
func TestParseSlugFromClaudeMd(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{"bare marker at top of file", "# Proj\n\n**Slug:** `mxLore`\n", "mxLore"},
		{"bullet form from claude-md-template", "## Project\n- **Slug:** <x>\n", "<x>"},
		{"star bullet", "* **Slug:** `mxLore`\n", "mxLore"},
		{"plus bullet", "+ **Slug:** mxLore\n", "mxLore"},
		{"tab after bullet", "-\t**Slug:** mxLore\n", "mxLore"},
		{"indented bullet", "  - **Slug:** mxLore\n", "mxLore"},
		{"trailing prose after the value", "- **Slug:** wsf-app (renamed later)\n", "wsf-app"},
		{"marker mid-sentence is not a value", "Der Parser suchte **Slug:** irgendwo.\n", ""},
		{"marker quoted in a blockquote", "> Kein `**Slug:**` hier\n", ""},
		{"bare marker without a value keeps scanning", "**Slug:**\n\n- **Slug:** mxLore\n", "mxLore"},
		{"no marker at all", "# Proj\n\nnothing here\n", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "CLAUDE.md")
			if err := os.WriteFile(path, []byte(c.body), 0644); err != nil {
				t.Fatal(err)
			}
			if got := parseSlugFromClaudeMd(path); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

// The file this proxy actually reads at startup on the build host. If the
// project's own CLAUDE.md stops yielding its slug, the Mac loses its wakeups —
// which is exactly how the wrong-slug defect stayed invisible.
func TestProjectClaudeMdYieldsItsOwnSlug(t *testing.T) {
	if got := parseSlugFromClaudeMd("CLAUDE.md"); got != "mxLore" {
		t.Errorf("own CLAUDE.md yields %q, want \"mxLore\"", got)
	}
}
