# mxLoreOrchestrator

Single Windows executable that hosts Claude Code consoles (ConPTY + pwsh) and
shows them as tabs in the browser. The server owns the processes; closing the
browser does not stop them, and reconnecting replays up to 1 MiB of scrollback.

## Build

    bash build.sh        # -> bin/mxLoreOrchestrator.exe (Go 1.23+)

## Run

    mxLoreOrchestrator.exe [--data <dir>] [--listen 127.0.0.1:8443]

Private data (config, certificate, sessions) lives in `%LOCALAPPDATA%\mxLoreOrchestrator`
unless `--data` names another directory; never point it into a repository checkout.

Sign-in uses an mxLore key (plus a TOTP code once 2FA is on). A self-signed TLS
certificate (`cert.pem`, `key.pem`) is generated in the data directory. Open
https://localhost:8443.

While no mxLore developer is bound (setup mode) the orchestrator writes a setup
code to `<data>/setup-code.txt` (readable only by the current user, new code on
every start). The mxLore server address can be set on the login page with that
code. The first mxLore sign-in also needs the setup code, binds the developer
and must then set up 2FA before anything else works. Once bound, changing the
address before sign-in needs a TOTP code and returns to setup mode.

Flags: `--recovery` (prints a one-time key valid until the process exits),
`--mxlore-url <url>` (http only for this computer, https otherwise),
`--mxlore-unbind`, `--enable-2fa`, `--disable-2fa`, `--listen`, `--data`.

## Security

- HTTPS only, session cookie `HttpOnly; Secure; SameSite=Strict`. Sessions slide on use and are persisted in `sessions.json`. Length = `sessionDays` (default 7, setting 1-90); an mxLore-key session is capped at that length from login.
- Login rate limit: 5 failures per minute per IP.
- Host header must be localhost/127.0.0.1 on the configured port; state-changing
  requests and WebSocket upgrades must carry a matching `Origin`.
