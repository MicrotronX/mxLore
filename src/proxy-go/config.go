package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Config mirrors the INI consumed by the Delphi proxy (mx.Proxy.Config.pas).
type Config struct {
	ServerURL         string
	APIKey            string
	ConnectionTimeout int // ms
	ReadTimeout       int // ms
	AgentPolling      bool
	AgentPollInterval int // s
	InboxDir          string
	WorkDir           string
	LogLevel          string
}

type iniFile map[string]map[string]string

// parseINI is a minimal, dependency-free INI reader matching Delphi TIniFile
// semantics: case-insensitive sections/keys, ';' and '#' line comments,
// value = everything after the first '=' (no inline-comment stripping).
func parseINI(path string) (iniFile, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	result := iniFile{}
	section := ""
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		// strip a UTF-8 BOM on the very first line if present
		line = strings.TrimPrefix(line, "\xef\xbb\xbf")
		if line == "" || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			if result[section] == nil {
				result[section] = map[string]string{}
			}
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(line[:eq]))
		val := strings.TrimSpace(line[eq+1:])
		if result[section] == nil {
			result[section] = map[string]string{}
		}
		result[section][key] = val
	}
	return result, sc.Err()
}

func (ini iniFile) getString(section, key, def string) string {
	if s, ok := ini[strings.ToLower(section)]; ok {
		if v, ok := s[strings.ToLower(key)]; ok {
			return v
		}
	}
	return def
}

func (ini iniFile) getInt(section, key string, def int) int {
	v := strings.TrimSpace(ini.getString(section, key, ""))
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

func (ini iniFile) getBool(section, key string, def bool) bool {
	v := strings.ToLower(strings.TrimSpace(ini.getString(section, key, "")))
	switch v {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return def
}

// LoadConfig reads and validates the INI at path.
func LoadConfig(path string) (*Config, error) {
	ini, err := parseINI(path)
	if err != nil {
		return nil, err
	}
	c := &Config{}
	c.ServerURL = ini.getString("Server", "Url", "")
	c.APIKey = ini.getString("Server", "ApiKey", "")
	c.ConnectionTimeout = ini.getInt("Server", "ConnectionTimeout", 10000)
	c.ReadTimeout = ini.getInt("Server", "ReadTimeout", 120000)
	c.AgentPolling = ini.getBool("Agent", "Polling", false)
	c.AgentPollInterval = ini.getInt("Agent", "PollInterval", 15)
	if c.AgentPollInterval < 5 {
		c.AgentPollInterval = 5
	}
	c.InboxDir = ini.getString("Agent", "InboxDir", "")
	if c.InboxDir == "" {
		c.InboxDir = filepath.Join(filepath.Dir(path), "agent_inbox")
	}
	c.WorkDir = ini.getString("Agent", "WorkDir", "")
	c.LogLevel = ini.getString("General", "LogLevel", "info")
	return c, nil
}

const defaultINI = `[Server]
; URL of the mxLore MCP server
Url=https://YOUR-SERVER/mxLore/mcp
; API key for developer identification (from Admin UI)
ApiKey=YOUR_API_KEY_HERE
; TCP connection timeout in ms (Default: 10000)
ConnectionTimeout=10000
; Response/read timeout in ms (Default: 120000)
ReadTimeout=120000

[General]
; Log verbosity. info=production-clean (startup+errors+warnings),
; debug=hot-path tracing. Enable debug only for bug hunts.
LogLevel=info

[Agent]
; Multi-agent messaging: proxy polls inbox and writes to file.
Polling=1
; Poll interval in seconds (Default: 15, Minimum: 5).
PollInterval=15
`

func writeDefaultINI(path string) error {
	return os.WriteFile(path, []byte(defaultINI), 0644)
}
