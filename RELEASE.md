# codex-ticketing @VERSION@

A ticketing plugin for Codex agents: immutable tickets, append-only comments,
status-only mutation, session-scoped ownership — a local MCP server built on
the upstream [lua-lunet/lunet](https://github.com/lua-lunet/lunet) runtime
(v0.19.0, fetched and SHA-256 verified), transport adapted from
[lua-lunet/lunet-mcp](https://github.com/lua-lunet/lunet-mcp) as a reference.

## What's in each archive

`codex-ticketing-<os>-<arch>.tar.gz` (`.zip` for Windows), with a `.sha256`
digest beside each asset:

- `app/` — the MCP server (Streamable HTTP + legacy SSE, 8 ticket tools)
- `lunet-run[.exe]` + `lunet/` — the pinned upstream runtime, including the
  SQLite driver used by the ticket store
- `run.sh` (`run.cmd` on Windows) — launcher (default port 8080,
  `PORT`/`HOST`/`TICKETS_DB` env)
- `plugin.json`, `mcp.json`, `skills/`, `.agents/plugins/marketplace.json` —
  Codex plugin packaging (local marketplace)
- `test_mcp_flow.sh` — the full MCP flow test

## Quick start

```sh
tar -xzf codex-ticketing-macos.tar.gz   # or the archive for your platform
cd codex-ticketing-macos                # (extract dir)
./run.sh                                # or run.cmd on Windows
# UI:        http://127.0.0.1:8080/ui
# MCP:       http://127.0.0.1:8080/mcp  (Streamable HTTP)
# Flow test: ./test_mcp_flow.sh 8080
```

## Install as a Codex plugin (local marketplace)

```sh
codex plugin marketplace add <extracted-dir>
codex plugin add codex-ticketing@codex-ticketing
```

## Tools

`ticket_add`, `ticket_get`, `ticket_list`, `ticket_comment`, `ticket_status`,
`ticket_rules`, `ticket_help`, `ticket_session_id` — full contract via
`ticket_help`. Ticket bodies are immutable; comments are append-only (1000
chars); status is the only mutation and is owner-gated; superseded tickets
soft-delete and stay recoverable with `include_deleted`.

## 中文

各平台压缩包（`codex-ticketing-<os>-<arch>.tar.gz`，Windows 为 `.zip`）内含：
`app/` MCP 服务器、上游 lua-lunet/lunet v0.19.0 运行时（含 SQLite 驱动）、
`run.sh`（Windows 为 `run.cmd`）启动脚本、Codex 插件打包文件（plugin.json、
mcp.json、skills/、marketplace.json）以及完整 MCP 流程测试脚本。每个资产旁
均附 `.sha256` 校验文件。安装方式见上方命令；工具契约通过 `ticket_help` 获取。
