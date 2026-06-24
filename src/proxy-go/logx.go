package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var (
	logMu      sync.Mutex
	logPath    string
	logDebugOn bool
)

func logInit(exeDir string) {
	logPath = filepath.Join(exeDir, "mxMCPProxy.log")
}

func setLogLevel(level string) {
	l := strings.ToLower(strings.TrimSpace(level))
	logDebugOn = l == "debug" || l == "trace" || l == "verbose"
}

func emitLine(s string) {
	// stderr write outside the file lock — Claude Code may stall draining
	// stderr; we must not hold logMu while that blocks, or the poll goroutine
	// would deadlock on its own Log call (mirrors the Delphi critsec ordering).
	fmt.Fprintln(os.Stderr, s)

	if logPath == "" {
		return
	}
	stamp := time.Now().Format("15:04:05.000")
	line := stamp + " " + s + "\n"

	logMu.Lock()
	defer logMu.Unlock()
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(line)
}

func logMsg(s string) { emitLine(s) }

func logDebug(s string) {
	if logDebugOn {
		emitLine(s)
	}
}
