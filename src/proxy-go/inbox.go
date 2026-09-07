package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Poller fetches pending agent messages for this project and injects them
// straight into the Claude Code session that spawned this proxy (FR#15127,
// Spec#15135). Mirrors TMxAgentPollThread in mx.Proxy.Poll.pas.
//
// Claude Code exports CLAUDE_CODE_MESSAGING_SOCKET (unix socket on macOS/Linux,
// named pipe on Windows) and CLAUDE_CODE_MESSAGING_TOKEN to every child
// process. One proxy = one session. A line written there arrives as an
// own-child message and wakes an idle session. No buffer file, no hook.
//
//   - Separation is the project slug: one proxy serves one project, the
//     server's project + key filters decide what this session receives. Two
//     sessions on the SAME project both get the message (deterministic
//     broadcast; the first ack archives it, the second ack is a no-op).
//   - Per poll, every row not injected yet — or injected more than 10 minutes
//     ago and still pending — is rendered, in server order, into ONE user
//     line over ONE connection.
//   - The proxy never acks: the injected text tells the model to call
//     mx_agent_ack. Ack-by-reader is the only real delivery proof.
//   - injected lives in memory only; a restart re-injects what is still
//     pending, at most once per 10 minutes.
//   - Without the env vars nothing is injected.
type Poller struct {
	serverURL string
	apiKey    string
	project   string
	interval  int
	sockPath  string // "" => no session inbox
	sockToken string

	client       *http.Client
	injected     map[int]time.Time // id -> when it was injected
	noSockLogged bool

	stopCh   chan struct{}
	doneCh   chan struct{}
	stopOnce sync.Once
}

// reinjectAfter: a row injected this long ago and still pending is offered again.
const reinjectAfter = 10 * time.Minute

func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func NewPoller(serverURL, apiKey, project string, interval int) *Poller {
	p := &Poller{
		serverURL:  serverURL,
		apiKey:     apiKey,
		project:    project,
		interval:   interval,
		sockPath:   os.Getenv("CLAUDE_CODE_MESSAGING_SOCKET"),
		sockToken:  os.Getenv("CLAUDE_CODE_MESSAGING_TOKEN"),
		client:     &http.Client{Timeout: 5 * time.Second},
		injected:   map[int]time.Time{},
		stopCh:     make(chan struct{}),
		doneCh:     make(chan struct{}),
	}
	if p.sockPath == "" {
		logMsg("[poll] no CLAUDE_CODE_MESSAGING_SOCKET in environment - messages stay " +
			"pending on the server for mx_agent_inbox (bare mode / old client?)")
	} else {
		logDebug("[poll] session inbox=" + p.sockPath)
	}
	return p
}

func (p *Poller) Start() { go p.run() }

func (p *Poller) Stop() {
	p.stopOnce.Do(func() { close(p.stopCh) })
	<-p.doneCh
}

func (p *Poller) run() {
	defer close(p.doneCh)
	url := p.serverURL + "?agent_inbox=" + p.project
	logDebug("[poll] URL=" + url)
	for {
		p.pollOnce(url)
		select {
		case <-p.stopCh:
			return
		case <-time.After(time.Duration(p.interval) * time.Second):
		}
	}
}

type inboxRow struct {
	ID int `json:"id"`
}

func (p *Poller) pollOnce(url string) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return
	}
	req.Header.Set("Authorization", "Bearer "+p.apiKey)
	resp, err := p.client.Do(req)
	if err != nil {
		logMsg("[mxProxy] Agent poll error: " + err.Error())
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return
	}

	var parsed struct {
		Count    int               `json:"count"`
		Messages []json.RawMessage `json:"messages"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return
	}
	if parsed.Count <= 0 || len(parsed.Messages) == 0 {
		// Nothing pending => everything injected so far was acked or expired.
		p.injected = map[int]time.Time{}
		return
	}

	seen := map[int]bool{}
	var out []json.RawMessage
	var ids []string
	var pending []int
	for _, m := range parsed.Messages {
		var r inboxRow
		if err := json.Unmarshal(m, &r); err != nil || r.ID <= 0 {
			continue
		}
		seen[r.ID] = true
		// Injected less than reinjectAfter ago => the session has it, wait for
		// the ack. Older and still pending => offer it again (Spec#15135 R3).
		if t, ok := p.injected[r.ID]; ok && time.Since(t) < reinjectAfter {
			continue
		}
		out = append(out, m)
		ids = append(ids, strconv.Itoa(r.ID))
		pending = append(pending, r.ID)
	}
	// Forget ids the server no longer returns so the set tracks pending.
	for id := range p.injected {
		if !seen[id] {
			delete(p.injected, id)
		}
	}
	if len(out) == 0 {
		return
	}
	if p.sockPath == "" {
		if !p.noSockLogged {
			logMsg("[poll] " + strconv.Itoa(len(out)) + " pending message(s), no session " +
				"inbox - read them with mx_agent_inbox")
			p.noSockLogged = true
		}
		return
	}

	idsStr := strings.Join(ids, ",")
	// Commit ONLY after the write is proven (Lesson#14130); on failure the
	// next poll retries the very same rows.
	if !p.injectIntoSession(p.renderBatch(out, idsStr)) {
		return
	}
	now := time.Now()
	for _, id := range pending {
		p.injected[id] = now
	}
	logMsg("[poll] injected " + strconv.Itoa(len(out)) + " message(s) into session (ids " + idsStr + ")")
}

// renderBatch produces the same text the UserPromptSubmit hook injected before
// FR#15127, so the model's handling rules do not change.
func (p *Poller) renderBatch(msgs []json.RawMessage, ids string) string {
	msgsJSON, err := json.Marshal(msgs)
	if err != nil {
		return ""
	}
	env := fmt.Sprintf(`{"v":2,"ts":%q,"ids":%q,"messages":%s}`,
		time.Now().Format("2006-01-02T15:04:05"), ids, string(msgsJSON))
	return "[Agent-Inbox] Messages for " + p.project + " (delivered by mxMCPProxy):\n" +
		env + "\n" +
		"Act on these as their content requires, then: mx_agent_ack\n" +
		"A reply is NOT the default. Send one only if the sender needs a decision, " +
		"an answer, or a correction from you. Acknowledging without replying is the " +
		"normal case and ends the exchange.\n" +
		"When YOU send: silence back means 'handled, nothing needed'. If you need " +
		"confirmation that it was processed, ask for it in the message itself - " +
		"there is no read receipt."
}

// openSessionInbox connects to the session's inbox: named pipe on Windows
// (plain file open on \\.\pipe\...), unix domain socket elsewhere.
func openSessionInbox(path string) (interface {
	Write([]byte) (int, error)
	Close() error
}, error) {
	if strings.HasPrefix(path, `\\.\pipe\`) {
		return os.OpenFile(path, os.O_RDWR, 0)
	}
	return net.DialTimeout("unix", path, 5*time.Second)
}

// injectIntoSession writes the auth line and ONE user line, then closes.
// Reports whether every byte was written; the caller must not record the
// rows as injected otherwise.
func (p *Poller) injectIntoSession(content string) bool {
	if p.sockPath == "" || content == "" {
		return false
	}
	auth, err := json.Marshal(map[string]string{"type": "auth", "token": p.sockToken})
	if err != nil {
		return false
	}
	// `content` MUST be a non-empty string or Claude Code drops the line
	// silently; `uuid` is its duplicate-suppression identity.
	user, err := json.Marshal(map[string]interface{}{
		"type": "user",
		"uuid": newUUID(),
		"message": map[string]string{
			"role":    "user",
			"content": content,
		},
	})
	if err != nil {
		return false
	}
	payload := append(append(auth, '\n'), append(user, '\n')...)

	// Open only now, with the payload ready: Claude Code closes a connection
	// that has not sent a complete line within 30 s.
	c, err := openSessionInbox(p.sockPath)
	if err != nil {
		logMsg("[poll] session inbox open failed: " + err.Error())
		return false
	}
	defer c.Close()
	n, err := c.Write(payload)
	if err != nil {
		logMsg("[poll] session inbox write failed: " + err.Error())
		return false
	}
	if n != len(payload) {
		logMsg("[poll] session inbox short write " + strconv.Itoa(n) + "/" + strconv.Itoa(len(payload)))
		return false
	}
	return true
}
