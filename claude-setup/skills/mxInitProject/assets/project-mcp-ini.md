# Project-specific mxMCPProxy INI template

Write to `.claude/mxMCPProxy.ini` in the project directory when the user opts
into a project-scoped MCP server.

Substitute:
- `<URL without /mcp suffix>` — base URL the user provided, with `/mcp` stripped
- `<API-KEY>` — user-supplied key (must start with `mxk_`)

```ini
[Server]
BaseUrl=<URL without /mcp suffix>
ApiKey=<API-KEY>
McpEndpoint=/mcp

[Agent]
Polling=1
PollInterval=15
```
