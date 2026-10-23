package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

var base, origin string
var cl *http.Client
var failed bool

func check(name string, ok bool, info string) {
	s := "PASS"
	if !ok {
		s = "FAIL"
		failed = true
	}
	fmt.Printf("%s %s %s\n", s, name, info)
}

func req(method, path string, body any, org string) (int, []byte) {
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	q, _ := http.NewRequest(method, base+path, r)
	q.Header.Set("Content-Type", "application/json")
	if org != "" {
		q.Header.Set("Origin", org)
	}
	resp, err := cl.Do(q)
	if err != nil {
		return 0, []byte(err.Error())
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func dial(id, org string) (*websocket.Conn, int, error) {
	d := websocket.Dialer{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, Jar: cl.Jar}
	h := http.Header{}
	h.Set("Origin", org)
	c, resp, err := d.Dial(strings.Replace(base, "https", "wss", 1)+"/ws/tabs/"+id, h)
	code := 0
	if resp != nil {
		code = resp.StatusCode
	}
	return c, code, err
}

func readUntil(c *websocket.Conn, want string, d time.Duration) string {
	var buf bytes.Buffer
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		c.SetReadDeadline(end)
		_, m, err := c.ReadMessage()
		if err != nil {
			break
		}
		buf.Write(m)
		if strings.Count(buf.String(), want) >= 2 {
			break
		}
	}
	return buf.String()
}

func main() {
	base, origin = os.Args[1], os.Args[1]
	key, proj := os.Args[2], os.Args[3]
	jar, _ := cookiejar.New(nil)
	cl = &http.Client{Jar: jar, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}

	c, b := req("POST", "/api/login", map[string]string{"key": "wrong"}, origin)
	check("login-wrong-key", c == 401 && strings.Contains(string(b), "invalid_key"), fmt.Sprint(c, string(b)))
	c, b = req("POST", "/api/login", map[string]string{"key": key}, origin)
	u, _ := url.Parse(base)
	hasCookie := false
	for _, ck := range jar.Cookies(u) {
		if ck.Name == "mxo_session" {
			hasCookie = true
		}
	}
	check("login-right-key", c == 200 && hasCookie, fmt.Sprint(c, string(b)))
	c, b = req("GET", "/api/me", nil, "")
	check("me", c == 200 && strings.Contains(string(b), `"authenticated":true`), string(b))
	c, b = req("POST", "/api/projects", map[string]any{"name": "smoke", "path": proj, "create": true}, "https://evil.example")
	check("foreign-origin-post-rejected", c == 403, fmt.Sprint(c))
	c, b = req("POST", "/api/projects", map[string]any{"name": "smoke", "path": proj, "create": true}, origin)
	var p struct{ ID string }
	json.Unmarshal(b, &p)
	check("project-create", c < 300 && p.ID != "", fmt.Sprint(c, string(b)))
	c, b = req("GET", "/api/projects", nil, "")
	check("project-list", c == 200 && strings.Contains(string(b), p.ID), string(b))
	c, b = req("POST", "/api/tabs", map[string]any{"projectId": p.ID, "mode": "shell"}, origin)
	var t struct {
		ID      string
		Running bool
	}
	json.Unmarshal(b, &t)
	check("tab-shell", c < 300 && t.ID != "" && t.Running, fmt.Sprint(c, string(b)))

	_, code, err := dial(t.ID, "https://evil.example")
	check("ws-foreign-origin-rejected", err != nil && code == 403, fmt.Sprint(code))

	ws, code, err := dial(t.ID, origin)
	check("ws-connect", err == nil, fmt.Sprint(code, err))
	if err == nil {
		time.Sleep(2 * time.Second)
		ws.WriteJSON(map[string]any{"type": "resize", "cols": 100, "rows": 30})
		ws.WriteMessage(websocket.BinaryMessage, []byte("echo hello-mxo\r"))
		out := readUntil(ws, "hello-mxo", 10*time.Second)
		check("ws-echo", strings.Count(out, "hello-mxo") >= 2, fmt.Sprintf("count=%d", strings.Count(out, "hello-mxo")))
		ws.Close()
		ws2, _, err := dial(t.ID, origin)
		if err == nil {
			out2 := readUntil(ws2, "hello-mxo", 3*time.Second)
			check("ws-scrollback-replay", strings.Contains(out2, "hello-mxo"), "")
			ws2.Close()
		} else {
			check("ws-scrollback-replay", false, err.Error())
		}
	}
	c, b = req("GET", "/api/workspace", nil, "")
	check("workspace", c == 200 && strings.Contains(string(b), p.ID), string(b))
	c, b = req("DELETE", "/api/tabs/"+t.ID, nil, origin)
	check("tab-delete", c < 300, fmt.Sprint(c, string(b)))
	c, b = req("GET", "/api/tabs", nil, "")
	check("tabs-after-delete", c == 200 && !strings.Contains(string(b), t.ID), string(b))
	saveCloseTest(p.ID)
	c, _ = req("POST", "/api/logout", nil, origin)
	c2, _ := req("GET", "/api/tabs", nil, "")
	check("logout", c < 300 && c2 == 401, fmt.Sprint(c, c2))
	if failed {
		os.Exit(1)
	}
}

// saveCloseTest needs the server's claudeCommand pointing at a fake claude
// that echoes input lines and exits on /exit.
func saveCloseTest(projectID string) {
	c, b := req("POST", "/api/tabs/nope/save-close", nil, origin)
	check("save-close-unknown-404", c == 404, fmt.Sprint(c))
	c, b = req("POST", "/api/tabs", map[string]any{"projectId": projectID, "mode": "new"}, origin)
	var t struct {
		ID      string
		Running bool
		State   string
	}
	json.Unmarshal(b, &t)
	check("tab-fake-claude", c < 300 && t.Running && t.State == "running", fmt.Sprint(c, string(b)))
	ws, _, err := dial(t.ID, origin)
	var out bytes.Buffer
	got := make(chan struct{})
	if err == nil {
		go func() {
			defer close(got)
			for {
				ws.SetReadDeadline(time.Now().Add(90 * time.Second))
				_, m, err := ws.ReadMessage()
				if err != nil {
					return
				}
				out.Write(m)
			}
		}()
	} else {
		close(got)
	}
	time.Sleep(3 * time.Second)
	saveOnlyTest(t.ID, &out)
	c, b = req("POST", "/api/tabs/"+t.ID+"/save-close", nil, origin)
	json.Unmarshal(b, &t)
	check("save-close-202", c == 202 && t.State == "saving", fmt.Sprint(c, string(b)))
	c, b = req("POST", "/api/tabs/"+t.ID+"/save-close", nil, origin)
	check("save-close-busy-409", c == 409, fmt.Sprint(c))
	gone := false
	sawExiting := false
	end := time.Now().Add(60 * time.Second)
	for time.Now().Before(end) {
		_, b = req("GET", "/api/tabs", nil, "")
		if strings.Contains(string(b), `"state":"exiting"`) {
			sawExiting = true
		}
		if !strings.Contains(string(b), t.ID) {
			gone = true
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	check("save-close-tab-closed", gone, fmt.Sprintf("sawExiting=%v", sawExiting))
	<-got
	o := out.String()
	check("save-close-prompt-sent", strings.Contains(o, "echo:/mxSave"), "")
	check("save-close-exit-sent", strings.Contains(o, "bye-fake"), "")
	c, b = req("GET", "/api/workspace", nil, "")
	check("save-close-workspace-kept", c == 200 && strings.Contains(string(b), `"mode":"new"`), string(b))
	c, b = req("POST", "/api/workspace/save-close-all", nil, origin)
	check("save-close-all-202", c == 202, fmt.Sprint(c, string(b)))
}

// saveOnlyTest runs save-all (no close) on the fake claude tab: the prompt must
// arrive, the tab must stay running and its state must return to "running".
func saveOnlyTest(id string, out *bytes.Buffer) {
	c, b := req("POST", "/api/workspace/save-all", nil, origin)
	var r struct{ Started, Skipped []string }
	json.Unmarshal(b, &r)
	check("save-all-202", c == 202 && len(r.Started) == 1 && r.Started[0] == id, fmt.Sprint(c, string(b)))
	c, _ = req("POST", "/api/tabs/"+id+"/save", nil, origin)
	check("save-busy-409", c == 409, fmt.Sprint(c))
	back := false
	end := time.Now().Add(60 * time.Second)
	for time.Now().Before(end) {
		_, b = req("GET", "/api/tabs", nil, "")
		if strings.Contains(string(b), id) && strings.Contains(string(b), `"state":"running"`) {
			back = true
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	check("save-all-back-to-running", back && strings.Contains(string(b), `"running":true`), string(b))
	check("save-all-prompt-received", strings.Contains(out.String(), "echo:/mxSave"), "")
	c, b = req("POST", "/api/tabs/"+id+"/save", nil, origin)
	check("save-single-202", c == 202, fmt.Sprint(c, string(b)))
	for end = time.Now().Add(60 * time.Second); time.Now().Before(end); time.Sleep(500 * time.Millisecond) {
		if _, b = req("GET", "/api/tabs", nil, ""); strings.Contains(string(b), `"state":"running"`) {
			break
		}
	}
	check("save-single-back-to-running", strings.Contains(string(b), `"state":"running"`), "")
}
