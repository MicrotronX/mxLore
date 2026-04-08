unit mx.MCP.Schema;

interface

uses
  System.SysUtils, System.JSON, System.Generics.Collections,
  mx.Types;

type
  TMxParamType = (mptString, mptInteger, mptBoolean, mptNumber, mptArray);

  TMxToolParam = record
    Name: string;
    ParamType: TMxParamType;
    Required: Boolean;
    Description: string;
  end;

  TMxToolDef = class
  private
    FName: string;
    FDescription: string;
    FHandler: TMxToolHandler;
    FParams: TList<TMxToolParam>;
  public
    constructor Create(const AName: string; AHandler: TMxToolHandler);
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    property Name: string read FName;
    property Description: string read FDescription write FDescription;
    property Handler: TMxToolHandler read FHandler;
  end;

  TMxMcpRegistry = class
  private
    FTools: TObjectList<TMxToolDef>;
    FCurrent: TMxToolDef;
  public
    constructor Create;
    destructor Destroy; override;
    // Fluent API
    function Add(const AName: string; AHandler: TMxToolHandler): TMxMcpRegistry;
    function Desc(const ADescription: string): TMxMcpRegistry;
    function Param(const AName: string; AType: TMxParamType;
      ARequired: Boolean; const ADesc: string): TMxMcpRegistry;
    // Query
    function FindHandler(const AName: string): TMxToolHandler;
    function ToToolListJSON: TJSONArray;
    function ToolCount: Integer;
  end;

function ParamTypeToJsonType(AType: TMxParamType): string;

implementation

function ParamTypeToJsonType(AType: TMxParamType): string;
begin
  case AType of
    mptString:  Result := 'string';
    mptInteger: Result := 'integer';
    mptBoolean: Result := 'boolean';
    mptNumber:  Result := 'number';
    mptArray:   Result := 'array';
  else
    Result := 'string';
  end;
end;

{ TMxToolDef }

constructor TMxToolDef.Create(const AName: string; AHandler: TMxToolHandler);
begin
  inherited Create;
  FName := AName;
  FHandler := AHandler;
  FParams := TList<TMxToolParam>.Create;
end;

destructor TMxToolDef.Destroy;
begin
  FParams.Free;
  inherited;
end;

function TMxToolDef.ToJSON: TJSONObject;
var
  Schema, Props, ParamObj: TJSONObject;
  Req: TJSONArray;
  P: TMxToolParam;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', FName);
  Result.AddPair('description', FDescription);

  // inputSchema (JSON Schema)
  Schema := TJSONObject.Create;
  Schema.AddPair('type', 'object');

  Props := TJSONObject.Create;
  Req := TJSONArray.Create;

  for P in FParams do
  begin
    ParamObj := TJSONObject.Create;
    if P.ParamType = mptArray then
    begin
      ParamObj.AddPair('type', 'array');
      ParamObj.AddPair('items', TJSONObject.Create.AddPair('type', 'string'));
    end
    else
      ParamObj.AddPair('type', ParamTypeToJsonType(P.ParamType));
    ParamObj.AddPair('description', P.Description);
    Props.AddPair(P.Name, ParamObj);
    if P.Required then
      Req.Add(P.Name);
  end;

  Schema.AddPair('properties', Props);
  Schema.AddPair('required', Req);
  Result.AddPair('inputSchema', Schema);
end;

{ TMxMcpRegistry }

constructor TMxMcpRegistry.Create;
begin
  inherited Create;
  FTools := TObjectList<TMxToolDef>.Create(True);
  FCurrent := nil;
end;

destructor TMxMcpRegistry.Destroy;
begin
  FTools.Free;
  inherited;
end;

function TMxMcpRegistry.Add(const AName: string;
  AHandler: TMxToolHandler): TMxMcpRegistry;
begin
  FCurrent := TMxToolDef.Create(AName, AHandler);
  FTools.Add(FCurrent);
  Result := Self;
end;

function TMxMcpRegistry.Desc(const ADescription: string): TMxMcpRegistry;
begin
  if Assigned(FCurrent) then
    FCurrent.Description := ADescription;
  Result := Self;
end;

function TMxMcpRegistry.Param(const AName: string; AType: TMxParamType;
  ARequired: Boolean; const ADesc: string): TMxMcpRegistry;
var
  P: TMxToolParam;
begin
  if Assigned(FCurrent) then
  begin
    P.Name := AName;
    P.ParamType := AType;
    P.Required := ARequired;
    P.Description := ADesc;
    FCurrent.FParams.Add(P);
  end;
  Result := Self;
end;

function TMxMcpRegistry.FindHandler(const AName: string): TMxToolHandler;
var
  Tool: TMxToolDef;
begin
  Result := nil;
  for Tool in FTools do
    if SameText(Tool.Name, AName) then
      Exit(Tool.Handler);
end;

function TMxMcpRegistry.ToToolListJSON: TJSONArray;
var
  Tool: TMxToolDef;
begin
  Result := TJSONArray.Create;
  for Tool in FTools do
    Result.Add(Tool.ToJSON);
end;

function TMxMcpRegistry.ToolCount: Integer;
begin
  Result := FTools.Count;
end;

end.
