---
name: codex-ticketing
description: Create, read, comment on, and update tickets from Codex. Use when asked to track work, open a ticket, triage a queue, or delegate a subagent with a ticket owner.
---

# Codex Ticketing

Tickets are the center of attention: an agent creates a ticket, numbers its
todo item with the ticket number, stores the plan (spec) in the ticket as an
**immutable body**, then delegates work. Anyone can fetch the ticket to see
what was decided and why.

## Laws

- **Immutability** — the body (`md_content`) is written once at creation and
  never rewritten. The only write after creation is `ticket_comment`
  (append-only, 1000 chars max) and `ticket_status`.
- **One ticket per subagent** — when you delegate a subagent, the subagent
  does work against exactly one ticket, and its launch prompt names that
  ticket's number and the owner's session_id.
- **Session ids are explicit** — MCP provides no harness session context.
  Every tool that needs an owner takes a `session_id` parameter. Know your
  own session id (call `ticket_session_id`) and pass it explicitly. Never
  invent or guess one.
- **Statuses**: `pending | in_progress | completed | cancelled | superseded`.
  Only the owner (the session that created the ticket) may change status.
- **Types**: `unknown | task | bug | feature | chore | milestone` (default
  `unknown`).
- **Errors**: tools return `{code, message, corrected_call?}`. Re-emit
  `corrected_call` to recover in one call.

## Flow

1. `ticket_add` with `todo` (one line), `md_content` (spec), `session_id`
   (yours), optional `type` → returns the permanent ticket number N.
2. Mirror in your todo list as `N: <todo>`.
3. Work the ticket. Comment go/no-go with `ticket_comment`.
4. On completion, `ticket_status id=N session_id=<owner> status=completed`.
