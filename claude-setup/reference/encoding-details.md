# Encoding-Details (Ausgelagert aus CLAUDE.md)

## Kernregeln (auch in CLAUDE.md)

- IMMER urspruengliche Zeichenkodierung beibehalten
- Delphi-Units (.pas, .dfm, .dpr, .dpk) können oft ANSI (Windows-1252) sein
- ANSI-Dateien mit Nicht-ASCII (Bytes >127): User warnen vor Edit

## Detaillierte Erkenntnisse

### ANSI-Dateien mit Nicht-ASCII-Zeichen (Bytes > 127)

Vor dem Editieren pruefen ob Umlaute, Euro, Paragraph, sz oder andere Sonderzeichen
in der Datei vorkommen. Falls ja: den Benutzer warnen, da das Edit-Tool die Datei
nach UTF-8 konvertieren kann und dabei ANSI-Sonderzeichen (z.B. ue=0xFC) zerstoert
werden (Replacement Character 0xEF 0xBF 0xBD).

### ANSI-Dateien ohne Nicht-ASCII-Zeichen (nur Bytes 0-127)

Edit-Tool ist sicher, da ASCII in ANSI und UTF-8 identisch ist.

### PowerShell/Bash-Verbot fuer Dateiinhalte

- **NIEMALS PowerShell oder Bash fuer Dateiinhalts-Manipulationen verwenden**
- PowerShell Write-Output kontaminiert Funktionsrueckgabewerte und kann Muell
  in Dateien schreiben
- PowerShell-Encoding-Parameter (UTF8/ANSI) fuehren zu stillen Konvertierungen
- Immer die internen Read/Edit/Write-Tools verwenden
- **NIEMALS PowerShell zum Lesen, Ersetzen oder Schreiben von Quellcode-Dateien
  verwenden** — auch nicht als Workaround bei Tab/Space-Problemen im Edit-Tool
- Bei Edit-Problemen kleinere, eindeutigere old_string-Abschnitte verwenden
  statt auf Shell-Skripte auszuweichen

### Reihenfolge bei Dateiaenderungen

1. Read-Tool (Datei lesen)
2. Edit-Tool mit exakt kopiertem old_string
3. Read-Tool zur Verifizierung

### Kodierung unklar?

Falls die Kodierung einer Datei unklar ist, vor der Bearbeitung beim Benutzer
nachfragen. Sonderzeichen (Umlaute, sz, Euro, Dollar, Paragraph, Ampersand, etc.)
muessen nach der Bearbeitung korrekt erhalten bleiben.
