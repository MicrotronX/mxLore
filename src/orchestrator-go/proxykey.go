package main

import (
	"bufio"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// deviceIDPath is the device.id file the mxLore proxy uses; "" if unknown.
func deviceIDPath() string {
	if runtime.GOOS == "windows" {
		if d := os.Getenv("LOCALAPPDATA"); d != "" {
			return filepath.Join(d, "mxLore", "device.id")
		}
	}
	d, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(d, "mxLore", "device.id")
}

// readDeviceID returns the proxy's device id, or "" when the file is missing
// or does not hold a plausible id. It never creates the file.
func readDeviceID() string {
	p := deviceIDPath()
	if p == "" {
		return ""
	}
	b, err := os.ReadFile(p)
	if err != nil || len(b) > 128 {
		return ""
	}
	id := strings.TrimSpace(string(b))
	for _, r := range id {
		if !(r == '-' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
			return ""
		}
	}
	return id
}

// readProxyKey returns [Server] ApiKey from the mxLore proxy INI
// (~/.claude/mxMCPProxy.ini), or "". The key stays on the server side.
func readProxyKey() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return parseProxyKey(filepath.Join(home, ".claude", "mxMCPProxy.ini"))
}

func parseProxyKey(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 4096), 64*1024)
	inServer := false
	for sc.Scan() {
		line := strings.TrimSpace(strings.TrimPrefix(sc.Text(), "\ufeff"))
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			inServer = strings.EqualFold(strings.TrimSpace(line[1:len(line)-1]), "Server")
			continue
		}
		if !inServer {
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok && strings.EqualFold(strings.TrimSpace(k), "ApiKey") {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// hostOf returns the host part of an mxLore base URL for log lines.
func hostOf(base string) string {
	if u, err := url.Parse(base); err == nil && u.Host != "" {
		return u.Host
	}
	return base
}

// otpLabel returns the authenticator account name "<name>@<hostname>".
func otpLabel(name string) string {
	if strings.TrimSpace(name) == "" {
		name = "admin"
	}
	h, err := os.Hostname()
	if err != nil || h == "" {
		h = "localhost"
	}
	return name + "@" + h
}

// isLoopbackClient reports whether the TCP peer is this machine; forwarded
// headers are ignored on purpose.
func isLoopbackClient(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// localClient reports whether a request may use the stored proxy key in place
// of a typed key: the TCP peer is this machine and no reverse proxy is
// configured. Behind a proxy (allowed-hosts.txt) every remote client arrives
// from loopback, so the peer address proves nothing there.
func (s *Server) localClient(r *http.Request) bool {
	return isLoopbackClient(r) && !s.guard.proxied()
}
