package main

import (
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
)

const proxyVersion = "1.0.6-go"

func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	return filepath.Dir(exe)
}

func main() {
	ed := exeDir()
	logInit(ed)
	logMsg("=== mxMCPProxy v" + proxyVersion + " startup ===")
	logMsg("[boot] ExePath: " + os.Args[0])
	logMsg("[boot] ExeDir: " + ed)
	if cwd, err := os.Getwd(); err == nil {
		logMsg("[boot] CWD: " + cwd)
	}

	var iniPath string
	if len(os.Args) >= 2 {
		iniPath = os.Args[1]
	} else {
		iniPath = filepath.Join(ed, "mxMCPProxy.ini")
	}
	logMsg("[boot] IniPath: " + iniPath)
	logMsg("[boot] IniPath exists: " + boolStr(fileExists(iniPath)))

	// First-run bootstrap: write a default template and exit so the user can
	// edit it. The template lives in the code — no .example file needed.
	if !fileExists(iniPath) {
		logMsg("[boot] First-run: " + filepath.Base(iniPath) + " not found, writing default template.")
		if err := writeDefaultINI(iniPath); err != nil {
			logMsg("[boot] First-run: write failed: " + err.Error())
		} else {
			logMsg("[boot] First-run: wrote " + iniPath)
			logMsg("[boot] First-run: Please edit Url and ApiKey, then restart.")
		}
		os.Exit(1)
	}

	cfg, err := LoadConfig(iniPath)
	if err != nil {
		logMsg("FATAL: config load: " + err.Error())
		os.Exit(1)
	}
	setLogLevel(cfg.LogLevel)
	logMsg("[boot] Config loaded. ServerUrl=" + cfg.ServerURL +
		" ApiKey=" + safePrefix(cfg.APIKey) + "***" +
		" AgentPolling=" + boolStr(cfg.AgentPolling) +
		" WorkDir=" + cfg.WorkDir +
		" InboxDir=" + cfg.InboxDir +
		" LogLevel=" + cfg.LogLevel)

	if cfg.ServerURL == "" {
		logMsg("ERROR: ServerUrl not configured in " + iniPath)
		os.Exit(1)
	}
	if cfg.APIKey == "" {
		logMsg("ERROR: ApiKey not configured in " + iniPath)
		os.Exit(1)
	}

	logMsg("mxMCPProxy v" + proxyVersion)
	logMsg("URL: " + cfg.ServerURL)
	logMsg("Ready.")

	proxy := NewProxy(cfg)

	// Graceful shutdown on SIGINT/SIGTERM (stops the poll goroutine cleanly).
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		logMsg("[boot] Signal received, shutting down")
		proxy.Close()
		os.Exit(0)
	}()

	proxy.Run()
	proxy.Close()
	logMsg("=== mxMCPProxy shutdown ===")
}
