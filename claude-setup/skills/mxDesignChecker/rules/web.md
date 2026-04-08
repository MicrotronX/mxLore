# Web / PHP / JavaScript / HTML Pruefregeln

## 1. XSS (Cross-Site Scripting)

- **Pruefe**: Werden alle User-Inputs vor der Ausgabe escaped/sanitized?
- **Typische Fehler**:
  - `echo $_GET['param']` ohne htmlspecialchars()
  - innerHTML mit User-Input ohne Sanitization
  - Template-Engine ohne Auto-Escaping
  - URL-Parameter in href/src ohne Validierung (javascript:-Protokoll)
- **Severity**: CRITICAL

## 2. SQL Injection

- **Pruefe**: Werden Prepared Statements / parametrisierte Queries verwendet?
- **Typische Fehler**:
  - String-Konkatenation in SQL: `"SELECT * FROM users WHERE id=" + id`
  - `mysqli_query()` mit nicht-escaptem Input
  - ORM-Bypass mit Raw-Queries ohne Parameter
- **Severity**: CRITICAL

## 3. CSRF (Cross-Site Request Forgery)

- **Pruefe**: Haben alle state-aendernden Endpunkte CSRF-Schutz?
- **Typische Fehler**:
  - POST/PUT/DELETE ohne CSRF-Token
  - Token nur im Cookie, nicht im Header/Form (Cookie-only ist nicht sicher)
  - SameSite-Cookie-Attribut fehlt
- **Severity**: CRITICAL bei Admin-Aktionen, WARNING bei normalen Aktionen

## 4. Session-Handling

- **Pruefe**: Sind Sessions sicher konfiguriert?
- **Typische Fehler**:
  - Session-ID in URL statt Cookie
  - Fehlende `HttpOnly`/`Secure`/`SameSite` Flags
  - Kein Session-Timeout
  - Session-Fixation: Session-ID nicht nach Login erneuert
- **Severity**: CRITICAL bei fehlenden Basis-Flags, WARNING bei fehlender Erneuerung

## 5. CORS (Cross-Origin Resource Sharing)

- **Pruefe**: Ist CORS korrekt konfiguriert?
- **Typische Fehler**:
  - `Access-Control-Allow-Origin: *` mit Credentials
  - Origin nicht validiert (reflektiert jeden Origin)
  - Preflight-Requests nicht korrekt behandelt
- **Severity**: CRITICAL bei Wildcard + Credentials, WARNING bei zu offener Config

## 6. Input-Validierung

- **Pruefe**: Werden alle externen Inputs validiert?
- **Typische Fehler**:
  - Datei-Upload ohne Extension/MIME-Typ-Pruefung
  - Numerische Parameter nicht auf Range geprueft
  - Path-Traversal: `../../../etc/passwd` nicht blockiert
  - JSON/XML-Parsing ohne Size-Limit
- **Severity**: CRITICAL bei Path-Traversal/Injection, WARNING bei fehlender Range-Pruefung

## 7. API-Design

- **Pruefe**: Ist das API-Design konsistent und sicher?
- **Typische Fehler**:
  - Fehler-Responses geben Stack-Traces oder interne Details preis
  - Keine Versionierung (Breaking Changes brechen Clients)
  - Rate-Limiting fehlt auf oeffentlichen Endpunkten
  - Pagination fehlt bei Listen-Endpunkten (Memory-Explosion bei grossen Datasets)
- **Severity**: WARNING

## 8. Browser-Kompatibilitaet

- **Pruefe**: Funktioniert der Code in den Ziel-Browsern?
- **Typische Fehler**:
  - ES6+-Syntax ohne Transpilation fuer IE11
  - CSS-Features ohne Fallback (Grid, Container Queries)
  - WebAPI ohne Verfuegbarkeits-Check (z.B. `navigator.clipboard`)
- **Severity**: WARNING (abhaengig von Zielgruppe)

## 9. Performance

- **Pruefe**: Gibt es offensichtliche Performance-Probleme?
- **Typische Fehler**:
  - N+1 Queries in Schleifen
  - Keine Pagination bei grossen Datenmengen
  - Synchrone Operationen die den Main-Thread blockieren
  - Fehlende Caching-Header
- **Severity**: WARNING bei N+1, INFO bei fehlenden Optimierungen
