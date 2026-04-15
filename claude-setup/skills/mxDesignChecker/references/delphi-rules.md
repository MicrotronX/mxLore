# Delphi / Object Pascal / VCL Pruefregeln

## 1. Ownership / Lifecycle

- **Pruefe**: Ist der TComponent-Owner korrekt gesetzt? Wird Free/FreeAndNil korrekt verwendet?
- **Typische Fehler**:
  - Objekt mit Owner erstellt aber manuell gefreed → Owner versucht spaeter nochmal zu freeen → Double-Free
  - Objekt ohne Owner erstellt, kein try/finally → Memory Leak
  - FreeNotification/RemoveFreeNotification fehlt bei Referenz-Properties
  - `FreeAndNil` in Destructor verwendet wo `Free` reicht (aber FreeAndNil ist nie falsch, nur ueberflussig)
- **Severity**: CRITICAL bei Double-Free, WARNING bei Leaks

## 2. VCL FormState / Component Lifecycle

- **Pruefe**: Werden FormState und ComponentState korrekt abgefragt?
- **Typische Fehler**:
  - Zugriff auf `Handle` bevor das Handle erstellt wurde (vor `CreateWnd`)
  - Zugriff auf Komponenten im `Destroy` obwohl `csDestroying` gesetzt ist
  - `if not assigned(self)` — wirkungslos, self ist immer zugewiesen wenn die Methode aufgerufen wird
  - FormState-Flags (fsVisible, fsShowing, fsCreating) nicht geprueft vor Operationen
- **Severity**: CRITICAL bei Handle-Zugriff vor Erstellung, WARNING bei fehlenden State-Checks

## 3. ANSI / UTF-8 Encoding

- **Pruefe**: Werden .pas/.dfm/.dpr/.dpk Dateien im korrekten Encoding bearbeitet?
- **Typische Fehler**:
  - Edit-Tool konvertiert ANSI nach UTF-8 → Umlaute in String-Literalen zerstoert (0xFC → 0xEF 0xBF 0xBD)
  - Datei hat Nicht-ASCII-Bytes (>127) aber wird mit UTF-8-Tool bearbeitet
  - PowerShell-Skripte fuer Datei-Manipulation → stille Encoding-Konvertierung
- **Pruefpunkte**:
  - Enthaelt die zu bearbeitende Datei Umlaute, ss, Euro, Paragraph, Ampersand in STRINGS (nicht nur Kommentaren)?
  - Falls ja: WARNUNG ausgeben, Edit-Tool kann ANSI-Bytes zerstoeren
  - Falls nur in Kommentaren: INFO, geringes Risiko
- **Severity**: CRITICAL wenn String-Literale betroffen, WARNING wenn nur Kommentare

## 4. Conditional Compilation

- **Pruefe**: Sind {$ifdef}/{$endif}-Guards korrekt und vollstaendig?
- **Typische Fehler**:
  - Code der Framework_VCL braucht aber unter Framework_FMX kompiliert wird
  - ifdef mxerpbin Code der Zugriff auf Units hat die nur im ERP-Build verfuegbar sind
  - Fehlende else-Zweige bei ifdef (was passiert wenn der Schalter NICHT gesetzt ist?)
  - ifdef-Verschachtelung unklar oder inkonsistent
- **Severity**: CRITICAL wenn Code nicht kompiliert, WARNING bei totem Code

## 5. Registry-Kompatibilitaet

- **Pruefe**: Aendern sich Registry-Pfade oder Wert-Typen?
- **Typische Fehler**:
  - Registry-Pfad geaendert → alte gespeicherte Werte werden nicht mehr gefunden
  - Wert-Typ geaendert (REG_SZ → REG_DWORD) → ReadInteger liest falschen Typ
  - TRegIniFile vs TRegistry: unterschiedliches Pfad-Handling (Section vs Key)
  - Registry-Key-Erstellung: `OpenKey(path, true)` erstellt Keys, `OpenKey(path, false)` nicht
- **Severity**: CRITICAL bei Pfad-Inkompatibilitaet, WARNING bei Typ-Aenderungen

## 6. Application.MainForm

- **Pruefe**: Wird `Application.MainForm` vor Zugriff auf nil geprueft?
- **Typische Fehler**:
  - Zugriff auf `Application.MainForm.ClientRect` ohne nil-Check
  - Fruehe Startup-Phase: MainForm ist noch nicht erstellt
  - DLL-Kontext: Application.MainForm kann nil sein
  - MDI-Child greift auf MainForm zu: `Application.MainForm.FormStyle = fsMDIForm` ohne Check
- **Severity**: CRITICAL bei fehlendem nil-Check in haeufig aufgerufenem Code

## 7. Monitor / Multi-Monitor / DPI

- **Pruefe**: Werden Monitor-APIs korrekt verwendet?
- **Typische Fehler**:
  - `Screen.MonitorFromPoint` / `Screen.MonitorFromRect` kann nil zurueckgeben
  - Monitor.BoundsRect vs Monitor.WorkareaRect: WorkareaRect beruecksichtigt Taskbar
  - DPI-Aenderungen zur Laufzeit (Windows DPI Awareness)
  - Absolute vs relative Koordinaten bei Multi-Monitor (negative Koordinaten auf linkem Monitor)
  - `MoveWindow` vs `SetWindowPlacement` vs `BoundsRect := ...` — unterschiedliches Verhalten
- **Severity**: CRITICAL bei nil-Dereference, WARNING bei falscher Rect-Verwendung

## 8. Memory Management (Delphi-spezifisch)

- **Pruefe**: Sind alle Create/Free-Paare korrekt?
- **Typische Fehler**:
  - `TStringList.Create` ohne try/finally/Free
  - `TStream.Create` ohne try/finally/Free
  - Interface-Referenz und Objekt-Referenz auf gleiche Instanz → Reference-Count-Probleme
  - `Result` eines Funktionsaufrufs nicht gefreed wenn Caller Ownership hat
- **Severity**: CRITICAL bei Leak in haeufig aufgerufenem Code, WARNING sonst

## 9. GetWindowPlacement / Window-API

- **Pruefe**: Werden Windows-API-Aufrufe korrekt verwendet?
- **Typische Fehler**:
  - `Placement.length` nicht gesetzt vor `GetWindowPlacement` → undefined behavior
  - `MoveWindow` mit falschen Koordinaten (Width/Height statt Right/Bottom)
  - `IsWindowVisible` vs `Form.Visible` — unterschiedliche Semantik
  - `Handle`-Zugriff erzeugt Fenster wenn es noch nicht existiert (Seiteneffekt!)
- **Severity**: CRITICAL bei undefined behavior, WARNING bei Semantik-Unterschieden

## 10. Delphi-Version-Kompatibilitaet

- **Pruefe**: Sind alle verwendeten APIs in der aktiven Delphi-Version verfuegbar?
- **Typische Fehler**:
  - Generics-Features die erst ab XE7 verfuegbar sind
  - `System.Threading` erst ab XE7
  - `TMonitor.PixelsPerInch` erst ab XE8
  - `ARect.Height := value` (setter) erst ab bestimmter Version
- **Hinweis**: Aktive Version aus CLAUDE.md lesen (aktuell: Delphi 13)
- **Severity**: CRITICAL wenn API nicht verfuegbar

## 11. Threading / Concurrency / Race Conditions

- **Pruefe**: Werden Threads korrekt und sicher verwendet?
- **Typische Fehler**:
  - **VCL-Zugriff aus Worker-Thread**: Jeder Zugriff auf VCL-Komponenten (Controls, Forms, Properties) MUSS ueber `TThread.Synchronize` oder `TThread.Queue` laufen
  - **Globale Variablen ohne Lock**: Geteilte Variablen (globale Vars, Singleton-Felder) werden aus mehreren Threads gelesen/geschrieben ohne `TCriticalSection`, `TMonitor.Enter/Exit` oder `TInterlocked`
  - **Race Condition bei Initialisierung**: Lazy-Init-Pattern (`if FInstance = nil then FInstance := TFoo.Create`) ohne Lock → zwei Threads erstellen gleichzeitig die Instanz
  - **TThread.WaitFor im Main-Thread**: Blockiert den UI-Thread → Deadlock wenn der Worker-Thread `Synchronize` aufruft
  - **TEvent/TSignal nicht korrekt**: `WaitFor` ohne Timeout → haengt ewig wenn Signal nie kommt
  - **TStringList/TList nicht thread-safe**: Standard-Containerklassen sind NICHT thread-safe — paralleler Zugriff ohne Lock fuehrt zu Korruption
  - **FreeOnTerminate + Referenz**: `TThread.FreeOnTerminate := True` aber anderer Code haelt noch eine Referenz auf den Thread → Access Violation nach Beendigung
  - **Synchronize in DLL**: `TThread.Synchronize` funktioniert nur korrekt wenn `Application.Handle` korrekt gesetzt ist — in DLLs oft nicht der Fall
- **Severity**: CRITICAL bei VCL-Zugriff aus Worker-Thread und Race Conditions, WARNING bei fehlenden Timeouts

## 12. String-Handling / Unicode

- **Pruefe**: Werden Strings korrekt konvertiert und verglichen?
- **Typische Fehler**:
  - `AnsiString` und `UnicodeString` gemischt ohne explizite Konvertierung → stille Datenverluste ab Delphi 2009
  - `PChar`/`PAnsiChar` Verwechslung → Compiler-Warnung ignoriert, zur Laufzeit Crash oder Muell
  - `Copy(s, i, n)` mit Byte-Index statt Zeichen-Index bei UTF-16-Strings
  - `Length(s)` gibt Zeichen (nicht Bytes) zurueck — bei externen APIs (WinAPI, Datenbank) Bytes erwartet
  - `CompareStr` (case-sensitive) vs `CompareText` (case-insensitive) vs `AnsiCompareText` (Locale-aware) — falscher Vergleich
  - `Pos()` / `StringReplace` Case-Sensitivity nicht beachtet
- **Severity**: CRITICAL bei Datenverlust durch stille Konvertierung, WARNING bei falschen Vergleichen

## 13. Exception-Handling (Delphi-spezifisch)

- **Pruefe**: Werden Exceptions korrekt gefangen und behandelt?
- **Typische Fehler**:
  - Leerer `except`-Block (`except end;`) verschluckt ALLE Exceptions inkl. `EAccessViolation` — nur akzeptabel wenn bewusst dokumentiert
  - `except on E: Exception` statt spezifischer Exception-Klasse → faengt zu viel
  - `raise` vs `raise Exception.Create` — bei Re-Raise MUSS `raise;` ohne Parameter verwendet werden (sonst geht Stack-Trace verloren)
  - Exception im `finally`-Block: ueberschreibt die urspruengliche Exception still
  - `ShowMessage` im Exception-Handler: blockiert bei nicht-sichtbarer Form → haengt
  - `EAbort` / `Abort` wird von leeren except-Bloecken verschluckt — Programmfluss unberechenbar
- **Severity**: CRITICAL bei verschluckten Exceptions in kritischem Code, WARNING bei zu breiten Exception-Handlern

## 14. Datenbank / SQL (Delphi-Kontext)

- **Pruefe**: Werden Datenbank-Operationen korrekt und sicher verwendet?
- **Typische Fehler**:
  - SQL-Injection: String-Konkatenation statt parametrisierte Queries (`SQL.Text := 'SELECT * FROM t WHERE id=' + id`)
  - Transaktion nicht korrekt: `StartTransaction` ohne `Commit`/`Rollback` im try/finally
  - `DisableControls`/`EnableControls` nicht im try/finally → Controls bleiben deaktiviert nach Exception
  - `Active := True` statt `Open` — semantisch gleich, aber `Open` ist expliziter
  - Cursor nach Query nicht auf `First` gesetzt → erster Record wird uebersprungen
  - `RecordCount` auf grossen Datasets: bei einigen DB-Engines (ADS) liest das ALLE Records → Performance-Desaster
  - `Locate()` vs `FindKey()` — unterschiedliche Semantik bei Teiluebereinstimmungen
  - N+1 Query-Problem: Query in Schleife statt JOIN oder Batch-Query
- **Severity**: CRITICAL bei SQL-Injection und fehlenden Transaktionen, WARNING bei Performance-Problemen

## 15. Property-Setter Seiteneffekte

- **Pruefe**: Haben Property-Setter unerwartete Seiteneffekte?
- **Typische Fehler**:
  - Property-Write loest Notification/Change-Event aus → rekursiver Aufruf
  - Setter ruft `Invalidate`/`Repaint` auf → Performance bei Batch-Updates (100x Setter = 100x Repaint)
  - Setter prueft `FValue <> Value` nicht → unnoetige Arbeit und Events
  - Setter im Constructor: Component ist noch nicht vollstaendig geladen (`csLoading` nicht geprueft)
  - `Assign` vs direkter Property-Zugriff: `Assign` kopiert, direkter Zugriff kann Referenz-Probleme erzeugen
- **Severity**: WARNING bei fehlenden Guard-Checks, CRITICAL bei Endlosrekursion

## 16. Variant / OleVariant Risiken

- **Pruefe**: Werden Variant-Typen sicher verwendet?
- **Typische Fehler**:
  - Zugriff auf Variant ohne VarType-Pruefung → `EVariantTypeCastError` bei `Null` oder falschem Typ
  - `VarIsNull` vs `VarIsEmpty` vs `VarIsClear` — unterschiedliche Semantik
  - Variant-Array ohne korrekte Bounds-Pruefung
  - `c__triggerconstants.getvalue()` gibt Variant zurueck → `.S()`, `.I()`, `.F()`, `.B()` verwenden statt direkt casten
  - OleVariant in Nicht-COM-Kontext: unnoetige Overhead und Einschraenkungen
- **Severity**: CRITICAL bei Variant-Null-Crash, WARNING bei Performance-Impact

## 17. Timer / Message-Handling

- **Pruefe**: Werden Timer und Windows-Messages korrekt verwendet?
- **Typische Fehler**:
  - `TTimer.Enabled := True` ohne vorheriges `Enabled := False` → Timer laeuft doppelt
  - Timer-Event greift auf freigegebene Objekte zu (Timer feuert waehrend `Destroy`)
  - `PostMessage` vs `SendMessage`: PostMessage ist asynchron — Objekt kann zwischen Post und Verarbeitung freigegeben werden
  - Custom Messages (`WM_USER + x`): Kollision mit Framework-Messages wenn Offset zu klein
  - `Application.ProcessMessages` in Schleifen: Reentrancy-Risiko (Button-Click waehrend Verarbeitung)
- **Severity**: CRITICAL bei Reentrancy und Use-After-Free, WARNING bei Timer-Duplikaten

## 18. Typecast-Sicherheit

- **Pruefe**: Werden Typecasts sicher durchgefuehrt?
- **Typische Fehler**:
  - Hard-Cast `TFoo(obj)` statt `obj as TFoo` → kein Runtime-Check, AV bei falschem Typ
  - `is`/`as`-Check auf nil-Objekt: `nil is TFoo` gibt `False`, aber `nil as TFoo` wirft Exception
  - `Sender as TButton` im OnClick ohne vorherige `is`-Pruefung → AV wenn Event von anderem Control kommt
  - Integer-Typecast auf Pointer: `Integer(Pointer)` ist 32-Bit, auf 64-Bit-Plattform abgeschnitten → `NativeInt` verwenden
- **Severity**: CRITICAL bei Hard-Casts auf ungepruefte Typen, WARNING bei fehlender is-Pruefung

## 19. Anonymous Methods / Closures + var-Parameter Konflikt

- **Pruefe**: Wird dieselbe Variable sowohl als `var`-Parameter uebergeben ALS AUCH von einer Anonymous Method captured?
- **Hintergrund**: Delphi-Compiler verschiebt gecapturte Variablen auf einen Heap-Frame. Wird dieselbe Variable gleichzeitig als `var`-Parameter gebunden, kann der Compiler den `var`-Parameter auf die alte Stack-Adresse binden → Schreibvorgaenge ueber `var` werden von der Closure nicht gesehen (und umgekehrt).
- **Typische Fehler**:
  - `Foo(myVar, procedure begin Bar(myVar); end)` wo `Foo` den ersten Parameter als `var` nimmt → `myVar` wird sowohl `var`-gebunden als auch captured
  - DataSnap/REST-Proxy-Calls mit `var`-Parametern in Closures → Proxy ersetzt Object via UnMarshal, aber `var`-Parameter sieht die Aenderung nicht
  - Symptom: "Im Debugger korrekt, aber nach Rueckkehr falscher Wert" — intermittent, haeuft sich bei grossen Daten
- **Fix-Pattern**: Variable NICHT capturen, sondern als **expliziten Parameter** der Anonymous Method durchreichen:
  ```pascal
  // FALSCH:
  SafeCall(v, procedure begin Proxy.Method(v); end);  // v captured + var
  // RICHTIG:
  type TSafeProc = reference to procedure(var vTP: TMyClass);
  SafeCall(v, procedure(var vTP: TMyClass) begin Proxy.Method(vTP); end);  // kein Capture
  ```
- **Design-Prinzip**: Wenn eine Abstraktion ein Compiler-Problem aufdeckt → Schnittstelle reparieren (Proc-Signatur aendern), NICHT Abstraktion wegwerfen und inline ersetzen
- **Severity**: CRITICAL — fuehrt zu stillem Datenverlust, schwer reproduzierbar, leicht zu uebersehen
