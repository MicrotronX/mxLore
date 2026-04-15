# mxBugChecker — Category Catalog

Full bug-category taxonomy with example patterns. The SKILL.md body carries the short names; this reference file expands each with concrete examples and red flags to look for during Phase 3 analysis.

## 1. Logic
**What to look for:**
- Boolean confusion: `(a or b) and c` where operator precedence matters
- Dead code after unconditional `return` / `exit` / `raise`
- Wrong-direction assignments (`if x = 5` vs `if x == 5` in languages that allow both)
- Infinite loops: `while True` without a break condition, `for` with immutable loop var
- Off-by-one in index math: `for i := 0 to Length - 1` vs `for i := 0 to Length`
- Negation errors: `!(a || b)` vs `!a && !b` (De Morgan)

## 2. Runtime
**What to look for:**
- Nil-deref: `obj.Method` without a prior `if Assigned(obj)` or `obj != null` check
- Off-by-one: array index `arr[length]` instead of `arr[length-1]`
- Division by zero: `a / b` where `b` can be 0
- Invalid casts: `TMyClass(obj)` in Delphi without `is TMyClass` check
- Stack overflow: recursive calls without a base case or depth limit
- Integer overflow: `i + 1` where `i = MaxInt`

## 3. Edge Cases
**What to look for:**
- Empty collections: `arr[0]` on a zero-length array
- Boundary values: `0`, `-1`, `MaxInt`, `MinInt`, `NaN`, empty string, null
- Unicode / ANSI: Delphi `AnsiString` vs `String`, UTF-8 byte vs codepoint counts
- Date edges: month boundaries, year boundaries, DST transitions, 2038 epoch rollover
- Timezone assumptions: local vs UTC confusion

## 4. Error Handling
**What to look for:**
- Missing `try / except / finally` around IO/DB/network calls
- Swallowed exceptions: `except on E: Exception do ;` (empty handler)
- Incomplete cleanup: resource opened in try but freed only on success path
- Raising in finally (replaces original exception)
- Error codes ignored: function returns error code that caller never checks

## 5. Concurrency
**What to look for:**
- Unprotected shared access: global var mutated from multiple threads
- Missing locks: `TCriticalSection` declared but `Enter` / `Leave` skipped
- Deadlock: two locks taken in different orders across code paths
- TOCTOU (time-of-check to time-of-use): `if Exists(file) then Read(file)` without atomicity
- Race on initialization: double-checked locking without memory barriers

## 6. Resource Leaks
**What to look for:**
- Delphi: missing `Free` / `Destroy` / `FreeAndNil` on owned objects
- Missing `try / finally Free` pattern around objects created in a method
- Open file handles not closed on error path
- DB connections / streams not returned to pool on exception
- Event listeners registered but never unregistered

## 7. Security
**What to look for:**
- SQL injection: string concatenation of user input into query text (should be parameterized)
- Command injection: shell exec with user-controlled arguments (should use arg array)
- XSS: HTML output without escaping
- Path traversal: file operations with user-controlled path (look for `..`, absolute paths)
- Hardcoded credentials: passwords / API keys / tokens in source
- Insecure random: `Random()` used for security-sensitive tokens (should be CSPRNG)
- TLS downgrade: HTTPS → HTTP redirects followed automatically

## 8. Performance (only when bug-relevant)
**What to look for:**
- N+1 queries: loop that calls DB inside the body
- Unbounded data: query without `LIMIT` / pagination
- Blocking UI calls: long-running sync operation on UI thread
- O(n^2) algorithms on hot paths where O(n) is possible
- Cache invalidation bugs that cause stale reads

## Category Selection Rules

- Pick MAX 5 categories per run, matching the file type and nature of the change
- Fewer categories = more thorough analysis per category
- For Delphi `.pas` files prioritize: Resource Leaks, Runtime, Error Handling
- For PHP / web files prioritize: Security, Input Validation, Error Handling
- For SQL / DB code prioritize: Security (injection), Performance (N+1), Edge Cases
- For concurrency-heavy code prioritize: Concurrency, Runtime, Error Handling
