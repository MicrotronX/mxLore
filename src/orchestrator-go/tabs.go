package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"mxloreorchestrator/internal/conpty"
)

const (
	scrollbackMax = 1 << 20
	defaultCols   = 120
	defaultRows   = 30
	viewerQueue   = 256
)

var sessionIDRe = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)

// errBusy refuses a restart while a save or exit sequence drives the process.
var errBusy = errors.New("busy")

// viewerMsg is one outbound WebSocket frame; text frames carry JSON.
type viewerMsg struct {
	text bool
	data []byte
}

type viewer struct {
	ch         chan viewerMsg
	cols, rows int // last size this client measured (0 = none yet); guarded by Tab.mu
}

// Tab is one ConPTY-backed console owned by the server.
type Tab struct {
	ID        string `json:"id"`
	ProjectID string `json:"projectId"`
	Title     string `json:"title"`
	Mode      string `json:"mode"`
	SessionID string `json:"sessionId,omitempty"`
	Running   bool   `json:"running"`
	ExitCode  *int   `json:"exitCode"`
	StartedAt string `json:"startedAt"`
	State     string `json:"state"`

	claudeCmd   string
	closeOnExit bool        // shell ends with claude; a clean exit closes the tab
	inAction    bool        // set by a quick action until save & close; an /exit from it still auto-closes
	mgr         *TabManager // set for tabs opened through Open
	lastOut     time.Time
	claudeState string // last OSC 7501 state reported by Claude Code ("" = never)
	stateSeq    int64  // counts OSC 7501 reports, so a step can tell a fresh report from an old one
	outCount    int64
	cwd         string
	startedAt   time.Time  // when the current process was started; session files written after this belong to the tab
	life        sync.Mutex // serializes start/kill sequences (Restart, Close)
	closed      bool       // set under mu once the tab is closed; start refuses
	mu          sync.Mutex
	pty         *conpty.ConPty
	job         windows.Handle
	gen         int
	scrollback  []byte
	viewers     map[*viewer]struct{}
	// The PTY grid (cols, rows) is authoritative: every viewer renders it. Only
	// sizeOwner may change it; when the owner leaves, the grid stays and the
	// next client that sends a size becomes owner.
	sizeOwner  *viewer
	cols, rows int
	resizeMu   sync.Mutex // serializes resizeFrom so PTY resizes apply in order; taken before mu
}

// TabInfo is the JSON view of a tab.
type TabInfo struct {
	ID        string `json:"id"`
	ProjectID string `json:"projectId"`
	Title     string `json:"title"`
	Mode      string `json:"mode"`
	SessionID string `json:"sessionId,omitempty"`
	Running   bool   `json:"running"`
	ExitCode  *int   `json:"exitCode"`
	StartedAt string `json:"startedAt"`
	State     string `json:"state"`
	// Working: Claude reports "working" (OSC 7501), or, without that report,
	// the tab printed output in the last workingWindow.
	Working bool `json:"working,omitempty"`
	// ClaudeState is the state Claude Code reports itself via OSC 7501
	// (working, blocked, idle, done, error); empty until it reported one.
	ClaudeState string `json:"claudeState,omitempty"`
}

const workingWindow = 2500 * time.Millisecond

func (t *Tab) info() TabInfo {
	t.mu.Lock()
	defer t.mu.Unlock()
	c := TabInfo{ID: t.ID, ProjectID: t.ProjectID, Title: t.Title, Mode: t.Mode, SessionID: t.SessionID,
		Running: t.Running, StartedAt: t.StartedAt, State: t.State}
	if t.Running && isClaudeMode(t.Mode) {
		c.ClaudeState = t.claudeState
		if t.claudeState != "" {
			c.Working = t.claudeState == "working"
		} else {
			// Fallback for Claude builds without OSC 7501: recent output.
			c.Working = !t.lastOut.IsZero() && time.Since(t.lastOut) < workingWindow
		}
	}
	if t.ExitCode != nil {
		v := *t.ExitCode
		c.ExitCode = &v
	}
	return c
}

func shellExe() string {
	for _, n := range []string{"pwsh.exe", "powershell.exe"} {
		if p, err := exec.LookPath(n); err == nil {
			return p
		}
	}
	return "powershell.exe"
}

func isClaudeMode(mode string) bool {
	return mode == "new" || mode == "continue" || mode == "resume"
}

func buildCommandLine(mode, sessionID, claudeCmd string, closeOnExit bool) (string, error) {
	cl := fmt.Sprintf(`"%s" -NoLogo`, shellExe())
	if !closeOnExit || !isClaudeMode(mode) {
		cl += ` -NoExit`
	}
	if claudeCmd == "" {
		claudeCmd = "claude"
	}
	if strings.ContainsRune(claudeCmd, '"') {
		return "", errors.New("invalid claude command")
	}
	switch mode {
	case "new":
		cl += ` -Command "` + claudeCmd + `"`
	case "continue":
		cl += ` -Command "` + claudeCmd + ` --continue"`
	case "resume":
		if !sessionIDRe.MatchString(sessionID) {
			return "", errors.New("invalid session id")
		}
		cl += ` -Command "` + claudeCmd + ` --resume ` + sessionID + `"`
	case "shell":
	default:
		return "", errors.New("invalid mode")
	}
	return cl, nil
}

// newKillJob creates a job object that kills all member processes when closed,
// so closing a tab (or exiting the server) takes the whole process tree down.
// newKillJob puts pid into a job object that kills the whole process tree when
// closed. On failure it returns 0 and the reason, so the caller can log it.
func newKillJob(pid int) (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, fmt.Errorf("CreateJobObject: %w", err)
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(job)
		return 0, fmt.Errorf("SetInformationJobObject: %w", err)
	}
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		windows.CloseHandle(job)
		return 0, fmt.Errorf("OpenProcess: %w", err)
	}
	defer windows.CloseHandle(h)
	if err := windows.AssignProcessToJobObject(job, h); err != nil {
		windows.CloseHandle(job)
		return 0, fmt.Errorf("AssignProcessToJobObject: %w", err)
	}
	return job, nil
}

// start launches the process for the tab's current mode. Caller must not hold t.mu.
func (t *Tab) start() error {
	cl, err := buildCommandLine(t.Mode, t.SessionID, t.claudeCmd, t.closeOnExit)
	if err != nil {
		return err
	}
	// Held from reading the grid until the new PTY is in place: a resize in
	// between would set a grid the new PTY was not started with.
	t.resizeMu.Lock()
	defer t.resizeMu.Unlock()
	t.mu.Lock()
	cols, rows := t.cols, t.rows
	t.mu.Unlock()
	p, err := conpty.Start(cl, conpty.ConPtyDimensions(cols, rows), conpty.ConPtyWorkDir(t.cwd), conpty.ConPtyEnv(childEnv()))
	if err != nil {
		return err
	}
	job, jobErr := newKillJob(p.Pid())
	if jobErr != nil && t.mgr != nil {
		t.mgr.log("tab %s (%s): no kill job, child processes may survive close: %v", t.Title, t.ID, jobErr)
	}
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		if job != 0 {
			windows.TerminateJobObject(job, 1)
			windows.CloseHandle(job)
		}
		p.Close()
		return errors.New("tab closed")
	}
	oldP, oldJob := t.pty, t.job
	t.gen++
	gen := t.gen
	t.claudeState = ""
	t.pty, t.job = p, job
	t.Running, t.ExitCode = true, nil
	t.State = "running"
	t.StartedAt = time.Now().UTC().Format(time.RFC3339)
	t.mu.Unlock()
	if oldJob != 0 {
		windows.TerminateJobObject(oldJob, 1)
		windows.CloseHandle(oldJob)
	}
	if oldP != nil {
		oldP.Close()
	}
	go t.readLoop(p, gen)
	return nil
}

func (t *Tab) readLoop(p *conpty.ConPty, gen int) {
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		buf := make([]byte, 32*1024)
		var ps programStatusScanner
		for {
			n, err := p.Read(buf)
			if n > 0 {
				if probe, st := ps.scan(buf[:n]); probe || st != "" {
					if probe {
						p.Write(osc7501Reply)
					}
					if st != "" {
						t.mu.Lock()
						if t.gen == gen {
							t.claudeState = st
							t.stateSeq++
						}
						t.mu.Unlock()
					}
				}
				t.broadcastGen(append([]byte(nil), buf[:n]...), gen)
			}
			if err != nil {
				return
			}
		}
	}()
	code, _ := p.Wait(context.Background())
	// Let the reader drain the final output before closing the pseudo console.
	select {
	case <-readDone:
	case <-time.After(300 * time.Millisecond):
	}
	t.mu.Lock()
	if t.gen != gen {
		t.mu.Unlock()
		return
	}
	c := int(code)
	// A save or shutdown in progress keeps the tab so it stays restorable.
	autoClose := t.closeOnExit && c == 0 && t.mgr != nil && (t.inAction || t.State != "saving" && t.State != "exiting") && !t.mgr.shuttingDown.Load()
	t.Running, t.ExitCode = false, &c
	t.State = "exited"
	t.pty = nil
	job := t.job
	t.job = 0
	msg := viewerMsg{text: true, data: []byte(fmt.Sprintf(`{"type":"exit","code":%d}`, c))}
	for v := range t.viewers {
		t.sendLocked(v, msg)
	}
	t.mu.Unlock()
	// Claude exited with code 0 (/exit) by the user, not a server shutdown or a crash.
	if c == 0 && isClaudeMode(t.Mode) && t.mgr != nil && !t.mgr.shuttingDown.Load() {
		t.mgr.markProjectEnd(t.ProjectID, "exit")
	}
	t.resizeMu.Lock() // wait out a resize that captured p before t.pty was cleared
	p.Close()
	t.resizeMu.Unlock()
	if job != 0 {
		windows.CloseHandle(job)
	}
	if autoClose {
		t.mgr.closeIfGen(t, gen)
	}
}

func (t *Tab) sendLocked(v *viewer, m viewerMsg) {
	select {
	case v.ch <- m:
	default:
		// Slow viewer: drop it; it can reconnect and replay scrollback.
		delete(t.viewers, v)
		close(v.ch)
	}
}

func (t *Tab) broadcastGen(b []byte, gen int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if gen >= 0 && gen != t.gen {
		return
	}
	if gen >= 0 {
		t.lastOut = time.Now()
		t.outCount++
	}
	t.scrollback = append(t.scrollback, b...)
	if len(t.scrollback) > scrollbackMax {
		// Trim in a large step (keep 75%) so the copy is amortized, and cut at a
		// line boundary so a replay does not start inside a rune or escape sequence.
		cut := len(t.scrollback) - scrollbackMax*3/4
		if i := bytes.IndexByte(t.scrollback[cut:], '\n'); i >= 0 && i < 64*1024 {
			cut += i + 1
		}
		nb := make([]byte, len(t.scrollback)-cut, scrollbackMax+64*1024)
		copy(nb, t.scrollback[cut:])
		t.scrollback = nb
	}
	for v := range t.viewers {
		t.sendLocked(v, viewerMsg{data: b})
	}
}

// attach registers a viewer and returns, captured atomically with it, the
// scrollback, the exit code of an ended process, and the grid frame the viewer
// must apply before it writes the scrollback.
func (t *Tab) attach() (*viewer, []byte, *int, viewerMsg) {
	t.mu.Lock()
	defer t.mu.Unlock()
	v := &viewer{ch: make(chan viewerMsg, viewerQueue)}
	t.viewers[v] = struct{}{}
	var exit *int
	if !t.Running && t.ExitCode != nil {
		c := *t.ExitCode
		exit = &c
	}
	return v, append([]byte(nil), t.scrollback...), exit, t.gridMsgLocked(v)
}

// detach removes a viewer. If it owned the grid, the grid stays as it is and
// nobody owns it until a client sends its size; no other client is picked, so
// the grid never jumps to a device nobody is using.
func (t *Tab) detach(v *viewer) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.viewers[v]; ok {
		delete(t.viewers, v)
		close(v.ch)
	}
	if t.sizeOwner == v {
		t.sizeOwner = nil
		t.broadcastGridLocked()
	}
}

// gridMsgLocked is the {"type":"size"} frame for viewer v: the authoritative
// PTY grid, whether v owns it, and whether anyone does. t.mu must be held.
func (t *Tab) gridMsgLocked(v *viewer) viewerMsg {
	b, _ := json.Marshal(struct {
		Type  string `json:"type"`
		Cols  int    `json:"cols"`
		Rows  int    `json:"rows"`
		Owner bool   `json:"owner"`
		Owned bool   `json:"owned"`
	}{"size", t.cols, t.rows, v != nil && t.sizeOwner == v, t.sizeOwner != nil})
	return viewerMsg{text: true, data: b}
}

// broadcastGridLocked tells every viewer the grid and its ownership. t.mu must be held.
func (t *Tab) broadcastGridLocked() {
	for v := range t.viewers {
		t.sendLocked(v, t.gridMsgLocked(v))
	}
}

func (t *Tab) write(b []byte) {
	t.mu.Lock()
	p := t.pty
	t.mu.Unlock()
	if p != nil {
		p.Write(b)
	}
}

// resizeFrom applies client v's size to the grid if v owns it, or makes v the
// owner if nobody does. claim is the user's explicit "fit to this screen" and
// takes ownership from another client. Any other size is ignored: that client
// renders the grid the owner set. Typing never changes the grid.
func (t *Tab) resizeFrom(v *viewer, cols, rows int, claim bool) {
	if cols < 2 || rows < 2 || cols > 1000 || rows > 500 {
		return
	}
	t.resizeMu.Lock()
	defer t.resizeMu.Unlock()
	t.mu.Lock()
	v.cols, v.rows = cols, rows
	if t.sizeOwner != nil && t.sizeOwner != v && !claim {
		t.mu.Unlock()
		return
	}
	if _, attached := t.viewers[v]; !attached {
		t.mu.Unlock()
		return
	}
	changed := t.sizeOwner != v || t.cols != cols || t.rows != rows
	t.sizeOwner = v
	var p *conpty.ConPty
	if t.cols != cols || t.rows != rows {
		t.cols, t.rows = cols, rows
		p = t.pty
	}
	if changed {
		t.broadcastGridLocked()
	}
	t.mu.Unlock()
	// Resize outside t.mu: the reader needs t.mu to drain output, and the
	// console may wait for that output before it applies the new size.
	if p != nil {
		p.Resize(cols, rows)
	}
}

// kill terminates the running process tree (if any).
func (t *Tab) kill() {
	// resizeFrom resizes outside t.mu; resizeMu keeps it off a PTY closed here.
	t.resizeMu.Lock()
	defer t.resizeMu.Unlock()
	t.mu.Lock()
	t.gen++
	p, job := t.pty, t.job
	t.pty, t.job = nil, 0
	if t.Running {
		c := -1
		t.ExitCode = &c
	}
	t.Running = false
	t.State = "exited"
	t.mu.Unlock()
	if job != 0 {
		windows.TerminateJobObject(job, 1)
		windows.CloseHandle(job)
	}
	if p != nil {
		p.Close()
	}
}

func (t *Tab) closeViewers() {
	t.mu.Lock()
	defer t.mu.Unlock()
	for v := range t.viewers {
		delete(t.viewers, v)
		close(v.ch)
	}
}

// TabManager owns all tabs and keeps the persisted workspace in sync.
type TabManager struct {
	store *Store
	mu    sync.Mutex
	tabs  []*Tab
	// kept holds workspace entries of tabs closed by save & close all, so they
	// stay restorable until the next restore.
	kept []WorkspaceEntry
	// openMu makes "is this session already open?" and opening it one step,
	// so two devices resuming the same session cannot both start it.
	openMu sync.Mutex
	logf func(format string, args ...any)
	// shuttingDown stops auto-close so FastCloseAll leaves the workspace intact.
	shuttingDown atomic.Bool
}

func NewTabManager(store *Store) *TabManager { return &TabManager{store: store} }

func (m *TabManager) List() []TabInfo {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]TabInfo, 0, len(m.tabs))
	for _, t := range m.tabs {
		out = append(out, t.info())
	}
	return out
}

// Move puts tab id at position index (clamped) and persists the new order,
// so the workspace restores tabs in the order the user arranged them.
func (m *TabManager) Move(id string, index int) bool {
	m.mu.Lock()
	from := -1
	for i, t := range m.tabs {
		if t.ID == id {
			from = i
			break
		}
	}
	if from < 0 {
		m.mu.Unlock()
		return false
	}
	t := m.tabs[from]
	m.tabs = append(m.tabs[:from], m.tabs[from+1:]...)
	index = max(0, min(index, len(m.tabs)))
	m.tabs = append(m.tabs[:index], append([]*Tab{t}, m.tabs[index:]...)...)
	m.mu.Unlock()
	m.persistWorkspace()
	return true
}

func (m *TabManager) Get(id string) *Tab {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, t := range m.tabs {
		if t.ID == id {
			return t
		}
	}
	return nil
}

func (m *TabManager) Open(p Project, mode, sessionID string) (*Tab, error) {
	if mode != "resume" {
		sessionID = ""
	}
	t := &Tab{ID: randomToken(9), ProjectID: p.ID, Title: p.Name, Mode: mode, SessionID: sessionID,
		claudeCmd: m.store.ClaudeCmd(), closeOnExit: isClaudeMode(mode) && m.store.CloseOnClaudeExit(), mgr: m, cwd: p.Path, viewers: map[*viewer]struct{}{}, cols: defaultCols, rows: defaultRows}
	t.startedAt = time.Now()
	if err := t.start(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	m.tabs = append(m.tabs, t)
	m.mu.Unlock()
	m.persistWorkspace()
	if isClaudeMode(mode) {
		m.markProjectEnd(p.ID, "")
		go m.trackSession(t)
	}
	return t, nil
}

// markProjectEnd stores how the last Claude session of a project ended ("clear",
// "exit" or "" for a new or crashed session). Only "clear" and "exit" make the next
// default start a new session; everything else resumes.
func (m *TabManager) markProjectEnd(projectID, end string) {
	if m.store == nil || projectID == "" {
		return
	}
	_ = m.store.Update(func(c *Config) error {
		for i := range c.Projects {
			if c.Projects[i].ID == projectID {
				c.Projects[i].LastEnd = end
			}
		}
		return nil
	})
}

func (m *TabManager) Close(id string) bool {
	m.mu.Lock()
	var t *Tab
	for i, x := range m.tabs {
		if x.ID == id {
			t = x
			m.tabs = append(m.tabs[:i], m.tabs[i+1:]...)
			break
		}
	}
	m.mu.Unlock()
	if t == nil {
		return false
	}
	t.life.Lock()
	t.mu.Lock()
	t.closed = true
	t.mu.Unlock()
	t.kill()
	t.life.Unlock()
	t.closeViewers()
	m.persistWorkspace()
	return true
}

// closeIfGen closes t only if it is still the exited generation gen; a Restart
// that raced the exit wins. Lock order matches Close/Restart: t.life, then t.mu,
// and m.mu is taken only after t.life is released.
func (m *TabManager) closeIfGen(t *Tab, gen int) {
	t.life.Lock()
	t.mu.Lock()
	ok := !t.closed && t.gen == gen && !t.Running
	if ok {
		t.closed = true
	}
	t.mu.Unlock()
	t.life.Unlock()
	if !ok {
		return
	}
	m.mu.Lock()
	for i, x := range m.tabs {
		if x == t {
			m.tabs = append(m.tabs[:i], m.tabs[i+1:]...)
			break
		}
	}
	m.mu.Unlock()
	t.closeViewers()
	m.persistWorkspace()
}

func (m *TabManager) Restart(id string) (*Tab, error) {
	t := m.Get(id)
	if t == nil {
		return nil, errors.New("not found")
	}
	t.life.Lock()
	defer t.life.Unlock()
	t.mu.Lock()
	closed := t.closed
	busy := t.State == "saving" || t.State == "exiting"
	if !closed && !busy {
		t.closeOnExit = isClaudeMode(t.Mode) && m.store.CloseOnClaudeExit()
	}
	t.mu.Unlock()
	if closed {
		return nil, errors.New("not found")
	}
	if busy {
		// runSave still types into this process and closes the tab when done;
		// a new process would receive its /exit and be closed with it.
		return t, errBusy
	}
	t.kill()
	t.broadcastGen([]byte("\r\n\x1b[90m--- restarted ---\x1b[0m\r\n"), -1)
	if err := t.start(); err != nil {
		return nil, err
	}
	return t, nil
}

func (m *TabManager) HasRunning(projectID string) bool {
	m.mu.Lock()
	tabs := append([]*Tab(nil), m.tabs...)
	m.mu.Unlock()
	for _, t := range tabs {
		if t.ProjectID == projectID && t.info().Running {
			return true
		}
	}
	return false
}

// RenameProject updates titles of open tabs for a renamed project.
func (m *TabManager) RenameProject(projectID, name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, t := range m.tabs {
		if t.ProjectID == projectID {
			t.mu.Lock()
			t.Title = name
			t.mu.Unlock()
		}
	}
}

// sessionPollInterval is how often a claude tab re-checks which session it writes to.
const sessionPollInterval = 5 * time.Second

// trackSession keeps the stored session id current for the tab's whole lifetime,
// so /clear, /resume or a new session inside the tab reach the workspace.
func (m *TabManager) trackSession(t *Tab) {
	for {
		time.Sleep(sessionPollInterval)
		t.mu.Lock()
		stop := t.closed || !t.Running
		t.mu.Unlock()
		if stop {
			return
		}
		m.updateSession(t)
	}
}

// refreshSessions updates every running claude tab; called before the shutdown save.
func (m *TabManager) refreshSessions() {
	m.mu.Lock()
	tabs := append([]*Tab(nil), m.tabs...)
	m.mu.Unlock()
	for _, t := range tabs {
		if i := t.info(); i.Running && isClaudeMode(i.Mode) {
			m.updateSession(t)
		}
	}
}

// updateSession sets the tab's session id to the session it writes to and persists a change.
// Without a file written since the tab started, the stored id stays as it is.
func (m *TabManager) updateSession(t *Tab) {
	t.mu.Lock()
	path, started := t.cwd, t.startedAt
	t.mu.Unlock()
	id := currentSession(path, started, m.ownedSessions(t))
	if id == "" {
		return
	}
	t.mu.Lock()
	prev := t.SessionID
	changed := prev != id
	t.SessionID = id
	t.mu.Unlock()
	if changed {
		// A new session id in a tab that already had one means /clear inside the tab.
		if prev != "" {
			m.markProjectEnd(t.ProjectID, "clear")
		}
		m.persistWorkspace()
	}
}

// ownedSessions returns the session ids of running tabs other than skip.
func (m *TabManager) ownedSessions(skip *Tab) map[string]bool {
	m.mu.Lock()
	tabs := append([]*Tab(nil), m.tabs...)
	m.mu.Unlock()
	out := map[string]bool{}
	for _, t := range tabs {
		if t == skip {
			continue
		}
		if i := t.info(); i.Running && i.SessionID != "" {
			out[i.SessionID] = true
		}
	}
	return out
}

// OwnedSessions returns the session ids held by running tabs.
func (m *TabManager) OwnedSessions() map[string]bool { return m.ownedSessions(nil) }

// RunningBySession returns the running tab that holds session id, or nil.
// An empty id is no session: new, continue and shell tabs all carry "".
func (m *TabManager) RunningBySession(id string) *Tab {
	if id == "" {
		return nil
	}
	m.mu.Lock()
	tabs := append([]*Tab(nil), m.tabs...)
	m.mu.Unlock()
	for _, t := range tabs {
		if i := t.info(); i.Running && i.SessionID == id {
			return t
		}
	}
	return nil
}

// ClearKept drops the save-closed entries once a restore has run.
func (m *TabManager) ClearKept() {
	m.mu.Lock()
	m.kept = nil
	m.mu.Unlock()
	m.persistWorkspace()
}

func (m *TabManager) log(format string, args ...any) {
	if m.logf != nil {
		m.logf(format, args...)
	}
}

func (t *Tab) setState(s string) {
	t.mu.Lock()
	t.State = s
	t.mu.Unlock()
}

func (t *Tab) outputMark() (int64, time.Time, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.outCount, t.lastOut, t.Running
}

// waitQuiet waits until output arrived after mark and then stayed quiet for
// idle, or the process exited. It returns false when deadline passes first.
func (t *Tab) waitQuiet(mark int64, idle time.Duration, deadline time.Time) bool {
	for {
		n, last, running := t.outputMark()
		if !running {
			return true
		}
		if n > mark && time.Since(last) >= idle {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(250 * time.Millisecond)
	}
}

const actionStatusTimeout = 30 * time.Minute

func (t *Tab) statusMark() (int64, string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.stateSeq, t.claudeState
}

// waitStep waits for a typed quick-action step to finish. With OSC 7501 the step
// is done when Claude reports idle (or done) after the step was typed; a blocked
// report (question, permission) stops the action so the user answers. Without a
// fresh report it falls back to waitQuiet's rule: output, then idle quiet time.
func (t *Tab) waitStep(mark, smark int64, idle time.Duration, deadline time.Time) (ok, blocked bool) {
	for {
		n, last, running := t.outputMark()
		if !running {
			return true, false
		}
		seq, st := t.statusMark()
		quiet := n > mark && time.Since(last) >= idle
		if seq > smark {
			switch st {
			case "blocked":
				return false, true
			case "idle", "done", "error":
				if time.Since(last) >= time.Second {
					return true, false
				}
			}
		} else if quiet && st != "working" {
			return true, false
		}
		if time.Now().After(deadline) {
			return false, false
		}
		time.Sleep(250 * time.Millisecond)
	}
}

// typeLine sends text, pauses so the TUI autocomplete settles, then Enter.
func (t *Tab) typeLine(text string) {
	t.write([]byte(text))
	time.Sleep(300 * time.Millisecond)
	t.write([]byte("\r"))
}

// SaveClose starts the graceful save & close sequence for a tab. Shell tabs
// are closed directly. The returned channel is closed when the sequence ends.
// A single save & close is final; only SaveCloseAll keeps tabs for restore.
func (m *TabManager) SaveClose(id string) (*Tab, <-chan struct{}, error) {
	return m.saveClose(id, false)
}

func (m *TabManager) saveClose(id string, keep bool) (*Tab, <-chan struct{}, error) {
	t := m.Get(id)
	if t == nil {
		return nil, nil, errors.New("not found")
	}
	done := make(chan struct{})
	t.mu.Lock()
	mode, running, state := t.Mode, t.Running, t.State
	if isClaudeMode(mode) && running && state == "running" {
		t.State = "saving"
		t.inAction = false
	}
	t.mu.Unlock()
	if !isClaudeMode(mode) || !running {
		m.Close(id)
		close(done)
		return t, done, nil
	}
	if state != "running" {
		return t, nil, errors.New("busy")
	}
	go func() {
		defer close(done)
		m.runSave(t, keep)
	}()
	return t, done, nil
}

// typeSave types the save prompt and waits for output followed by the idle
// period. On timeout it sets state save_timeout and returns false.
func (m *TabManager) typeSave(t *Tab) bool {
	cfg := m.store.SaveSettings()
	deadline := time.Now().Add(cfg.Timeout)
	m.log("save: %s (%s) sending %s", t.Title, t.ID, cfg.Prompt)
	mark, _, _ := t.outputMark()
	t.typeLine(cfg.Prompt)
	if !t.waitQuiet(mark, cfg.Idle, deadline) {
		t.setState("save_timeout")
		m.log("save: %s (%s) timed out after %s, left running", t.Title, t.ID, cfg.Timeout)
		return false
	}
	return true
}

// beginSave marks a running claude tab as saving. ok=false means not eligible.
func (t *Tab) beginSave() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !isClaudeMode(t.Mode) || !t.Running || t.State != "running" {
		return false
	}
	t.State = "saving"
	return true
}

// SaveOnly types the save prompt into a running claude tab without closing it;
// the state returns to running afterwards. Returns errors "not found" or "busy".
func (m *TabManager) SaveOnly(id string) (*Tab, error) {
	t := m.Get(id)
	if t == nil {
		return nil, errors.New("not found")
	}
	if !t.beginSave() {
		return t, errors.New("busy")
	}
	go func() {
		if m.typeSave(t) {
			t.mu.Lock()
			if t.State == "saving" && t.Running {
				t.State = "running"
			}
			t.mu.Unlock()
			m.log("save: %s (%s) saved, kept open", t.Title, t.ID)
		}
	}()
	return t, nil
}

// RunAction types the steps of a quick action into a running claude tab, each
// after the previous output went quiet; the tab shows "saving" meanwhile.
func (m *TabManager) RunAction(id string, a QuickAction) (*Tab, error) {
	t := m.Get(id)
	if t == nil {
		return nil, errors.New("not found")
	}
	if !t.beginSave() {
		return t, errors.New("busy")
	}
	t.mu.Lock()
	t.inAction = true
	t.mu.Unlock()
	go func() {
		cfg := m.store.SaveSettings()
		deadline := time.Now().Add(cfg.Timeout) // one budget for the whole action, like typeSave
		for i, step := range a.Steps {
			if _, _, running := t.outputMark(); !running {
				m.log("action: %s (%s) %q aborted at step %d, tab ended", t.Title, t.ID, a.Name, i+1)
				return
			}
			m.log("action: %s (%s) %q step %d/%d: %s", t.Title, t.ID, a.Name, i+1, len(a.Steps), step)
			mark, _, _ := t.outputMark()
			smark, _ := t.statusMark()
			t.typeLine(step)
			if ok, blocked := t.waitStep(mark, smark, cfg.Idle, deadline); blocked {
				t.setState("running")
				m.log("action: %s (%s) %q stopped at step %d, claude waits for input", t.Title, t.ID, a.Name, i+1)
				return
			} else if !ok {
				t.setState("save_timeout")
				m.log("action: %s (%s) %q timed out at step %d, stopped", t.Title, t.ID, a.Name, i+1)
				return
			}
		}
		t.mu.Lock()
		if t.State == "saving" && t.Running {
			t.State = "running"
		}
		t.mu.Unlock()
		m.log("action: %s (%s) %q done", t.Title, t.ID, a.Name)
	}()
	return t, nil
}

// SaveAll runs SaveOnly on every eligible tab and returns started/skipped ids.
func (m *TabManager) SaveAll() (started, skipped []string) {
	m.mu.Lock()
	tabs := append([]*Tab(nil), m.tabs...)
	m.mu.Unlock()
	started, skipped = []string{}, []string{}
	for _, t := range tabs {
		if _, err := m.SaveOnly(t.ID); err != nil {
			skipped = append(skipped, t.ID)
		} else {
			started = append(started, t.ID)
		}
	}
	return started, skipped
}

func (m *TabManager) runSave(t *Tab, keep bool) {
	start := time.Now()
	if !m.typeSave(t) {
		return
	}
	if _, _, running := t.outputMark(); running {
		t.setState("exiting")
		m.log("save: %s (%s) saved after %s, exiting", t.Title, t.ID, time.Since(start).Round(time.Second))
		exitDeadline := time.Now().Add(15 * time.Second)
		mark, _, _ := t.outputMark()
		t.typeLine("/exit")
		// Unless close-on-exit is set, the tab runs pwsh -NoExit around claude: once claude is gone, end the shell too.
		t.waitQuiet(mark, 2*time.Second, exitDeadline)
		if _, _, running := t.outputMark(); running {
			t.write([]byte("exit\r"))
		}
		for time.Now().Before(exitDeadline) {
			if _, _, running := t.outputMark(); !running {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		if _, _, running := t.outputMark(); running {
			m.log("save: %s (%s) did not exit, killing", t.Title, t.ID)
		}
	}
	if keep {
		m.closeKeep(t)
	} else {
		m.Close(t.ID)
	}
	m.log("save: %s (%s) closed", t.Title, t.ID)
}

// closeKeep closes a tab but keeps its workspace entry for restore.
func (m *TabManager) closeKeep(t *Tab) {
	m.mu.Lock()
	found := false
	for i, x := range m.tabs {
		if x == t {
			m.tabs = append(m.tabs[:i], m.tabs[i+1:]...)
			found = true
			break
		}
	}
	if found {
		t.mu.Lock()
		m.kept = append(m.kept, WorkspaceEntry{ProjectID: t.ProjectID, Mode: t.Mode, SessionID: t.SessionID})
		t.mu.Unlock()
	}
	m.mu.Unlock()
	if !found {
		return
	}
	t.life.Lock()
	t.mu.Lock()
	t.closed = true
	t.mu.Unlock()
	t.kill()
	t.life.Unlock()
	t.closeViewers()
	m.persistWorkspace()
}

// SaveCloseAll runs save & close on every running tab in parallel and
// returns the started tabs plus a channel closed when all have finished.
// The tabs are kept for restore, replacing entries of an earlier save & close all.
func (m *TabManager) SaveCloseAll() ([]*Tab, <-chan struct{}) {
	m.mu.Lock()
	m.kept = nil
	tabs := append([]*Tab(nil), m.tabs...)
	m.mu.Unlock()
	var wg sync.WaitGroup
	var started []*Tab
	for _, t := range tabs {
		if !t.info().Running {
			continue
		}
		x, done, err := m.saveClose(t.ID, true)
		if err != nil || done == nil {
			continue
		}
		started = append(started, x)
		wg.Add(1)
		go func() { <-done; wg.Done() }()
	}
	all := make(chan struct{})
	go func() { wg.Wait(); close(all) }()
	return started, all
}

func (m *TabManager) persistWorkspace() {
	// m.mu is held across the write so snapshots are persisted in order.
	// Lock order m.mu -> store.mu; Store never calls back into TabManager.
	m.mu.Lock()
	defer m.mu.Unlock()
	ws := make([]WorkspaceEntry, 0, len(m.tabs)+len(m.kept))
	for _, t := range m.tabs {
		t.mu.Lock()
		ws = append(ws, WorkspaceEntry{ProjectID: t.ProjectID, Mode: t.Mode, SessionID: t.SessionID})
		t.mu.Unlock()
	}
	ws = append(ws, m.kept...)
	_ = m.store.Update(func(c *Config) error { c.Workspace = ws; return nil })
}

// FastCloseAll is the shutdown path for external stops (service manager, Ctrl+C):
// no /mxSave. It persists the workspace first so every tab is resumable even if
// the process is killed mid-way, then asks claude tabs to /exit (Esc first
// cancels a running turn) and waits up to grace for them to end.
func (m *TabManager) FastCloseAll(grace time.Duration) {
	m.shuttingDown.Store(true)
	m.refreshSessions()
	m.persistWorkspace()
	_ = m.store.Update(func(c *Config) error { c.CleanShutdownAt = time.Now().UTC().Format(time.RFC3339); return nil })
	m.mu.Lock()
	tabs := append([]*Tab(nil), m.tabs...)
	m.mu.Unlock()
	for _, t := range tabs {
		if i := t.info(); i.Running && isClaudeMode(i.Mode) {
			go func(t *Tab) {
				t.write([]byte{0x1b})
				time.Sleep(200 * time.Millisecond)
				t.typeLine("/exit")
			}(t)
		}
	}
	deadline := time.Now().Add(grace)
	for time.Now().Before(deadline) {
		running := 0
		for _, t := range tabs {
			if t.info().Running {
				running++
			}
		}
		if running == 0 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	m.KillAll()
}

// Busy returns the titles of running tabs that are saving/closing or printed
// output within the last idle period (claude's spinner prints while it works).
func (m *TabManager) Busy(idle time.Duration) []string {
	m.mu.Lock()
	tabs := append([]*Tab(nil), m.tabs...)
	m.mu.Unlock()
	out := []string{}
	for _, t := range tabs {
		t.mu.Lock()
		busy := t.Running && (t.State == "saving" || t.State == "exiting" || time.Since(t.lastOut) < idle)
		title := t.Title
		t.mu.Unlock()
		if busy {
			out = append(out, title)
		}
	}
	return out
}

// KillAll is used on shutdown; it does not touch the persisted workspace.
func (m *TabManager) KillAll() {
	m.mu.Lock()
	tabs := append([]*Tab(nil), m.tabs...)
	m.mu.Unlock()
	for _, t := range tabs {
		t.kill()
	}
}

// sessionMarkerEnv are variables a running Claude Code session exports to its
// children. If the orchestrator itself was launched from inside Claude Code,
// tabs would inherit them and claude would treat itself as a child session
// (transcript persistence off, so --resume finds nothing). User-level
// CLAUDE_CODE_* settings (e.g. provider switches) are deliberately kept.
var sessionMarkerEnv = map[string]bool{
	"CLAUDECODE":                   true,
	"CLAUDE_CODE_CHILD_SESSION":    true,
	"CLAUDE_CODE_ENTRYPOINT":       true,
	"CLAUDE_CODE_SSE_PORT":         true,
	"CLAUDE_CODE_SESSION_ID":       true,
	"CLAUDE_CODE_SESSION_ATTENDED": true,
	"CLAUDE_CODE_EXECPATH":         true,
	"CLAUDE_CODE_MESSAGING_SOCKET": true,
	"CLAUDE_CODE_MESSAGING_TOKEN":  true,
	"CLAUDE_EFFORT":                true,
	"CLAUDE_PID":                   true,
}

func childEnv() []string {
	env := os.Environ()
	out := env[:0:0]
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if sessionMarkerEnv[strings.ToUpper(name)] {
			continue
		}
		out = append(out, kv)
	}
	return out
}
