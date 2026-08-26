# Agent-Inbox Wakeup — Canonical Arm/Teardown Procedure (Shared)

Single source-of-truth for the agent-inbox `Monitor` (mxOrchestrate Init 3a arms it;
mxSave stops it for the duration of a save and re-arms at the end). Edit here,
mirror to consumers.

## What this watcher is — and is not

The Monitor is a **wakeup, not a transport**. The proxy writes
`agent_inbox_<slug>.json` whether or not anything watches it, and the
`UserPromptSubmit` hook is what consumes and deletes it. The Monitor only reads a
signature.

Two consequences that decide every design question about it:
- **Stopping it never loses a message.** The buffer keeps being written; only the
  push notification pauses.
- **Arming it never consumes a message.** A redundant watcher costs duplicate
  lines, never delivery.

⚡ Do NOT reason about this watcher as if it carried the mail. Every "should we
stop/re-arm here?" question collapses once the above is applied.

## Why it exists

A *waiting* instance never submits a prompt, so the `UserPromptSubmit` inbox hook
never fires for it and the message sits in the file buffer indefinitely (observed
live: three undelivered messages, oldest six weeks). Push delivery needs the
Monitor.

## State fields

| Field | Meaning |
|---|---|
| `agent_watch_session_id` | session the live watcher belongs to |
| `agent_watch_task_id` | task id of the live watcher, for `TaskStop` |

⚡ Both fields are written **together, always**. A task id without a session id
cannot be reasoned about; a session id without a task id cannot be torn down.

## Arm

1. ⚡ **Tear down first.** If `agent_watch_task_id` is set → `TaskStop(that id)`,
   ignoring failure (already dead is fine). A Monitor is a persistent background
   task NOT tied to the state file, so arming without teardown leaves the previous
   watcher running — N re-arms produce N live watchers and N duplicate lines per
   message.
2. ⚡ **Main-only, NEVER from a subagent.** A Monitor armed inside a subagent
   notifies THAT subagent, not the main thread.
3. ⚡ **Slug filter is MANDATORY.** Watch EXACTLY `agent_inbox_<slug>.json`, slug
   from the project CLAUDE.md `**Slug:**` line. **NEVER** an `agent_inbox_*.json`
   glob: the inbox dir is machine-wide, so a glob drags foreign projects' messages
   into this session's context (observed live).
4. `Monitor(command=<poll loop below>, persistent=true)` over
   `$HOME/.claude/agent_inbox/agent_inbox_<slug>.json`, 5s interval.
5. Write the returned task id + the current session id into the state in ONE edit.

### Poll-loop contract

- ⚡ Signature via `cksum "$F" 2>/dev/null` — filename as **argument**, never
  `cksum < "$F"`: bash opens an input redirect BEFORE applying `2>/dev/null`, so
  the missing-file error escapes to real stderr on every poll, and the file is
  absent almost all the time.
- Content signature, not `stat` mtime+size (1s mtime granularity plus an unchanged
  byte count would hide a rewrite).
- ⚡ **Report an already-present file once at arm time** — otherwise a message that
  arrived before arming stays invisible forever. This is also what covers the
  window during which mxSave held the watcher stopped.
- ⚡ **Fire on DISAPPEARANCE too, never gate on "file exists":** the inbox hook is
  keyed by slug, NOT by session — a second session on the same project deletes the
  buffer the moment its user types, and the proxy then ACKs because the file is
  gone. A watcher that only fires on a non-empty signature misses that message
  silently and in full. Signature changed AND now empty → emit a line saying the
  buffer was cleared by another delivery path, prompting a confirming
  `mx_agent_inbox`. A redundant wakeup costs one turn; a silent miss costs the
  message.

### Known and accepted

A write **and** delete completing between two polls leaves the signature unchanged,
so that change goes unseen. Harmless in practice — the deleting party is the prompt
hook, which only deletes after injecting the full payload, so the message was
delivered by the other path.

⚡ Do NOT add a cooldown/batching layer to "fix" this: more latency means more time
for both sides to act on a stale view, which is what actually multiplies messages.

## Stop (mxSave holds it down for the duration of a save)

1. Read `agent_watch_task_id` → `TaskStop(id)`, ignore failure.
2. ⚡ Clear **both** fields in the state. Not cosmetic: if the save aborts between
   stop and re-arm, the cleared `agent_watch_session_id` makes the next
   mxOrchestrate call arm a fresh watcher instead of trusting a dead id.

Residual, accepted and not papered over: if a save aborts hard AND the session
never calls mxOrchestrate again, it stays without a wakeup until the next context.
The buffer still accumulates, so nothing is lost — only the push is missing.

## On notification

`mx_agent_inbox(project=<slug>)` → handle → `mx_agent_ack`. An empty inbox on a
disappearance event is the expected benign case, not an error. No inbox dir → skip
silently, no error.
