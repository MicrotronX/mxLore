# Delphi – Senior Mindset Rules

> Referenced by `CLAUDE.md`. Load ONLY when needed.
> Applies to all Delphi projects (VCL, FMX, DataSnap, REST).

---

## Ownership & Lifecycle (MOST CRITICAL RULE)

### TComponent Ownership
- Whoever passes `Owner` delegates lifetime management to the Owner
- Whoever passes `nil` as Owner is responsible for `Free` themselves
- `Free` on a component with an Owner is NOT a double-free — `TComponent.Destroy` calls `Owner.RemoveComponent(Self)` and removes itself from the Owner list
- Early `Free` of owned components is allowed but usually unnecessary

```pascal
// OK — Owner releases, no manual Free needed
btn := TButton.Create(Self);
btn.Parent := Panel1;
// btn is automatically freed when Self is destroyed

// ALSO OK — early Free removes itself from Owner list (no double-free)
btn := TButton.Create(Self);
try
  // kurzlebige Nutzung
finally
  FreeAndNil(btn); // ruft RemoveComponent auf, Owner vergisst btn
end;

// OHNE OWNER — manuelles Free ist PFLICHT
btn := TButton.Create(nil);
try
  // ...
finally
  FreeAndNil(btn); // ohne das → Memory Leak
end;
```

**When Owner, when nil?**
- `Create(Self)` / `Create(Form)`: component lives as long as the Owner (UI elements, long-lived objects)
- `Create(nil)`: short-lived helper objects, objects with unclear lifetime, performance-critical (no notification overhead)

### Destructor Order
- Release dependencies in the reverse order of creation
- `FreeAndNil()` instead of `.Free` — prevents dangling pointer access
- In the destructor: never let exceptions propagate (wrap everything in try/except)

### Interface References
- Interfaces are managed via reference counting — no manual Free
- **NEVER** mix interface references and object references to the same object (reference counter conflict)
- `TInterfacedObject` as a base when interface ownership is desired

---

## Memory Management

### General Rules
- Every `Create` requires a corresponding `Free`/`FreeAndNil`
- try/finally is MANDATORY for manual memory management:

```pascal
obj := TMyClass.Create;
try
  obj.DoSomething;
finally
  FreeAndNil(obj);
end;
```

### Collections & Lists
- `TObjectList<T>` with `OwnsObjects := True` for automatic release
- With `OwnsObjects := False`: free elements yourself before freeing the list
- Never free items from a `TObjectList` (OwnsObjects=True) externally
- `TStringList.OwnsObjects`: Default=False — Objects[] are NOT freed on Clear/Delete. Explicitly set `OwnsObjects := True` if Objects[] ownership is desired

### Strings & Memory
- `string` in Delphi is reference-counted — no manual management needed
- `ShortString` only in legacy contexts or interop
- For large binary data: `TBytes` or `TMemoryStream` instead of string

---

## Class Declaration — Order (IMPORTANT)

Within each visibility section (`private`, `protected`, `public`, `published`)
a **strict order** applies:

1. **Fields** (variables) — first
2. **Methods** (procedure/function) — next
3. **Properties** — last

```pascal
// RICHTIG:
private
    FName: string;              // 1. Felder (F-Prefix → private)
    FAge: Integer;
    procedure InternalCalc;     // 2. Methoden
public
    procedure DoSomething;      // 2. Methoden
    function GetInfo: string;
    property Name: string read FName write FName;  // 3. Properties
    property Age: Integer read FAge;

// FALSCH — Compiler-Fehler:
private
    procedure DoSomething;      // Methode VOR Feld
    FName: string;              // ← FEHLER: Feld nach Methode
```

When inserting new members into existing classes:
- New fields → insert after the last existing field
- New methods → after the last existing field / before properties
- New properties → at the end of the section

---

## Compiler Awareness

### Anonymous Methods / Closures
- Anonymous methods create **heap-allocated frames** — not free of cost
- Captured variables live as long as the closure lives — can cause memory leaks
- `var` parameters CANNOT be captured in anonymous methods

```pascal
// PROBLEM: i wird captured, aber als Referenz!
for i := 0 to 9 do
  List.Add(procedure begin DoSomething(i) end);
// Alle Closures sehen dasselbe i (= 10 nach Loop)

// LOESUNG 1 (ab Delphi 10.3 Rio): Inline-Variable erzeugt eigenen Frame
for i := 0 to 9 do
begin
  var local := i;  // inline var = eigener Capture-Frame
  List.Add(procedure begin DoSomething(local) end);
end;

// LOESUNG 2 (alle Versionen): Hilfsfunktion erzeugt eigenen Frame
function CaptureProc(AValue: Integer): TProc;
begin
  Result := procedure begin DoSomething(AValue) end;
end;

for i := 0 to 9 do
  List.Add(CaptureProc(i));
```

### Generics
- Generics increase compile time and code size — use deliberately
- Specify generic constraints explicitly: `TMyClass<T: class>`, `TMyClass<T: IInterface>`
- Prefer generic collections: `TList<T>`, `TDictionary<K,V>`, `TObjectList<T>`
- No deep generics nesting (>2 levels) — readability suffers

### RTTI
- Set `{$RTTI}` directives deliberately — default RTTI increases binary size
- `TValue` for type-safe RTTI values instead of casts via `Pointer`
- `TRttiContext.Create` is cheap, but cache `TRttiType` accesses

---

## Delphi Idioms (Don't Force Java/C# Style)

### Properties Instead of Getter/Setter Methods
```pascal
// FALSCH — Java-Stil
function GetName: string;
procedure SetName(const Value: string);

// RICHTIG — Delphi-Stil
property Name: string read FName write SetName;
```

### Message Handling
- VCL messages via `procedure WMSize(var Msg: TWMSize); message WM_SIZE;`
- Never post Windows messages directly with `SendMessage`/`PostMessage` if a VCL wrapper exists
- Custom messages: constants in the `WM_APP` range (`WM_APP + 1` to `WM_APP + $3FFF`)

### Notification / TComponent.Notification
- For component references to other components: override `Notification`
- Prevents dangling pointers when the referenced component is deleted:

```pascal
procedure TMyComponent.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FTargetComponent) then
    FTargetComponent := nil;
end;
```

### Event Handlers
- Define events as `TNotifyEvent` or typed procedure-of-object
- Always check `Assigned()` before calling: `if Assigned(FOnChange) then FOnChange(Self);`

---

## Error Handling

### Exception Hierarchy
- Derive your own exceptions from `Exception` or specific subclasses
- Class naming: `E` prefix (EMyAppError, EValidationError)
- Exceptions for exceptional states — not for normal control flow

### try/except Rules
- Never empty `except` blocks (swallowing errors)
- `on E: ESpecificException do` instead of generic `except`
- Re-raise with `raise` (not `raise E`) to preserve the stack trace

```pascal
// FALSCH
try
  DoSomething;
except
  // nichts — Fehler verschluckt!
end;

// RICHTIG
try
  DoSomething;
except
  on E: EMyException do
    Logger.Error('DoSomething failed: ' + E.Message);
  on E: Exception do
    raise; // unbekannte Exceptions weiterleiten
end;
```

---

## DataSnap / REST

### DataSnap Proxies
- Proxy classes are created as **new instances** via `UnMarshal` — always free them
- Never cache a proxy instance without thread-safety considerations
- Connection handling: do not share `TSQLConnection` across threads

### REST / TRESTClient
- `TRESTClient`, `TRESTRequest`, `TRESTResponse` can be placed in the designer
- `TRESTResponse.JSONValue` does not transfer ownership — do not free
- Authentication: use a `TCustomAuthenticator` subclass, never put a token in a URL parameter

### JSON
- `TJSONObject.ParseJSONValue` returns ownership — always free
- `TJSONObject` / `TJSONArray`: when manually created, use try/finally
- Prefer `System.JSON.Builders` for complex JSON construction

---

## Database (FireDAC / BDE Successor)

- Never share `TFDConnection` across threads — one connection per thread
- Always set `TFDQuery.Params` typed: `ParamByName('x').AsInteger := 5`
- Never build SQL via string concatenation — always use parameters
- `TFDTransaction` explicitly for multi-statement operations
- `FetchOptions.Mode := fmAll` only if the dataset is known to be small

---

## Threading

### VCL Thread Safety
- VCL is **not thread-safe** — all UI access from the main thread
- `TThread.Synchronize` for blocking UI updates
- `TThread.Queue` for non-blocking UI updates (preferred)

### TThread
- `FreeOnTerminate := True`: never touch the object after `Execute`
- `Terminate` only sets a flag — cooperative cancellation via `Terminated` check in the Execute loop
- `TMonitor` or `TCriticalSection` for shared state

### Parallel Programming Library (PPL)
- `TTask.Run` for simple background tasks
- `TParallel.For` only when iterations are truly independent
- Exceptions in tasks: catch via `TTask.Wait` or `ITask.Wait`

---

## Code Quality & Patterns

### Naming Conventions
- Classes: `T` prefix (TMyClass)
- Interfaces: `I` prefix (IMyInterface)
- Fields: `F` prefix (FMyField)
- Constants: no prefix required, but ALL_CAPS or CamelCase consistently
- Parameters: no prefix required, but `A` prefix is common (AValue, AIndex)

### Unit Structure
```
unit MyUnit;

interface
uses
  // Nur was im Interface gebraucht wird

type
  // Typen, Klassen, Interfaces

const
  // Konstanten

var
  // Globale Variablen (sparsam!)

implementation
uses
  // Nur was in der Implementation gebraucht wird
```

### Anti-Patterns
- ❌ Global variables for state — use class fields or the singleton pattern instead
- ❌ `Application.ProcessMessages` in loops — use threading instead
- ❌ `Halt()` / `ExitProcess()` — no clean shutdown
- ❌ `Form.Free` instead of `Form.Close` + `caFree` in OnClose
- ❌ Deep `with` nesting — readability and debugging suffer
- ❌ Forgetting `inherited` in overridden methods (especially Create/Destroy)

---

## VCL vs. FMX

### VCL-Specific
- `TWinControl` for components with a handle, `TGraphicControl` without
- Handle access: only after `HandleAllocated` or in `CreateWnd`
- `Canvas` only between `BeginPaint`/`EndPaint` or in `OnPaint`

### FMX-Specific
- No handle concept — platform-independent
- `TCanvas.BeginScene`/`EndScene` for direct drawing
- Styles via `StyleLookup` — never access sub-controls directly
- Platform-specific code: `IFMXApplicationService` and platform interfaces

---

## Performance

- `TStringBuilder` instead of string concatenation in loops
- `SetLength` with pre-allocation for arrays that grow
- `TDictionary` for frequent key lookups instead of linear search
- Large files: `TFileStream` instead of `TStringList.LoadFromFile`
- `const` parameters for strings and records in method signatures (avoids copies)

```pascal
// BESSER — kein String-Copy
procedure DoSomething(const AName: string);

// Schlechter — erzeugt Kopie
procedure DoSomething(AName: string);
```
