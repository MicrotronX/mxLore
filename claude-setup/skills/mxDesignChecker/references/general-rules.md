# General Review Rules (all languages / technologies)

## 1. Nil / Null Safety

- **Check**: Are return values from functions / methods checked for nil / null before being used?
- **Typical failures**:
  - API call returns nil, caller dereferences a property -> Access Violation / NullPointerException
  - Factory methods that return nil on error instead of raising an exception
  - Optional types that are not checked before unwrapping
- **Severity**: CRITICAL if a crash is likely, WARNING if only theoretically possible

## 2. Resource Leaks

- **Check**: Are all allocated resources released in a finally block?
- **Typical failures**:
  - Object created, exception thrown before Free -> leak
  - Stream / connection opened, no Close in finally
  - Tempfile created, never cleaned up
- **Severity**: CRITICAL for connection / handle leaks, WARNING for memory leaks

## 3. Exception Safety

- **Check**: Are exceptions handled correctly?
- **Typical failures**:
  - Empty catch / except blocks that swallow errors
  - Exception handler that logs the failure but continues in an inconsistent state
  - Finally block that can itself raise an exception and mask the original
- **Severity**: WARNING for exception swallowing, CRITICAL for inconsistent state

## 4. Backward Compatibility

- **Check**: Does the proposed change alter existing interfaces or data formats?
- **Typical failures**:
  - Method signature changed -> all callers must be updated
  - File format / registry schema changed -> old data can no longer be read
  - Default values changed -> implicit behavior changes silently
- **Severity**: CRITICAL for schema incompatibility, WARNING for signature changes

## 5. Encoding Risks

- **Check**: Are files read / written in the correct encoding?
- **Typical failures**:
  - ANSI file edited with a UTF-8 tool -> special characters destroyed
  - BOM added / removed -> parser problems
  - String literals with special characters in the wrong encoding
- **Severity**: CRITICAL when data loss occurs, WARNING when only cosmetic

## 6. Concurrency / Thread Safety

- **Check**: Are shared resources accessed in a thread-safe way?
- **Typical failures**:
  - Global variable without a lock
  - UI access from a worker thread
  - Race condition during initialization
- **Severity**: CRITICAL for race conditions, WARNING for theoretical risks

## 7. API Contracts

- **Check**: Are API contracts (parameter meaning, return values, side effects) respected?
- **Typical failures**:
  - Function expects an absolute path but receives a relative one
  - Return value ignored (e.g. `IncMilliSecond` in Delphi)
  - Parameter order swapped for similar types
- **Severity**: CRITICAL for silent misbehavior, WARNING for obvious errors

## 8. Sentinel / Magic Value Risks

- **Check**: Are sentinel values used that can collide with real data?
- **Typical failures**:
  - `$fff` (4095) as a "not present" marker — but 4095 is a valid screen coordinate
  - `-1` as an error return — but -1 is a valid index in some contexts
  - `""` as "no value" — but an empty string may itself be a valid value
- **Severity**: WARNING (often pre-existing, document rather than change)
