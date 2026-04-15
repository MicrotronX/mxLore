# Delphi / Object Pascal / VCL Review Rules

## 1. Ownership / Lifecycle

- **Check**: Is the `TComponent` owner set correctly? Are `Free` / `FreeAndNil` used correctly?
- **Typical failures**:
  - Object created with an owner but freed manually -> owner tries to free again later -> double-free
  - Object created without an owner, no `try / finally` -> memory leak
  - `FreeNotification` / `RemoveFreeNotification` missing on reference properties
  - `FreeAndNil` used in a destructor where `Free` suffices (but `FreeAndNil` is never wrong, only redundant)
- **Severity**: CRITICAL for double-free, WARNING for leaks

## 2. VCL FormState / Component Lifecycle

- **Check**: Are `FormState` and `ComponentState` queried correctly?
- **Typical failures**:
  - Accessing `Handle` before the handle was created (before `CreateWnd`)
  - Accessing components in `Destroy` even though `csDestroying` is set
  - `if not Assigned(self)` — has no effect, `self` is always assigned inside a method call
  - `FormState` flags (`fsVisible`, `fsShowing`, `fsCreating`) not checked before operations
- **Severity**: CRITICAL for handle access before creation, WARNING for missing state checks

## 3. ANSI / UTF-8 Encoding

- **Check**: Are `.pas` / `.dfm` / `.dpr` / `.dpk` files edited in the correct encoding?
- **Typical failures**:
  - Edit tool converts ANSI to UTF-8 -> umlauts in string literals destroyed (0xFC -> 0xEF 0xBF 0xBD)
  - File has non-ASCII bytes (>127) but is edited with a UTF-8 tool
  - PowerShell scripts used for file manipulation -> silent encoding conversion
- **Check points**:
  - Does the file being edited contain umlauts, sz, Euro, paragraph, ampersand in STRINGS (not only comments)?
  - If yes: emit a WARNING — the Edit tool can destroy ANSI bytes
  - If only in comments: INFO, low risk
- **Severity**: CRITICAL when string literals are affected, WARNING when only comments

## 4. Conditional Compilation

- **Check**: Are `{$ifdef}` / `{$endif}` guards correct and complete?
- **Typical failures**:
  - Code that needs `Framework_VCL` but is compiled under `Framework_FMX`
  - `ifdef mxerpbin` code that accesses units only available in the ERP build
  - Missing `else` branches in `ifdef` (what happens when the switch is NOT set?)
  - `ifdef` nesting unclear or inconsistent
- **Severity**: CRITICAL when code fails to compile, WARNING for dead code

## 5. Registry Compatibility

- **Check**: Do registry paths or value types change?
- **Typical failures**:
  - Registry path changed -> previously saved values are no longer found
  - Value type changed (REG_SZ -> REG_DWORD) -> `ReadInteger` reads the wrong type
  - `TRegIniFile` vs `TRegistry`: different path handling (section vs key)
  - Registry key creation: `OpenKey(path, true)` creates keys, `OpenKey(path, false)` does not
- **Severity**: CRITICAL for path incompatibility, WARNING for type changes

## 6. Application.MainForm

- **Check**: Is `Application.MainForm` checked against nil before access?
- **Typical failures**:
  - Access to `Application.MainForm.ClientRect` without a nil check
  - Early startup phase: `MainForm` is not yet created
  - DLL context: `Application.MainForm` can be nil
  - MDI child accesses main form: `Application.MainForm.FormStyle = fsMDIForm` without check
- **Severity**: CRITICAL for missing nil check in frequently-called code

## 7. Monitor / Multi-Monitor / DPI

- **Check**: Are monitor APIs used correctly?
- **Typical failures**:
  - `Screen.MonitorFromPoint` / `Screen.MonitorFromRect` can return nil
  - `Monitor.BoundsRect` vs `Monitor.WorkareaRect`: `WorkareaRect` excludes the taskbar
  - DPI changes at runtime (Windows DPI awareness)
  - Absolute vs relative coordinates on multi-monitor (negative coordinates on a left-hand monitor)
  - `MoveWindow` vs `SetWindowPlacement` vs `BoundsRect := ...` — different behavior
- **Severity**: CRITICAL for nil dereference, WARNING for wrong Rect usage

## 8. Memory Management (Delphi-specific)

- **Check**: Are all `Create` / `Free` pairs correct?
- **Typical failures**:
  - `TStringList.Create` without `try / finally / Free`
  - `TStream.Create` without `try / finally / Free`
  - Interface reference and object reference to the same instance -> ref-count problems
  - `Result` of a function call not freed when the caller has ownership
- **Severity**: CRITICAL for leaks in frequently-called code, WARNING otherwise

## 9. GetWindowPlacement / Window API

- **Check**: Are Windows API calls used correctly?
- **Typical failures**:
  - `Placement.length` not set before `GetWindowPlacement` -> undefined behavior
  - `MoveWindow` with wrong coordinates (Width / Height instead of Right / Bottom)
  - `IsWindowVisible` vs `Form.Visible` — different semantics
  - `Handle` access creates the window if it does not yet exist (side effect!)
- **Severity**: CRITICAL for undefined behavior, WARNING for semantic differences

## 10. Delphi Version Compatibility

- **Check**: Are all used APIs available in the active Delphi version?
- **Typical failures**:
  - Generics features only available starting from XE7
  - `System.Threading` only starting from XE7
  - `TMonitor.PixelsPerInch` only starting from XE8
  - `ARect.Height := value` (setter) only starting from a certain version
- **Note**: Read the active version from CLAUDE.md (current: Delphi 13)
- **Severity**: CRITICAL if the API is not available

## 11. Threading / Concurrency / Race Conditions

- **Check**: Are threads used correctly and safely?
- **Typical failures**:
  - **VCL access from a worker thread**: every access to VCL components (controls, forms, properties) MUST go through `TThread.Synchronize` or `TThread.Queue`
  - **Global variables without a lock**: shared variables (global vars, singleton fields) read / written from multiple threads without `TCriticalSection`, `TMonitor.Enter / Exit`, or `TInterlocked`
  - **Race condition during initialization**: lazy-init pattern (`if FInstance = nil then FInstance := TFoo.Create`) without a lock -> two threads create the instance simultaneously
  - **TThread.WaitFor in the main thread**: blocks the UI thread -> deadlock if the worker thread calls `Synchronize`
  - **TEvent / TSignal not correct**: `WaitFor` without timeout -> hangs forever if the signal never comes
  - **TStringList / TList not thread-safe**: the standard container classes are NOT thread-safe — parallel access without a lock causes corruption
  - **FreeOnTerminate + lingering reference**: `TThread.FreeOnTerminate := True` while other code still holds a reference -> Access Violation after termination
  - **Synchronize inside a DLL**: `TThread.Synchronize` only works correctly if `Application.Handle` is set — often not the case in DLLs
- **Severity**: CRITICAL for VCL access from a worker thread and race conditions, WARNING for missing timeouts

## 12. String Handling / Unicode

- **Check**: Are strings converted and compared correctly?
- **Typical failures**:
  - `AnsiString` and `UnicodeString` mixed without explicit conversion -> silent data loss from Delphi 2009 on
  - `PChar` / `PAnsiChar` confusion -> compiler warning ignored, runtime crash or garbage
  - `Copy(s, i, n)` with a byte index instead of a character index on UTF-16 strings
  - `Length(s)` returns characters (not bytes) — external APIs (WinAPI, database) may expect bytes
  - `CompareStr` (case-sensitive) vs `CompareText` (case-insensitive) vs `AnsiCompareText` (locale-aware) — wrong comparison chosen
  - `Pos()` / `StringReplace` case-sensitivity not considered
- **Severity**: CRITICAL for data loss from silent conversion, WARNING for wrong comparisons

## 13. Exception Handling (Delphi-specific)

- **Check**: Are exceptions caught and handled correctly?
- **Typical failures**:
  - Empty `except` block (`except end;`) swallows ALL exceptions including `EAccessViolation` — only acceptable when deliberately documented
  - `except on E: Exception` instead of a specific exception class -> catches too much
  - `raise` vs `raise Exception.Create` — for a re-raise you MUST use `raise;` without parameters (otherwise the stack trace is lost)
  - Exception inside a `finally` block: silently overwrites the original exception
  - `ShowMessage` in an exception handler: blocks when the form is not visible -> hang
  - `EAbort` / `Abort` is swallowed by empty except blocks — program flow becomes unpredictable
- **Severity**: CRITICAL for swallowed exceptions in critical code, WARNING for overly broad exception handlers

## 14. Database / SQL (Delphi context)

- **Check**: Are database operations used correctly and safely?
- **Typical failures**:
  - SQL injection: string concatenation instead of parameterized queries (`SQL.Text := 'SELECT * FROM t WHERE id=' + id`)
  - Transaction not correct: `StartTransaction` without `Commit` / `Rollback` inside `try / finally`
  - `DisableControls` / `EnableControls` not in `try / finally` -> controls stay disabled after an exception
  - `Active := True` instead of `Open` — semantically the same, but `Open` is more explicit
  - Cursor after a query not reset to `First` -> the first record is skipped
  - `RecordCount` on large datasets: on some DB engines (ADS) this reads ALL records -> performance disaster
  - `Locate()` vs `FindKey()` — different semantics on partial matches
  - N+1 query problem: query inside a loop instead of a JOIN or batch query
- **Severity**: CRITICAL for SQL injection and missing transactions, WARNING for performance problems

## 15. Property Setter Side Effects

- **Check**: Do property setters have unexpected side effects?
- **Typical failures**:
  - Property write triggers notification / change event -> recursive call
  - Setter calls `Invalidate` / `Repaint` -> performance hit on batch updates (100x setter = 100x repaint)
  - Setter does not check `FValue <> Value` -> unnecessary work and events
  - Setter in the constructor: the component is not fully loaded (`csLoading` not checked)
  - `Assign` vs direct property access: `Assign` copies, direct access can create reference problems
- **Severity**: WARNING for missing guard checks, CRITICAL for infinite recursion

## 16. Variant / OleVariant Risks

- **Check**: Are variant types used safely?
- **Typical failures**:
  - Access to a variant without a `VarType` check -> `EVariantTypeCastError` on `Null` or wrong type
  - `VarIsNull` vs `VarIsEmpty` vs `VarIsClear` — different semantics
  - Variant array without a correct bounds check
  - `c__triggerconstants.getvalue()` returns a variant -> use `.S()`, `.I()`, `.F()`, `.B()` instead of casting directly
  - `OleVariant` in a non-COM context: unnecessary overhead and restrictions
- **Severity**: CRITICAL for variant-null crashes, WARNING for performance impact

## 17. Timer / Message Handling

- **Check**: Are timers and Windows messages used correctly?
- **Typical failures**:
  - `TTimer.Enabled := True` without a preceding `Enabled := False` -> timer runs twice
  - Timer event accesses freed objects (timer fires during `Destroy`)
  - `PostMessage` vs `SendMessage`: `PostMessage` is asynchronous — the object can be freed between post and processing
  - Custom messages (`WM_USER + x`): collision with framework messages if the offset is too small
  - `Application.ProcessMessages` in loops: reentrancy risk (button click during processing)
- **Severity**: CRITICAL for reentrancy and use-after-free, WARNING for timer duplicates

## 18. Typecast Safety

- **Check**: Are typecasts performed safely?
- **Typical failures**:
  - Hard cast `TFoo(obj)` instead of `obj as TFoo` -> no runtime check, Access Violation on wrong type
  - `is` / `as` check on a nil object: `nil is TFoo` returns `False`, but `nil as TFoo` raises an exception
  - `Sender as TButton` in an `OnClick` without a prior `is` check -> Access Violation when the event comes from another control
  - Integer typecast to pointer: `Integer(Pointer)` is 32-bit; on a 64-bit platform it is truncated — use `NativeInt`
- **Severity**: CRITICAL for hard casts on unchecked types, WARNING for missing `is` checks

## 19. Anonymous Methods / Closures + `var` Parameter Conflict

- **Check**: Is the same variable passed both as a `var` parameter AND captured by an anonymous method?
- **Background**: The Delphi compiler moves captured variables to a heap frame. If the same variable is simultaneously bound as a `var` parameter, the compiler can bind the `var` parameter to the old stack address -> writes via `var` are not seen by the closure (and vice versa).
- **Typical failures**:
  - `Foo(myVar, procedure begin Bar(myVar); end)` where `Foo` takes the first parameter as `var` -> `myVar` is both `var`-bound and captured
  - DataSnap / REST proxy calls with `var` parameters inside closures -> proxy replaces the object via unmarshal, but the `var` parameter does not see the change
  - Symptom: "correct in the debugger, but wrong after return" — intermittent, more frequent with large payloads
- **Fix pattern**: Do NOT capture the variable; pass it as an **explicit parameter** of the anonymous method instead:
  ```pascal
  // WRONG:
  SafeCall(v, procedure begin Proxy.Method(v); end);  // v captured + var
  // RIGHT:
  type TSafeProc = reference to procedure(var vTP: TMyClass);
  SafeCall(v, procedure(var vTP: TMyClass) begin Proxy.Method(vTP); end);  // no capture
  ```
- **Design principle**: When an abstraction exposes a compiler problem -> fix the interface (change the proc signature), do NOT throw the abstraction away and inline-replace it
- **Severity**: CRITICAL — leads to silent data loss, hard to reproduce, easy to overlook
