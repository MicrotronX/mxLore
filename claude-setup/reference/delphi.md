# Delphi – Senior Mindset Rules

> Referenced by `CLAUDE.md`. Load ONLY when needed.
> Applies to all Delphi projects (VCL, FMX, DataSnap, REST).

---

## Build & Toolchain

### Never assume "no Delphi environment available"

Neither `dcc32` nor `msbuild` is on the default `PATH`. Their absence proves nothing
about whether RAD Studio is installed — set up the environment first, then check.

`rsvars.bat` lives in the RAD Studio `bin` directory and sets:

| Variable | Meaning |
|----------|---------|
| `BDS` | RAD Studio installation root |
| `BDSINCLUDE`, `BDSCOMMONDIR` | include dir / shared user dir |
| `FrameworkDir`, `FrameworkVersion` | the .NET Framework directory used for the build |
| `PATH` | prepends `FrameworkDir`, `%BDS%\bin`, `%BDS%\bin64`, `%BDS%\cmake` |

Two consequences worth knowing:

- `dcc32.exe` / `dcc64.exe` live in `%BDS%\bin` — that is why they appear on `PATH`.
- `MSBuild.exe` is **not** part of RAD Studio; it ships with the .NET Framework and
  lives in `FrameworkDir`. It becomes callable only because `rsvars.bat` puts that
  directory on `PATH`.

`rsvars.bat` is a **cmd batch file**: it sets variables in the `cmd.exe` session that
runs it. Invoking it from PowerShell or a POSIX shell spawns a child `cmd`, and the
variables die with that child. Chain it with the build in a single `cmd` invocation.

### Building from the command line

```batch
rem Set up the environment, then build — one cmd session
call "%BDS%\bin\rsvars.bat"
msbuild MyProject.dproj /t:Build /p:Config=Debug /p:Platform=Win32
```

- `msbuild <project>.dproj` builds what the IDE builds: the `.dproj` imports
  `$(BDS)\Bin\CodeGear.Delphi.Targets`, which defines the `Build`, `Make` and `Clean`
  targets — the same ones the IDE drives.
- `Config` and `Platform` are ordinary MSBuild properties. The `.dproj` declares a
  default for each (`<Config Condition="'$(Config)'==''">`), so `/p:` overrides them.
- `/t:Clean` before `/t:Build` when stale `.dcu` files are suspected. `/t:Make` is the
  incremental variant.
- `dcc32` / `dcc64` can compile a single unit or a `.dpr` directly when no `.dproj`
  exists — but then unit search paths and conditional defines must be passed by hand,
  so the result no longer necessarily matches an IDE build.

### IDE artefacts are not source — never read them

The IDE stores revision backups right next to the code: `__history\` (per-file
revisions, e.g. `Unit1.pas.~235~`), `__recovery\` (crash recovery), and — depending on
project settings — the same `.~N~` files directly beside the unit.

- Never read, grep, index, or cite them, and exclude them from every search, refactor
  and code-generation pass.
- A `.~235~` file is an **old** revision. Treating it as current silently reintroduces
  logic that was already fixed — and the failure is invisible, because the stale code
  looks perfectly plausible.
- They also poison search results by sheer volume: one grep can return the same routine
  in a dozen versions and bury the one copy that actually compiles.

A prompt rule alone will not hold — enforce it in `~/.claude/settings.json`:

```json
"permissions": {
  "deny": ["Read(**/__history/**)", "Read(**/__recovery/**)", "Read(**/*.~*~)"]
}
```

This covers the `Read` tool, and — on a best-effort basis, per the permissions docs —
Grep, Glob, `@file` mentions and the file commands Claude Code recognises in Bash
(`cat`, `head`, `tail`, `sed`). It does **not** cover arbitrary subprocesses that open
files themselves (a Python/Node script, `find -exec cat`). For a hard, process-level
block, use the sandbox's `denyRead` instead.

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
- **Case-insensitive value comparison:** never compare a DB field value case-sensitively with `=` (`Field.AsString = 'marker'`) when the column's collation/storage does not guarantee case — many DBs/columns upper-case values on write. Use `SameText` / `AnsiSameText(Trim(Field.AsString), 'marker')`. A case-sensitive `=` against an upper-cased stored value **fails silently** — no error, just the wrong branch. (Note: the DB engine's own SQL `=`/`<>`/`LIKE` may be case-insensitive by collation while Pascal `=` stays case-sensitive — so the bug hides in the Pascal side only.)

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

## DFM & Form Streaming

Forms, frames, and data modules are **resolved at runtime via RTTI**, not at compile
time. A form whose `.dfm` and `.pas` disagree still compiles cleanly — the failure
surfaces as an access violation or a filer error when the form is created. The
compiler is not your safety net here.

### The DFM ↔ .pas contract (error source #1)

Every `object <Name>: <Type>` block in the `.dfm` needs a matching **field** in the
form class, and every event binding (`OnClick = BtnBrowseClick`) needs a matching
**method**. Both are resolved by name at runtime, and both are found **only if they are
`published`**.

```pascal
type
  TMainForm = class(TForm)
    BtnBrowse: TButton;                        // implicitly published — DFM finds it
    EdtPath: TEdit;
    procedure BtnBrowseClick(Sender: TObject); // handler bound in the DFM
  private
    FSettings: TSettings;                      // no DFM counterpart — correct here
  end;
```

In a form class, everything between `= class(TForm)` and the first explicit `private` /
`protected` / `public` is **implicitly published**. That is where the designer puts its
components and where manual additions belong; no explicit `published:` keyword is needed.

**`public` is not enough — only `published` works.** Visibility is not a spectrum here.
A field moved from the implicit section into `public` is exactly as invisible to the
streaming system as a `private` one.

The two failure modes are **not** the same, and the difference matters when debugging:

- **Event handler not published → hard error at load.** `TReader.FindMethod` resolves
  the handler via `Root.MethodAddress(MethodName)`; a `nil` result goes straight to
  `PropValueError`. So a handler in the wrong section produces an immediate, loud
  read error when the form is created.
- **Component field not published → silence.** `TComponent.SetReference` looks the field
  up via `TObject.FieldAddress` and assigns only `if Field <> nil`. A missing or
  non-published field is therefore a **no-op**: the component is still created and owned
  by the form, no exception is raised, and the form appears to load fine — the field
  simply stays `nil`. The access violation arrives later, wherever code first touches
  that reference. This is the more dangerous of the two, precisely because loading
  succeeds.

Further rules:

- Delete a published field in the `.pas` and the corresponding `object` block MUST go
  from the `.dfm` too (and vice versa). A leftover `object` block whose class is no
  longer reachable through the type declaration raises **`EClassNotFound`** — note this
  is about the missing *class*, not the missing *field*.
- Case may differ between `.pas` and `.dfm` — the name match is case-insensitive.

### The field is looked up on the Owner — not on the form by default

`SetReference` resolves the field on the component's **`Owner`**, not on whatever
object encloses it in the DFM text. Two consequences that look contradictory but are
not:

- **DFM nesting is not ownership.** A button placed on a panel is nested under that
  panel in the DFM, but the form is still its Owner (the panel is only its `Parent`).
  It therefore *does* need a field on the form. Do not assume "nested = no field needed".
- **Components owned by another component get no form field.** Where a third-party
  component creates children of its own (report fields under a pipeline, items under a
  collection owner), the lookup happens on that owner, not on the form — so no form
  field exists and none is needed.

A naive "every `object` block needs a form field" check flags the second group as
errors. Before believing such a finding on a large third-party form, check it against
the unmodified file: if the form has been loading for years, the finding is a false
positive, not something your edit introduced.

### Published semantics — what actually gets stored

- **All published properties are streamed by default.** You can exclude a property
  from storage (`stored False`) or decide dynamically via a function — but you cannot
  force a property to be stored that otherwise would not be.
- **`stored` / `default` / `nodefault` control storage only, never behaviour.** They
  do not initialize anything. A property whose current value equals its declared
  `default` is simply not written to the DFM.
- Consequence for hand-editing: a property you add manually that equals its default
  (or is `stored False`) is **removed again on the next IDE save**. That is documented
  behaviour, not a bug.
- `TComponent.Name` is itself published with `stored False`. Renaming a component at
  runtime invalidates every reference to the old name.
- Data too complex for automatic streaming (the classic case: `TStrings`) is persisted
  by overriding **`DefineProperties`** — call `inherited` first, then register your own
  read/write methods via `DefineProperty` / `DefineBinaryProperty`.
- A class referenced in a form declaration is registered automatically. Any other class
  whose instances get streamed must be registered explicitly with **`RegisterClass`**.
  Registering a *different* class under an already-taken name raises `EFilerError`.

### Owner vs. Parent — two independent relationships

- **Owner** = responsible for **streaming and freeing**. The form owns its designer
  components: it frees them, and it loads/saves their published properties.
- **Parent** = the windowed control that **visually contains** the control and writes
  it to the stream when the form is saved.
- A control can have a different Parent than Owner. Do not conflate them.
- ⚡ A component whose Owner is **not** a form or data module is **not streamed with
  its owner** unless it is explicitly marked via `SetSubComponent`. Rebuilding owner
  chains by hand without that marking makes properties silently vanish on the next save.

### Loading order and forward references

- After a component has read all its property values, the streaming system calls the
  virtual **`Loaded`** method — before the form is displayed. When overriding it, call
  `inherited Loaded` **first**.
- Anything that only makes sense once *all* sibling components exist (references to
  other controls on the same form) belongs in `Loaded`, **not** in the constructor.
  This is the official mechanism against forward-reference problems during load.
- Property references between components are resolved by `TReader`; references that
  cannot be satisfied yet are deferred through the fixup list rather than failing.
  That safety net covers the RTL's own streaming — it does not cover a third-party
  component that dereferences a referenced object during its own load. If a form dies
  with an AV inside an RTL/vendor package during creation and none of your code is on
  the stack, suspect a component reference the vendor resolves eagerly, and check that
  the referenced object sits where that vendor expects it (inside its repository or
  collection owner, not free-standing).

### Visual Form Inheritance & Frames — diffs only

- VFI writes **only the differences** to the ancestor (`TFiler.Ancestor`). An
  `inherited` block in a descendant DFM must contain only the properties that actually
  deviate. Duplicating the full ancestor property set contradicts the streaming model
  and gets reduced back to a diff on the next IDE save.
- Unmodified components of an embedded **frame** belong to the frame, not to the host
  form, and do **not** appear in the host DFM. Only changed components show up, inside
  the frame's `inline` block. Copying all frame components into the host DFM is wrong.
- A validator or edit that pairs DFM objects to `.pas` fields must skip `inherited` /
  `inline` blocks — those inherit their field from the ancestor or frame class.

### Text DFM is a projection, not a separate model

- Text and binary DFM are the same data. `ObjectTextToBinary` / `ObjectBinaryToText`
  convert between them, and the **same `TReader`/`TWriter` parser** consumes both.
- Therefore any structural slip in a hand-edited text DFM (missing `end`, wrong bracket
  type) is a hard parser error at the next load — never a silent ignore. Bracket types
  are meaningful: `[...]` set, `<...>` collection, `{...}` binary, `(...)` string list.
- `{$R *.dfm}` binds the form file to its unit. The compiler only records the name —
  a missing or broken `.dfm` fails at **link** time, not at parse time.

### What NOT to hand-edit

- Binary blocks (`{ ... }` — glyphs, images) and long string-list blocks (`( ... )`).
  Their content is arbitrary text and may itself contain the words `object` or `end`;
  a line-based parser that counts those keywords miscounts across such blocks.
- Pixel-perfect layout. When adding a control by hand, clone a real sibling of the same
  type in the same container, give it a unique name, anchor `Left`/`Top` relative to
  that sibling — and have a human check the result visually.
- ⚡ When cloning a control, review `OnClick` & friends **and** `Caption`/`Hint`. The
  designer carries event bindings over verbatim, so the clone silently fires the
  original's handler; a stale `Caption` holding the original's *name* is invisible on
  an icon-only button and surfaces much later.
- Non-visual components (datasets, queries, timers, data sources) carry no layout risk
  and are the safest thing to add by hand — but the DFM ↔ `.pas` field rule still applies.

### Encoding

Delphi recognizes UTF-8 **only by BOM**; without one it reads the file as ANSI
(Windows-1252). A UTF-8 file containing literal non-ASCII characters but no BOM is
misread and the damage is cemented on the next IDE save. Preserve a file's existing
encoding — do not "repair" it. See `encoding-details.md`.

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
