# PreCompact / PostCompact Hooks — DORMANT

**Status:** Removed from `~/.claude/settings.json`.
**Reason:** `type: "prompt"` Hooks fuer `PreCompact` und `PostCompact` werden in der aktuellen Claude Code Version **nicht ausgefuehrt**. Sie feuerten still ohne sichtbaren Effekt und erzeugten ein Marketing/Realitaet-Mismatch (CLAUDE.md versprach Auto-mxSave + Auto-Briefing).

**Re-Activate:** Sobald Anthropic prompt-type Hooks fuer Pre/PostCompact supportet, die beiden Bloecke wieder in `~/.claude/settings.json` unter `"hooks"` einfuegen — direkt nach dem `PostToolUse`-Block, vor der schliessenden `}` der Hooks-Section. Komma nach `PostToolUse`-Closing `]` ergaenzen.

## Original PreCompact Block

```json
"PreCompact": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "prompt",
        "prompt": "CONTEXT-COMPACTING STEHT BEVOR! Fuehre diese 2 Schritte SOFORT aus:\n\n1. AUTO-ADR EXTRACT (VOR mxSave!): Analysiere den Chat-Verlauf nach signifikanten Entscheidungen (Signal-Woerterbuch: ~/.claude/reference/auto-adr.md). Pro erkannter Entscheidung (Stufe 1+2): mx_create_doc(project, doc_type='note', title='ADR-Kandidat: <Zusammenfassung>', content=<Template aus auto-adr.md>, tags='adr-candidate'). Vorher Deduplizierung via mx_search(tag='adr-candidate') + mx_search(doc_type='decision'). Keine User-Rueckfrage. Output: 'Auto-ADR: N Kandidaten extrahiert'.\n\n2. /mxSave ausfuehren um den aktuellen Projektzustand zu persistieren.\n\nKeine Rueckfragen, keine Erklaerungen — einfach ausfuehren und dann das Compacting zulassen."
      }
    ]
  }
]
```

## Original PostCompact Block

```json
"PostCompact": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "prompt",
        "prompt": "SCHRITT 1: Pruefe 2 zwingende Bedingungen:\n  - CLAUDE.md im aktuellen Working Dir existiert UND enthaelt **Slug:**-Eintrag\n  - mx_ping() erfolgreich\n  Wenn EINE Bedingung fehlschlaegt → SILENT (kein Output, gar nichts). Beim naechsten User-Prompt einfach normal weitermachen.\n\nSCHRITT 2: (nur wenn beide Bedingungen OK) mx_briefing(project='<slug>', include_content=false, token_budget=1500)\n\nSCHRITT 3: (optional, soft-fail) Pruefe ob .claude/projects/<project>/.claude/orchestrate-state.json existiert. Wenn ja: Read und parse last_save_deltas (default 0 wenn Feld fehlt). Wenn nein: ueberspringen, kein Error.\n\nSCHRITT 4: Output max 3 Zeilen:\n  Project: <slug> | Session: #<id> | <N> active WFs\n  Open items: <X>\n  Last save: <last_save_deltas> deltas processed   ← NUR wenn SCHRITT 3 erfolgreich UND last_save_deltas > 0\n\nKeine Erklaerungen, keine Rueckfragen — direkt ausfuehren und weiterarbeiten."
      }
    ]
  }
]
```

## Bis Re-Activate

Manueller Ersatz:
1. **Vor** `/compact`: `/mxSave` selbst aufrufen.
2. **Nach** `/compact`: `mx_briefing(project='<slug>', include_content=false, token_budget=1500)` selbst aufrufen.

Die `last_save_deltas`-Mechanik in `mxSave` Step 4 + `orchestrate-state.json` ist code-seitig komplett funktionsbereit — sie wartet nur auf den Trigger.
