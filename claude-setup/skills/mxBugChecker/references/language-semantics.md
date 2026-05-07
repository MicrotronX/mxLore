## Language Semantics ⚡ (Bug#2989 F7 — isset Overclaim Fix)

Before claiming a language-level bug, verify against actual language semantics. Cross-reference this section during Phase 3 analysis for any finding that depends on how a language treats undefined/null/missing values. Common false-positive traps:

### PHP null-safety primitives — NONE emit "Undefined variable" warnings

- `isset($var)` / `isset($arr['k'])` — returns `false` on undefined OR null. No warning. No notice. Array-access form does NOT require the key to exist.
- `empty($var)` — returns `true` on undefined/null/0/`""`/`"0"`/`[]`/`false`. No warning even if `$var` was never set.
- `$a ?? $b` (null-coalesce) — short-circuits on undefined/null and returns `$b`. No warning. `$arr['k'] ?? 'default'` is safe even if `'k'` is missing.
- `array_key_exists('k', $arr)` — checks key presence without triggering on null values. No warning if `$arr` is an array. !confuse with `isset` — `isset` returns `false` for `null` values, `array_key_exists` returns `true`.
- `??=` (null-coalesce assignment, PHP 7.4+) — same semantics as `??`, null-safe.

**PHP constructs that DO warn on undefined:**
- Direct read: `$var` (bare access outside a null-safe primitive)
- String interpolation: `"hello $var"` or `"hello {$arr['k']}"`
- Array access without `isset`/`??` guard: `$arr['k']` when `'k'` may be missing
- Passing to functions that don't null-check the argument
- Concatenation: `'x' . $var` when `$var` may be undefined

**Verification protocol before filing a PHP undefined-variable/index finding:**
1. `Grep` the surrounding 5 lines around the alleged bug site.
2. Confirm the variable is read via a BARE access, not wrapped in `isset` / `empty` / `??` / `array_key_exists`.
3. If the bare access is on a branch guarded by an earlier `isset` in the same scope → no bug.
4. If unsure → mark the finding as `INFO` with `reachability: unverified` per the Severity Calibration section above. Do NOT file as WARNING.

### Other languages

Delphi/Pascal, JS/TS, Python, Go null-safety primitives live in `mxDesignChecker/references/` (language-specific rule files). Cross-read those when a finding hinges on language semantics. If the target language is NOT covered in the references and you are uncertain → finding goes to `INFO` with an explicit `language-semantics: unverified` note.
