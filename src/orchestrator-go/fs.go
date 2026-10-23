package main

import (
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// dirEntry is one folder in the add-project browser. Project marks folders that
// already look like a code project (CLAUDE.md or .git inside).
type dirEntry struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Project bool   `json:"project,omitempty"`
}

type dirListing struct {
	Path   string     `json:"path"`
	Parent string     `json:"parent"`
	Dirs   []dirEntry `json:"dirs"`
	More   bool       `json:"more,omitempty"`
}

const maxDirEntries = 1000

func looksLikeProject(dir string) bool {
	for _, n := range []string{"CLAUDE.md", ".git"} {
		if _, err := os.Stat(filepath.Join(dir, n)); err == nil {
			return true
		}
	}
	return false
}

// handleFsList lists sub-folders of ?path= (read-only). An empty path lists the drives.
func (s *Server) handleFsList(w http.ResponseWriter, r *http.Request) {
	p := strings.TrimSpace(r.URL.Query().Get("path"))
	out := dirListing{Dirs: []dirEntry{}}
	if p == "" {
		for c := 'A'; c <= 'Z'; c++ {
			d := string(c) + `:\`
			if st, err := os.Stat(d); err == nil && st.IsDir() {
				out.Dirs = append(out.Dirs, dirEntry{Name: string(c) + ":", Path: d})
			}
		}
		writeJSON(w, http.StatusOK, out)
		return
	}
	if !filepath.IsAbs(p) || hasControlChar(p) {
		apiErr(w, http.StatusBadRequest, "invalid_path")
		return
	}
	p = filepath.Clean(p)
	ents, err := os.ReadDir(p)
	if err != nil {
		apiErr(w, http.StatusNotFound, "path_not_found")
		return
	}
	out.Path = p
	if parent := filepath.Dir(p); parent != p {
		out.Parent = parent
	}
	for _, e := range ents {
		name := e.Name()
		if !e.IsDir() || strings.HasPrefix(name, "$") || strings.HasPrefix(name, ".") {
			continue
		}
		if len(out.Dirs) == maxDirEntries {
			out.More = true
			break
		}
		full := filepath.Join(p, name)
		out.Dirs = append(out.Dirs, dirEntry{Name: name, Path: full, Project: looksLikeProject(full)})
	}
	sort.Slice(out.Dirs, func(i, j int) bool { return strings.ToLower(out.Dirs[i].Name) < strings.ToLower(out.Dirs[j].Name) })
	writeJSON(w, http.StatusOK, out)
}
