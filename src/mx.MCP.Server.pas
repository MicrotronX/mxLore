unit mx.MCP.Server;

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  Sparkle.HttpSys.Server,
  Sparkle.HttpServer.Module,
  Sparkle.HttpServer.Context,
  Sparkle.Middleware.Cors,
  Data.DB, FireDAC.Comp.Client,
  mx.Types, mx.Config, mx.Log, mx.Data.Pool, mx.Auth,
  mx.MCP.Schema, mx.MCP.Protocol, mx.Logic.AccessControl;

type
  TMxMcpApiModule = class(THttpServerModule)
  private
    FPool: TMxConnectionPool;
    FAuth: TMxAuthManager;
    FLogger: IMxLogger;
    FProtocol: TMxMcpProtocol;
    procedure HandleAgentInboxGet(const C: THttpServerContext;
      const AProject: string);
    procedure HandleAgentAckGet(const C: THttpServerContext;
      const AIds: string);
  protected
    procedure ProcessRequest(const C: THttpServerContext); override;
  public
    constructor Create(const ABaseUri: string; APool: TMxConnectionPool;
      AAuth: TMxAuthManager; ARegistry: TMxMcpRegistry;
      ALogger: IMxLogger); reintroduce;
    destructor Destroy; override;
  end;

  TMxMcpServer = class
  private
    FServer: THttpSysServer;
    FPool: TMxConnectionPool;
    FLogger: IMxLogger;
    FPort: Integer;
    FBindAddress: string;
  public
    constructor Create(APool: TMxConnectionPool; AAuth: TMxAuthManager;
      ARegistry: TMxMcpRegistry; AConfig: TMxConfig; ALogger: IMxLogger);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

implementation

{ TMxMcpApiModule }

constructor TMxMcpApiModule.Create(const ABaseUri: string;
  APool: TMxConnectionPool; AAuth: TMxAuthManager;
  ARegistry: TMxMcpRegistry; ALogger: IMxLogger);
begin
  inherited Create(ABaseUri);
  FPool := APool;
  FAuth := AAuth;
  FLogger := ALogger;
  FProtocol := TMxMcpProtocol.Create(ARegistry, APool, ALogger);
end;

destructor TMxMcpApiModule.Destroy;
begin
  FreeAndNil(FProtocol);
  inherited;
end;

procedure TMxMcpApiModule.ProcessRequest(const C: THttpServerContext);
var
  AuthHeader, Body, ResponseJson: string;
  AuthResult: TMxAuthResult;
  Bytes: TBytes;
  Request: TMxJsonRpcRequest;
  OwnedJson: TJSONObject;
  ResponseBytes: TBytes;
begin
  try
    // GET /mcp?agent_inbox=<project> — lightweight polling for proxy
    if C.Request.MethodType = THttpMethod.Get then
    begin
      var QS := C.Request.Uri.Query;
      var InboxIdx := Pos('agent_inbox=', LowerCase(QS));
      if InboxIdx > 0 then
      begin
        var InboxProject := Copy(QS, InboxIdx + 12, Length(QS));
        var AmpIdx := Pos('&', InboxProject);
        if AmpIdx > 0 then
          InboxProject := Copy(InboxProject, 1, AmpIdx - 1);
        if InboxProject <> '' then
        begin
          HandleAgentInboxGet(C, InboxProject);
          Exit;
        end;
      end;
      // GET /mcp?agent_ack=<id,id,...> — proxy confirms delivery
      var AckIdx := Pos('agent_ack=', LowerCase(QS));
      if AckIdx > 0 then
      begin
        var AckIds := Copy(QS, AckIdx + 10, Length(QS));
        var AmpIdx2 := Pos('&', AckIds);
        if AmpIdx2 > 0 then
          AckIds := Copy(AckIds, 1, AmpIdx2 - 1);
        if AckIds <> '' then
        begin
          HandleAgentAckGet(C, AckIds);
          Exit;
        end;
      end;

      C.Response.StatusCode := 405;
      C.Response.Close;
      Exit;
    end;

    // Only POST allowed for MCP
    if C.Request.MethodType <> THttpMethod.Post then
    begin
      C.Response.StatusCode := 405;
      C.Response.Close;
      Exit;
    end;

    // Auth: Bearer token
    AuthHeader := '';
    C.Request.Headers.GetIfExists('Authorization', AuthHeader);
    if AuthHeader = '' then
    begin
      C.Response.StatusCode := 401;
      ResponseBytes := TEncoding.UTF8.GetBytes('{"error":"Missing Authorization header"}');
      C.Response.Headers.SetValue('Content-Type', 'application/json');
      C.Response.Close(ResponseBytes);
      FLogger.Log(mlWarning, 'MCP auth failed: no Authorization header');
      Exit;
    end;

    AuthResult := FAuth.ValidateKey(AuthHeader);
    if not AuthResult.Valid then
    begin
      C.Response.StatusCode := 403;
      ResponseBytes := TEncoding.UTF8.GetBytes('{"error":"Invalid or expired API key"}');
      C.Response.Headers.SetValue('Content-Type', 'application/json');
      C.Response.Close(ResponseBytes);
      FLogger.Log(mlWarning, 'MCP auth failed: invalid key');
      Exit;
    end;

    // Store auth for tool handlers (threadvar)
    MxSetThreadAuth(AuthResult);

    // Read request body
    Body := TEncoding.UTF8.GetString(C.Request.Content);

    if Body = '' then
    begin
      C.Response.StatusCode := 400;
      ResponseBytes := TEncoding.UTF8.GetBytes('{"error":"Empty request body"}');
      C.Response.Headers.SetValue('Content-Type', 'application/json');
      C.Response.Close(ResponseBytes);
      Exit;
    end;

    // Parse and process JSON-RPC request
    OwnedJson := nil;
    try
      Request := TMxMcpProtocol.ParseRequest(Body, OwnedJson);
      ResponseJson := FProtocol.ProcessRequest(Request);
    finally
      OwnedJson.Free;
    end;

    // Notifications get no response
    if ResponseJson = '' then
    begin
      C.Response.StatusCode := 202;
      C.Response.Close;
      Exit;
    end;

    // Send JSON-RPC response
    C.Response.StatusCode := 200;
    C.Response.Headers.SetValue('Content-Type', 'application/json');
    ResponseBytes := TEncoding.UTF8.GetBytes(ResponseJson);
    C.Response.Close(ResponseBytes);

  except
    on E: Exception do
    begin
      FLogger.Log(mlError, 'MCP request error: ' + E.Message);
      C.Response.StatusCode := 500;
      ResponseJson := TMxMcpProtocol.FormatError(nil, -32700, 'Parse error');
      ResponseBytes := TEncoding.UTF8.GetBytes(ResponseJson);
      C.Response.Headers.SetValue('Content-Type', 'application/json');
      C.Response.Close(ResponseBytes);
    end;
  end;
end;

// GET ?agent_inbox=<project> — lightweight polling for proxy background thread
procedure TMxMcpApiModule.HandleAgentInboxGet(const C: THttpServerContext;
  const AProject: string);
var
  AuthHeader: string;
  AuthResult: TMxAuthResult;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  ProjectId: Integer;
  Arr: TJSONArray;
  Row, Resp: TJSONObject;
  ResponseBytes: TBytes;
begin
  // Auth: same Bearer token as MCP
  AuthHeader := '';
  C.Request.Headers.GetIfExists('Authorization', AuthHeader);
  if AuthHeader = '' then
  begin
    C.Response.StatusCode := 401;
    C.Response.Close;
    Exit;
  end;

  AuthResult := FAuth.ValidateKey(AuthHeader);
  if not AuthResult.Valid then
  begin
    C.Response.StatusCode := 403;
    C.Response.Close;
    Exit;
  end;

  try
    Ctx := FPool.AcquireAuthContext(AuthResult, FLogger);

    // Resolve project
    Qry := Ctx.CreateQuery(
      'SELECT id FROM projects WHERE slug = :slug AND is_active = TRUE');
    try
      Qry.ParamByName('slug').AsString := AProject;
      Qry.Open;
      if Qry.IsEmpty then
      begin
        C.Response.StatusCode := 404;
        C.Response.Close;
        Exit;
      end;
      ProjectId := Qry.FieldByName('id').AsInteger;
    finally
      Qry.Free;
    end;

    // ACL: check read access
    if not Ctx.AccessControl.CheckProject(ProjectId, alRead) then
    begin
      C.Response.StatusCode := 403;
      C.Response.Close;
      Exit;
    end;

    // Fetch pending messages (compact: only essential fields)
    Qry := Ctx.CreateQuery(
      'SELECT am.id, am.message_type, am.payload, am.ref_doc_id, ' +
      '  am.priority, am.created_at, p.slug AS sender_project ' +
      'FROM agent_messages am ' +
      'JOIN projects p ON am.sender_project_id = p.id ' +
      'WHERE am.target_project_id = :pid AND am.status = ''pending'' ' +
      'ORDER BY am.created_at ASC LIMIT 20');
    try
      Qry.ParamByName('pid').AsInteger := ProjectId;
      Qry.Open;

      Arr := TJSONArray.Create;
      while not Qry.Eof do
      begin
        Row := TJSONObject.Create;
        Row.AddPair('id', TJSONNumber.Create(Qry.FieldByName('id').AsInteger));
        Row.AddPair('type', Qry.FieldByName('message_type').AsString);
        Row.AddPair('payload', Qry.FieldByName('payload').AsString);
        Row.AddPair('from', Qry.FieldByName('sender_project').AsString);
        Row.AddPair('priority', Qry.FieldByName('priority').AsString);
        if not Qry.FieldByName('ref_doc_id').IsNull then
          Row.AddPair('ref', TJSONNumber.Create(Qry.FieldByName('ref_doc_id').AsInteger));
        Arr.Add(Row);
        Qry.Next;
      end;
    finally
      Qry.Free;
    end;

    // Note: messages stay 'pending' until proxy confirms delivery via
    // GET ?agent_ack=<id,id,...> — prevents data loss if proxy crashes

    Resp := TJSONObject.Create;
    try
      Resp.AddPair('count', TJSONNumber.Create(Arr.Count));
      Resp.AddPair('messages', Arr);
      C.Response.StatusCode := 200;
      C.Response.Headers.SetValue('Content-Type', 'application/json');
      ResponseBytes := TEncoding.UTF8.GetBytes(Resp.ToJSON);
      C.Response.Close(ResponseBytes);
    finally
      Resp.Free;
    end;
  except
    on E: Exception do
    begin
      FLogger.Log(mlError, '[agent_inbox_get] ' + E.Message);
      C.Response.StatusCode := 500;
      C.Response.Close;
    end;
  end;
end;

// GET ?agent_ack=<id,id,...> — proxy confirms delivery, mark as read
procedure TMxMcpApiModule.HandleAgentAckGet(const C: THttpServerContext;
  const AIds: string);
var
  AuthHeader: string;
  AuthResult: TMxAuthResult;
  Ctx: IMxDbContext;
  Qry: TFDQuery;
  ResponseBytes: TBytes;
begin
  AuthHeader := '';
  C.Request.Headers.GetIfExists('Authorization', AuthHeader);
  if AuthHeader = '' then
  begin
    C.Response.StatusCode := 401;
    C.Response.Close;
    Exit;
  end;

  AuthResult := FAuth.ValidateKey(AuthHeader);
  if not AuthResult.Valid then
  begin
    C.Response.StatusCode := 403;
    C.Response.Close;
    Exit;
  end;

  try
    Ctx := FPool.AcquireAuthContext(AuthResult, FLogger);

    // Validate: only allow comma-separated integers (prevent SQL injection)
    var SafeIds := '';
    var Parts := AIds.Split([',']);
    for var Part in Parts do
    begin
      var IdVal := StrToIntDef(Trim(Part), -1);
      if IdVal > 0 then
      begin
        if SafeIds <> '' then SafeIds := SafeIds + ',';
        SafeIds := SafeIds + IntToStr(IdVal);
      end;
    end;
    if SafeIds = '' then
    begin
      C.Response.StatusCode := 400;
      C.Response.Close;
      Exit;
    end;

    Qry := Ctx.CreateQuery(
      'UPDATE agent_messages SET status = ''read'', read_at = NOW() ' +
      'WHERE id IN (' + SafeIds + ') AND status = ''pending''');
    try
      Qry.ExecSQL;
    finally
      Qry.Free;
    end;

    C.Response.StatusCode := 200;
    ResponseBytes := TEncoding.UTF8.GetBytes('{"ok":true}');
    C.Response.Headers.SetValue('Content-Type', 'application/json');
    C.Response.Close(ResponseBytes);
  except
    on E: Exception do
    begin
      FLogger.Log(mlError, '[agent_ack_get] ' + E.Message);
      C.Response.StatusCode := 500;
      C.Response.Close;
    end;
  end;
end;

{ TMxMcpServer }

constructor TMxMcpServer.Create(APool: TMxConnectionPool;
  AAuth: TMxAuthManager; ARegistry: TMxMcpRegistry;
  AConfig: TMxConfig; ALogger: IMxLogger);
var
  BaseUrl: string;
begin
  inherited Create;
  FPool := APool;
  FLogger := ALogger;
  FPort := AConfig.ServerPort;
  FBindAddress := AConfig.BindAddress;

  if (FBindAddress = '') or (FBindAddress = '0.0.0.0') then
    BaseUrl := Format('http://+:%d/', [FPort])
  else
    BaseUrl := Format('http://%s:%d/', [FBindAddress, FPort]);

  FServer := THttpSysServer.Create;
  var Module := TMxMcpApiModule.Create(BaseUrl, APool, AAuth, ARegistry, ALogger);
  Module.AddMiddleware(TCorsMiddleware.Create('*', 'POST'));
  FServer.AddModule(Module);

  FLogger.Log(mlDebug, 'MCP server configured on port ' + IntToStr(FPort));
end;

destructor TMxMcpServer.Destroy;
begin
  Stop;
  FreeAndNil(FServer);
  inherited;
end;

procedure TMxMcpServer.Start;
begin
  FServer.Start;
  FLogger.Log(mlInfo, 'MCP server started on port ' + IntToStr(FPort));
end;

procedure TMxMcpServer.Stop;
begin
  if Assigned(FServer) then
  begin
    FServer.Stop;
    FLogger.Log(mlInfo, 'MCP server stopped');
  end;
end;

end.
