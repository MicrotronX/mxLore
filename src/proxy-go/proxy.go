package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
)

// Proxy is the stdio<->HTTP bridge. It reads one JSON-RPC line at a time from
// stdin, forwards it to the MCP server, and writes the response(s) to stdout.
// Mirrors TMxStdioProxy in mx.Proxy.Core.pas.
type Proxy struct {
	cfg         *Config
	fwd         *HTTPForwarder
	outMu       sync.Mutex
	projectSlug string
	poller      *Poller
}

func NewProxy(cfg *Config) *Proxy {
	p := &Proxy{
		cfg: cfg,
		fwd: NewHTTPForwarder(cfg.ServerURL, cfg.APIKey, cfg.ConnectionTimeout, cfg.ReadTimeout),
	}

	// WorkDir override: change CWD so CLAUDE.md slug detection works even when
	// the binary lives outside the project directory.
	if cfg.WorkDir != "" {
		if dirExists(cfg.WorkDir) {
			if err := os.Chdir(cfg.WorkDir); err == nil {
				logMsg("[mxProxy] WorkDir changed to: " + cfg.WorkDir)
			} else {
				logMsg("[mxProxy] WorkDir chdir failed: " + err.Error())
			}
		} else {
			logMsg("[mxProxy] WorkDir not found: " + cfg.WorkDir)
		}
	}

	if cfg.AgentPolling && fileExists("CLAUDE.md") {
		if slug := parseSlugFromClaudeMd("CLAUDE.md"); slug != "" {
			p.projectSlug = slug
			logMsg("[mxProxy] Slug from CLAUDE.md: " + slug)
			p.startPolling(slug)
		}
	}
	return p
}

func parseSlugFromClaudeMd(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		logMsg("[mxProxy] CLAUDE.md read failed: " + err.Error())
		return ""
	}
	content := string(data)
	const marker = "**Slug:**"
	idx := strings.Index(content, marker)
	if idx < 0 {
		return ""
	}
	after := strings.TrimSpace(content[idx+len(marker):])
	after = strings.ReplaceAll(after, "`", "")
	after = strings.TrimSpace(after)
	// take the first whitespace-delimited token
	if i := strings.IndexAny(after, " \t\r\n"); i >= 0 {
		after = after[:i]
	}
	return strings.TrimSpace(after)
}

func (p *Proxy) startPolling(slug string) {
	if p.poller != nil {
		return
	}
	p.poller = NewPoller(p.cfg.ServerURL, p.cfg.APIKey, slug, p.cfg.InboxDir, p.cfg.AgentPollInterval)
	p.poller.Start()
	logMsg("[mxProxy] Agent polling started for " + slug +
		" (every " + strconv.Itoa(p.cfg.AgentPollInterval) + "s)")
}

// detectProjectFromRequest pulls params.arguments.project from a tools/call.
func detectProjectFromRequest(line string) string {
	var obj struct {
		Method string `json:"method"`
		Params struct {
			Arguments struct {
				Project string `json:"project"`
			} `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		return ""
	}
	if obj.Method != "tools/call" {
		return ""
	}
	return obj.Params.Arguments.Project
}

func makeParseError() string {
	return `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}`
}

// writeOutput emits exactly one JSON-RPC message per line. Embedded CR/LF are
// collapsed to spaces so pretty-printed server JSON can't break CC's framing.
func (p *Proxy) writeOutput(line string) {
	safe := strings.ReplaceAll(line, "\r\n", " ")
	safe = strings.ReplaceAll(safe, "\n", " ")
	safe = strings.ReplaceAll(safe, "\r", " ")

	p.outMu.Lock()
	defer p.outMu.Unlock()
	_, _ = os.Stdout.Write([]byte(safe + "\n"))
}

func (p *Proxy) handleLine(line string) {
	if strings.TrimSpace(line) == "" {
		return
	}
	if !json.Valid([]byte(line)) {
		p.writeOutput(makeParseError())
		return
	}

	// Detect project from any request to auto-start polling.
	if p.cfg.AgentPolling && p.poller == nil {
		if slug := detectProjectFromRequest(line); slug != "" {
			p.projectSlug = slug
			p.startPolling(slug)
		}
	}

	responses, _ := p.fwd.Forward(line)
	for _, r := range responses {
		// Per MCP spec, notifications produce no stdout response. The server
		// returns HTTP 202 with empty body; forwarding a blank line would
		// corrupt CC's JSON-RPC framing ("Unexpected EOF").
		if strings.TrimSpace(r) == "" {
			logDebug("[run] Skipping empty response (notification ACK)")
			continue
		}
		p.writeOutput(r)
	}
}

// Run is the stdin read loop. Go's bufio reader on a pipe blocks correctly and
// returns io.EOF only when the peer (Claude Code) actually closes stdin — none
// of the Win32 PIPE_WAIT / raw-handle workarounds the Delphi build needed.
func (p *Proxy) Run() {
	logMsg("[run] Enter Run loop")
	reader := bufio.NewReaderSize(os.Stdin, 1024*1024)
	for {
		line, err := reader.ReadString('\n')
		if len(line) > 0 {
			trimmed := strings.TrimRight(line, "\r\n")
			if trimmed != "" {
				p.safeHandle(trimmed)
			}
		}
		if err != nil {
			if err == io.EOF {
				logMsg("[run] stdin EOF — exiting Run loop")
			} else {
				logMsg("[run] stdin read error: " + err.Error())
			}
			return
		}
	}
}

// safeHandle isolates a single line so a panic on one message can't kill the
// whole transport — the session keeps serving subsequent requests.
func (p *Proxy) safeHandle(line string) {
	defer func() {
		if r := recover(); r != nil {
			logMsg(fmt.Sprintf("[run] PANIC in handleLine (recovered): %v", r))
		}
	}()
	p.handleLine(line)
}

func (p *Proxy) Close() {
	if p.poller != nil {
		p.poller.Stop()
	}
}
