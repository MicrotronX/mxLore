# Spezifikation / PRD Pruefregeln

Diese Regeln werden geladen wenn mxDesignChecker eine `SPEC-*.md` Datei prueft.

## 1. Klarheit der Requirements

- **Pruefe**: Ist jedes Requirement in 1-2 Saetzen verstaendlich? Gibt es Mehrdeutigkeiten?
- **Typische Fehler**:
  - Vage Formulierungen: "System soll benutzerfreundlich sein" (nicht messbar)
  - Implizite Annahmen: "Wie gewohnt verarbeiten" (wer gewohnt? wie genau?)
  - Mehrfach-Bedeutungen: "Schnell" kann Ladezeit, Durchsatz oder Reaktionszeit meinen
  - Abkuerzungen ohne Erklaerung, die nicht im Projekt-Glossar stehen
- **Pruefmethode**: Lese jedes Requirement einzeln. Kann ein Entwickler der nur die Spec liest (ohne den Chat) verstehen was gemeint ist?
- **Severity**: CRITICAL wenn Mehrdeutigkeit zu falscher Implementierung fuehren kann, WARNING wenn unklar aber kontextabhebbar

## 2. Testbarkeit der Acceptance Criteria

- **Pruefe**: Kann man fuer jedes Acceptance Criterion einen konkreten Test formulieren?
- **Typische Fehler**:
  - Nicht messbar: "Soll performant sein" → Besser: "Antwortzeit unter X ms"
  - Zu allgemein: "Daten werden korrekt gespeichert" → Besser: "Pflichtfelder Name, E-Mail werden in Tabelle X persistiert und bei erneutem Laden angezeigt"
  - Fehlende Grenzwerte: "Grosse Datenmengen verarbeiten" → Wie gross genau?
  - Fehlende Negativtests: Nur Happy-Path beschrieben, keine Fehlerfaelle
- **Pruefmethode**: Fuer jedes Kriterium fragen: "Wie wuerde ich das testen? Welchen Input, welches erwartete Ergebnis?"
- **Severity**: WARNING bei untestbaren Kriterien, INFO bei fehlenden Negativtests

## 3. Vollstaendigkeit

- **Pruefe**: Sind alle besprochenen Anforderungen in der Spec abgedeckt?
- **Typische Fehler**:
  - Brainstorming-Ergebnis teilweise vergessen
  - Edge Cases nur muendlich besprochen aber nicht in Spec dokumentiert
  - Error-Handling nicht spezifiziert (was passiert bei Fehler X?)
  - Berechtigungen/Rollen nicht definiert (wer darf was?)
- **Pruefmethode**: Chat-Verlauf (falls verfuegbar) oder Overview/Goals mit Requirements abgleichen. Jedes Goal muss durch mindestens ein Requirement abgedeckt sein.
- **WICHTIG**: NUR pruefen was tatsaechlich im Chat besprochen oder in der Spec dokumentiert ist. NICHT vermuten welche Anforderungen "wahrscheinlich noch fehlen". Die Goldene Regel gilt: Kein Finding ohne Beweis.
- **Severity**: WARNING bei fehlender Abdeckung eines Goals, INFO bei fehlenden Error-Handling-Details

## 4. Konsistenz

- **Pruefe**: Gibt es Widersprueche innerhalb der Spec oder zu bestehenden Dokumenten?
- **Typische Fehler**:
  - Requirement 3 widerspricht Requirement 7
  - Spec sagt "nur fuer Admins", bestehende ADR sagt "fuer alle Benutzer"
  - Non-goals Liste enthaelt etwas das in Requirements steht
  - Acceptance Criteria decken ein Requirement nicht ab (AC testet etwas anderes als Req definiert)
- **Pruefmethode**: Requirements durchnummeriert lesen, auf Ueberlappungen und Widersprueche pruefen. Falls Related-Links existieren: Ziel-Dokument lesen und abgleichen.
- **Severity**: CRITICAL bei Widerspruechen, WARNING bei fehlender AC-Abdeckung

## 5. Abgrenzung (Scope)

- **Pruefe**: Sind Non-goals definiert? Ist der Scope klar begrenzt?
- **Typische Fehler**:
  - Non-goals Sektion fehlt oder leer
  - Scope schleichend zu gross ("und ausserdem noch X und Y")
  - Abhaengigkeiten zu anderen Features nicht dokumentiert
  - Migrationsbedarf nicht erwaehnt (bestehende Daten, bestehende APIs)
- **Pruefmethode**: Non-goals lesen. Fragen: "Kann jemand denken, dass X auch dazugehoert obwohl es nicht soll?" Falls ja, muss X in Non-goals stehen.
- **Severity**: WARNING bei fehlender Abgrenzung, INFO bei fehlenden Abhaengigkeiten

## 6. Edge Cases

- **Pruefe**: Sind offensichtliche Sonderfaelle dokumentiert?
- **Typische Fehler**:
  - Leere Eingaben nicht beruecksichtigt (leerer String, leere Liste, keine Auswahl)
  - Berechtigungsgrenzen: Was passiert wenn ein Benutzer ohne Berechtigung zugreift?
  - Gleichzeitige Bearbeitung: Was wenn zwei Benutzer dasselbe editieren?
  - Datenvolumen: Verhaelt sich das System bei 1 Eintrag gleich wie bei 10.000?
- **Pruefmethode**: NUR Edge Cases melden die sich direkt aus den Requirements ergeben. KEINE theoretischen Edge Cases erfinden die zum Requirement-Kontext nicht passen.
- **Severity**: WARNING bei fehlenden offensichtlichen Edge Cases, INFO bei theoretischen

## 7. Umsetzbarkeit

- **Pruefe**: Sind die Requirements technisch machbar im Projektkontext?
- **Typische Fehler**:
  - Feature erfordert eine Technologie die laut CLAUDE.md nicht verwendet wird (z.B. WebSocket in einem PHP-only-Projekt)
  - Performance-Anforderung unrealistisch fuer den Tech-Stack
  - Abhaengigkeit von externem Service der nicht verfuegbar ist
  - Komplexitaet eines Requirements uebersteigt den geplanten Aufwand massiv
- **Pruefmethode**: Requirements gegen CLAUDE.md Tech-Stack pruefen. NUR offensichtliche Konflikte melden, KEINE spekulativen Machbarkeitsbedenken.
- **Severity**: CRITICAL bei technischer Unmachbarkeit, WARNING bei hoher Komplexitaet
