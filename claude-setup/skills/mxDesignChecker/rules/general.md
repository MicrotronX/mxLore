# Allgemeine Pruefregeln (alle Sprachen/Technologien)

## 1. Nil/Null-Safety

- **Pruefe**: Werden Rueckgabewerte von Funktionen/Methoden auf nil/null geprueft bevor sie verwendet werden?
- **Typische Fehler**:
  - API-Aufruf gibt nil zurueck → Zugriff auf Property → Access Violation / NullPointerException
  - Factory-Methoden die nil bei Fehler zurueckgeben statt Exception
  - Optional-Typen die nicht geprueft werden
- **Severity**: CRITICAL wenn ein Crash wahrscheinlich ist, WARNING wenn theoretisch moeglich

## 2. Resource Leaks

- **Pruefe**: Werden alle allozierten Ressourcen in einem finally-Block freigegeben?
- **Typische Fehler**:
  - Objekt erstellt, Exception vor Free → Leak
  - Stream/Connection geoeffnet, kein Close im finally
  - Tempfile erstellt, nicht aufgeraeumt
- **Severity**: CRITICAL bei Connection/Handle-Leaks, WARNING bei Memory-Leaks

## 3. Exception Safety

- **Pruefe**: Werden Exceptions korrekt behandelt?
- **Typische Fehler**:
  - Leere catch/except-Bloecke die Fehler verschlucken
  - Exception-Handler der den Fehler loggt aber trotzdem weitermacht in inkonsistentem Zustand
  - Finally-Block der selbst eine Exception werfen kann
- **Severity**: WARNING bei Exception-Swallowing, CRITICAL bei inkonsistentem Zustand

## 4. Abwaertskompatibilitaet

- **Pruefe**: Aendert die vorgeschlagene Aenderung bestehende Schnittstellen oder Datenformate?
- **Typische Fehler**:
  - Methodensignatur geaendert → alle Aufrufer muessen angepasst werden
  - Dateiformat/Registry-Schema geaendert → alte Daten werden nicht mehr gelesen
  - Default-Werte geaendert → implizites Verhalten aendert sich
- **Severity**: CRITICAL bei Schema-Inkompatibilitaet, WARNING bei Signatur-Aenderungen

## 5. Encoding-Risiken

- **Pruefe**: Werden Dateien im korrekten Encoding gelesen/geschrieben?
- **Typische Fehler**:
  - ANSI-Datei mit UTF-8-Tool bearbeitet → Sonderzeichen zerstoert
  - BOM hinzugefuegt/entfernt → Parser-Probleme
  - String-Literale mit Sonderzeichen in falscher Kodierung
- **Severity**: CRITICAL wenn Datenverlust, WARNING wenn nur kosmetisch

## 6. Concurrency / Thread-Safety

- **Pruefe**: Werden geteilte Ressourcen thread-safe zugegriffen?
- **Typische Fehler**:
  - Globale Variable ohne Lock
  - UI-Zugriff aus Worker-Thread
  - Race Condition bei Initialisierung
- **Severity**: CRITICAL bei Race Conditions, WARNING bei theoretischen Risiken

## 7. API-Vertraege

- **Pruefe**: Werden API-Vertraege (Parameter-Bedeutung, Rueckgabewerte, Seiteneffekte) eingehalten?
- **Typische Fehler**:
  - Funktion erwartet absoluten Pfad, bekommt relativen
  - Rueckgabewert ignoriert (z.B. IncMilliSecond in Delphi)
  - Parameter-Reihenfolge vertauscht bei aehnlichen Typen
- **Severity**: CRITICAL bei stillem Fehlverhalten, WARNING bei offensichtlichem Fehler

## 8. Sentinel/Magic-Value-Risiken

- **Pruefe**: Werden Sentinel-Werte verwendet die mit echten Daten kollidieren koennen?
- **Typische Fehler**:
  - `$fff` (4095) als "nicht vorhanden" Marker — aber 4095 ist eine gueltige Bildschirm-Koordinate
  - `-1` als Fehler-Rueckgabe — aber -1 ist ein gueltiger Index in manchen Kontexten
  - `""` als "kein Wert" — aber leerer String kann ein gueltiger Wert sein
- **Severity**: WARNING (oft pre-existing, dokumentieren statt aendern)
