# codex-ticketing

Ticketing for Codex agents: a plugin that wraps an MCP server (Streamable
HTTP + legacy SSE, built on the [Lunet](https://github.com/lua-lunet/lunet)
runtime) exposing ticket tools. Tickets are **immutable records with an
append-only comment stream; status is the only field that ever changes.**

Mirrors [opencode-ticketing](https://github.com/prompt-cult/opencode-ticketing)
v2.2.5-46f95db semantics for Codex's MCP-based plugin model.

## What it does

| Tool | Purpose |
|---|---|
| `ticket_add` | Create a ticket (body written once, never rewritten); explicit `session_id` owner, optional `type` |
| `ticket_get` | Read a ticket + its comments |
| `ticket_list` | Filter by `session_id`, `status`, `type`/`types`, or `all=true` |
| `ticket_comment` | Append a short go/no-go note (≤1000 chars) |
| `ticket_status` | The only mutation; owner-gated (`pending\|in_progress\|completed\|cancelled\|superseded`) |
| `ticket_rules` | Delegatee banner |
| `ticket_help` | Full contract |
| `ticket_session_id` | Echo your session id |

Types: `unknown|task|bug|feature|chore|milestone` (default `unknown`).
Errors are `{code, message, corrected_call?}` — re-emit `corrected_call` to
recover in one call.

## Architecture

- `app/main.lua` — MCP server (transport adapted from `lua-lunet/lunet-mcp`
  tag v0.20.0-issue024; MCP 2025-03-26 Streamable HTTP + 2024-11-05 SSE).
- `app/store.lua` — SQLite ticket store (`lunet.sqlite3`, WAL, separate DB).
- `app/ui.lua` — local web UI at `GET /ui` + JSON API `GET/POST /api/tickets`,
  `GET /api/stats`.
- `.lunet/$(LUNET_VERSION)/` — pinned Lunet runtime (fetched, never committed).
- `plugin.json` / `mcp.json` / `skills/` / `.agents/plugins/marketplace.json`
  — Codex plugin packaging.

## Requirements

- macOS arm64 (or the matching Lunet runtime archive for your platform).
- `lua` or `luajit` available for the fetcher.
- Codex CLI 0.169.0+ for the plugin flow.

## Build & run

```sh
make build          # fetch pinned Lunet runtime + types
./run.sh            # MCP server on :8080 (PORT/HOST/TICKETS_DB env)
```

For streaming `codex-ticketing` (or `make run-trace`), set `PORT=8099`
to match `mcp.json`.

## Test

```sh
./run.sh            # server running
./test/test_mcp_flow.sh   # full MCP flow (initialize, tools, add/get/list/comment/status, error envelopes)
curl http://127.0.0.1:8080/ui      # local web UI
curl http://127.0.0.1:8080/api/stats
```

## Single-file embedded executable (L5 stretch)

`make embed` builds `codex-ticketing-macos-arm64.run` (in
`.tmp/dist/codex-ticketing-macos-arm64/`): the app's Lua tree is compiled
INTO the binary via the official Lunet release SDK
(`lunet-macos-sdk.tar.gz`, v0.19.0) — `generate_embed_scripts.lua` →
blob header → `cc` + `liblunet-static.a`. The static core does not include
the optional extension loaders (`lunet.http`, `sqlite3`, `jsonic`, …), so
the runtime's `lunet/` loader tree is staged beside the binary (documented
SDK caveat). The app self-locates loaders (`.lunet/<ver>/` or `./lunet/`).

## Install as a Codex plugin (local marketplace)

```sh
codex plugin marketplace add /path/to/codex-ticketing
codex plugin add codex-ticketing@codex-ticketing
```

The plugin's `mcp.json` points at `http://127.0.0.1:8099/mcp`
(Streamable HTTP). Start the server first; in an interactive Codex session
approve the MCP tool when prompted.

## Ownership model

MCP provides no harness session context. Every tool that needs an owner
takes an explicit `session_id` parameter. Know your own session id
(`ticket_session_id`) and pass it explicitly; never invent one. Only the
owner may change status; any session may append comments.

## Upstream

The Lunet runtime is pinned (currently `v0.19.0`) and fetched via the
official release fetcher (`scripts/lunet_fetch_release_v<version>.lua`,
SHA-256 verified before extraction). `lua-lunet/lunet-mcp` is the transport
*reference only* (its Streamable HTTP skeleton inspired `app/main.lua`);
the binary we run is the upstream Lunet runtime itself, including the
sqlite3 driver (`lunet.sqlite3`).
