// mxLoreOrchestrator: a browser-based terminal host that owns ConPTY consoles
// running Claude Code in registered project folders.
package main

import (
	"context"
	"crypto/tls"
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/pquerna/otp/totp"

	"mxloreorchestrator/internal/conpty"
)

//go:embed all:www
var wwwFS embed.FS

// defaultDataDir keeps private data (keys, certificate, sessions) out of the
// install directory, which may sit inside a repository checkout.
func defaultDataDir() string {
	if d, err := os.UserCacheDir(); err == nil { // %LOCALAPPDATA% on Windows
		return filepath.Join(d, "mxLoreOrchestrator")
	}
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

func main() {
	dataDir := flag.String("data", "", "data directory (default: %LOCALAPPDATA%\\mxLoreOrchestrator)")
	listen := flag.String("listen", "", "listen address, e.g. 127.0.0.1:8443 (persisted)")
	recovery := flag.Bool("recovery", false, "print a one-time recovery key that signs in until this process exits")
	enable2FA := flag.Bool("enable-2fa", false, "generate a TOTP secret and print the otpauth:// URI")
	disable2FA := flag.Bool("disable-2fa", false, "remove the TOTP secret")
	mxLoreURL := flag.String("mxlore-url", "", "mxLore server base URL, e.g. http://127.0.0.1:8080 or https://lore.example.com (persisted; changing it unbinds the developer)")
	mxLoreUnbind := flag.Bool("mxlore-unbind", false, "forget the mxLore developer this orchestrator is bound to")
	flag.Parse()

	dir := *dataDir
	if dir == "" {
		dir = defaultDataDir()
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Fatalf("data dir: %v", err)
	}
	store, err := LoadStore(dir)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	err = store.Update(func(c *Config) error {
		if *listen != "" {
			c.Listen = *listen
		}
		// KeyHash (the former local access key) is kept in the file but no longer used.
		if *mxLoreURL != "" {
			u, err := validateMxLoreURL(*mxLoreURL)
			if err != nil {
				return err
			}
			if u != c.MxLoreURL {
				c.MxLoreDeveloperID, c.MxLoreDeveloperName = 0, ""
			}
			c.MxLoreURL = u
			fmt.Println("mxLore sign-in via " + u)
		}
		if *mxLoreUnbind {
			c.MxLoreDeveloperID = 0
			c.MxLoreDeveloperName = ""
			fmt.Println("mxLore developer binding removed.")
		}
		if *disable2FA {
			c.TOTPSecret = ""
			fmt.Println("2FA disabled.")
		}
		if *enable2FA {
			k, err := totp.Generate(totp.GenerateOpts{Issuer: "mxLoreOrchestrator", AccountName: "admin"})
			if err != nil {
				return err
			}
			c.TOTPSecret = k.Secret()
			fmt.Println("2FA enabled. Add this URI to your authenticator app:")
			fmt.Println(" " + k.URL())
		}
		return nil
	})
	if err != nil {
		log.Fatalf("save config: %v", err)
	}
	if *enable2FA || *disable2FA || *mxLoreUnbind || *mxLoreURL != "" {
		if err := clearSessions(dir); err != nil {
			log.Fatalf("clear sessions: %v", err)
		}
		fmt.Println("All login sessions cleared.")
	}

	cert, err := ensureCert(dir)
	if err != nil {
		log.Fatalf("tls: %v", err)
	}

	var addr string
	var unbound bool
	store.View(func(c *Config) { addr, unbound = c.Listen, c.MxLoreDeveloperID == 0 })
	// allowed-hosts.txt lists extra Host names (one per line, e.g. a tailscale serve
	// name) for a TLS-terminating reverse proxy in front of the loopback listener.
	// A separate file so an older build rewriting orchestrator.json cannot drop it.
	var allowed []string
	if b, err := os.ReadFile(filepath.Join(dir, "allowed-hosts.txt")); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
				allowed = append(allowed, l)
			}
		}
	}
	if err := requireLoopback(addr); err != nil {
		log.Fatalf("listen: %v", err)
	}

	sub, err := fs.Sub(wwwFS, "www")
	if err != nil {
		log.Fatal(err)
	}
	auth, err := NewAuth(store, dir)
	if err != nil {
		log.Fatalf("load sessions: %v", err)
	}
	auth.logf = log.Printf
	if unbound {
		auth.enterSetupMode()
	} else {
		auth.leaveSetupMode()
	}
	if *recovery {
		key := randomToken(24)
		auth.SetRecoveryKey(key)
		fmt.Println("==============================================================")
		fmt.Println(" Recovery key (valid until this process exits, shown once):")
		fmt.Println(" " + key)
		fmt.Println("==============================================================")
	}
	go auth.sweep()
	tabs := NewTabManager(store)
	tabs.logf = log.Printf
	upd := NewUpdater(tabs, store)
	upd.logf = log.Printf
	go upd.Run()
	srv := &Server{store: store, auth: auth, tabs: tabs, guard: NewHostGuard(addr, allowed...), update: upd}
	srv.autoRestore(log.Printf)

	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           srv.Routes(http.FileServer(http.FS(sub))),
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	go func() {
		ch := make(chan os.Signal, 1)
		// SIGTERM covers console close, logoff and system shutdown on Windows.
		signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
		<-ch
		log.Println("shutting down: fast close (workspace saved, claude tabs /exit)")
		tabs.FastCloseAll(4 * time.Second)
		log.Println("all tabs closed")
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		httpSrv.Shutdown(ctx)
	}()

	log.Printf("mxLoreOrchestrator listening on https://%s (data: %s, console: %s)", addr, dir, conpty.Mode)
	if err := httpSrv.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
