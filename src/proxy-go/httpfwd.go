package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// HTTPForwarder forwards a single JSON-RPC line to the mxLore MCP server over
// HTTP and returns the response line(s). It owns the MCP session id and
// transparently re-initializes a stale session (mirrors mx.Proxy.Http.pas).
type HTTPForwarder struct {
	url       string
	apiKey    string
	client    *http.Client
	sessionID string
}

func NewHTTPForwarder(url, apiKey string, connTimeoutMs, readTimeoutMs int) *HTTPForwarder {
	return &HTTPForwarder{
		url:    url,
		apiKey: apiKey,
		client: &http.Client{
			// Overall ceiling = read timeout; dial gets its own shorter budget.
			Timeout: time.Duration(readTimeoutMs) * time.Millisecond,
			Transport: &http.Transport{
				DialContext: (&net.Dialer{
					Timeout: time.Duration(connTimeoutMs) * time.Millisecond,
				}).DialContext,
			},
		},
	}
}

func (h *HTTPForwarder) buildError(id json.RawMessage, code int, message string) string {
	idVal := "null"
	if len(id) > 0 && string(id) != "null" {
		idVal = string(id)
	}
	msgBytes, _ := json.Marshal(message)
	return fmt.Sprintf(`{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":%s}}`,
		idVal, code, string(msgBytes))
}

// parseSSE extracts the concatenated "data:" payloads from a text/event-stream
// body, one entry per SSE event (blank-line separated).
func parseSSE(body string) []string {
	lines := strings.Split(body, "\n")
	var result []string
	current := ""
	for _, ln := range lines {
		ln = strings.TrimRight(ln, "\r")
		if strings.HasPrefix(ln, "data:") {
			d := strings.TrimLeft(ln[5:], " ")
			if current != "" {
				current = current + "\n" + d
			} else {
				current = d
			}
		} else if ln == "" && current != "" {
			result = append(result, current)
			current = ""
		}
		// event:, id:, retry: lines are ignored
	}
	if current != "" {
		result = append(result, current)
	}
	return result
}

// reInitialize performs the MCP initialize + notifications/initialized
// handshake to recover from a stale session / server restart.
func (h *HTTPForwarder) reInitialize() bool {
	logMsg("INFO: Re-Initialize MCP session...")

	initBody := `{"jsonrpc":"2.0","id":"_reinit","method":"initialize","params":{` +
		`"protocolVersion":"2024-11-05","capabilities":{},` +
		`"clientInfo":{"name":"mxMCPProxy","version":"` + proxyVersion + `"}}}`

	req, err := http.NewRequest("POST", h.url, strings.NewReader(initBody))
	if err != nil {
		logMsg("ERROR: Re-Initialize request build failed: " + err.Error())
		return false
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+h.apiKey)
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Mcp-Session-Id", "")

	resp, err := h.client.Do(req)
	if err != nil {
		logMsg("ERROR: Re-Initialize failed: " + err.Error())
		return false
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if !(resp.StatusCode == 200 || resp.StatusCode == 201 || resp.StatusCode == 202) {
		logMsg("ERROR: Re-Initialize failed: HTTP " + strconv.Itoa(resp.StatusCode))
		return false
	}
	if sid := resp.Header.Get("Mcp-Session-Id"); sid != "" {
		h.sessionID = sid
	}

	// initialized notification (no response expected)
	notif := `{"jsonrpc":"2.0","method":"notifications/initialized"}`
	req2, err := http.NewRequest("POST", h.url, strings.NewReader(notif))
	if err == nil {
		req2.Header.Set("Content-Type", "application/json")
		req2.Header.Set("Authorization", "Bearer "+h.apiKey)
		if h.sessionID != "" {
			req2.Header.Set("Mcp-Session-Id", h.sessionID)
		}
		if resp2, e := h.client.Do(req2); e == nil {
			_, _ = io.Copy(io.Discard, resp2.Body)
			resp2.Body.Close()
		}
	}

	logMsg("INFO: Re-Initialize OK, new session: " + h.sessionID)
	return true
}

// Forward sends one JSON-RPC line and returns the response line(s).
// newSessionID is the session id observed on the response (also stored
// internally), reported for logging/visibility.
func (h *HTTPForwarder) Forward(jsonRPCLine string) (responses []string, newSessionID string) {
	logDebug("[http] Forward entry. len=" + strconv.Itoa(len(jsonRPCLine)) + " session=" + h.sessionID)

	// Extract request id for error responses.
	var reqID json.RawMessage
	var probe map[string]json.RawMessage
	if err := json.Unmarshal([]byte(jsonRPCLine), &probe); err == nil {
		if id, ok := probe["id"]; ok {
			reqID = id
		}
	}

	for retry := 0; retry <= 1; retry++ {
		req, err := http.NewRequest("POST", h.url, strings.NewReader(jsonRPCLine))
		if err != nil {
			return []string{h.buildError(reqID, -32603, err.Error())}, newSessionID
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+h.apiKey)
		req.Header.Set("Accept", "application/json, text/event-stream")
		if h.sessionID != "" {
			req.Header.Set("Mcp-Session-Id", h.sessionID)
		}

		resp, err := h.client.Do(req)
		if err != nil {
			if retry == 0 {
				logMsg("WARN: Connection error, retry in 1s: " + err.Error())
				time.Sleep(1 * time.Second)
				continue
			}
			return []string{h.buildError(reqID, -32000, "MCP server unreachable")}, newSessionID
		}

		if sid := resp.Header.Get("Mcp-Session-Id"); sid != "" {
			h.sessionID = sid
			newSessionID = sid
		}

		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		ct := strings.ToLower(resp.Header.Get("Content-Type"))

		switch {
		case resp.StatusCode == 200 || resp.StatusCode == 201 || resp.StatusCode == 202:
			if strings.Contains(ct, "text/event-stream") {
				responses = parseSSE(string(body))
			} else {
				responses = []string{string(body)}
			}
			logDebug("[http] Forward return. result_count=" + strconv.Itoa(len(responses)) + " session=" + h.sessionID)
			return responses, newSessionID

		case resp.StatusCode == 401 || resp.StatusCode == 403:
			return []string{h.buildError(reqID, -32001, "Authentication failed")}, newSessionID

		case resp.StatusCode == 400 || resp.StatusCode == 404:
			if retry == 0 && h.reInitialize() {
				newSessionID = h.sessionID
				logMsg("INFO: Re-Initialize successful, retry with new session")
				continue
			}
			return []string{h.buildError(reqID, -32002,
				fmt.Sprintf("Server error: HTTP %d", resp.StatusCode))}, newSessionID

		default:
			return []string{h.buildError(reqID, -32002,
				fmt.Sprintf("Server error: HTTP %d", resp.StatusCode))}, newSessionID
		}
	}
	return responses, newSessionID
}
