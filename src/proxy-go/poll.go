package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Poller polls the server agent-inbox endpoint and writes new messages to a
// JSON file that the Claude Code hook consumes; it ACKs once the file is gone.
// Mirrors TMxAgentPollThread in mx.Proxy.Core.pas.
type Poller struct {
	serverURL string
	apiKey    string
	project   string
	inboxDir  string
	interval  int

	client     *http.Client
	writtenIDs string
	knownIDs   map[int]bool

	stopCh   chan struct{}
	doneCh   chan struct{}
	stopOnce sync.Once
}

func NewPoller(serverURL, apiKey, project, inboxDir string, interval int) *Poller {
	p := &Poller{
		serverURL: serverURL,
		apiKey:    apiKey,
		project:   project,
		inboxDir:  inboxDir,
		interval:  interval,
		client:    &http.Client{Timeout: 5 * time.Second},
		knownIDs:  map[int]bool{},
		stopCh:    make(chan struct{}),
		doneCh:    make(chan struct{}),
	}
	if err := os.MkdirAll(inboxDir, 0755); err != nil {
		logMsg("[poll] MkdirAll failed: " + err.Error())
	}
	// Restore known-IDs from disk — survives proxy restarts, prevents the
	// accumulation-gap where un-acked messages get rewritten on every startup.
	p.loadKnownIDs()
	return p
}

func (p *Poller) inboxFile() string { return filepath.Join(p.inboxDir, "agent_inbox_"+p.project+".json") }
func (p *Poller) tmpFile() string   { return filepath.Join(p.inboxDir, "agent_inbox_"+p.project+".tmp") }
func (p *Poller) knownFile() string { return filepath.Join(p.inboxDir, "known_ids_"+p.project+".txt") }

func (p *Poller) Start() { go p.run() }

func (p *Poller) Stop() {
	p.stopOnce.Do(func() { close(p.stopCh) })
	<-p.doneCh
}

func (p *Poller) run() {
	defer close(p.doneCh)
	url := p.serverURL + "?agent_inbox=" + p.project
	logDebug("[poll] run entry. URL=" + url)
	for {
		p.checkAndAck()
		p.pollOnce(url)
		select {
		case <-p.stopCh:
			logDebug("[poll] stop signaled")
			return
		case <-time.After(time.Duration(p.interval) * time.Second):
		}
	}
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
		return
	}

	var newMsgs []json.RawMessage
	var newIDs []string
	for _, m := range parsed.Messages {
		var idObj struct {
			ID int `json:"id"`
		}
		if err := json.Unmarshal(m, &idObj); err != nil {
			continue
		}
		if idObj.ID > 0 && !p.knownIDs[idObj.ID] {
			p.knownIDs[idObj.ID] = true
			newMsgs = append(newMsgs, m)
			newIDs = append(newIDs, strconv.Itoa(idObj.ID))
		}
	}
	if len(newMsgs) == 0 {
		return
	}

	idsStr := strings.Join(newIDs, ",")
	msgsJSON, err := json.Marshal(newMsgs)
	if err != nil {
		logMsg("[poll] marshal messages failed: " + err.Error())
		return
	}
	fileObj := fmt.Sprintf(`{"v":1,"ts":%q,"ids":%q,"messages":%s}`,
		time.Now().Format("2006-01-02T15:04:05"), idsStr, string(msgsJSON))
	p.writeInboxFile(fileObj, idsStr)
	// Persist FKnownIds so a restart does not re-consider these IDs "new".
	p.saveKnownIDs()
}

// writeInboxFile writes atomically: .tmp first (no BOM — bash hooks can't
// handle it), then rename to .json (retry on transient failure).
func (p *Poller) writeInboxFile(jsonStr, ids string) {
	tmp := p.tmpFile()
	dst := p.inboxFile()
	if err := os.WriteFile(tmp, []byte(jsonStr), 0644); err != nil {
		logMsg("[mxProxy] write inbox tmp failed: " + err.Error())
		return
	}
	var renameErr error
	for retry := 1; retry <= 3; retry++ {
		renameErr = os.Rename(tmp, dst)
		if renameErr == nil {
			p.writtenIDs = ids
			return
		}
		if retry < 3 {
			time.Sleep(50 * time.Millisecond)
		}
	}
	_ = os.Remove(tmp)
	logMsg("[mxProxy] Failed to write inbox file after 3 retries: " + renameErr.Error())
}

// checkAndAck sends an ACK once the hook has consumed (deleted) the inbox file.
func (p *Poller) checkAndAck() {
	if p.writtenIDs == "" {
		return
	}
	if fileExists(p.inboxFile()) {
		return
	}
	req, err := http.NewRequest("GET", p.serverURL+"?agent_ack="+p.writtenIDs, nil)
	if err == nil {
		req.Header.Set("Authorization", "Bearer "+p.apiKey)
		if resp, e := p.client.Do(req); e == nil {
			resp.Body.Close()
		} else {
			logMsg("[mxProxy] ACK failed: " + e.Error())
		}
	}
	// Clear regardless of ACK success (prevent infinite retry).
	p.writtenIDs = ""
	p.knownIDs = map[int]bool{}
	_ = os.Remove(p.knownFile())
}

func (p *Poller) loadKnownIDs() {
	f, err := os.Open(p.knownFile())
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(strings.TrimPrefix(sc.Text(), "\xef\xbb\xbf"))
		if id, err := strconv.Atoi(line); err == nil && id > 0 {
			p.knownIDs[id] = true
		}
	}
	logDebug("[poll] Loaded " + strconv.Itoa(len(p.knownIDs)) + " known IDs from disk")
}

func (p *Poller) saveKnownIDs() {
	var sb strings.Builder
	for id := range p.knownIDs {
		sb.WriteString(strconv.Itoa(id))
		sb.WriteString("\n")
	}
	if err := os.WriteFile(p.knownFile(), []byte(sb.String()), 0644); err != nil {
		logMsg("[poll] saveKnownIDs failed: " + err.Error())
	}
}
