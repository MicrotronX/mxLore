# mxSpec Verification — Per-Target Grep/Glob Examples

Reference companion to SKILL.md "Verification" section. The 6 verify-targets
are listed terse in SKILL.md; this file holds the example commands plus the
pattern-rationale, so the main skill stays lean.

## Class names

- `Grep pattern='class <Name>\b' glob='*.php,*.pas,*.ts,*.js,*.py'`
- Must return at least one hit.

## Method / function names

- `Grep pattern='function <name>\b|def <name>\b|procedure <name>\b'`
- Must return a hit. Examples of past hallucinations: `storeTicket` vs actual
  `store`, `saveFoo` vs actual `persistFoo`.

## File paths (views, templates, controllers, units)

- `Glob pattern='<path>'` must return a match.
- Underscore vs hyphen matters: `notification_filters/create.php` is NOT the
  same as `notification-filters/form.php`. Never paraphrase a path from memory.

## i18n / language-key namespaces

- `Grep pattern="'<prefix>\." glob='lang/**/*.php,locales/**/*.json,resources/lang/**'`
- Prefix must exist. `notification_filter.*` and `notification_filters.*` are
  NOT the same key.

## AC / test counts

- When claiming "existing test has N cases" -> `Read` the test file AND count
  actual `it(` / `test(` / `assert` lines. Do not extrapolate from a summary
  or from memory.

## Plan / ADR / doc IDs (in Related or body prose)

- `mx_search` or `mx_detail` confirmation before writing the ID.
- Do not cite `Plan#145` unless you have just seen `doc_id=145` exist.

## Why these six (rationale)

If verification fails -> EITHER drop the claim entirely, OR mark it explicitly
as `**unverified:** <reason>` inline. Never write a plausible-sounding name
without proof. Downstream `/mxDesignChecker` catches unverified claims, but
the first line of defense is here at write-time — do not outsource integrity
to the reviewer.
