# Web / PHP / JavaScript / HTML Review Rules

## 1. XSS (Cross-Site Scripting)

- **Check**: Are all user inputs escaped / sanitized before output?
- **Typical failures**:
  - `echo $_GET['param']` without `htmlspecialchars()`
  - `innerHTML` with user input without sanitization
  - Template engine without auto-escaping
  - URL parameters in `href` / `src` without validation (`javascript:` protocol)
- **Severity**: CRITICAL

## 2. SQL Injection

- **Check**: Are prepared statements / parameterized queries used?
- **Typical failures**:
  - String concatenation in SQL: `"SELECT * FROM users WHERE id=" + id`
  - `mysqli_query()` with un-escaped input
  - ORM bypass with raw queries without parameters
- **Severity**: CRITICAL

## 3. CSRF (Cross-Site Request Forgery)

- **Check**: Do all state-changing endpoints have CSRF protection?
- **Typical failures**:
  - POST / PUT / DELETE without CSRF token
  - Token only in cookie, not in header / form (cookie-only is not safe)
  - `SameSite` cookie attribute missing
- **Severity**: CRITICAL for admin actions, WARNING for normal actions

## 4. Session Handling

- **Check**: Are sessions configured securely?
- **Typical failures**:
  - Session ID in URL instead of cookie
  - Missing `HttpOnly` / `Secure` / `SameSite` flags
  - No session timeout
  - Session fixation: session ID not rotated after login
- **Severity**: CRITICAL for missing base flags, WARNING for missing rotation

## 5. CORS (Cross-Origin Resource Sharing)

- **Check**: Is CORS configured correctly?
- **Typical failures**:
  - `Access-Control-Allow-Origin: *` together with credentials
  - Origin not validated (reflects any origin)
  - Preflight requests not handled correctly
- **Severity**: CRITICAL for wildcard + credentials, WARNING for overly open config

## 6. Input Validation

- **Check**: Are all external inputs validated?
- **Typical failures**:
  - File upload without extension / MIME-type check
  - Numeric parameters not range-checked
  - Path traversal: `../../../etc/passwd` not blocked
  - JSON / XML parsing without a size limit
- **Severity**: CRITICAL for path traversal / injection, WARNING for missing range checks

## 7. API Design

- **Check**: Is the API design consistent and secure?
- **Typical failures**:
  - Error responses leak stack traces or internal details
  - No versioning (breaking changes break clients silently)
  - Rate limiting missing on public endpoints
  - No pagination on list endpoints (memory blow-up on large datasets)
- **Severity**: WARNING

## 8. Browser Compatibility

- **Check**: Does the code work in the target browsers?
- **Typical failures**:
  - ES6+ syntax without transpilation for IE11
  - CSS features without fallback (Grid, Container Queries)
  - Web API without availability check (e.g. `navigator.clipboard`)
- **Severity**: WARNING (depends on target audience)

## 9. Performance

- **Check**: Are there obvious performance problems?
- **Typical failures**:
  - N+1 queries in loops
  - No pagination on large datasets
  - Synchronous operations that block the main thread
  - Missing caching headers
- **Severity**: WARNING for N+1, INFO for missing optimizations
