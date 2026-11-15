# codex-ticketing

为 Codex 代理提供工单（ticket）系统：一个插件，包裹一个基于
[Lunet](https://github.com/lua-lunet/lunet) 运行时的 MCP 服务器
（Streamable HTTP + 兼容 SSE），暴露工单工具。工单是**不可变记录，
附加只读评论流；status 是唯一可变字段。**

语义镜像 [opencode-ticketing](https://github.com/prompt-cult/opencode-ticketing)
v2.2.5-46f95db，适配 Codex 基于 MCP 的插件模型。

## 工具

| 工具 | 用途 |
|---|---|
| `ticket_add` | 创建工单（正文只写一次）；显式 `session_id` 所有者，可选 `type` |
| `ticket_get` | 读取工单及评论 |
| `ticket_list` | 按 `session_id`/`status`/`type`/`types` 或 `all=true` 过滤 |
| `ticket_comment` | 追加简短 go/no-go 备注（≤1000 字符） |
| `ticket_status` | 唯一变更；所有者授权（`pending\|in_progress\|completed\|cancelled\|superseded`） |
| `ticket_rules` | 被委托者（delegatee）须知 |
| `ticket_help` | 完整契约 |
| `ticket_session_id` | 返回你的会话 ID |

类型：`unknown|task|bug|feature|chore|milestone`（默认 `unknown`）。
错误为 `{code, message, corrected_call?}` —— 重发 `corrected_call` 即可一次恢复。

## 架构

- `app/main.lua` — MCP 服务器（传输改编自 `lua-lunet/lunet-mcp`
  tag v0.20.0-issue024；MCP 2025-03-26 Streamable HTTP + 2024-11-05 SSE）。
- `app/store.lua` — SQLite 工单存储（`lunet.sqlite3`，WAL，独立库）。
- `app/ui.lua` — 本地网页 UI `GET /ui` + JSON API `GET/POST /api/tickets`、
  `GET /api/stats`。
- `.lunet/$(LUNET_VERSION)/` — 固定的 Lunet 运行时（下载所得，不入库）。
- `plugin.json` / `mcp.json` / `skills/` / `.agents/plugins/marketplace.json`
  — Codex 插件打包。

## 依赖

- macOS arm64（或匹配平台的 Lunet 运行时归档）。
- 需要 `lua` 或 `luajit`（用于 fetcher）。
- 插件流程需要 Codex CLI 0.169.0+。

## 构建与运行

```sh
make build          # 下载固定 Lunet 运行时与 types
./run.sh            # :8080 启动 MCP 服务器（PORT/HOST/TICKETS_DB 环境变量）
```

服务 `codex-ticketing` 时设 `PORT=8099`（与 `mcp.json` 一致）。

## 测试

```sh
./run.sh            # 启动服务器
./test/test_mcp_flow.sh   # 完整 MCP 流程（initialize、工具、add/get/list/comment/status、错误信封）
curl http://127.0.0.1:8080/ui      # 本地网页 UI
curl http://127.0.0.1:8080/api/stats
```

## 安装为 Codex 插件（本地 marketplace）

```sh
codex plugin marketplace add /path/to/codex-ticketing
codex plugin add codex-ticketing@codex-ticketing
```

插件 `mcp.json` 指向 `http://127.0.0.1:8099/mcp`（Streamable HTTP）。
先启动服务器；在交互式 Codex 会话中按提示批准 MCP 工具调用。

## 所有权模型

MCP 不提供 harness 会话上下文。需要所有者的工具必须显式传 `session_id`
参数。用 `ticket_session_id` 获取自己的会话 ID 并显式传入；切勿臆造。
只有所有者可改状态；任何会话可追加评论。

## 上游

Lunet 运行时固定（当前 `v0.19.0`），通过官方 release fetcher 获取
（`scripts/lunet_fetch_release_v<version>.lua`，解压前校验 SHA-256）。
`lua-lunet/lunet-mcp` 仅是传输层**参考**（其 Streamable HTTP 骨架
启发了 `app/main.lua`）；我们运行的是上游 Lunet 运行时本身，
包含 sqlite3 驱动（`lunet.sqlite3`）。
