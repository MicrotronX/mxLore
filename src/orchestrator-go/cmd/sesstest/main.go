// sesstest checks that login sessions survive a server restart. It signs in
// with the one-time recovery key (--recovery) of the first run.
// Usage: sesstest <orchestrator.exe> <datadir> <port>
package main

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

var failed bool

func check(name string, ok bool, info string) {
	s := "PASS"
	if !ok {
		s = "FAIL"
		failed = true
	}
	fmt.Printf("%s %s %s\n", s, name, info)
}

// start launches the server and returns the process and the printed recovery key (if any).
func start(exe, dir, addr string, recovery bool) (*exec.Cmd, string) {
	args := []string{"--data", dir, "--listen", addr}
	if recovery {
		args = append(args, "--recovery")
	}
	cmd := exec.Command(exe, args...)
	pr, pw := io.Pipe()
	cmd.Stdout, cmd.Stderr = pw, pw
	if err := cmd.Start(); err != nil {
		fmt.Println("FAIL start", err)
		os.Exit(1)
	}
	keyCh := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(pr)
		next, key := false, ""
		for sc.Scan() {
			l := sc.Text()
			if next {
				key, next = strings.TrimSpace(l), false
			}
			if strings.Contains(l, "Recovery key") {
				next = true
			}
			if strings.Contains(l, "listening on") {
				keyCh <- key
			}
		}
	}()
	select {
	case k := <-keyCh:
		time.Sleep(300 * time.Millisecond)
		return cmd, k
	case <-time.After(20 * time.Second):
		cmd.Process.Kill()
		fmt.Println("FAIL server did not start")
		os.Exit(1)
	}
	return nil, ""
}

func stop(cmd *exec.Cmd) {
	cmd.Process.Kill() // by PID
	cmd.Wait()
}

func main() {
	exe, dir, port := os.Args[1], os.Args[2], os.Args[3]
	os.RemoveAll(dir)
	os.MkdirAll(dir, 0o700)
	addr := "127.0.0.1:" + port
	base := "https://" + addr
	jar, _ := cookiejar.New(nil)
	cl := &http.Client{Jar: jar, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	do := func(method, path, body string) (int, string, *http.Response) {
		q, _ := http.NewRequest(method, base+path, strings.NewReader(body))
		q.Header.Set("Content-Type", "application/json")
		if method != "GET" {
			q.Header.Set("Origin", base)
		}
		r, err := cl.Do(q)
		if err != nil {
			return 0, err.Error(), nil
		}
		defer r.Body.Close()
		b, _ := io.ReadAll(r.Body)
		return r.StatusCode, string(b), r
	}

	srv, key := start(exe, dir, addr, true)
	check("key-printed", key != "", "")
	sc, err := os.ReadFile(filepath.Join(dir, "setup-code.txt"))
	check("setup-code-file", err == nil && len(strings.TrimSpace(string(sc))) > 0, fmt.Sprint(err))
	c, b, resp := do("POST", "/api/login", `{"key":"`+key+`"}`)
	var tok string
	maxAge := 0
	if resp != nil {
		for _, ck := range resp.Cookies() {
			if ck.Name == "mxo_session" {
				tok, maxAge = ck.Value, ck.MaxAge
			}
		}
	}
	check("login", c == 200 && tok != "", fmt.Sprint(c, b))
	check("cookie-max-age-7d", maxAge == 7*24*3600, fmt.Sprint(maxAge))
	c, b, _ = do("GET", "/api/me", "")
	check("me-before-restart", strings.Contains(b, `"authenticated":true`), b)

	stop(srv)
	raw, err := os.ReadFile(filepath.Join(dir, "sessions.json"))
	check("sessions-json-exists", err == nil && len(raw) > 2, fmt.Sprint(err))
	check("sessions-json-no-raw-token", tok != "" && !strings.Contains(string(raw), tok), "")

	srv, key2 := start(exe, dir, addr, false)
	check("no-key-without-recovery", key2 == "", "")
	u, _ := url.Parse(base)
	same := false
	for _, ck := range jar.Cookies(u) {
		same = same || (ck.Name == "mxo_session" && ck.Value == tok)
	}
	c, b, _ = do("GET", "/api/me", "")
	check("me-after-restart", same && strings.Contains(b, `"authenticated":true`), b)
	c, _, _ = do("GET", "/api/tabs", "")
	check("tabs-after-restart-200", c == 200, fmt.Sprint(c))
	q0, _ := http.NewRequest("POST", base+"/api/login", strings.NewReader(`{"key":"`+key+`"}`))
	q0.Header.Set("Content-Type", "application/json")
	q0.Header.Set("Origin", base)
	r0, err := (&http.Client{Transport: cl.Transport}).Do(q0)
	c0 := 0
	if err == nil {
		c0 = r0.StatusCode
		r0.Body.Close()
	}
	check("recovery-key-dead-after-restart", c0 == 401, fmt.Sprint(c0))
	c, _, _ = do("POST", "/api/logout", "")
	check("logout", c == 200, fmt.Sprint(c))
	// re-send the old token explicitly (jar dropped it on logout)
	q, _ := http.NewRequest("GET", base+"/api/tabs", nil)
	q.AddCookie(&http.Cookie{Name: "mxo_session", Value: tok})
	r2, err := (&http.Client{Transport: cl.Transport}).Do(q)
	code := 0
	if err == nil {
		code = r2.StatusCode
		r2.Body.Close()
	}
	check("old-token-401-after-logout", code == 401, fmt.Sprint(code))
	stop(srv)
	raw, _ = os.ReadFile(filepath.Join(dir, "sessions.json"))
	check("sessions-json-empty-after-logout", strings.TrimSpace(string(raw)) == "{}", string(raw))
	if failed {
		os.Exit(1)
	}
}
