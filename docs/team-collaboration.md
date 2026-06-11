# Team Collaboration with mxLore

How a team works together through mxLore across roles — PM, Developer, QA, Documentation — from first idea to shipped-and-documented feature, without losing context along the way.

> **New here?** This guide is about *how you collaborate*. For *how to connect* your client (Claude Code, claude.ai, Cursor) and onboard people, see **[team-onboarding.md](./team-onboarding.md)** first.

---

## The Big Picture

mxLore is a **shared brain and workspace** for your team. Every piece of knowledge your team produces — specifications, plans, architectural decisions, bug reports, feature requests, QA findings, lessons learned — lives in **one place** (a MariaDB database behind your mxLore server), visible to everyone, and recalled automatically whenever it's relevant.

The most important thing to understand:

> **You don't have to learn any tools or commands. You talk; the AI acts.**

There are two ways your people interact with the same shared brain:

| Surface | Who uses it | How it feels |
|---|---|---|
| **Claude Code** (CLI / IDE) | Developers | The full **mx-skills** — `/mxSpec`, `/mxPlan`, `/mxOrchestrate`, `/mxSave`, `/mxBugChecker`, … Structured and automated. |
| **Claude chat** (claude.ai web/desktop) + MCP | PM, QA, Documentation, anyone non-coding | Just **describe what you want in plain language**. The AI reaches into mxLore and picks the right tool itself. No commands to memorize. |

A PM never types a command. They say *"write this up as a feature and hand it to the dev team"* — and Claude creates the document and notifies the developers. A developer gets the extra power of skills, but underneath it's the same knowledge base everyone shares.

Because the knowledge is shared and Claude recalls it automatically, **handoffs carry their full context**. Nobody copies text between tools. Nobody re-explains last week's decision. When the next person — or their AI — opens the topic, the history is already there.

---

## One Server, Many Projects and People

mxLore is a **shared server**. It usually hosts **several projects** and **several team members** at once — the webshop, the mobile app, the internal ERP — each with its own specs, plans, decisions and history. And each member only sees the projects their access key grants them.

Because of that, **every piece of work is scoped to a project**. You still just talk — you only name the project once. Two practical consequences:

- **In Claude Code (developers):** the project is set **automatically** from the folder you're working in (its `CLAUDE.md` carries the project name). The session already knows it's the *webshop* project — you don't have to say it.
- **In Claude chat (PM, QA, Doc):** there is no folder, so **tell Claude which project you mean the first time** — *"In the webshop project, write a feature for…"*. Claude keeps that project in mind for the rest of the conversation. Not sure what you have access to? Just ask *"which projects can I access?"*.

This is also how a PM keeps different products apart: a feature request created *"in the webshop project"* lands in the webshop's knowledge, is recalled for webshop developers, and never bleeds into the ERP project. One server, many clearly separated workspaces.

> **Rule of thumb:** in a browser chat, start with the project — *"In project X, …"*. In Claude Code, the folder already answers that for you.

---

## The Roles at a Glance

These four roles are **conventions**, not something mxLore enforces. Use them as-is, rename them, or add your own (Design, Security, Support…). They simply describe *who tends to produce what*.

| Role | Owns | Typically produces | Usually connects via |
|---|---|---|---|
| **PM / Product** | The "what" and "why" | Feature requests, specifications, priorities, change requests | claude.ai chat |
| **Developer** | The "how" and the code | Plans, architectural decisions, the implementation, bug fixes | Claude Code (skills) |
| **QA** | Quality and proof | Review findings, verified bug reports, sign-off | Claude Code *or* claude.ai chat |
| **Documentation** | The user-facing story | End-user docs, release notes, how-tos | claude.ai chat |

Everything each role produces lands in the same shared knowledge base and is automatically linked and recalled — which is what makes the handoffs below seamless.

---

## End-to-End: One Feature, Idea → Shipped → Documented

Let's follow **one real feature** — *"Add two-factor authentication (2FA) to login"* — through every role and every handoff. Watch how the work moves without anyone copy-pasting or re-explaining.

```
        ┌─────────────────── the shared mxLore brain ───────────────────┐
        │                                                               │
   PM ──spec──▶  Developer ──plan + build──▶  QA ──review──▶  Documentation
    ▲                │                          │
    └──── change ────┘ ◀────────── bug ─────────┘
   (every arrow is just a person talking to Claude; mxLore carries the context)
```

### 1. PM starts the topic
**Paula (PM)** opens claude.ai and says:

> *"We need two-factor authentication on login. Write it up as a specification: it must support an authenticator app, be optional per user, and we'll need it for the enterprise tier."*

Claude writes a proper specification into mxLore (acceptance criteria, constraints, the "why"). Paula reviews it in the chat, then:

> *"Looks good — hand this to the dev team."*

Behind the scenes, Claude notifies the developers. *(Capability: spec creation + agent messaging — Paula never names a tool.)*

### 2. Developer picks it up
**Dario (Developer)** starts a Claude Code session the next morning. Before he asks anything, Claude **recalls** Paula's new 2FA spec and the handoff message. He says:

> *"Let's plan the 2FA feature."*

`/mxPlan` turns the spec into a step-by-step plan with milestones. As Dario builds, he hits a design fork — authenticator app (TOTP) vs SMS codes — and records the choice so nobody re-litigates it later:

> `/mxDecision` → *"Use TOTP (RFC 6238), not SMS, because SMS is phishable and adds carrier cost."*

The decision is stored and **linked to the spec automatically**.

### 3. PM pushes a change mid-flight
Partway through, **Paula** learns from compliance that users also need **backup recovery codes**. From claude.ai:

> *"Add a requirement to the 2FA spec: users must be able to generate one-time backup recovery codes."*

Claude updates the specification and flags Dario. At Dario's next session, Claude surfaces the change:

> *"Heads up — the 2FA spec changed: backup recovery codes are now required."*

Dario adjusts his plan and implements the codes. **No email thread, no 'didn't see that' — the change traveled with the work.**

### 4. Handoff to QA
When the implementation is done, Dario says:

> *"Mark the 2FA feature ready for QA."*

QA is notified, with the spec, the plan, and the TOTP decision all attached.

### 5. QA reviews and finds something
**Quinn (QA)** reviews the change — in Claude Code with `/mxBugChecker`, or simply by asking Claude chat to *"review this change against the 2FA spec for bugs."* Claude finds that the backup-code endpoint isn't rate-limited. Quinn logs it:

> *"File a bug: backup recovery codes can be brute-forced — no rate limit on the verify endpoint."*

The bug is stored, linked to the spec, and Dario is notified. He fixes it, re-flags QA, and this time the review passes. Quinn signs off. *(The bug ↔ spec ↔ fix chain is now permanent history.)*

### 6. Documentation closes the loop
**Dana (Documentation)** opens claude.ai:

> *"Write end-user documentation for the new 2FA feature — how to turn it on, how backup codes work."*

Claude recalls the final spec, the TOTP decision, and the as-shipped behavior, and drafts the user docs from the real source of truth — not from a guess about what was built.

### And later…
Three months on, someone asks *"why did we choose TOTP over SMS again?"* Anyone — PM, new hire, support — asks Claude, and the decision from step 2 comes back instantly, with its reasoning. **The knowledge didn't leave with the person who made it.**

---

## Handoffs Without Friction

Three mechanisms make the choreography above smooth. None of them require a human to manage them — they're just *there*:

1. **Shared knowledge.** Specs, plans, decisions, bugs and findings live in one database. Every role sees the same source of truth. When the spec changes, it changes for everyone — no stale copies.
2. **Agent messaging.** When you say *"hand this to the devs"* or *"this is ready for QA"*, Claude notifies the next role's AI directly inside mxLore. The next person's session starts already knowing what's waiting for them.
3. **Automatic recall.** Open a topic next week or next quarter and Claude pulls back the relevant history — the original spec, the decision behind a design, the bug that was found and fixed — without anyone searching for it.

The net effect: **no copy-paste between tools, no lost context, no "who has the latest version?"** The work moves; the context moves with it.

---

## Capability Cheat-Sheet

You don't need this to use mxLore — the AI picks the right tool for you. It's here for the curious, so you can see what's happening under the hood, and so developers know which skill maps to which intent.

| What you want to do | Developer in Claude Code | Anyone in Claude chat — just say… |
|---|---|---|
| Capture a feature or write a spec | `/mxSpec` | *"write a spec for …"* / *"create a feature request for …"* |
| Turn a spec into a plan | `/mxPlan` | *"turn this into an implementation plan"* |
| Record an architectural decision | `/mxDecision` | *"record the decision to use X over Y, and why"* |
| Find / recall existing knowledge | automatic, or just ask | *"what do we know about …?"* / *"search mxLore for …"* |
| Review code or design against the spec | `/mxDesignChecker` | *"review this against the spec"* |
| Find bugs with proof | `/mxBugChecker` | *"review this change for bugs"* |
| Hand work to another role | *"notify the QA team this is ready"* | *"let the dev team know this is ready"* |
| Persist the session | `/mxSave` | nothing to do — documents are saved as they're created |
| Check the knowledge base is healthy | `/mxHealth` | — (developer task) |

The pattern: **a developer's `/mxSpec` and a PM's *"write a spec for…"* do the same thing** — one through a skill, one through plain conversation.

---

## Roles Are Conventions, Not Configuration

mxLore does not hard-code "PM" or "QA". The roles above are a *way of working*, not a setting. Two practical notes:

- **Want light gating?** Each team member's access key can be `readwrite` or `readonly`. For example, give Documentation `readonly` so they consume and reference specs but don't alter them, or keep everyone `readwrite` for a small, high-trust team. This is optional — see **[team-onboarding.md](./team-onboarding.md)** for how keys and access levels are issued.
- **Mix surfaces freely.** A developer can review in Claude Code while a PM watches the same spec evolve in claude.ai. It's one shared brain, two windows into it.

---

## Recommended Starting Point

1. Developers install **Claude Code** and run `/mxSetup` (full skill set). See [team-onboarding.md](./team-onboarding.md).
2. PM, QA, and Documentation connect **claude.ai** to the same mxLore server — no terminal needed.
3. Run the 2FA-style flow above on a small, real feature once. After one round, the handoffs feel natural and you'll have a living example in your knowledge base to point new people at.

That's the whole idea: **everyone talks to the same brain in their own way, and the work flows from role to role without friction.**
