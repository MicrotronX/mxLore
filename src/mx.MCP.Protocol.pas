unit mx.MCP.Protocol;

interface

uses
  System.SysUtils, System.JSON,
  mx.MCP.Schema, mx.Types, mx.Errors, mx.Data.Pool;

const
  MCP_PROTOCOL_VERSION = '2024-11-05';
  MCP_SERVER_NAME = 'mxLore';
  MCP_SERVER_VERSION = MXAI_VERSION;

  // JSON-RPC error codes
  JSONRPC_PARSE_ERROR      = -32700;
  JSONRPC_INVALID_REQUEST  = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS   = -32602;
  JSONRPC_INTERNAL_ERROR   = -32603;

type
  TMxJsonRpcRequest = record
    Method: string;
    Params: TJSONObject;  // borrowed, do NOT free
    Id: TJSONValue;       // borrowed, do NOT free
    IsNotification: Boolean;
  end;

  TMxMcpProtocol = class
  private
    FRegistry: TMxMcpRegistry;
    FPool: TMxConnectionPool;
    FLogger: IMxLogger;
    function HandleInitialize: TJSONObject;
    function HandleToolsList: TJSONObject;
    function HandleToolsCall(const AParams: TJSONObject): string;
  public
    constructor Create(ARegistry: TMxMcpRegistry; APool: TMxConnectionPool;
      ALogger: IMxLogger);
    /// Parse raw JSON into a request record. Caller must free the returned
    /// TJSONObject in AOwned (the parsed root object that owns Params/Id).
    class function ParseRequest(const AJson: string;
      out AOwned: TJSONObject): TMxJsonRpcRequest;
    class function FormatResult(const AId: TJSONValue;
      AResult: TJSONObject): string;
    class function FormatResultRaw(const AId: TJSONValue;
      const ARawJson: string): string;
    class function FormatError(const AId: TJSONValue; ACode: Integer;
      const AMessage: string): string;
    /// Process a parsed request, return JSON-RPC response string.
    /// Returns empty string for notifications (no response needed).
    function ProcessRequest(const ARequest: TMxJsonRpcRequest): string;
  end;

implementation

uses
  System.Diagnostics, Data.DB, FireDAC.Comp.Client,
  mx.Tool.Registry, mx.Logic.AccessControl;

{ TMxMcpProtocol }

constructor TMxMcpProtocol.Create(ARegistry: TMxMcpRegistry;
  APool: TMxConnectionPool; ALogger: IMxLogger);
begin
  inherited Create;
  FRegistry := ARegistry;
  FPool := APool;
  FLogger := ALogger;
end;

class function TMxMcpProtocol.ParseRequest(const AJson: string;
  out AOwned: TJSONObject): TMxJsonRpcRequest;
var
  IdVal: TJSONValue;
begin
  AOwned := nil;
  Result.Method := '';
  Result.Params := nil;
  Result.Id := nil;
  Result.IsNotification := True;

  AOwned := TJSONObject.ParseJSONValue(AJson) as TJSONObject;
  if AOwned = nil then
    raise Exception.Create('Invalid JSON');

  Result.Method := AOwned.GetValue<string>('method', '');

  // params is optional
  if AOwned.GetValue('params') is TJSONObject then
    Result.Params := AOwned.GetValue('params') as TJSONObject;

  // id presence determines request vs notification
  IdVal := AOwned.GetValue('id');
  if IdVal <> nil then
  begin
    Result.Id := IdVal;
    Result.IsNotification := False;
  end;
end;

class function TMxMcpProtocol.FormatResult(const AId: TJSONValue;
  AResult: TJSONObject): string;
var
  Resp: TJSONObject;
begin
  Resp := TJSONObject.Create;
  try
    Resp.AddPair('jsonrpc', '2.0');
    if (AId <> nil) and (not (AId is TJSONNull)) then
      Resp.AddPair('id', AId.Clone as TJSONValue)
    else
      Resp.AddPair('id', TJSONNull.Create);
    Resp.AddPair('result', AResult.Clone as TJSONObject);
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;

class function TMxMcpProtocol.FormatResultRaw(const AId: TJSONValue;
  const ARawJson: string): string;
var
  Resp: TJSONObject;
  RawVal: TJSONValue;
begin
  Resp := TJSONObject.Create;
  try
    Resp.AddPair('jsonrpc', '2.0');
    if (AId <> nil) and (not (AId is TJSONNull)) then
      Resp.AddPair('id', AId.Clone as TJSONValue)
    else
      Resp.AddPair('id', TJSONNull.Create);
    // Parse raw JSON for the result
    RawVal := TJSONObject.ParseJSONValue(ARawJson);
    if RawVal <> nil then
      Resp.AddPair('result', RawVal)
    else
      Resp.AddPair('result', TJSONObject.Create.AddPair('text', ARawJson));
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;

class function TMxMcpProtocol.FormatError(const AId: TJSONValue;
  ACode: Integer; const AMessage: string): string;
var
  Resp, ErrObj: TJSONObject;
begin
  Resp := TJSONObject.Create;
  try
    Resp.AddPair('jsonrpc', '2.0');
    if (AId <> nil) and (not (AId is TJSONNull)) then
      Resp.AddPair('id', AId.Clone as TJSONValue)
    else
      Resp.AddPair('id', TJSONNull.Create);
    ErrObj := TJSONObject.Create;
    ErrObj.AddPair('code', TJSONNumber.Create(ACode));
    ErrObj.AddPair('message', AMessage);
    Resp.AddPair('error', ErrObj);
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;

function TMxMcpProtocol.HandleInitialize: TJSONObject;
var
  ServerInfo, Capabilities, ToolsCap: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('protocolVersion', MCP_PROTOCOL_VERSION);

  ServerInfo := TJSONObject.Create;
  ServerInfo.AddPair('name', MCP_SERVER_NAME);
  ServerInfo.AddPair('version', MCP_SERVER_VERSION);
  Result.AddPair('serverInfo', ServerInfo);

  Capabilities := TJSONObject.Create;
  ToolsCap := TJSONObject.Create;
  Capabilities.AddPair('tools', ToolsCap);
  Result.AddPair('capabilities', Capabilities);
end;

function TMxMcpProtocol.HandleToolsList: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('tools', FRegistry.ToToolListJSON);
end;

function TMxMcpProtocol.HandleToolsCall(const AParams: TJSONObject): string;
var
  ToolName: string;
  Arguments: TJSONObject;
  Handler: TMxToolHandler;
  ToolResult: TJSONObject;
  ResultText: string;
  Content: TJSONArray;
  ContentItem, ResultObj: TJSONObject;
  Compact: Boolean;
  SW: TStopwatch;
  LatencyMs, ResponseBytes: Integer;
  IsError: Boolean;
  ErrorCode: string;
begin
  if AParams = nil then
    raise EMxValidation.Create('Missing params for tools/call');

  ToolName := AParams.GetValue<string>('name', '');
  if ToolName = '' then
    raise EMxValidation.Create('Missing tool name');

  Handler := FRegistry.FindHandler(ToolName);
  if not Assigned(Handler) then
    raise EMxValidation.CreateFmt('Unknown tool: %s', [ToolName]);

  // Extract arguments (default empty object)
  var OwnsArguments := False;
  if (AParams.GetValue('arguments') <> nil) and
     (AParams.GetValue('arguments') is TJSONObject) then
    Arguments := AParams.GetValue('arguments') as TJSONObject
  else
  begin
    Arguments := TJSONObject.Create;
    OwnsArguments := True;
  end;

  // Extract compact flag from arguments
  Compact := False;
  if Arguments.GetValue('compact') <> nil then
    Compact := Arguments.GetValue<Boolean>('compact', False);

  // Execute via SafeExecute (handles auth, context, errors)
  SW := TStopwatch.StartNew;
  ToolResult := SafeExecute(Handler, Arguments, FPool, FLogger);
  try
    SW.Stop;
    LatencyMs := SW.ElapsedMilliseconds;

    if Compact then
      ResultText := StripCompactWrapper(ToolResult)
    else
      ResultText := ToolResult.ToJSON;

    ResponseBytes := TEncoding.UTF8.GetByteCount(ResultText);

    // Detect error in response
    IsError := ToolResult.GetValue('error') <> nil;
    if IsError then
      ErrorCode := Copy(ToolResult.GetValue<string>('error', ''), 1, 30)
    else
      ErrorCode := '';

    // Central tool call logging (non-critical, reuses pooled connection from SafeExecute)
    try
      var Auth := MxGetThreadAuth;
      var SessionId := Arguments.GetValue<Integer>('session_id', 0);
      var LogCtx := FPool.AcquireContext;
      var LogQry := LogCtx.CreateQuery(
        'INSERT INTO tool_call_log (tool_name, session_id, developer_id, ' +
        '  response_bytes, latency_ms, is_error, error_code) ' +
        'VALUES (:tool, :sid, :dev, :bytes, :ms, :err, :ecode)');
      try
        LogQry.ParamByName('tool').AsString := ToolName;
        if SessionId > 0 then
          LogQry.ParamByName('sid').AsInteger := SessionId
        else
        begin
          LogQry.ParamByName('sid').DataType := ftInteger;
          LogQry.ParamByName('sid').Clear;
        end;
        LogQry.ParamByName('dev').AsInteger := Auth.DeveloperId;
        LogQry.ParamByName('bytes').AsInteger := ResponseBytes;
        LogQry.ParamByName('ms').AsInteger := LatencyMs;
        LogQry.ParamByName('err').AsInteger := Ord(IsError);
        if IsError then
          LogQry.ParamByName('ecode').AsString := ErrorCode
        else
        begin
          LogQry.ParamByName('ecode').DataType := ftString;
          LogQry.ParamByName('ecode').Clear;
        end;
        LogQry.ExecSQL;
      finally
        LogQry.Free;
      end;
    except
      on E: Exception do
        FLogger.Log(mlDebug, 'Tool call log: ' + E.Message);
    end;
  finally
    ToolResult.Free;
  end;

  // Wrap in MCP tools/call response format:
  // { content: [{ type: "text", text: "<json>" }] }
  ContentItem := TJSONObject.Create;
  ContentItem.AddPair('type', 'text');
  ContentItem.AddPair('text', ResultText);

  Content := TJSONArray.Create;
  Content.Add(ContentItem);

  ResultObj := TJSONObject.Create;
  try
    ResultObj.AddPair('content', Content);
    Result := ResultObj.ToJSON;
  finally
    ResultObj.Free;
  end;
  if OwnsArguments then
    Arguments.Free;
end;

function TMxMcpProtocol.ProcessRequest(
  const ARequest: TMxJsonRpcRequest): string;
var
  InitResult, ListResult: TJSONObject;
  CallResultJson: string;
  CallResult: TJSONValue;
begin
  Result := '';

  // Notifications: no response
  if ARequest.IsNotification then
  begin
    FLogger.Log(mlDebug, 'MCP notification: ' + ARequest.Method);
    Exit;
  end;

  try
    if ARequest.Method = 'initialize' then
    begin
      InitResult := HandleInitialize;
      try
        Result := FormatResult(ARequest.Id, InitResult);
      finally
        InitResult.Free;
      end;
    end
    else if ARequest.Method = 'tools/list' then
    begin
      ListResult := HandleToolsList;
      try
        Result := FormatResult(ARequest.Id, ListResult);
      finally
        ListResult.Free;
      end;
    end
    else if ARequest.Method = 'tools/call' then
    begin
      CallResultJson := HandleToolsCall(ARequest.Params);
      // CallResultJson is already a JSON object string, parse and embed
      CallResult := TJSONObject.ParseJSONValue(CallResultJson);
      if CallResult <> nil then
      begin
        try
          Result := FormatResult(ARequest.Id, CallResult as TJSONObject);
        finally
          CallResult.Free;
        end;
      end
      else
        Result := FormatError(ARequest.Id, JSONRPC_INTERNAL_ERROR,
          'Failed to format tool result');
    end
    else
      Result := FormatError(ARequest.Id, JSONRPC_METHOD_NOT_FOUND,
        'Unknown method: ' + ARequest.Method);
  except
    on E: EMxValidation do
      Result := FormatError(ARequest.Id, JSONRPC_INVALID_PARAMS, E.Message);
    on E: Exception do
    begin
      FLogger.Log(mlError, 'MCP error: ' + E.Message);
      Result := FormatError(ARequest.Id, JSONRPC_INTERNAL_ERROR, E.Message);
    end;
  end;
end;

end.
