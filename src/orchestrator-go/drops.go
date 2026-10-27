package main

// Dropped files (FR#19592): the browser only hands over name and bytes of a
// file dragged into a terminal, never its original path. The file is stored
// under <dataDir>/drops and the absolute path is what the page types into the
// terminal, so Claude Code can read it like a path dropped into a native window.

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	dropMaxBytes = 64 << 20 // one file per request
	dropKeep     = 14 * 24 * time.Hour
)

func (s *Store) DataDir() string { return filepath.Dir(s.path) }

// dropName keeps the original name readable but safe for a Windows path.
func dropName(name string) string {
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	var b strings.Builder
	for _, r := range name {
		switch {
		case r < 0x20, strings.ContainsRune(`<>:"/\|?*`, r):
			b.WriteRune('_')
		default:
			b.WriteRune(r)
		}
	}
	out := strings.Trim(b.String(), " .")
	if out == "" || out == "_" {
		out = "file"
	}
	if len(out) > 120 {
		out = out[len(out)-120:]
	}
	return out
}

// pruneDrops removes stored drops older than dropKeep. Errors are ignored: a
// failed prune only costs disk space.
func pruneDrops(dir string) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	cut := time.Now().Add(-dropKeep)
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		if fi, err := e.Info(); err == nil && fi.ModTime().Before(cut) {
			os.Remove(filepath.Join(dir, e.Name()))
		}
	}
}

// handleDrop stores one multipart file ("file") and returns its absolute path.
func (s *Server) handleDrop(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, dropMaxBytes+4096)
	f, hdr, err := r.FormFile("file")
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			apiErr(w, http.StatusRequestEntityTooLarge, "drop_too_large")
			return
		}
		apiErr(w, http.StatusBadRequest, "drop_missing_file")
		return
	}
	defer f.Close()

	dir := filepath.Join(s.store.DataDir(), "drops")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		apiErr(w, http.StatusInternalServerError, "drop_store_failed")
		return
	}
	pruneDrops(dir)

	name := dropName(hdr.Filename)
	stamp := time.Now().Format("20060102-150405")
	path := filepath.Join(dir, stamp+"-"+name)
	for i := 2; ; i++ {
		if _, err := os.Stat(path); err != nil {
			break
		}
		path = filepath.Join(dir, fmt.Sprintf("%s-%d-%s", stamp, i, name))
	}
	out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		apiErr(w, http.StatusInternalServerError, "drop_store_failed")
		return
	}
	n, err := io.Copy(out, f)
	out.Close()
	if err != nil {
		os.Remove(path)
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			apiErr(w, http.StatusRequestEntityTooLarge, "drop_too_large")
			return
		}
		apiErr(w, http.StatusInternalServerError, "drop_store_failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"path": path, "name": name, "size": n})
}
