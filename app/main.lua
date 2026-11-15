#!/usr/bin/env luajit
-- codex-ticketing MCP server
--
-- Streamable HTTP transport (spec 2025-03-26) + legacy HTTP+SSE
-- (spec 2024-11-05), on the Lunet framework. Transport plumbing adapted
-- from lua-lunet/lunet-mcp (MIT) tag v0.21.0-issue026; tool surface is
-- the codex-ticketing ticket store (app/store.lua) with contract parity
-- to opencode-ticketing v2.2.5.
--
-- Environment:
--   PORT               - Server port (default 8080)
--   HOST               - Bind host (default 127.0.0.1)
--   TICKETS_DB        - SQLite path (default: .lunet/tickets.db)
--   MCP_TRACE         - off|error|warn|info|debug|trace

io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

local VERBOSE = false
for i = 1, #arg do
    if arg[i] == "-v" or arg[i] == "--verbose" then
        VERBOSE = true
        break
    end
end

local lunet = require("lunet")
local socket = require("lunet.socket")
local http = require("lunet.http")
local jsonic = require("lunet.jsonic")
local trace = require("app.trace")
local store_mod = require("app.store")
local ui = require("app.ui")

local MCP_VERSION = "2024-11-05"
local STREAMABLE_HTTP_VERSION = "2025-03-26"
local SUPPORTED_PROTOCOL_VERSIONS = { STREAMABLE_HTTP_VERSION, MCP_VERSION }
local SERVER_NAME = "codex-ticketing"
local SERVER_VERSION = "0.1.0"

local EMPTY_OBJECT = setmetatable({}, { __jsontype = "object" })

local CORS = {
    origin = "*",
    methods = { "GET", "POST", "DELETE", "OPTIONS" },
    headers = { "Content-Type", "Mcp-Session-Id", "Last-Event-ID", "MCP-Protocol-Version" },
}

local function load_env_file(path)
    local file = io.open(path, "r")
    if not file then return end
    for line in file:lines() do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key and value then
            value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
            if not os.getenv(key) then
                rawset(_G, "_ENV_" .. key, value)
            end
        end
    end
    file:close()
end

local function getenv(key)
    return os.getenv(key) or rawget(_G, "_ENV_" .. key)
end

load_env_file(".env")

-- DB path (store itself opens inside the event-loop coroutine below)
local db_path = getenv("TICKETS_DB") or ".lunet/tickets.db"
local store

local function random_id()
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local id = {}
    for i = 1, 16 do
        local idx = math.random(1, #chars)
        id[i] = chars:sub(idx, idx)
    end
    return table.concat(id)
end

local function sse_event(event_name, data)
    local lines = {}
    if event_name then
        lines[#lines + 1] = "event: " .. event_name
    end
    lines[#lines + 1] = "data: " .. data
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function jsonrpc_response(id, result)
    return jsonic.encode({
        jsonrpc = "2.0",
        id = id,
        result = result,
    })
end

local function jsonrpc_error(id, code, message)
    return jsonic.encode({
        jsonrpc = "2.0",
        id = id,
        error = {
            code = code,
            message = message,
        },
    })
end

-- ─── JTD-style legal parameter sets (RFC 8927, issue #18 of the
-- reference implementation) ─────────────────────────────────────────────
-- Each tool's legal set is exactly its declared params. Unknown keys,
-- missing required params, wrong types and illegal enum values are rejected
-- before the handler runs, with the reference's stable envelope codes.
--
--   E_<TOOL>_MISSING_<PARAM>   missing required param
--   E_<TOOL>_BAD_<PARAM>        wrong type / illegal enum value
--   E_<TOOL>_EXTRA_PROPERTY     unknown param
--   E_<TOOL>_NOT_AN_OBJECT      non-object arguments

local TYPE_ENUM = { "unknown", "task", "bug", "feature", "chore", "milestone" }
local STATUS_ENUM = { "pending", "in_progress", "completed", "cancelled", "superseded" }

local function enum_contains(enum, v)
    for _, e in ipairs(enum) do
        if e == v then return true end
    end
    return false
end

-- tool params: required = {name=kind}, optional = {name=kind}
-- kind: "string" | "integer" | "boolean" | "enum" | "array-string"
local TOOL_PARAMS = {
    ticket_add = {
        required = { todo = "string", session_id = "string" },
        optional = { md_content = "string", type = "enum" },
    },
    ticket_get = {
        required = { id = "integer" },
        optional = {},
    },
    ticket_list = {
        required = {},
        optional = {
            session_id = "string", status = "enum", type = "enum",
            types = "array-string", include_deleted = "boolean", all = "boolean",
        },
    },
    ticket_comment = {
        required = { id = "integer", content = "string", session_id = "string" },
        optional = {},
    },
    ticket_status = {
        required = { id = "integer", session_id = "string", status = "enum" },
        optional = {},
    },
    ticket_rules = { required = {}, optional = {} },
    ticket_help = { required = {}, optional = {} },
    ticket_session_id = {
        required = { session_id = "string" },
        optional = {},
    },
}

local function kind_ok(kind, v, enum)
    if kind == "string" then return type(v) == "string" end
    if kind == "integer" then
        return type(v) == "number" and v == math.floor(v) and v >= 0 and v <= 4294967295
    end
    if kind == "boolean" then return type(v) == "boolean" end
    if kind == "enum" then
        return type(v) == "string" and enum_contains(enum, v)
    end
    if kind == "array-string" then
        if type(v) ~= "table" then return false end
        for _, item in ipairs(v) do
            if type(item) ~= "string" then return false end
        end
        return true
    end
    return false
end

local function validate_args(tool, args)
    local spec = TOOL_PARAMS[tool]
    local errors = {}
    if type(args) ~= "table" or args == jsonic.null then
        errors[1] = { instancePath = "", schemaPath = "/properties" }
        return errors
    end
    local function enum_for(name)
        return (name == "type" or name == "status") and (name == "type" and TYPE_ENUM or STATUS_ENUM) or nil
    end
    for name, kind in pairs(spec.required) do
        if args[name] == nil then
            errors[#errors + 1] = { instancePath = "", schemaPath = "/properties/" .. name }
        elseif not kind_ok(kind, args[name], enum_for(name)) then
            errors[#errors + 1] = { instancePath = "/" .. name, schemaPath = "/properties/" .. name .. "/type" }
        end
    end
    for name, kind in pairs(spec.optional) do
        if args[name] ~= nil then
            local path = kind == "enum" and "/optionalProperties/" .. name .. "/enum"
                or "/optionalProperties/" .. name .. "/type"
            if not kind_ok(kind, args[name], enum_for(name)) then
                errors[#errors + 1] = { instancePath = "/" .. name, schemaPath = path }
            end
        end
    end
    for k in pairs(args) do
        if not spec.required[k] and not spec.optional[k] then
            errors[#errors + 1] = { instancePath = "/" .. k, schemaPath = "" }
        end
    end
    return errors
end

local function jtd_fail(tool, errors)
    local first = errors[1]
    local lower = tool:gsub("^ticket_", "")
    local missing = first.schemaPath:match("^/properties/(%w+)$")
    if missing then
        return {
            code = "E_" .. lower:upper() .. "_MISSING_" .. missing:upper(),
            message = "ticket_" .. lower .. " requires '" .. missing .. "'",
        }
    end
    local bad = first.schemaPath:match("^/properties/(%w+)/type$")
        or first.schemaPath:match("^/properties/(%w+)/enum$")
        or first.schemaPath:match("^/optionalProperties/(%w+)/type$")
        or first.schemaPath:match("^/optionalProperties/(%w+)/enum$")
    if bad then
        local is_enum = first.schemaPath:find("/enum$") ~= nil
        local what = is_enum
            and "ticket_" .. lower .. ": '" .. bad .. "' is not one of the legal values ("
                .. table.concat(STATUS_ENUM, "|") .. ")"
            or "ticket_" .. lower .. ": '" .. bad .. "' has the wrong type"
        return {
            code = "E_" .. lower:upper() .. "_BAD_" .. bad:upper(),
            message = what,
        }
    end
    local extra = first.instancePath:match("^/(%w+)$")
    if first.schemaPath == "" and extra then
        return {
            code = "E_" .. lower:upper() .. "_EXTRA_PROPERTY",
            message = "'" .. extra .. "' is not a legal parameter of ticket_" .. lower
                .. " — the legal set is exactly its declared params",
        }
    end
    return {
        code = "E_" .. lower:upper() .. "_NOT_AN_OBJECT",
        message = "ticket_" .. lower .. " takes an object with exactly its declared params",
    }
end

local function corrected_call(tool, args)
    local spec = TOOL_PARAMS[tool]
    local corrected = {}
    for name in pairs(spec.required) do
        corrected[name] = (args and args[name] ~= nil) and args[name] or "<fill: " .. name .. ">"
    end
    for name in pairs(spec.optional) do
        if args and args[name] ~= nil then corrected[name] = args[name] end
    end
    return corrected
end

-- ─── Tool schemas (MCP inputSchema) ────────────────────────────────────

local tools = {
    {
        name = "ticket_add",
        description = "Create a ticket. Body (md_content) is written once and never rewritten. Owner is the caller's session_id (explicit parameter). type may be unknown|task|bug|feature|chore|milestone (default unknown). Returns {session_id, id, ticket}.",
        inputSchema = {
            type = "object",
            properties = {
                todo = { type = "string", description = "One-line todo summary" },
                md_content = { type = "string", description = "Immutable spec body" },
                session_id = { type = "string", description = "The caller's session id" },
                type = { type = "string", description = "ticket type: unknown|task|bug|feature|chore|milestone" },
            },
            required = { "todo", "session_id" },
            additionalProperties = false,
        },
    },
    {
        name = "ticket_get",
        description = "Read one ticket by number, plus its comments (oldest first). Returns the ticket row JSON (comments as a block below).",
        inputSchema = {
            type = "object",
            properties = {
                id = { type = "integer", description = "Ticket number" },
            },
            required = { "id" },
            additionalProperties = false,
        },
    },
    {
        name = "ticket_list",
        description = "List tickets. session_id = the session id to query (required unless all=true); status filters; type filters by a single type, types by many; include_deleted=true reveals soft-deleted tickets; all=true lists every session's tickets. Returns a JSON array.",
        inputSchema = {
            type = "object",
            properties = {
                session_id = { type = "string", description = "Owner session id" },
                status = { type = "string", description = "pending|in_progress|completed|cancelled|superseded" },
                type = { type = "string", description = "single type filter" },
                types = { type = "array", items = { type = "string" }, description = "multi type filter" },
                include_deleted = { type = "boolean", description = "include soft-deleted tickets (default: excluded)" },
                all = { type = "boolean", description = "list every session's tickets" },
            },
            additionalProperties = false,
        },
    },
    {
        name = "ticket_comment",
        description = "Append ONE comment to a ticket (append-only): a short go/no-go note — done / not done / blocked — 1000 chars max. Any session may append; session_id is the author, stamped. Returns the comment row.",
        inputSchema = {
            type = "object",
            properties = {
                id = { type = "integer", description = "Ticket number" },
                content = { type = "string", description = "Note, 1000 chars max" },
                session_id = { type = "string", description = "The caller's session id (author)" },
            },
            required = { "id", "content", "session_id" },
            additionalProperties = false,
        },
    },
    {
        name = "ticket_status",
        description = "Set a ticket's status (the only mutation after creation). Owner-gated: session_id must be the ticket owner. superseded soft-deletes the ticket (hidden from lists; include_deleted reveals it). Returns the updated ticket row.",
        inputSchema = {
            type = "object",
            properties = {
                id = { type = "integer", description = "Ticket number" },
                session_id = { type = "string", description = "Owner session id" },
                status = { type = "string", description = "pending|in_progress|completed|cancelled|superseded" },
            },
            required = { "id", "session_id", "status" },
            additionalProperties = false,
        },
    },
    {
        name = "ticket_rules",
        description = "The delegatee banner: who you are (DELEGATEE), the immutability law, your only writes, and the standing subagent rules.",
        inputSchema = { type = "object", properties = {}, additionalProperties = false },
    },
    {
        name = "ticket_help",
        description = "The whole ticket contract in one call: tools, required params, session-id doctrine, statuses, delegation, and the error envelope.",
        inputSchema = { type = "object", properties = {}, additionalProperties = false },
    },
    {
        name = "ticket_session_id",
        description = "Return YOUR current session id (echo of the session_id argument).",
        inputSchema = {
            type = "object",
            properties = {
                session_id = { type = "string", description = "Your session id" },
            },
            required = { "session_id" },
            additionalProperties = false,
        },
    },
}

-- ─── Response rendering (reference shapes) ──────────────────────────────

local function envelope_result(env)
    local text = env.code .. ": " .. env.message
    if env.corrected_call then
        text = text .. "\n\nCorrected call:\n" .. jsonic.encode(env.corrected_call)
    end
    return {
        content = {{ type = "text", text = text }},
        isError = true,
    }
end

local function ok_result(payload)
    return { content = {{ type = "text", text = jsonic.encode(payload) }} }
end

local function row_wire(t)
    return {
        id = t.id,
        created_at = t.created_at,
        updated_at = t.updated_at,
        todo = t.todo,
        md_content = t.md_content,
        status = t.status,
        type = t.type,
        deleted = t.deleted,
        last_actor = t.last_actor,
        session_id = t.session_id,
    }
end

local RULES_TEXT = table.concat({
    "WHO YOU ARE: you are the DELEGATEE — a subagent launched by the main agent",
    "(the DELEGATOR), which created the ticket and handed you ONLY its number.",
    "Your first two calls: ticket_get id=N (your instructions), then this read.",
    "THE TICKET IS IMMUTABLE: the body was written once by the delegator before",
    "your launch — there is no rewrite action. Your only writes are ticket_comment",
    "notes — SHORT go/no-go: done / not done / blocked, 1000 chars max — and,",
    "when the work is done, ticket_status with the OWNER's session id — your launch",
    "prompt NAMES it; use it. Long reports NEVER go on the ticket: put the detail",
    "in your final response (or a gist). The DELEGATOR reviews the diff, runs the",
    "tests, and commits — you do not.",
    "",
    "Subagent rules — obey all of them:",
    "- Read the repo's AGENTS.md if it exists and obey it.",
    "- No commit, no push, no PR creation, no watch/poll of CI.",
    "- Only run tests and `git add`.",
    "- No rm/reset/stash — mv to .tmp; no /tmp.",
    "- No issue numbers in committed files, messages, docs, comments.",
    "- EN/CN doc parity for any doc touched.",
    "- Tee all command output to .tmp/clobber_me_NN.txt (incrementing).",
    "- bare-env macOS proof: env -u HOMEBREW_PREFIX -u PKG_CONFIG_PATH.",
    "- When extra work is discovered, record it in the ticket (ticket_comment) —",
    "  do not chase it.",
    "- Mark your todo item/ticket done when the work is done (ticket_status with",
    "  the OWNER's session id); the ORCHESTRATOR removes todo items — never you.",
    "- On any error, re-emit corrected_call verbatim — it is the complete call.",
}, "\n")

local HELP_TEXT = table.concat({
    "codex-ticketing — ticket contract",
    "",
    "A ticket is an IMMUTABLE record with an APPEND-ONLY comment stream; STATUS is",
    "the only field that ever changes. One tool per action; each tool's schema",
    "declares its required params:",
    "",
    "- ticket_add todo=\"one-line summary\" session_id=<your session id> [type=…]",
    "  [md_content=spec] -> creates the ticket under the given session id. Returns",
    "  the permanent ticket number N. type is optional, one of",
    "  unknown|task|bug|feature|chore|milestone (default unknown). The body",
    "  (md_content) is written ONCE, here — never after.",
    "- ticket_session_id session_id=<id> -> echoes the session id (use it to name",
    "  your id: to hand to a delegatee, to query another session's tickets, to adopt).",
    "- ticket_get id=N -> the row + its comments (chronological).",
    "- ticket_list session_id=<session id> [status=<status>] [type=<type> |",
    "  types=a,b] [include_deleted=true] -> ONE session's tickets; type filters a",
    "  single type, types many; all=true -> every session's. Soft-deleted tickets",
    "  are hidden unless include_deleted=true. The session id is required — an",
    "  agent must know which session it is querying.",
    "- ticket_comment id=N content=\"...\" session_id=<your session id> -> the ONLY",
    "  write after creation: a SHORT go/no-go note — done / not done / blocked —",
    "  1000 chars max. Any session may append (the author is your session, stamped).",
    "- ticket_status id=N session_id=<OWNER session id> status=<pending|",
    "  in_progress|completed|cancelled|superseded> -> the ONLY mutation.",
    "  Owner-gated. Setting superseded marks the old ticket soft-deleted (hidden",
    "  from lists; include_deleted=true reveals it).",
    "- ticket_rules -> the DELEGATEE's banner (its second call, after ticket_get).",
    "- ticket_help -> this text.",
    "",
    "Session ids: session_id IS the agent session id — one id, no other. MCP",
    "provides no harness session context, so every tool that needs an owner takes",
    "an explicit session_id parameter. Know your own session id (ticket_session_id)",
    "and pass it explicitly; never invent one. When delegating, NAME the session id",
    "the delegatee must use. Access is by ticket number everywhere else.",
    "",
    "Errors: every failure returns {code, message, corrected_call}. corrected_call",
    "is the COMPLETE call — your received values kept, the missing ones filled (the",
    "REAL owner session id wherever the ticket is known). Re-emit it verbatim (fill",
    "any \"<fill: …>\" placeholder) and the call succeeds.",
    "",
    "Mark-complete vs drop: a subagent MARKS its todo item / the ticket done; only",
    "the ORCHESTRATOR removes todo items. Nothing is ever hard-deleted — soft",
    "delete (superseded) hides a ticket from lists while keeping it in the DB.",
    "Never read the SQLite file directly — the tools are the API.",
}, "\n")

-- ─── Tool call dispatch (validation first, reference shape) ─────────────

local function handle_tool_call(name, args)
    trace.info("TOOL", "Calling tool: %s", name)

    -- JTD-style schema validation before touching the store.
    local errors = validate_args(name, args)
    if #errors > 0 then
        local jtd = jtd_fail(name, errors)
        return envelope_result({
            code = jtd.code,
            message = jtd.message,
            corrected_call = corrected_call(name, args),
        })
    end

    if name == "ticket_add" then
        local t, err = store.add(store, args)
        if not t then return envelope_result(err) end
        return ok_result({ session_id = t.session_id, id = t.id, ticket = row_wire(t) })
    elseif name == "ticket_get" then
        local t = store.get(store, args.id)
        if not t then
            return envelope_result({
                code = "E_NO_TICKET",
                message = "no ticket with number " .. tostring(args.id) .. " — recover with one call: ticket_help",
                corrected_call = { id = args.id },
            })
        end
        local cmts = store.comments(store, args.id)
        local body = jsonic.encode(row_wire(t))
        if #cmts > 0 then
            local lines = {}
            for _, c in ipairs(cmts) do
                lines[#lines + 1] = "[" .. c.created_at .. "] " .. c.content
            end
            body = body .. "\n\n--- comments (chronological) ---\n" .. table.concat(lines, "\n")
        end
        return { content = {{ type = "text", text = body }} }
    elseif name == "ticket_list" then
        local rows, err = store.list(store, args)
        if rows == nil then return envelope_result(err) end
        local out = {}
        for _, t in ipairs(rows) do out[#out + 1] = row_wire(t) end
        return ok_result(out)
    elseif name == "ticket_comment" then
        local res, err = store.comment(store, args)
        if not res then return envelope_result(err) end
        return ok_result(res)
    elseif name == "ticket_status" then
        -- self-healing corrected_call: when the ticket is known and the owner is
        -- wrong, fill the REAL owner session id (reference behavior).
        local known = (type(args.id) == "number") and store.get(store, args.id) or nil
        local t, err = store.status(store, args)
        if not t then
            if known and err and err.code == "E_STATUS_REFUSED" then
                err.corrected_call = { id = known.id, session_id = known.session_id, status = args.status }
            end
            return envelope_result(err)
        end
        return ok_result(row_wire(t))
    elseif name == "ticket_rules" then
        return { content = {{ type = "text", text = RULES_TEXT }} }
    elseif name == "ticket_help" then
        return { content = {{ type = "text", text = HELP_TEXT }} }
    elseif name == "ticket_session_id" then
        local res, err = store.session_id(store, args)
        if not res then return envelope_result(err) end
        return ok_result(res)
    end

    return {
        content = {{ type = "text", text = "Unknown tool: " .. name }},
        isError = true,
    }
end

-- MCP JSON-RPC dispatch
local function handle_mcp_request(msg)
    local method = msg.method
    local params = msg.params or {}
    local id = msg.id

    trace.debug("MCP", "Request: method=%s id=%s", method or "nil", tostring(id))

    if method == "initialize" then
        local negotiated = MCP_VERSION
        for _, v in ipairs(SUPPORTED_PROTOCOL_VERSIONS) do
            if params.protocolVersion == v then
                negotiated = v
                break
            end
        end
        return jsonrpc_response(id, {
            protocolVersion = negotiated,
            capabilities = { tools = EMPTY_OBJECT },
            serverInfo = { name = SERVER_NAME, version = SERVER_VERSION },
        })
    elseif method == "notifications/initialized" then
        return nil
    elseif method == "tools/list" then
        return jsonrpc_response(id, { tools = tools })
    elseif method == "tools/call" then
        local result = handle_tool_call(params.name, params.arguments or {})
        return jsonrpc_response(id, result)
    elseif method == "ping" then
        return jsonrpc_response(id, EMPTY_OBJECT)
    else
        return jsonrpc_error(id, -32601, "Method not found: " .. (method or "nil"))
    end
end

local sessions = {}
local mcp_sessions = {}

local function write_sse_head(client, connection, extra_headers)
    local header_str = "HTTP/1.1 200 OK\r\n"
        .. "Content-Type: text/event-stream\r\n"
        .. "Cache-Control: no-cache\r\n"
    if connection == "close" then
        header_str = header_str .. "Connection: close\r\n"
    else
        header_str = header_str .. "Connection: keep-alive\r\n"
    end
    for k, v in pairs(extra_headers or {}) do
        header_str = header_str .. k .. ": " .. v .. "\r\n"
    end
    for k, v in pairs(http.cors_headers(CORS)) do
        header_str = header_str .. k .. ": " .. v .. "\r\n"
    end
    header_str = header_str .. "\r\n"
    socket.write(client, header_str)
end

local function handle_sse_request(client)
    write_sse_head(client, "keep-alive")
    local session_id = random_id()
    local endpoint = "/message?session=" .. session_id
    socket.write(client, sse_event("endpoint", endpoint))
    sessions[session_id] = { client = client, messages = {} }
    trace.info("SSE", "Session %s connected", session_id)
end

local function handle_message_request(client, request)
    local session_id = request.query_params.session
    if not session_id then
        socket.write(client, http.response(400, {}, jsonrpc_error(nil, -32600, "session parameter required"), CORS, false))
        return "close"
    end
    local session = sessions[session_id]
    if not session then
        socket.write(client, http.response(404, {}, jsonic.encode({error = "Session not found"}), CORS, false))
        return "close"
    end
    if not request.body or request.body == "" then
        socket.write(client, http.response(400, {}, jsonic.encode({error = "Empty body"}), CORS, false))
        return "close"
    end
    local ok, msg = pcall(jsonic.decode, request.body)
    if not ok or type(msg) ~= "table" or msg == jsonic.null then
        socket.write(client, http.response(400, {}, jsonic.encode({error = "Invalid JSON"}), CORS, false))
        return "close"
    end
    socket.write(client, http.response(202, {}, "", CORS, false))
    local response = handle_mcp_request(msg)
    if response and session.client then
        local err = socket.write(session.client, sse_event("message", response))
        if err then
            socket.close(session.client)
            sessions[session_id] = nil
        end
    end
    return "close"
end

local function handle_mcp_post(client, request)
    local persistent = request.persistent_connection
        and (request.headers["connection"] or ""):lower() ~= "close"

    local function respond_json(status, body, extra_headers)
        local headers = { ["Access-Control-Expose-Headers"] = "Mcp-Session-Id" }
        for k, v in pairs(extra_headers or {}) do
            headers[k] = v
        end
        socket.write(client, http.response(status, headers, body, CORS, persistent))
    end

    local function respond_sse(responses, extra_headers)
        write_sse_head(client, "close", extra_headers)
        for _, r in ipairs(responses) do
            socket.write(client, sse_event("message", r))
        end
    end

    if not request.body or request.body == "" then
        respond_json(400, jsonrpc_error(nil, -32600, "Invalid Request: empty body"))
        return "close"
    end

    local ok, msg = pcall(jsonic.decode, request.body)
    if not ok or type(msg) ~= "table" or msg == jsonic.null then
        respond_json(400, jsonrpc_error(nil, -32700, "Parse error"))
        return "close"
    end

    local messages = {}
    local is_batch = msg[1] ~= nil
    if is_batch then
        for _, m in ipairs(msg) do messages[#messages + 1] = m end
    else
        messages[1] = msg
    end

    local has_initialize = false
    for _, m in ipairs(messages) do
        if type(m) == "table" and m.method == "initialize" then
            has_initialize = true
        end
    end

    if not has_initialize then
        local session_id = request.headers["mcp-session-id"]
        if not session_id or session_id == "" then
            respond_json(400, jsonrpc_error(nil, -32600, "Missing Mcp-Session-Id header"))
            return "close"
        end
        if not mcp_sessions[session_id] then
            respond_json(404, jsonrpc_error(nil, -32600, "Session not found"))
            return "close"
        end
    end

    local responses = {}
    for _, m in ipairs(messages) do
        if type(m) ~= "table" or m == jsonic.null then
            responses[#responses + 1] = jsonrpc_error(nil, -32600, "Invalid Request")
        elseif m.method == nil and (m.result ~= nil or m.error ~= nil) then
            trace.debug("MCP", "Ignoring client response message")
        else
            local response = handle_mcp_request(m)
            if response then responses[#responses + 1] = response end
        end
    end

    local extra_headers = {}
    if has_initialize then
        local session_id = random_id()
        mcp_sessions[session_id] = { created = os.time() }
        extra_headers["Mcp-Session-Id"] = session_id
        trace.info("MCP", "Streamable HTTP session %s created", session_id)
    end

    if #responses == 0 then
        respond_json(202, "", extra_headers)
        return "close"
    end

    if (request.headers["accept"] or ""):find("text/event-stream", 1, true) then
        respond_sse(responses, extra_headers)
        return "close"
    end

    local body = responses[1]
    if is_batch then
        body = "[" .. table.concat(responses, ",") .. "]"
    end
    respond_json(200, body, extra_headers)
    return persistent and "keep" or "close"
end

local function handle_mcp_delete(client, request)
    local session_id = request.headers["mcp-session-id"]
    if session_id and mcp_sessions[session_id] then
        mcp_sessions[session_id] = nil
        socket.write(client, http.response(200, {}, "", CORS, false))
    else
        socket.write(client, http.response(404, {}, "", CORS, false))
    end
    return "close"
end

local function route_request(client, request)
    trace.debug("HTTP", "%s %s", request.method, request.path)

    if request.method == "OPTIONS" then
        socket.write(client, http.preflight_response(CORS, false))
        return "close"
    end

    -- Local web UI + JSON API (non-MCP HTTP surface)
    if request.path == "/ui" and request.method == "GET" then
        socket.write(client, http.response(200, { ["Content-Type"] = "text/html; charset=utf-8" }, ui.html, CORS, false))
        return "close"
    end

    if request.path == "/api/stats" and request.method == "GET" then
        socket.write(client, http.json_response(200, store.stats(store), CORS, false))
        return "close"
    end

    if request.path == "/api/tickets" then
        if request.method == "GET" then
            local q = request.query_params or {}
            local args = { all = true }
            if q.session_id and q.session_id ~= "" then
                args.session_id = q.session_id
                args.all = nil
            end
            if q.status and q.status ~= "" then args.status = q.status end
            if q.type and q.type ~= "" then args.type = q.type end
            if q.types and q.types ~= "" then
                local ts = {}
                for t in q.types:gmatch("[^,]+") do ts[#ts + 1] = t end
                args.types = ts
            end
            if q.include_deleted == "true" then args.include_deleted = true end
            local rows, err = store.list(store, args)
            if rows == nil then
                socket.write(client, http.json_response(400, { error = err }, CORS, false))
            else
                socket.write(client, http.json_response(200, rows, CORS, false))
            end
            return "close"
        elseif request.method == "POST" then
            if not request.body or request.body == "" then
                socket.write(client, http.json_response(400, { error = { code = "E_BAD_JSON", message = "empty body" } }, CORS, false))
                return "close"
            end
            local ok, msg = pcall(jsonic.decode, request.body)
            if not ok or type(msg) ~= "table" then
                socket.write(client, http.json_response(400, { error = { code = "E_BAD_JSON", message = "invalid JSON" } }, CORS, false))
                return "close"
            end
            local t, err = store.add(store, msg)
            if not t then
                socket.write(client, http.json_response(400, { error = err }, CORS, false))
            else
                socket.write(client, http.json_response(200, t, CORS, false))
            end
            return "close"
        end
    end

    if request.path == "/sse" and request.method == "GET" then
        handle_sse_request(client)
        return "hold"
    end

    if request.path == "/mcp" then
        if request.method == "POST" then
            return handle_mcp_post(client, request)
        elseif request.method == "DELETE" then
            return handle_mcp_delete(client, request)
        elseif request.method == "GET" then
            socket.write(client, http.response(405, { ["Allow"] = "POST, DELETE" }, "", CORS, false))
            return "close"
        end
    end

    if request.path == "/message" and request.method == "POST" then
        return handle_message_request(client, request)
    end

    if request.path == "/" and request.method == "GET" then
        local info = {
            name = SERVER_NAME,
            version = SERVER_VERSION,
            protocol = "MCP",
            protocolVersion = MCP_VERSION,
            endpoints = {
                sse = "/sse",
                message = "/message?session=<id>",
                mcp = "/mcp",
            },
            tools = {},
        }
        for _, tool in ipairs(tools) do
            info.tools[#info.tools + 1] = tool.name
        end
        socket.write(client, http.json_response(200, info, CORS, false))
        return "close"
    end

    socket.write(client, http.response(404, {}, "Not Found", nil, false))
    return "close"
end

local function handle_client(client)
    local conn = http.new_connection(function()
        local chunk, read_err = socket.read(client)
        if not chunk then return nil, read_err end
        return chunk
    end)

    while true do
        local request, err, status = conn:next_request()
        if not request and not status then
            socket.close(client)
            return
        end
        if not request then
            socket.write(client, http.error_response(status or 400, { err }, nil, false))
            socket.close(client)
            return
        end

        local outcome = route_request(client, request)
        if outcome == "hold" then return end
        if outcome ~= "keep"
            or not request.persistent_connection
            or (request.headers["connection"] or ""):lower() == "close" then
            socket.close(client)
            return
        end
    end
end

math.randomseed(os.time())

lunet.spawn(function()
    store = store_mod.open(db_path)
    trace.info("STORE", "open %s", db_path)

    local port = tonumber(getenv("PORT")) or 8080
    local host = getenv("HOST") or "127.0.0.1"
    local listener, err = socket.listen("tcp", host, port)
    if not listener then
        trace.error("SERVER", "Cannot listen on port %d: %s", port, err or "unknown")
        io.stderr:write("FATAL: Cannot listen: " .. (err or "unknown") .. "\n")
        return
    end

    trace.info("SERVER", "Starting on port %d", port)
    if VERBOSE then
        print("codex-ticketing MCP server")
        print("======================")
        print("Protocol: MCP " .. MCP_VERSION .. " / " .. STREAMABLE_HTTP_VERSION)
        print("Server:   " .. SERVER_NAME .. " v" .. SERVER_VERSION)
        print("Store:    " .. db_path)
        print("Port:     http://" .. host .. ":" .. port)
        print("Endpoints: /mcp, /sse, /message?session=<id>, /")
        print("Tools:     ticket_add, ticket_get, ticket_list, ticket_comment,")
        print("           ticket_status, ticket_rules, ticket_help, ticket_session_id")
    end

    while true do
        local client = socket.accept(listener)
        if client then
            lunet.spawn(function()
                handle_client(client)
            end)
        end
    end
end)
