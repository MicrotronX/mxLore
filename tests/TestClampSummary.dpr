program TestClampSummary;

// Bug#2738 Phase 4 — standalone unit test for ClampSummary helper.
// Verifies the clamp logic that protects docs.summary_l1 VARCHAR(500)
// from overflow on the direct-input path (claude.exe AI-Batch can
// deliver summaries > 500 chars that fail at INSERT with SQL state 22001).
//
// Build:   dcc32 -B TestClampSummary.dpr  (or compile via IDE)
// Run:     TestClampSummary.exe
// Exit:    0 on all pass, 1 on any fail

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  mx.Tool.Write in '..\src\mx.Tool.Write.pas';

var
  Failures: Integer = 0;

procedure Assert(const Name: string; Cond: Boolean; const Detail: string = '');
begin
  if Cond then
    WriteLn('[PASS] ', Name)
  else
  begin
    WriteLn('[FAIL] ', Name, '  ', Detail);
    Inc(Failures);
  end;
end;

procedure Run;
var
  Input, Output: string;
  Umlauts: string;
begin
  // Case 1: empty
  Output := ClampSummary('');
  Assert('empty', Output = '', 'got=' + Output);

  // Case 2: short (unchanged)
  Output := ClampSummary('short summary');
  Assert('short unchanged', Output = 'short summary', 'got=' + Output);

  // Case 3: exactly 500 (unchanged, no ellipsis)
  Input := StringOfChar('x', 500);
  Output := ClampSummary(Input);
  Assert('500 chars exact',
    (Length(Output) = 500) and (Output = Input),
    Format('len=%d', [Length(Output)]));

  // Case 4: 501 chars (first overflow — clamp to 500 with ellipsis)
  Input := StringOfChar('x', 501);
  Output := ClampSummary(Input);
  Assert('501 clamped to 500',
    (Length(Output) = 500) and (Copy(Output, 498, 3) = '...'),
    Format('len=%d tail=%s', [Length(Output), Copy(Output, 498, 3)]));

  // Case 5: 1000 chars (far overflow)
  Input := StringOfChar('x', 1000);
  Output := ClampSummary(Input);
  Assert('1000 clamped to 500',
    (Length(Output) = 500) and (Copy(Output, 498, 3) = '...'),
    Format('len=%d tail=%s', [Length(Output), Copy(Output, 498, 3)]));

  // Case 6: German umlauts (char-count, not byte-count under utf8mb4).
  // "Uebung macht den Meister. " is 26 chars; * 25 = 650 chars.
  Umlauts := '';
  while Length(Umlauts) < 650 do
    Umlauts := Umlauts + #$DC + 'bung macht den Meister. '; // #$DC = U umlaut
  Output := ClampSummary(Umlauts);
  Assert('umlauts clamped',
    (Length(Output) = 500) and (Copy(Output, 498, 3) = '...'),
    Format('len=%d', [Length(Output)]));

  // Case 7: string length exactly 501 with boundary check on Copy(S,1,497)
  Input := StringOfChar('a', 497) + 'XYZW'; // 497 + 4 = 501
  Output := ClampSummary(Input);
  Assert('boundary 497+ellipsis',
    (Length(Output) = 500) and (Copy(Output, 1, 497) = StringOfChar('a', 497))
      and (Copy(Output, 498, 3) = '...'),
    Format('len=%d', [Length(Output)]));
end;

begin
  try
    WriteLn('== ClampSummary unit test (Bug#2738 Phase 4) ==');
    Run;
    WriteLn;
    if Failures = 0 then
    begin
      WriteLn('ALL PASS');
      ExitCode := 0;
    end
    else
    begin
      WriteLn(Format('%d FAILURE(S)', [Failures]));
      ExitCode := 1;
    end;
  except
    on E: Exception do
    begin
      WriteLn('EXCEPTION: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
