# PHP / Web – Senior Mindset Details

> Referenced by `CLAUDE.md`. Load ONLY when needed.

---

## PHP Security

### Input Validation & Output Encoding
- **Output to HTML:** always `htmlspecialchars($val, ENT_QUOTES, 'UTF-8')`
- **Output to JS:** `json_encode($val, JSON_HEX_TAG | JSON_HEX_APOS)`
- **URL parameters:** `urlencode()` / `rawurlencode()` depending on context
- **Never:** `echo $_GET['x']` directly, `$$variable`, `extract($_POST)`

### Database Access
- Exclusively PDO or MySQLi with Prepared Statements
- No string concatenation for SQL values
- Error mode: `PDO::ERRMODE_EXCEPTION` — never silent errors
- Connection credentials: only from `.env` / environment variables, never in code

### CSRF / Session
- Every state-changing form needs a CSRF token (synchronizer token pattern)
- Sessions: `session_regenerate_id(true)` after login
- Cookies: set `HttpOnly`, `Secure`, `SameSite=Lax`

### File Uploads
- Whitelist allowed MIME types (never trust user input)
- Upload directory outside the webroot or secured via `.htaccess`
- Sanitize filenames (no `../`, no special characters)

### Forbid Code Execution
- No `eval()`, `exec()`, `shell_exec()`, `system()`, `passthru()`
- No `include($userInput)`, `require($userInput)`
- Check `disable_functions` in `php.ini` for production environments

---

## PHP Standards & Structure

### PSR Compliance
- **PSR-1 / PSR-12 (PER-CS 2.0):** Coding style (4 spaces, StudlyCaps for classes, camelCase for methods)
- **PSR-4:** Autoloading — namespace structure mirrors directory structure
- **PSR-7/15:** HTTP Message Interface / Middleware when the framework supports it
- **PSR-3:** Logger interface (`$logger->error(...)` instead of `error_log(...)`)

### Composer
- Dependencies always via `composer require vendor/package`
- Commit `composer.lock`, put `vendor/` in `.gitignore`
- Never copy packages manually into `vendor/`

### Error Handling
- Custom exception classes for domain errors
- Production: log all errors, never display them (`display_errors = Off`)
- Development: `error_reporting(E_ALL)`, `display_errors = On`

---

## Frontend (HTML / CSS / JS)

### HTML
- Semantic HTML5: `<main>`, `<article>`, `<section>`, `<nav>`, `<header>`, `<footer>`
- Accessibility: `alt` attributes, ARIA labels where needed, keyboard navigation
- `<form>`: always `method="post"` for data changes, CSRF token as a hidden field

### CSS
- BEM naming or a consistent convention within the project
- No `!important` abuse (at most for utility classes)
- CSS variables for colors/spacing (`--color-primary`, `--spacing-base`)
- Mobile-first breakpoints

### JavaScript
- No global namespace pollution: module pattern or ES6 modules
- Prefer `const`, use `let` when needed, no `var`
- DOM manipulation: cache elements, no repeated `document.querySelector` in loops
- Fetch/Axios: always handle errors (`.catch()` / `try/catch`)
- No sensitive data in `localStorage` (no auth token without encryption)

---

## Database (SQL General)

- Check indexes on all JOIN/WHERE/ORDER BY columns
- `EXPLAIN` / `EXPLAIN ANALYZE` before deploying complex queries
- Transactions for multi-step write operations
- No SELECT * in production — only the columns you need

---

## Web Performance (Core Web Vitals)

### Targets
- **LCP** (Largest Contentful Paint): < 2.5s
- **INP** (Interaction to Next Paint): < 200ms
- **CLS** (Cumulative Layout Shift): < 0.1

### Bundles & Load Times
- Landing pages: < 150kb JS (compressed)
- App pages: < 300kb JS (compressed)
- Images: AVIF > WebP > optimized JPEG/PNG (fallback chain)
- Fonts: max 2 families, `font-display: swap`, WOFF2 format

### CSS Performance
- Animations only on compositor properties: `transform`, `opacity`, `filter`
- No layout thrashing (no width/height/top/left animations)
- Use `will-change` sparingly (only for measured problems)
- `contain: layout` for isolated sections

### Lazy Loading
- Below-the-fold images: `loading="lazy"` + explicit `width`/`height` (CLS)
- Heavy JS modules: dynamic `import()` instead of static loading
- Intersection Observer for scroll-based content

---

## Security Headers & CSP

### HTTP Security Headers (in .htaccess or server config)
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
- Nonce-based (`'nonce-xyz'`) instead of `'unsafe-inline'` for scripts AND styles
- `'unsafe-inline'` for styles only as a last resort when nonce is not possible (legacy code)
- `object-src 'none'` — prevents plugin content (Flash, Java applets)
- `base-uri 'self'` — prevents base-tag injection (URL hijacking)
- `frame-ancestors 'none'` — modern replacement for X-Frame-Options
- External scripts: SRI hashes (`integrity="sha384-..."`)
- Configure `report-to` for CSP violations (`Report-URI` is deprecated since CSP Level 3)

### Form Security
- Rate limiting on login/registration (e.g. 5 attempts/minute)
- Honeypot fields against simple bots (invisible field; if filled → bot)
- Time-based check: form submitted in < 2s → suspicious

---

## JavaScript — Advanced Patterns

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

### Type Safety without TypeScript
- JSDoc annotations for IDE support: `/** @param {string} name */`
- `===` instead of `==` (strict comparisons)
- Optional chaining: `obj?.prop?.nested` instead of nested checks
- Nullish coalescing: `val ?? default` instead of `val || default` (0 and '' are valid)

### DOM Performance
- Event delegation instead of individual listeners on many elements
- `requestAnimationFrame` for visual updates
- `DocumentFragment` for batch DOM inserts
- `IntersectionObserver` instead of scroll event listeners

### Module Pattern (without bundler)
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

## HTML — Advanced Semantics & Accessibility

### Required Attributes
- Images: `alt` (descriptive), `width`, `height` (CLS avoidance)
- Links: `rel="noopener"` with `target="_blank"`
- Forms: `<label for="id">` for every input element
- Tables: `<thead>`, `<tbody>`, `scope="col/row"` for screen readers

### ARIA — Only When HTML Is Not Enough
- Semantic HTML first: `<button>` instead of `<div role="button">`
- `aria-label` for icon-only buttons
- `aria-live="polite"` for dynamically updated regions
- `aria-expanded`, `aria-controls` for accordions/dropdowns

### Keyboard Navigation
- All interactive elements must be reachable via Tab
- Custom widgets: `tabindex="0"` + keydown handler (Enter, Space, Escape)
- Focus trap in modals (Tab stays inside the dialog)
- Visible focus ring (`:focus-visible`, never `outline: none` globally)

---

## CSS — Advanced Patterns

### Design Tokens via Custom Properties
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
- Mobile-first: base styles for mobile, `min-width` media queries for larger screens
- Breakpoints: 640px (sm), 768px (md), 1024px (lg), 1280px (xl)
- `clamp()` for fluid typography: `font-size: clamp(1rem, 2.5vw, 2rem)`
- Container Queries (`@container`) for component-based layout

### Anti-Patterns
- ❌ `!important` — only for utility classes (e.g. `.hidden { display: none !important }`)
- ❌ Pixels for font sizes — use `rem`
- ❌ `z-index: 9999` — structured z-index system (10, 20, 30...)
- ❌ Deeply nested selectors (>3 levels) — flat selectors or BEM

---

## Encoding (PHP/Web Specific)

- PHP files: UTF-8 without BOM
- `mb_*` functions instead of `str_*` for multibyte strings: `mb_strlen()`, `mb_strtolower()`, etc.
- HTTP header: `header('Content-Type: text/html; charset=utf-8')` must match the file encoding
- Database connection: `SET NAMES utf8mb4` or PDO `charset=utf8mb4` in DSN
- `utf8mb4` instead of `utf8` in MySQL for full Unicode support (emoji, rare characters)
