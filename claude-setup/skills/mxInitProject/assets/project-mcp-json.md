# Project-specific .mcp.json template

Create or update `.mcp.json` in the project directory when the user opts into a
project-scoped MCP server. The proxy receives the INI path as its first
argument (no flag).

Substitute:
- `<absolute-path-to>/.claude/mxMCPProxy.exe` — proxy binary location
- `<absolute-path-to-project>/.claude/mxMCPProxy.ini` — INI file just written

```json
{
  "mcpServers": {
    "mxai-knowledge": {
      "command": "<absolute-path-to>/.claude/mxMCPProxy.exe",
      "args": ["<absolute-path-to-project>/.claude/mxMCPProxy.ini"]
    }
  }
}
```

Merge rule: if `.mcp.json` already exists, only add or replace the
`mxai-knowledge` key. Never touch other keys.
