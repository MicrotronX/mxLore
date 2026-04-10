# Troubleshooting

Common issues when setting up or running mxLore.

## Server Won't Start

| Problem | Solution |
|---------|----------|
| **"libmariadb.dll not found"** | The server auto-detects the MariaDB client library from your installation (registry, `C:\Program Files\MariaDB*`). If auto-detection fails, find `libmariadb.dll` in your MariaDB `lib/` directory and copy it to the mxLore `lib/` folder. |
| **"Port 8080 already in use"** | Another application is using port 8080. Change `Port=8080` in the `[Server]` section of your INI to a free port (e.g. 9080). The Admin UI port is always MCP port + 1 (e.g. 9081). |
| **Schema creation fails** | Ensure the database `mxai_knowledge` exists: `mysql -u root -p -e "SHOW DATABASES;"`. Check that the password in the INI matches your MariaDB root password. See `logs/mxLoreMCP.log` for details. |
| **"mysql client not found"** | The server needs `mysql.exe` or `mariadb.exe` to import `setup.sql` on first boot (it uses DELIMITER blocks that FireDAC can't parse). The CLI is auto-detected from your MariaDB `bin/` directory. If it fails, set `VendorHome=C:\Program Files\MariaDB 11.6` in the INI, or import manually: `mysql -u root -p mxai_knowledge < sql/setup.sql` |
| **Schema partially created (dirty state)** | If `setup.sql` import was interrupted, the database may have some but not all tables. Fix: `DROP DATABASE mxai_knowledge; CREATE DATABASE mxai_knowledge CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;` then restart the server. The schema uses `CREATE TABLE IF NOT EXISTS`, so re-running is safe on a clean database. |
| **MariaDB auto-detect picks wrong version** | Set the path explicitly: `VendorHome=C:\Program Files\MariaDB 11.6` in the `[Database]` section. |

## Connection Issues

| Problem | Solution |
|---------|----------|
| **"Connection refused" on port 8080/8081** | Check Windows Firewall: allow inbound TCP for ports 8080 and 8081. For LAN access, set `BindAddress=0.0.0.0` in the INI. |
| **Admin UI shows blank page** | Ensure the `admin/www/` folder with all HTML/CSS/JS files is in the same directory as the EXE. The server serves these files directly from that folder. |
| **claude.ai can't connect** | Ensure the server is reachable from the internet (use a reverse proxy with HTTPS). claude.ai requires `https://`. Check that `AllowUrlApiKey=1` is set in `[Security]` if using URL-based auth. |
| **Claude Code says "server not found"** | Check the MCP URL format: `http://localhost:8080/mcp` (not just `localhost:8080`). Ensure the server is running. Try the curl test from the [Installation Guide](installation.md#step-5-verify). |

## Admin UI Issues

| Problem | Solution |
|---------|----------|
| **Login fails with "Invalid API key"** | You need an API key with **admin** role. Check in the database or create a new admin key. |
| **"No team members yet" after creating one** | Refresh the page. If the member was created but you don't see it, check `logs/` for database errors. |
| **Settings page test-connection fails** | The test sends a real HTTP request from the server to the URL you entered. Check that the URL is reachable from the server machine. For internal test, the MCP port is inferred from the Admin UI port. |

## MariaDB Issues

| Problem | Solution |
|---------|----------|
| **"Access denied for user 'root'"** | The password in `mxLoreMCP.ini` doesn't match your MariaDB root password. Re-check or reset: `mysql -u root -p` should work with the same password. |
| **"Unknown database 'mxai_knowledge'"** | Run: `mysql -u root -p -e "CREATE DATABASE mxai_knowledge CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"` |
| **Semantic search not working** | Requires MariaDB 11.6+ with VECTOR support. Check your version: `mysql -u root -p -e "SELECT VERSION();"`. Older versions work fine — they just don't have semantic search. |

## Log Files

- **Server log:** `logs/mxLoreMCP.log` (auto-created, 5 MB rotation)
- **Console output:** Same as log file, but also printed to terminal when using `mxLoreMCP.exe`
- **GUI log:** Visible in the Log tab of `mxLoreMCPGui.exe`

Enable debug logging in the INI:

```ini
[Logging]
LogLevel=debug
```

## Getting Help

- [GitHub Issues](https://github.com/MicrotronX/mxLore/issues) — bug reports, feature requests
- [mxlore.dev](https://www.mxlore.dev) — product overview, FAQ
- Email: info@microtronx.com
