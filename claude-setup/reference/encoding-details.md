# Encoding Details (Offloaded from CLAUDE.md)

## Core Rules (also in CLAUDE.md)

- ALWAYS preserve the original character encoding
- Delphi units (.pas, .dfm, .dpr, .dpk) can often be ANSI (Windows-1252)
- ANSI files with non-ASCII (bytes >127): warn the user before editing

## Detailed Findings

### ANSI files with non-ASCII characters (bytes > 127)

Before editing, check whether umlauts, Euro, paragraph, sz or other special
characters appear in the file. If so: warn the user, because the Edit tool can
convert the file to UTF-8 and thereby destroy ANSI special characters
(e.g. ue=0xFC), turning them into the Replacement Character 0xEF 0xBF 0xBD.

### ANSI files without non-ASCII characters (only bytes 0-127)

Edit tool is safe, since ASCII is identical in ANSI and UTF-8.

### PowerShell/Bash prohibition for file contents

- **NEVER use PowerShell or Bash for file content manipulation**
- PowerShell Write-Output contaminates function return values and can write
  garbage into files
- PowerShell encoding parameters (UTF8/ANSI) lead to silent conversions
- Always use the internal Read/Edit/Write tools
- **NEVER use PowerShell to read, replace or write source code files** — not
  even as a workaround for tab/space issues in the Edit tool
- For Edit problems, use smaller, more unique old_string sections instead of
  falling back to shell scripts

### Order of file modifications

1. Read tool (read the file)
2. Edit tool with exactly copied old_string
3. Read tool for verification

### Encoding unclear?

If the encoding of a file is unclear, ask the user before editing. Special
characters (umlauts, sz, Euro, dollar, paragraph, ampersand, etc.) must remain
correctly preserved after editing.
