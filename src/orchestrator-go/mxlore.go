package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const mxLoreTimeout = 5 * time.Second

// mxLoreDeveloper is the identity GET /api/whoami returns for a valid key.
type mxLoreDeveloper struct {
	ID   int    `json:"developer_id"`
	Name string `json:"name"`
	Role string `json:"role"`
}

var (
	errMxLoreUnauthorized = errors.New("mxlore: unauthorized")
	errMxLoreUnreachable  = errors.New("mxlore: unreachable")
)

// mxLoreClient follows no redirects: the key must only ever go to the configured host.
var mxLoreClient = &http.Client{
	Timeout:       mxLoreTimeout,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// validateMxLoreURL accepts an absolute http(s) base URL without query or fragment.
func validateMxLoreURL(raw string) (string, error) {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		return "", fmt.Errorf("%q is not a valid http(s) base URL", raw)
	}
	// The key travels in a header; plain http is only acceptable on this machine.
	if u.Scheme == "http" {
		if ip := net.ParseIP(u.Hostname()); !strings.EqualFold(u.Hostname(), "localhost") && (ip == nil || !ip.IsLoopback()) {
			return "", fmt.Errorf("%q must use https for a server on another machine", raw)
		}
	}
	return raw, nil
}

// mxLoreWhoami asks the mxLore server who owns key. It returns
// errMxLoreUnauthorized for a rejected key and errMxLoreUnreachable for
// everything else (network error, timeout, redirect, unexpected answer).
// The key is only placed in the request header and never logged.
func mxLoreWhoami(base, key string) (mxLoreDeveloper, error) {
	var d mxLoreDeveloper
	req, err := http.NewRequest(http.MethodGet, base+"/api/whoami", nil)
	if err != nil {
		return d, errMxLoreUnreachable
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Accept", "application/json")
	resp, err := mxLoreClient.Do(req)
	if err != nil {
		return d, errMxLoreUnreachable
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusUnauthorized, http.StatusForbidden:
		return d, errMxLoreUnauthorized
	default:
		return d, errMxLoreUnreachable
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64*1024)).Decode(&d); err != nil || d.ID <= 0 {
		return mxLoreDeveloper{}, errMxLoreUnreachable
	}
	return d, nil
}
