unit mx.Logic.RateLimit;

// v2.4.0: Generic rolling-window rate limiter (Spec #1755, Plan #1756 Phase 2.3).
// Thread-safe. Use for invite link endpoints, login attempts, etc.
//
// Example:
//   FRateLimit := TMxRateLimit.Create(10, 60);  // 10 req / 60 sec
//   if not FRateLimit.TryAcquire(ClientIp) then
//     Exit(Send429);

interface

uses
  System.SysUtils, System.Classes, System.Diagnostics,
  System.Generics.Collections, System.SyncObjs;

type
  // Int64 = monotonic ticks from TStopwatch.GetTimeStamp (not TDateTime —
  // monotonic clock is immune to wall-clock jumps / DST transitions).
  TMxRateLimit = class
  private
    FBuckets: TObjectDictionary<string, TQueue<Int64>>;
    FLock: TCriticalSection;
    FMaxRequests: Integer;
    FWindowSeconds: Integer;
    FWindowTicks: Int64;  // precomputed: WindowSeconds * Frequency
    procedure PruneOldEntries(AQueue: TQueue<Int64>; ACutoff: Int64);
  public
    constructor Create(AMaxRequests, AWindowSeconds: Integer);
    destructor Destroy; override;

    /// <summary>
    ///   Attempts to record a new request for the given key. Returns True if
    ///   allowed (count incremented), False if the rolling-window limit has
    ///   been reached.
    /// </summary>
    function TryAcquire(const AKey: string): Boolean;

    /// <summary>
    ///   Removes buckets that have no active entries. Call periodically
    ///   (e.g. from a timer) to keep memory bounded.
    /// </summary>
    procedure CleanupExpired;

    property MaxRequests: Integer read FMaxRequests;
    property WindowSeconds: Integer read FWindowSeconds;
  end;

implementation

{ TMxRateLimit }

constructor TMxRateLimit.Create(AMaxRequests, AWindowSeconds: Integer);
begin
  inherited Create;
  if AMaxRequests <= 0 then
    raise EArgumentException.Create('AMaxRequests must be > 0');
  if AWindowSeconds <= 0 then
    raise EArgumentException.Create('AWindowSeconds must be > 0');
  FMaxRequests := AMaxRequests;
  FWindowSeconds := AWindowSeconds;
  FWindowTicks := Int64(AWindowSeconds) * TStopwatch.Frequency;
  FBuckets := TObjectDictionary<string, TQueue<Int64>>.Create([doOwnsValues]);
  FLock := TCriticalSection.Create;
end;

destructor TMxRateLimit.Destroy;
begin
  FBuckets.Free;
  FLock.Free;
  inherited;
end;

procedure TMxRateLimit.PruneOldEntries(AQueue: TQueue<Int64>; ACutoff: Int64);
begin
  while (AQueue.Count > 0) and (AQueue.Peek < ACutoff) do
    AQueue.Dequeue;
end;

function TMxRateLimit.TryAcquire(const AKey: string): Boolean;
var
  Queue: TQueue<Int64>;
  NowTicks, Cutoff: Int64;
  Pair: TPair<string, TQueue<Int64>>;
  KeysToRemove: TList<string>;
  Key: string;
begin
  NowTicks := TStopwatch.GetTimeStamp;
  Cutoff := NowTicks - FWindowTicks;
  FLock.Enter;
  try
    // Inline cleanup when bucket count grows large (prevents unbounded memory)
    if FBuckets.Count > 500 then
    begin
      KeysToRemove := TList<string>.Create;
      try
        for Pair in FBuckets do
        begin
          PruneOldEntries(Pair.Value, Cutoff);
          if Pair.Value.Count = 0 then
            KeysToRemove.Add(Pair.Key);
        end;
        for Key in KeysToRemove do
          FBuckets.Remove(Key);
      finally
        KeysToRemove.Free;
      end;
    end;

    if not FBuckets.TryGetValue(AKey, Queue) then
    begin
      Queue := TQueue<Int64>.Create;
      FBuckets.Add(AKey, Queue);
    end;
    PruneOldEntries(Queue, Cutoff);
    if Queue.Count >= FMaxRequests then
      Exit(False);
    Queue.Enqueue(NowTicks);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TMxRateLimit.CleanupExpired;
var
  Cutoff: Int64;
  Pair: TPair<string, TQueue<Int64>>;
  KeysToRemove: TList<string>;
  Key: string;
begin
  Cutoff := TStopwatch.GetTimeStamp - FWindowTicks;
  KeysToRemove := TList<string>.Create;
  try
    FLock.Enter;
    try
      for Pair in FBuckets do
      begin
        PruneOldEntries(Pair.Value, Cutoff);
        if Pair.Value.Count = 0 then
          KeysToRemove.Add(Pair.Key);
      end;
      for Key in KeysToRemove do
        FBuckets.Remove(Key);
    finally
      FLock.Leave;
    end;
  finally
    KeysToRemove.Free;
  end;
end;

end.
