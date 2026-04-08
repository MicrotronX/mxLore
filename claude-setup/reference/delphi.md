# Delphi – Senior-Mindset Rules

> Wird von `CLAUDE.md` referenziert. NUR bei Bedarf laden.
> Gilt fuer alle Delphi-Projekte (VCL, FMX, DataSnap, REST).

---

## Ownership & Lifecycle (KRITISCHSTE REGEL)

### TComponent-Ownership
- Wer `Owner` uebergibt, delegiert Lifetime-Management an den Owner
- Wer `nil` als Owner uebergibt, ist selbst fuer `Free` verantwortlich
- `Free` auf Komponente mit Owner ist KEIN Doppel-Free — `TComponent.Destroy` ruft `Owner.RemoveComponent(Self)` auf und entfernt sich aus der Owner-Liste
- Fruehes `Free` bei Owner-Komponenten ist erlaubt, aber meist unnoetig

```pascal
// OK — Owner gibt frei, kein manuelles Free noetig
btn := TButton.Create(Self);
btn.Parent := Panel1;
// btn wird automatisch freigegeben wenn Self zerstoert wird

// AUCH OK — fruehes Free entfernt sich aus Owner-Liste (kein Doppel-Free)
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

**Wann Owner, wann nil?**
- `Create(Self)` / `Create(Form)`: Komponente lebt solange wie Owner (UI-Elemente, lang-lebige Objekte)
- `Create(nil)`: kurzlebige Hilfs-Objekte, Objekte mit unklarer Lifetime, Performance-kritisch (kein Notification-Overhead)

### Destruktor-Reihenfolge
- Abhaengigkeiten in umgekehrter Erstellungsreihenfolge freigeben
- `FreeAndNil()` statt `.Free` — verhindert Dangling-Pointer-Zugriffe
- Im Destruktor: niemals Exceptions aufsteigen lassen (alles in try/except einwickeln)

### Interface-Referenzen
- Interfaces werden per Referenzzaehlung verwaltet — kein manuelles Free
- **NIE** Interface-Referenz und Objekt-Referenz auf dasselbe Objekt mischen (Referenzzaehler-Konflikt)
- `TInterfacedObject` als Basis wenn Interface-Ownership erwuenscht

---

## Memory Management

### Allgemeine Regeln
- Jedes `Create` braucht ein korrespondierendes `Free`/`FreeAndNil`
- try/finally ist PFLICHT bei manuellem Memory-Management:

```pascal
obj := TMyClass.Create;
try
  obj.DoSomething;
finally
  FreeAndNil(obj);
end;
```

### Collections & Listen
- `TObjectList<T>` mit `OwnsObjects := True` fuer automatische Freigabe
- Bei `OwnsObjects := False`: Elemente selbst freigeben vor List-Free
- Niemals Items aus `TObjectList` (OwnsObjects=True) extern freigeben
- `TStringList.OwnsObjects`: Default=False — Objects[] werden bei Clear/Delete NICHT freigegeben. Explizit `OwnsObjects := True` setzen wenn Objects[] Ownership gewuenscht

### Strings & Speicher
- `string` in Delphi ist reference-counted — kein manuelles Verwalten noetig
- `ShortString` nur noch in Legacy-Kontexten oder Interop
- Fuer grosse Binaerdaten: `TBytes` oder `TMemoryStream` statt string

---

## Klassendeklaration — Reihenfolge (WICHTIG)

Innerhalb jeder Sichtbarkeitssektion (`private`, `protected`, `public`, `published`)
gilt eine **strikte Reihenfolge**:

1. **Felder** (Variablen) — zuerst
2. **Methoden** (procedure/function) — danach
3. **Properties** — zuletzt

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

Beim Einfuegen neuer Members in bestehende Klassen:
- Neue Felder → nach dem letzten bestehenden Feld einfuegen
- Neue Methoden → nach dem letzten bestehenden Feld / vor Properties
- Neue Properties → am Ende der Sektion

---

## Compiler-Bewusstsein

### Anonymous Methods / Closures
- Anonymous Methods erzeugen **Heap-allozierte Frames** — nicht kostenlos
- Captured Variablen leben solange die Closure lebt — kann Memory-Leaks verursachen
- `var`-Parameter koennen NICHT in Anonymous Methods captured werden

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
- Generics erhoehen Compile-Zeit und Code-Groesse — gezielt einsetzen
- Generic Constraints explizit angeben: `TMyClass<T: class>`, `TMyClass<T: IInterface>`
- Generische Collections bevorzugen: `TList<T>`, `TDictionary<K,V>`, `TObjectList<T>`
- Keine tiefen Generics-Verschachtelungen (>2 Ebenen) — Lesbarkeit leidet

### RTTI
- `{$RTTI}` Direktiven gezielt setzen — Standard-RTTI erhoeht Binary-Groesse
- `TValue` fuer typsichere RTTI-Werte statt Casts ueber `Pointer`
- `TRttiContext.Create` ist kostenguenstig, aber `TRttiType`-Zugriffe cachen

---

## Delphi-Idiome (nicht Java/C# aufzwingen)

### Properties statt Getter/Setter-Methoden
```pascal
// FALSCH — Java-Stil
function GetName: string;
procedure SetName(const Value: string);

// RICHTIG — Delphi-Stil
property Name: string read FName write SetName;
```

### Message-Handling
- VCL-Messages ueber `procedure WMSize(var Msg: TWMSize); message WM_SIZE;`
- Niemals Windows-Messages direkt mit `SendMessage`/`PostMessage` posten wenn VCL-Wrapper existiert
- Custom-Messages: Konstanten im `WM_APP`-Bereich (`WM_APP + 1` bis `WM_APP + $3FFF`)

### Notification / TComponent.Notification
- Bei Komponentenreferenzen auf andere Komponenten: `Notification` ueberschreiben
- Verhindert Dangling-Pointer wenn referenzierte Komponente geloescht wird:

```pascal
procedure TMyComponent.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FTargetComponent) then
    FTargetComponent := nil;
end;
```

### Event-Handler
- Events als `TNotifyEvent` oder typisierte Procedure-of-Object definieren
- Vor Aufruf immer auf `Assigned()` pruefen: `if Assigned(FOnChange) then FOnChange(Self);`

---

## Fehlerbehandlung

### Exception-Hierarchie
- Eigene Exceptions von `Exception` oder spezifischen Subklassen ableiten
- Klassen-Naming: `E`-Prefix (EMyAppError, EValidationError)
- Exceptions fuer aussergewoehnliche Zustande — nicht fuer normalen Kontrollfluss

### try/except Regeln
- Niemals leere `except`-Bloecke (Fehler verschlucken)
- `on E: ESpecificException do` statt allgemeines `except`
- Re-raise mit `raise` (nicht `raise E`) um Stacktrace zu erhalten

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

### DataSnap-Proxies
- Proxy-Klassen werden per `UnMarshal` als **neue Instanzen** erzeugt — immer freigeben
- Niemals Proxy-Instanz cachen ohne Thread-Safety-Betrachtung
- Connection-Handling: `TSQLConnection` nicht in Threads teilen

### REST / TRESTClient
- `TRESTClient`, `TRESTRequest`, `TRESTResponse` koennen im Designer platziert werden
- `TRESTResponse.JSONValue` gibt keine Ownership ab — nicht freigeben
- Authentifizierung: `TCustomAuthenticator`-Subklasse, nie Token im URL-Parameter

### JSON
- `TJSONObject.ParseJSONValue` liefert Ownership — immer freigeben
- `TJSONObject` / `TJSONArray`: bei manueller Erstellung in try/finally
- `System.JSON.Builders` fuer komplexe JSON-Konstruktion bevorzugen

---

## Datenbank (FireDAC / BDE-Nachfolger)

- `TFDConnection` nie in Threads teilen — pro Thread eigene Connection
- `TFDQuery.Params` immer typisiert setzen: `ParamByName('x').AsInteger := 5`
- Niemals SQL via String-Konkatenation bauen — immer Parameter
- `TFDTransaction` explizit fuer Multi-Statement-Operationen
- `FetchOptions.Mode := fmAll` nur wenn Datenmenge bekannt klein ist

---

## Threading

### VCL-Thread-Safety
- VCL ist **nicht thread-safe** — alle UI-Zugriffe im Main-Thread
- `TThread.Synchronize` fuer blockierende UI-Updates
- `TThread.Queue` fuer nicht-blockierende UI-Updates (bevorzugt)

### TThread
- `FreeOnTerminate := True`: Objekt nie mehr nach `Execute` anfassen
- `Terminate` setzt nur Flag — kooperatives Abbrechen ueber `Terminated`-Check im Execute-Loop
- `TMonitor` oder `TCriticalSection` fuer shared state

### Parallel Programming Library (PPL)
- `TTask.Run` fuer einfache Hintergrundaufgaben
- `TParallel.For` nur wenn Iterationen wirklich unabhaengig
- Exceptions in Tasks: via `TTask.Wait` oder `ITask.Wait` abfangen

---

## Code-Qualitaet & Patterns

### Naming Conventions
- Klassen: `T`-Prefix (TMyClass)
- Interfaces: `I`-Prefix (IMyInterface)
- Felder: `F`-Prefix (FMyField)
- Konstanten: keine Prefix-Pflicht, aber ALL_CAPS oder CamelCase konsistent
- Parameter: keine Prefix-Pflicht, aber `A`-Prefix verbreitet (AValue, AIndex)

### Unit-Struktur
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
- ❌ Globale Variablen fuer State — stattdessen Klassen-Felder oder Singleton-Pattern
- ❌ `Application.ProcessMessages` in Schleifen — stattdessen Threading
- ❌ `Halt()` / `ExitProcess()` — kein sauberes Shutdown
- ❌ `Form.Free` statt `Form.Close` + `caFree` in OnClose
- ❌ Tiefe `with`-Verschachtelungen — Lesbarkeit und Debugging leiden
- ❌ `inherited` vergessen in ueberschriebenen Methoden (besonders Create/Destroy)

---

## VCL vs. FMX

### VCL-spezifisch
- `TWinControl` fuer Komponenten mit Handle, `TGraphicControl` ohne
- Handle-Zugriff: erst nach `HandleAllocated` oder in `CreateWnd`
- `Canvas` nur zwischen `BeginPaint`/`EndPaint` oder in `OnPaint`

### FMX-spezifisch
- Kein Handle-Konzept — plattformunabhaengig
- `TCanvas.BeginScene`/`EndScene` fuer direktes Zeichnen
- Styles ueber `StyleLookup` — nie direkt auf Sub-Controls zugreifen
- Plattform-spezifischer Code: `IFMXApplicationService` und Platform-Interfaces

---

## Performance

- `TStringBuilder` statt String-Konkatenation in Loops
- `SetLength` mit Pre-Allokation fuer Arrays die wachsen
- `TDictionary` fuer haeufige Key-Lookups statt linearer Suche
- Grosse Dateien: `TFileStream` statt `TStringList.LoadFromFile`
- `const`-Parameter fuer Strings und Records in Methoden-Signaturen (vermeidet Kopie)

```pascal
// BESSER — kein String-Copy
procedure DoSomething(const AName: string);

// Schlechter — erzeugt Kopie
procedure DoSomething(AName: string);
```
