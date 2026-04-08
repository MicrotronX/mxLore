# PHP / Web – Senior-Mindset Details

> Wird von `CLAUDE.md` referenziert. NUR bei Bedarf laden.

---

## PHP-Sicherheit

### Input-Validierung & Output-Encoding
- **Ausgabe ins HTML:** immer `htmlspecialchars($val, ENT_QUOTES, 'UTF-8')`
- **Ausgabe in JS:** `json_encode($val, JSON_HEX_TAG | JSON_HEX_APOS)`
- **URL-Parameter:** `urlencode()` / `rawurlencode()` je nach Kontext
- **Niemals:** `echo $_GET['x']` direkt, `$$variable`, `extract($_POST)`

### Datenbankzugriff
- Ausschliesslich PDO oder MySQLi mit Prepared Statements
- Keine String-Konkatenation fuer SQL-Werte
- Fehlermode: `PDO::ERRMODE_EXCEPTION` — nie stille Fehler
- Verbindungs-Credentials: nur aus `.env` / Umgebungsvariablen, nie im Code

### CSRF / Session
- Jedes zustandsaenderndes Formular braucht CSRF-Token (synchronizer token pattern)
- Sessions: `session_regenerate_id(true)` nach Login
- Cookies: `HttpOnly`, `Secure`, `SameSite=Lax` setzen

### Datei-Uploads
- Whitelist erlaubter MIME-Types (nie Userinput vertrauen)
- Upload-Verzeichnis ausserhalb des Webroots oder per `.htaccess` gesichert
- Dateinamen sanitisieren (kein `../`, keine Sonderzeichen)

### Code-Ausfuehrung verbieten
- Kein `eval()`, `exec()`, `shell_exec()`, `system()`, `passthru()`
- Kein `include($userInput)`, `require($userInput)`
- `disable_functions` in `php.ini` fuer Produktivumgebungen pruefen

---

## PHP-Standards & Struktur

### PSR-Compliance
- **PSR-1 / PSR-12 (PER-CS 2.0):** Coding Style (4 Spaces, StudlyCaps fuer Klassen, camelCase fuer Methoden)
- **PSR-4:** Autoloading — Namespace-Struktur spiegelt Verzeichnisstruktur
- **PSR-7/15:** HTTP Message Interface / Middleware wenn Framework das unterstuetzt
- **PSR-3:** Logger-Interface (`$logger->error(...)` statt `error_log(...)`)

### Composer
- Abhaengigkeiten immer via `composer require vendor/package`
- `composer.lock` committen, `vendor/` in `.gitignore`
- Niemals Pakete manuell in `vendor/` kopieren

### Fehlerbehandlung
- Custom Exception-Klassen fuer Domain-Fehler
- Produktiv: alle Errors loggen, nie anzeigen (`display_errors = Off`)
- Entwicklung: `error_reporting(E_ALL)`, `display_errors = On`

---

## Frontend (HTML / CSS / JS)

### HTML
- Semantisches HTML5: `<main>`, `<article>`, `<section>`, `<nav>`, `<header>`, `<footer>`
- Accessibility: `alt`-Attribute, ARIA-Labels wo noetig, Keyboard-Navigation
- `<form>`: immer `method="post"` fuer Daten-Aenderungen, CSRF-Token als Hidden-Field

### CSS
- BEM-Naming oder konsistente Konvention im Projekt
- Kein `!important`-Missbrauch (maximal fuer Utility-Classes)
- CSS-Variablen fuer Farben/Abstände (`--color-primary`, `--spacing-base`)
- Mobile-first Breakpoints

### JavaScript
- Kein globaler Namespace-Pollution: Module-Pattern oder ES6-Module
- `const` bevorzugen, `let` wenn noetig, kein `var`
- DOM-Manipulation: Elemente cachen, keine wiederholten `document.querySelector` in Loops
- Fetch/Axios: immer Error-Handling (`.catch()` / `try/catch`)
- Keine sensiblen Daten in `localStorage` (kein Auth-Token ohne Encryption)

---

## Datenbank (SQL-Allgemein)

- Indizes auf alle JOIN-/WHERE-/ORDER-BY-Spalten pruefen
- `EXPLAIN` / `EXPLAIN ANALYZE` vor Deployment von komplexen Queries
- Transaktionen fuer mehrstufige Schreiboperationen
- Keine SELECT * in Produktion — nur benoetigte Spalten

---

## Web-Performance (Core Web Vitals)

### Zielwerte
- **LCP** (Largest Contentful Paint): < 2.5s
- **INP** (Interaction to Next Paint): < 200ms
- **CLS** (Cumulative Layout Shift): < 0.1

### Bundle & Ladezeiten
- Landing-Pages: < 150kb JS (komprimiert)
- App-Seiten: < 300kb JS (komprimiert)
- Bilder: AVIF > WebP > optimiertes JPEG/PNG (Fallback-Chain)
- Fonts: max 2 Familien, `font-display: swap`, WOFF2-Format

### CSS-Performance
- Animationen nur auf Compositor-Properties: `transform`, `opacity`, `filter`
- Kein Layout-Thrashing (keine width/height/top/left Animationen)
- `will-change` sparsam einsetzen (nur bei gemessenen Problemen)
- `contain: layout` fuer isolierte Sektionen

### Lazy Loading
- Bilder below-the-fold: `loading="lazy"` + explizite `width`/`height` (CLS)
- Heavy JS-Module: dynamisches `import()` statt statisches Laden
- Intersection Observer fuer scroll-basierte Inhalte

---

## Security-Headers & CSP

### HTTP-Security-Headers (in .htaccess oder Server-Config)
```
Content-Security-Policy: default-src 'self'; script-src 'self' 'nonce-{random}'; style-src 'self' 'nonce-{random}'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=()
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

### CSP Best Practices
- Nonce-basiert (`'nonce-xyz'`) statt `'unsafe-inline'` fuer Scripts UND Styles
- `'unsafe-inline'` fuer Styles nur als letzter Ausweg wenn Nonce nicht moeglich (Legacy-Code)
- `object-src 'none'` — verhindert Plugin-Content (Flash, Java Applets)
- `base-uri 'self'` — verhindert base-tag-Injection (URL-Hijacking)
- `frame-ancestors 'none'` — moderner Ersatz fuer X-Frame-Options
- Externe Scripts: SRI-Hashes (`integrity="sha384-..."`)
- `report-to` fuer CSP-Violations konfigurieren (`Report-URI` ist deprecated seit CSP Level 3)

### Formular-Security
- Rate-Limiting auf Login/Registrierung (z.B. 5 Versuche/Minute)
- Honeypot-Felder gegen einfache Bots (unsichtbares Feld, wenn befuellt → Bot)
- Zeitbasierter Check: Formular in < 2s abgesendet → verdaechtig

---

## JavaScript — Erweiterte Patterns

### Async/Await Best Practices
```javascript
// FALSCH — sequentiell, blockiert
const a = await fetchA();
const b = await fetchB();

// RICHTIG — parallel wenn unabhaengig
const [a, b] = await Promise.all([fetchA(), fetchB()]);

// Error-Handling
try {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return await response.json();
} catch (e) {
  console.error('Fetch failed:', e.message);
  throw e; // re-throw fuer Caller
}
```

### Type-Safety ohne TypeScript
- JSDoc-Annotationen fuer IDE-Support: `/** @param {string} name */`
- `===` statt `==` (strikte Vergleiche)
- Optional Chaining: `obj?.prop?.nested` statt verschachtelte Checks
- Nullish Coalescing: `val ?? default` statt `val || default` (0 und '' sind gueltig)

### DOM-Performance
- Event-Delegation statt individuelle Listener auf viele Elemente
- `requestAnimationFrame` fuer visuelle Updates
- `DocumentFragment` fuer Batch-DOM-Inserts
- `IntersectionObserver` statt scroll-Event-Listener

### Module-Pattern (ohne Bundler)
```javascript
// ES6-Module im Browser (type="module")
<script type="module" src="app.js"></script>

// Namespace-Pattern fuer Legacy (var statt const — verhindert ReferenceError)
var MyApp = MyApp || {};
MyApp.utils = (function() {
  'use strict';
  // private
  function helper() { }
  // public API
  return { helper };
})();
```

---

## HTML — Erweiterte Semantik & Accessibility

### Pflicht-Attribute
- Bilder: `alt` (beschreibend), `width`, `height` (CLS-Vermeidung)
- Links: `rel="noopener"` bei `target="_blank"`
- Formulare: `<label for="id">` fuer jedes Input-Element
- Tabellen: `<thead>`, `<tbody>`, `scope="col/row"` fuer Screenreader

### ARIA — Nur wenn HTML nicht reicht
- Semantisches HTML zuerst: `<button>` statt `<div role="button">`
- `aria-label` fuer Icon-Only-Buttons
- `aria-live="polite"` fuer dynamisch aktualisierte Bereiche
- `aria-expanded`, `aria-controls` fuer Akkordeons/Dropdowns

### Keyboard-Navigation
- Alle interaktiven Elemente muessen per Tab erreichbar sein
- Custom-Widgets: `tabindex="0"` + Keydown-Handler (Enter, Space, Escape)
- Focus-Trap in Modals (Tab bleibt im Dialog)
- Sichtbarer Focus-Ring (`:focus-visible`, nie `outline: none` global)

---

## CSS — Erweiterte Patterns

### Design-Tokens via Custom Properties
```css
:root {
  --color-primary: #2563eb;
  --color-error: #dc2626;
  --spacing-xs: 0.25rem;
  --spacing-sm: 0.5rem;
  --spacing-md: 1rem;
  --spacing-lg: 2rem;
  --radius-sm: 4px;
  --radius-md: 8px;
  --font-size-sm: 0.875rem;
  --font-size-base: 1rem;
  --shadow-sm: 0 1px 2px rgba(0,0,0,0.05);
}
```

### Responsive Design
- Mobile-first: Basis-Styles fuer Mobile, `min-width` Media Queries fuer groessere Screens
- Breakpoints: 640px (sm), 768px (md), 1024px (lg), 1280px (xl)
- `clamp()` fuer fluide Typografie: `font-size: clamp(1rem, 2.5vw, 2rem)`
- Container Queries (`@container`) fuer komponentenbasiertes Layout

### Anti-Patterns
- ❌ `!important` — nur fuer Utility-Classes (z.B. `.hidden { display: none !important }`)
- ❌ Pixel fuer Schriftgroessen — `rem` verwenden
- ❌ `z-index: 9999` — strukturiertes z-index System (10, 20, 30...)
- ❌ Deeply nested selectors (>.3 Ebenen) — flache Selektoren oder BEM

---

## Encoding (PHP/Web spezifisch)

- PHP-Dateien: UTF-8 ohne BOM
- `mb_*`-Funktionen statt `str_*` bei Multibyte-Strings: `mb_strlen()`, `mb_strtolower()`, etc.
- HTTP-Header: `header('Content-Type: text/html; charset=utf-8')` muss mit Datei-Encoding uebereinstimmen
- Datenbank-Connection: `SET NAMES utf8mb4` oder PDO `charset=utf8mb4` in DSN
- `utf8mb4` statt `utf8` in MySQL fuer vollstaendigen Unicode-Support (Emoji, seltene Zeichen)
