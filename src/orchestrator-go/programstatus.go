package main

import (
	"bytes"
	"strings"
)

// Claude Code reports its state with OSC 7501 ("program status", see
// code.claude.com/docs/en/terminal-config, "See session status in your
// terminal") once the terminal answered its probe "OSC 7501 ; ?":
//   ESC ] 7501 ; state=<working|blocked|idle|done|error>:app=claude-code[:key=value...] BEL|ST
// The server answers the probe itself, so the state is known without a browser.

var osc7501Prefix = []byte("\x1b]7501;")

// osc7501Reply acknowledges the probe; Claude only checks for an OSC 7501 reply starting with "?".
var osc7501Reply = []byte("\x1b]7501;?\x1b\\")

const osc7501MaxLen = 4096

type programStatusScanner struct {
	carry []byte
}

// scan returns whether the chunk held a probe and the last reported state ("" if none).
// Sequences split across reads are carried over to the next call.
func (s *programStatusScanner) scan(b []byte) (probe bool, state string) {
	data := b
	if len(s.carry) > 0 {
		data = append(s.carry, b...)
		s.carry = nil
	}
	for {
		i := bytes.Index(data, osc7501Prefix)
		if i < 0 {
			// Keep a tail that may be the start of a prefix cut by the read.
			if k := len(osc7501Prefix) - 1; len(data) > k {
				data = data[len(data)-k:]
			}
			if j := bytes.IndexByte(data, 0x1b); j >= 0 {
				s.carry = append([]byte(nil), data[j:]...)
			}
			return
		}
		rest := data[i+len(osc7501Prefix):]
		end, term := -1, 0
		if j := bytes.IndexByte(rest, 0x07); j >= 0 {
			end, term = j, 1
		}
		if j := bytes.Index(rest, []byte("\x1b\\")); j >= 0 && (end < 0 || j < end) {
			end, term = j, 2
		}
		if end < 0 {
			if len(rest) < osc7501MaxLen {
				s.carry = append([]byte(nil), data[i:]...)
			}
			return
		}
		payload := string(rest[:end])
		if strings.HasPrefix(payload, "?") {
			probe = true
		} else {
			for _, f := range strings.Split(payload, ":") {
				if v, ok := strings.CutPrefix(f, "state="); ok {
					state = v
				}
			}
		}
		data = rest[end+term:]
	}
}
