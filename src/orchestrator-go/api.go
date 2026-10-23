package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// Server wires HTTP routes to the store, auth and tab manager.
type Server struct {
	store  *Store
	auth   *Auth
	tabs   *TabManager
	guard  *HostGuard
	update *Updater
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func apiErr(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}

func readJSON(r *http.Request, v any) error {
	return json.NewDecoder(io.LimitReader(r.Body, 64*1024)).Decode(v)
}

func (s *Server) requireSession(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.auth.Valid(w, r) {
			apiErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		h(w, r)
	}
}

func (s *Server) Routes(static http.Handler) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/login", s.handleLogin)
	mux.HandleFunc("POST /api/logout", s.handleLogout)
	mux.HandleFunc("GET /api/me", s.handleMe)
	mux.HandleFunc("GET /api/setup", s.handleSetupGet)
	mux.HandleFunc("POST /api/setup/mxlore-url", s.handleSetupURL)

	mux.HandleFunc("GET /api/projects", s.requireEnrolled(s.handleProjects))
	mux.HandleFunc("POST /api/projects", s.requireEnrolled(s.handleProjectCreate))
	mux.HandleFunc("PUT /api/projects/{id}", s.requireEnrolled(s.handleProjectRename))
	mux.HandleFunc("POST /api/projects/reorder", s.requireEnrolled(s.handleProjectReorder))
	mux.HandleFunc("POST /api/projects/{id}/open-explorer", s.requireEnrolled(s.handleProjectOpenExplorer))
	mux.HandleFunc("POST /api/projects/{id}/open-vscode", s.requireEnrolled(s.handleProjectOpenVSCode))
	mux.HandleFunc("DELETE /api/projects/{id}", s.requireEnrolled(s.handleProjectDelete))

	mux.HandleFunc("GET /api/fs", s.requireEnrolled(s.handleFsList))
	mux.HandleFunc("GET /api/update", s.requireEnrolled(s.handleUpdateGet))
	mux.HandleFunc("POST /api/update/restart", s.requireEnrolled(s.handleUpdateRestart))
	mux.HandleFunc("GET /api/groups", s.requireEnrolled(s.handleGroups))
	mux.HandleFunc("POST /api/groups", s.requireEnrolled(s.handleGroupCreate))
	mux.HandleFunc("PUT /api/groups/{id}", s.requireEnrolled(s.handleGroupUpdate))
	mux.HandleFunc("DELETE /api/groups/{id}", s.requireEnrolled(s.handleGroupDelete))

	mux.HandleFunc("GET /api/tabs", s.requireEnrolled(s.handleTabs))
	mux.HandleFunc("POST /api/tabs", s.requireEnrolled(s.handleTabCreate))
	mux.HandleFunc("DELETE /api/tabs/{id}", s.requireEnrolled(s.handleTabDelete))
	mux.HandleFunc("POST /api/tabs/{id}/restart", s.requireEnrolled(s.handleTabRestart))
	mux.HandleFunc("POST /api/tabs/{id}/move", s.requireEnrolled(s.handleTabMove))
	mux.HandleFunc("POST /api/tabs/{id}/save-close", s.requireEnrolled(s.handleTabSaveClose))

	mux.HandleFunc("GET /api/workspace", s.requireEnrolled(s.handleWorkspace))
	mux.HandleFunc("POST /api/workspace/restore", s.requireEnrolled(s.handleWorkspaceRestore))
	mux.HandleFunc("POST /api/tabs/{id}/save", s.requireEnrolled(s.handleTabSave))
	mux.HandleFunc("POST /api/tabs/{id}/action/{n}", s.requireEnrolled(s.handleTabAction))
	mux.HandleFunc("POST /api/workspace/save-all", s.requireEnrolled(s.handleSaveAll))
	mux.HandleFunc("POST /api/workspace/save-close-all", s.requireEnrolled(s.handleSaveCloseAll))

	mux.HandleFunc("GET /api/settings", s.requireEnrolled(s.handleSettingsGet))
	mux.HandleFunc("PUT /api/settings", s.requireEnrolled(s.handleSettingsPut))

	mux.HandleFunc("GET /api/security", s.requireEnrolled(s.handleSecurityGet))
	mux.HandleFunc("PUT /api/security/mxlore-url", s.requireEnrolled(s.handleSecurityURL))
	mux.HandleFunc("POST /api/security/mxlore-unbind", s.requireEnrolled(s.handleSecurityUnbind))
	mux.HandleFunc("POST /api/security/totp/start", s.requireSession(s.handleTOTPStart))
	mux.HandleFunc("POST /api/security/totp/confirm", s.requireSession(s.handleTOTPConfirm))
	mux.HandleFunc("POST /api/security/totp/disable", s.requireEnrolled(s.handleTOTPDisable))

	mux.HandleFunc("GET /ws/tabs/{id}", s.requireEnrolled(s.handleWS))
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) { apiErr(w, http.StatusNotFound, "not_found") })
	mux.Handle("/", static)
	return s.guard.Wrap(mux)
}

// --- auth ---

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	at, ok := s.auth.reserveAttempt(ip)
	if !ok {
		apiErr(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	var req struct {
		Key       string `json:"key"`
		TOTP      string `json:"totp"`
		SetupCode string `json:"setupCode"`
	}
	if err := readJSON(r, &req); err != nil {
		s.auth.releaseAttempt(ip, at)
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	tok, code := s.auth.Login(req.Key, req.TOTP, req.SetupCode)
	switch code {
	case "", "totp_required", "setup_code_required", "mxlore_not_configured", "mxlore_unreachable":
		// Success, or a missing second factor after a correct key, or no server: not a guess.
		s.auth.releaseAttempt(ip, at)
	}
	if code != "" {
		apiErr(w, http.StatusUnauthorized, code)
		return
	}
	http.SetCookie(w, s.auth.SessionCookie(tok))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookie); err == nil {
		s.auth.Logout(c.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", HttpOnly: true, Secure: true,
		SameSite: http.SameSiteStrictMode, MaxAge: -1})
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	var totpOn, setup bool
	s.store.View(func(c *Config) { totpOn, setup = c.TOTPSecret != "", c.MxLoreDeveloperID == 0 })
	e, ok := s.auth.Session(w, r)
	var dev any
	kind := ""
	if ok {
		kind = e.Kind
		if e.Kind == "mxlore" {
			dev = map[string]any{"id": e.DeveloperID, "name": e.DeveloperName}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"authenticated": ok, "totpEnabled": totpOn, "developer": dev, "loginKind": kind,
		"setupMode": setup, "mustEnroll2FA": ok && s.mustEnroll(e)})
}

// --- projects ---

type projectView struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Path          string `json:"path"`
	CreatedAt     string `json:"createdAt"`
	Pinned        bool   `json:"pinned"`
	Order         int    `json:"order"`
	GroupID       string `json:"groupId"`
	Exists        bool   `json:"exists"`
	LastSessionID string `json:"lastSessionId"`
	LastSessionAt string `json:"lastSessionAt"`
	// LastSessionActive: the session file changed within the last minute, so
	// it is probably open in another client.
	LastSessionActive bool `json:"lastSessionActive"`
	// CleanEnd: the last session was ended with /clear or exit, so the default start is
	// a new session instead of a resume.
	CleanEnd bool `json:"cleanEnd"`
}

func viewProject(p Project, owned map[string]bool) projectView {
	v := projectView{ID: p.ID, Name: p.Name, Path: p.Path, CreatedAt: p.CreatedAt, Pinned: p.Pinned, Order: p.Order, GroupID: p.GroupID, CleanEnd: p.LastEnd != ""}
	if st, err := os.Stat(p.Path); err == nil && st.IsDir() {
		v.Exists = true
	}
	if id, t := lastClaudeSession(p.Path, owned); id != "" {
		v.LastSessionID = id
		v.LastSessionAt = t.UTC().Format(time.RFC3339)
		v.LastSessionActive = time.Since(t) < 60*time.Second
	}
	return v
}

func (s *Server) handleProjects(w http.ResponseWriter, r *http.Request) {
	var ps []Project
	s.store.View(func(c *Config) { ps = append(ps, c.Projects...) })
	out := make([]projectView, 0, len(ps))
	owned := s.tabs.OwnedSessions()
	for _, p := range ps {
		out = append(out, viewProject(p, owned))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleProjectCreate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name    string `json:"name"`
		Path    string `json:"path"`
		Create  bool   `json:"create"`
		GroupID string `json:"groupId"`
	}
	if err := readJSON(r, &req); err != nil {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	req.Path = strings.TrimSpace(req.Path)
	if req.Path == "" || !filepath.IsAbs(req.Path) {
		apiErr(w, http.StatusBadRequest, "path_not_absolute")
		return
	}
	path := filepath.Clean(req.Path)
	if req.Name == "" {
		req.Name = filepath.Base(path)
	}
	// Validate the group before touching the filesystem so a rejected
	// request never leaves a freshly created folder behind.
	groupOK := true
	if req.GroupID != "" {
		s.store.View(func(c *Config) { groupOK = groupExists(c, req.GroupID) })
	}
	if !groupOK {
		apiErr(w, http.StatusBadRequest, "group_not_found")
		return
	}
	if req.Create {
		if err := os.MkdirAll(path, 0o755); err != nil {
			apiErr(w, http.StatusBadRequest, "mkdir_failed")
			return
		}
	} else if st, err := os.Stat(path); err != nil || !st.IsDir() {
		apiErr(w, http.StatusBadRequest, "path_not_found")
		return
	}
	p := Project{ID: randomToken(9), Name: req.Name, Path: path, CreatedAt: time.Now().UTC().Format(time.RFC3339), GroupID: req.GroupID}
	badGroup := false
	err := s.store.Update(func(c *Config) error {
		if p.GroupID != "" && !groupExists(c, p.GroupID) {
			badGroup = true
			return errors.New("group")
		}
		for _, x := range c.Projects {
			if strings.EqualFold(x.Path, path) {
				return errors.New("duplicate")
			}
		}
		c.Projects = append(c.Projects, p)
		return nil
	})
	if badGroup {
		apiErr(w, http.StatusBadRequest, "group_not_found")
		return
	}
	if err != nil {
		apiErr(w, http.StatusConflict, "path_already_registered")
		return
	}
	writeJSON(w, http.StatusCreated, viewProject(p, s.tabs.OwnedSessions()))
}

func (s *Server) handleProjectRename(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		Name    *string `json:"name"`
		Pinned  *bool   `json:"pinned"`
		Order   *int    `json:"order"`
		GroupID *string `json:"groupId"`
	}
	if err := readJSON(r, &req); err != nil || (req.Name == nil && req.Pinned == nil && req.Order == nil && req.GroupID == nil) {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	name := ""
	if req.Name != nil {
		name = strings.TrimSpace(*req.Name)
		if name == "" || len(name) > 200 || hasControlChar(name) {
			apiErr(w, http.StatusBadRequest, "bad_request")
			return
		}
	}
	var updated Project
	badGroup := false
	err := s.store.Update(func(c *Config) error {
		if req.GroupID != nil && *req.GroupID != "" && !groupExists(c, *req.GroupID) {
			badGroup = true
			return errors.New("group")
		}
		for i := range c.Projects {
			if c.Projects[i].ID == id {
				if req.GroupID != nil {
					c.Projects[i].GroupID = *req.GroupID
				}
				if req.Name != nil {
					c.Projects[i].Name = name
				}
				if req.Pinned != nil {
					c.Projects[i].Pinned = *req.Pinned
				}
				if req.Order != nil {
					c.Projects[i].Order = *req.Order
				}
				updated = c.Projects[i]
				return nil
			}
		}
		return errors.New("not found")
	})
	if badGroup {
		apiErr(w, http.StatusBadRequest, "group_not_found")
		return
	}
	if err != nil {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	if req.Name != nil {
		s.tabs.RenameProject(id, name)
	}
	writeJSON(w, http.StatusOK, viewProject(updated, s.tabs.OwnedSessions()))
}

// handleProjectReorder assigns order 1..n to the given ids in sequence.
func (s *Server) handleProjectReorder(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IDs []string `json:"ids"`
	}
	if err := readJSON(r, &req); err != nil || len(req.IDs) == 0 || len(req.IDs) > 1000 {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	err := s.store.Update(func(c *Config) error {
		idx := map[string]int{}
		for i := range c.Projects {
			idx[c.Projects[i].ID] = i
		}
		seen := map[string]bool{}
		for _, id := range req.IDs {
			if _, ok := idx[id]; !ok || seen[id] {
				return errors.New("bad id")
			}
			seen[id] = true
		}
		for n, id := range req.IDs {
			c.Projects[idx[id]].Order = n + 1
		}
		return nil
	})
	if err != nil {
		apiErr(w, http.StatusBadRequest, "unknown_project")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// projectDir resolves a registered project's existing directory; paths never come from the request.
func (s *Server) projectDir(w http.ResponseWriter, r *http.Request) (string, bool) {
	p, ok := s.store.Project(r.PathValue("id"))
	if !ok {
		apiErr(w, http.StatusNotFound, "not_found")
		return "", false
	}
	if st, err := os.Stat(p.Path); err != nil || !st.IsDir() {
		apiErr(w, http.StatusBadRequest, "path_not_found")
		return "", false
	}
	return p.Path, true
}

func (s *Server) handleProjectOpenExplorer(w http.ResponseWriter, r *http.Request) {
	dir, ok := s.projectDir(w, r)
	if !ok {
		return
	}
	if err := openExplorer(dir); err != nil {
		apiErr(w, http.StatusInternalServerError, "start_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleProjectOpenVSCode(w http.ResponseWriter, r *http.Request) {
	dir, ok := s.projectDir(w, r)
	if !ok {
		return
	}
	err := openVSCode(dir)
	if errors.Is(err, errCodeNotFound) {
		apiErr(w, http.StatusNotFound, "code_not_found")
		return
	}
	if err != nil {
		apiErr(w, http.StatusInternalServerError, "start_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleProjectDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	err := s.store.Update(func(c *Config) error {
		for i := range c.Projects {
			if c.Projects[i].ID == id {
				c.Projects = append(c.Projects[:i], c.Projects[i+1:]...)
				return nil
			}
		}
		return errors.New("not found")
	})
	if err != nil {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// --- tabs ---

func (s *Server) handleTabs(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.tabs.List())
}

func (s *Server) handleTabCreate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ProjectID string `json:"projectId"`
		Mode      string `json:"mode"`
		SessionID string `json:"sessionId"`
	}
	if err := readJSON(r, &req); err != nil {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	p, ok := s.store.Project(req.ProjectID)
	if !ok {
		apiErr(w, http.StatusNotFound, "project_not_found")
		return
	}
	switch req.Mode {
	case "new", "continue", "shell":
	case "resume":
		if req.SessionID == "" {
			req.SessionID, _ = lastClaudeSession(p.Path, s.tabs.OwnedSessions())
		}
		if !sessionIDRe.MatchString(req.SessionID) {
			apiErr(w, http.StatusBadRequest, "invalid_session_id")
			return
		}
	default:
		apiErr(w, http.StatusBadRequest, "invalid_mode")
		return
	}
	if st, err := os.Stat(p.Path); err != nil || !st.IsDir() {
		apiErr(w, http.StatusBadRequest, "path_not_found")
		return
	}
	if req.Mode == "resume" {
		// Desktop and phone may both ask for the same session; a second
		// `claude --resume` on it would write the same transcript twice.
		// openMu spans the check and Open, so two requests cannot both pass.
		s.tabs.openMu.Lock()
		defer s.tabs.openMu.Unlock()
		if running := s.tabs.RunningBySession(req.SessionID); running != nil {
			writeJSON(w, http.StatusOK, running.info())
			return
		}
	}
	t, err := s.tabs.Open(p, req.Mode, req.SessionID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "start_failed", "detail": err.Error()})
		return
	}
	writeJSON(w, http.StatusCreated, t.info())
}

func (s *Server) handleTabDelete(w http.ResponseWriter, r *http.Request) {
	if !s.tabs.Close(r.PathValue("id")) {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleTabMove(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Index *int `json:"index"`
	}
	if err := readJSON(r, &req); err != nil || req.Index == nil {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	if !s.tabs.Move(r.PathValue("id"), *req.Index) {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	writeJSON(w, http.StatusOK, s.tabs.List())
}

func (s *Server) handleTabRestart(w http.ResponseWriter, r *http.Request) {
	t, err := s.tabs.Restart(r.PathValue("id"))
	if err != nil {
		if err == errBusy {
			apiErr(w, http.StatusConflict, "busy")
			return
		}
		if t == nil && err.Error() == "not found" {
			apiErr(w, http.StatusNotFound, "not_found")
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "start_failed", "detail": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, t.info())
}

func (s *Server) handleTabSaveClose(w http.ResponseWriter, r *http.Request) {
	t, _, err := s.tabs.SaveClose(r.PathValue("id"))
	if t == nil {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		apiErr(w, http.StatusConflict, "busy")
		return
	}
	writeJSON(w, http.StatusAccepted, t.info())
}

func (s *Server) handleTabSave(w http.ResponseWriter, r *http.Request) {
	t, err := s.tabs.SaveOnly(r.PathValue("id"))
	if t == nil {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		apiErr(w, http.StatusConflict, "busy")
		return
	}
	writeJSON(w, http.StatusAccepted, t.info())
}

func (s *Server) handleSaveAll(w http.ResponseWriter, r *http.Request) {
	started, skipped := s.tabs.SaveAll()
	writeJSON(w, http.StatusAccepted, map[string][]string{"started": started, "skipped": skipped})
}

func (s *Server) handleSaveCloseAll(w http.ResponseWriter, r *http.Request) {
	started, _ := s.tabs.SaveCloseAll()
	out := make([]TabInfo, 0, len(started))
	for _, t := range started {
		out = append(out, t.info())
	}
	writeJSON(w, http.StatusAccepted, out)
}

// --- workspace ---

func (s *Server) handleWorkspace(w http.ResponseWriter, r *http.Request) {
	var ws []WorkspaceEntry
	s.store.View(func(c *Config) { ws = append([]WorkspaceEntry{}, c.Workspace...) })
	writeJSON(w, http.StatusOK, ws)
}

func (s *Server) handleWorkspaceRestore(w http.ResponseWriter, r *http.Request) {
	opened, skipped := s.restoreWorkspace()
	writeJSON(w, http.StatusOK, map[string]any{"opened": opened, "skipped": skipped})
}

// restoreWorkspace reopens the persisted workspace tabs; used by the UI and by auto-restore at startup.
func (s *Server) restoreWorkspace() ([]TabInfo, []string) {
	var ws []WorkspaceEntry
	s.store.View(func(c *Config) { ws = append([]WorkspaceEntry{}, c.Workspace...) })
	opened := []TabInfo{}
	skipped := []string{}
	// Skip entries whose (project, mode, session) is already open, so a second
	// restore does not duplicate tabs; distinct sessions on one project restore separately.
	seen := map[string]bool{}
	for _, t := range s.tabs.List() {
		if t.Running {
			seen[t.ProjectID+"|"+t.Mode+"|"+t.SessionID] = true
		}
	}
	owned := s.tabs.OwnedSessions()
	for _, e := range ws {
		p, ok := s.store.Project(e.ProjectID)
		if !ok {
			skipped = append(skipped, e.ProjectID)
			continue
		}
		mode, sid := e.Mode, e.SessionID
		switch mode {
		case "shell":
			sid = ""
		case "new", "continue":
			if sessionIDRe.MatchString(sid) && owned[sid] {
				skipped = append(skipped, e.ProjectID)
				continue
			}
			if sessionIDRe.MatchString(sid) {
				mode = "resume"
			} else {
				sid = ""
			}
		case "resume":
			if !sessionIDRe.MatchString(sid) {
				if id, _ := lastClaudeSession(p.Path, owned); id != "" {
					sid = id
				} else {
					mode, sid = "continue", ""
				}
			}
		default: // legacy entry without mode
			if sessionIDRe.MatchString(sid) {
				mode = "resume"
			} else if id, _ := lastClaudeSession(p.Path, owned); id != "" {
				mode, sid = "resume", id
			} else {
				mode, sid = "continue", ""
			}
		}
		k := p.ID + "|" + mode + "|" + sid
		if seen[k] {
			skipped = append(skipped, e.ProjectID)
			continue
		}
		seen[k] = true
		t, err := s.tabs.Open(p, mode, sid)
		if err != nil {
			skipped = append(skipped, e.ProjectID)
			continue
		}
		opened = append(opened, t.info())
		if sid != "" {
			owned[sid] = true
		}
	}
	s.tabs.ClearKept()
	return opened, skipped
}

// --- settings ---

// settingsView is the user-editable subset of Config, with defaults filled in.
type settingsView struct {
	SavePrompt         string        `json:"savePrompt"`
	SaveIdleSeconds    int           `json:"saveIdleSeconds"`
	SaveTimeoutMinutes int           `json:"saveTimeoutMinutes"`
	SessionDays        int           `json:"sessionDays"`
	AutoRestore        bool          `json:"autoRestore"`
	AutoRestoreReboot  bool          `json:"autoRestoreAfterReboot"`
	QuickActions       []QuickAction `json:"quickActions"`
	CloseOnClaudeExit  bool          `json:"closeOnClaudeExit"`
}

func (s *Server) currentSettings() settingsView {
	ss := s.store.SaveSettings()
	var auto, reboot bool
	s.store.View(func(c *Config) { auto, reboot = !c.NoAutoRestore, c.AutoRestoreAfterReboot })
	return settingsView{
		AutoRestore:        auto,
		AutoRestoreReboot:  reboot,
		SavePrompt:         ss.Prompt,
		SaveIdleSeconds:    int(ss.Idle / time.Second),
		SaveTimeoutMinutes: int(ss.Timeout / time.Minute),
		SessionDays:        int(s.store.SessionTTL() / (24 * time.Hour)),
		QuickActions:       s.store.QuickActionList(),
		CloseOnClaudeExit:  s.store.CloseOnClaudeExit(),
	}
}

// validQuickActions trims and checks user-defined quick actions.
func validQuickActions(in []QuickAction) ([]QuickAction, bool) {
	if len(in) > maxQuickActions {
		return nil, false
	}
	out := make([]QuickAction, 0, len(in))
	for _, a := range in {
		a.Name = strings.TrimSpace(a.Name)
		if a.Name == "" || len(a.Name) > maxQuickActionName || hasControlChar(a.Name) {
			return nil, false
		}
		steps := make([]string, 0, len(a.Steps))
		for _, st := range a.Steps {
			st = strings.TrimSpace(st)
			if st == "" {
				continue
			}
			if len(st) > maxSavePromptLen || hasControlChar(st) {
				return nil, false
			}
			steps = append(steps, st)
		}
		if len(steps) == 0 || len(steps) > maxQuickActionSteps {
			return nil, false
		}
		out = append(out, QuickAction{Name: a.Name, Steps: steps})
	}
	return out, true
}

func (s *Server) handleTabAction(w http.ResponseWriter, r *http.Request) {
	n, err := strconv.Atoi(r.PathValue("n"))
	actions := s.store.QuickActionList()
	if err != nil || n < 0 || n >= len(actions) {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	// The browser's list may be stale (changed in another window): never run a different action.
	if actions[n].Name != r.URL.Query().Get("name") {
		apiErr(w, http.StatusConflict, "stale_quick_action")
		return
	}
	t, err := s.tabs.RunAction(r.PathValue("id"), actions[n])
	if t == nil {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		apiErr(w, http.StatusConflict, "busy")
		return
	}
	writeJSON(w, http.StatusAccepted, t.info())
}

func (s *Server) handleSettingsGet(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.currentSettings())
}

// Allowed ranges for PUT /api/settings.
const (
	minIdleSeconds, maxIdleSeconds       = 2, 600
	minTimeoutMinutes, maxTimeoutMinutes = 1, 240
	minSessionDays, maxSessionDays       = 1, 90
	maxSavePromptLen                     = 200
	maxQuickActions, maxQuickActionSteps = 8, 10
	maxQuickActionName                   = 40
)

func (s *Server) handleSettingsPut(w http.ResponseWriter, r *http.Request) {
	var req settingsView
	if err := readJSON(r, &req); err != nil {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	req.SavePrompt = strings.TrimSpace(req.SavePrompt)
	switch {
	case req.SavePrompt == "" || len(req.SavePrompt) > maxSavePromptLen || hasControlChar(req.SavePrompt):
		apiErr(w, http.StatusBadRequest, "invalid_save_prompt")
		return
	case req.SaveIdleSeconds < minIdleSeconds || req.SaveIdleSeconds > maxIdleSeconds:
		apiErr(w, http.StatusBadRequest, "invalid_save_idle_seconds")
		return
	case req.SaveTimeoutMinutes < minTimeoutMinutes || req.SaveTimeoutMinutes > maxTimeoutMinutes:
		apiErr(w, http.StatusBadRequest, "invalid_save_timeout_minutes")
		return
	case req.SessionDays < minSessionDays || req.SessionDays > maxSessionDays:
		apiErr(w, http.StatusBadRequest, "invalid_session_days")
		return
	}
	actions, ok := validQuickActions(req.QuickActions)
	if !ok {
		apiErr(w, http.StatusBadRequest, "invalid_quick_actions")
		return
	}
	err := s.store.Update(func(c *Config) error {
		c.SavePrompt = req.SavePrompt
		c.SaveIdleSeconds = req.SaveIdleSeconds
		c.SaveTimeoutMinutes = req.SaveTimeoutMinutes
		c.SessionDays = req.SessionDays
		c.NoAutoRestore = !req.AutoRestore
		c.AutoRestoreAfterReboot = req.AutoRestoreReboot
		c.QuickActions = actions
		c.CloseOnClaudeExit = req.CloseOnClaudeExit
		return nil
	})
	if err != nil {
		apiErr(w, http.StatusInternalServerError, "save_failed")
		return
	}
	writeJSON(w, http.StatusOK, s.currentSettings())
}

// --- websocket ---

var upgrader = websocket.Upgrader{
	ReadBufferSize:  32 * 1024,
	WriteBufferSize: 32 * 1024,
	// Origin is already enforced by HostGuard; re-check here as defense in depth.
	CheckOrigin: nil,
}

// wsReadTimeout must exceed the 30s ping interval; any frame or pong extends it.
const wsReadTimeout = 70 * time.Second

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	t := s.tabs.Get(r.PathValue("id"))
	if t == nil {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	up := upgrader
	up.CheckOrigin = s.guard.originOK
	conn, err := up.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	conn.SetReadLimit(1 << 20)
	conn.SetReadDeadline(time.Now().Add(wsReadTimeout))
	conn.SetPongHandler(func(string) error { return conn.SetReadDeadline(time.Now().Add(wsReadTimeout)) })

	v, back, exit, grid := t.attach()
	defer t.detach(v)

	writeDone := make(chan struct{})
	go func() {
		defer close(writeDone)
		// The grid goes first: the client sizes its terminal to the PTY grid
		// before the scrollback is written into it.
		conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if conn.WriteMessage(websocket.TextMessage, grid.data) != nil {
			return
		}
		if len(back) > 0 {
			conn.SetWriteDeadline(time.Now().Add(30 * time.Second))
			if conn.WriteMessage(websocket.BinaryMessage, back) != nil {
				return
			}
		}
		if exit != nil {
			b, _ := json.Marshal(map[string]any{"type": "exit", "code": *exit})
			conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if conn.WriteMessage(websocket.TextMessage, b) != nil {
				return
			}
		}
		ping := time.NewTicker(30 * time.Second)
		defer ping.Stop()
		for {
			select {
			case m, ok := <-v.ch:
				if !ok {
					conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
					conn.Close()
					return
				}
				typ := websocket.BinaryMessage
				if m.text {
					typ = websocket.TextMessage
				}
				conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if conn.WriteMessage(typ, m.data) != nil {
					conn.Close()
					return
				}
			case <-ping.C:
				if conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)) != nil {
					conn.Close()
					return
				}
			}
		}
	}()

	for {
		typ, data, err := conn.ReadMessage()
		if err != nil {
			break
		}
		conn.SetReadDeadline(time.Now().Add(wsReadTimeout))
		switch typ {
		case websocket.BinaryMessage:
			t.write(data)
		case websocket.TextMessage:
			var m struct {
				Type string `json:"type"`
				Cols int    `json:"cols"`
				Rows int    `json:"rows"`
			}
			if json.Unmarshal(data, &m) == nil && (m.Type == "resize" || m.Type == "claim") {
				t.resizeFrom(v, m.Cols, m.Rows, m.Type == "claim")
			}
		}
	}
	t.detach(v)
	<-writeDone
}

// hasControlChar reports whether s contains a C0 control character or DEL;
// the save prompt is typed into the console, so it must be a single plain line.
func hasControlChar(s string) bool {
	for _, r := range s {
		if r < 32 || r == 127 {
			return true
		}
	}
	return false
}
