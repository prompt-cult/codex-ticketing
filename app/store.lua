-- codex-ticketing store: SQLite-backed ticket store on lunet.sqlite3.
--
-- Contract parity with opencode-ticketing v2.2.5 (reference: v2.2.1/ticket.ts):
--   * ticket body (md_content) is immutable, written once at creation
--   * comments are append-only, 1000 chars max
--   * the only mutation after creation is status (owner-gated)
--   * superseded soft-deletes: deleted=1, hidden from lists, revealed by
--     include_deleted / includeDeleted
--   * last_actor stamped on status change
--   * type enum: unknown|task|bug|feature|chore|milestone (default unknown)
--   * error envelope: {code, message, corrected_call?} with the hint suffix
--     " — recover with one call: ticket_help" and a COMPLETE args object in
--     corrected_call (received values kept, "<fill: …>" placeholders)
--   * ownership: session_id explicit param (MCP provides no harness session
--     context) on add/list/comment/status
--
-- Envelope codes (mirror the opencode plugin):
--   E_ADD_MISSING_TODO, E_ADD_BAD_TYPE, E_ADD_NO_SESSION_ID,
--   E_LIST_MISSING_SESSION_ID, E_STATUS_MISSING_SESSION_ID,
--   E_STATUS_BAD_STATUS, E_STATUS_REFUSED, E_NO_TICKET,
--   E_COMMENT_MISSING_CONTENT, E_COMMENT_TOO_LONG,
--   E_COMMENT_TICKET_NOT_FOUND, E_COMMENT_MISSING_SESSION_ID, E_SESSION_NO_ID

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local sqlite3 = IS_WINDOWS and require("app.sqlite_win") or require("lunet.sqlite3")

local function db_exec(db, sql, params)
  if IS_WINDOWS then return sqlite3.exec(db, sql, params) end
  if params then return sqlite3.exec_params(db, sql, params) end
  return sqlite3.exec(db, sql)
end

local function db_query(db, sql, params)
  if IS_WINDOWS then return sqlite3.query(db, sql, params) end
  if params then return sqlite3.query_params(db, sql, params) end
  return sqlite3.query_ro(db, sql)
end

local store = {}

local VALID_TYPES = {
  unknown = true, task = true, bug = true, feature = true,
  chore = true, milestone = true,
}

local VALID_STATUSES = {
  pending = true, in_progress = true, completed = true,
  cancelled = true, superseded = true,
}

local TYPES_STR = "unknown|task|bug|feature|chore|milestone"
local STATUSES_STR = "pending|in_progress|completed|cancelled|superseded"

local HELP_HINT = " — recover with one call: ticket_help"

local function now_ts()
  return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time())
end

local function error_envelope(code, message, corrected_call)
  local env = { code = code, message = message }
  if not message:find("recover with one call", 1, true) then
    env.message = message .. HELP_HINT
  end
  if corrected_call then env.corrected_call = corrected_call end
  return env
end

local function row_to_ticket(row)
  return {
    id = row.id,
    created_at = row.created_at,
    updated_at = row.updated_at,
    todo = row.todo,
    md_content = row.md_content,
    status = row.status,
    type = row.type,
    deleted = row.deleted,
    last_actor = row.last_actor,
    session_id = row.session_id,
  }
end

-- Open the DB. Preferred: `create = "WAL"` (v0.15.1+ open contract creates
-- the file and requests+verifies WAL). Fallback for older runtimes: touch
-- the file, then set WAL via PRAGMA after connecting.
local function open_db(path)
  if IS_WINDOWS then
    return sqlite3.open(path)
  elseif path == ":memory:" then
    return sqlite3.connect(path, {})
  end
  local db = sqlite3.connect(path, { create = "WAL" })
  if not db then
    local f = io.open(path, "a")
    if f then f:close() end
    db = sqlite3.connect(path, {})
    if db then
      pcall(function() sqlite3.exec(db, "PRAGMA journal_mode=WAL") end)
    end
  end
  return db
end

-- Idempotent migration: type column (default 'unknown'), index, last_actor
-- column, soft-delete column — guarded by PRAGMA table_info (backwards
-- compatible with legacy schemas).
local function migrate(db)
  db_exec(db, [[
    CREATE TABLE IF NOT EXISTS ticket (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      todo TEXT NOT NULL,
      md_content TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      session_id TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      last_actor TEXT,
      type TEXT NOT NULL DEFAULT 'unknown'
    );
  ]])

  db_exec(db, [[
    CREATE TABLE IF NOT EXISTS ticket_comment (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ticket_id INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      content TEXT NOT NULL,
      author_session_id TEXT NOT NULL
    );
  ]])

  local cols = db_query(db, "PRAGMA table_info(ticket)")
  local has_type = false
  local has_last_actor = false
  for _, c in ipairs(cols) do
    if c.name == "type" then has_type = true end
    if c.name == "last_actor" then has_last_actor = true end
  end
  if not has_type then
    db_exec(db, "ALTER TABLE ticket ADD COLUMN type TEXT NOT NULL DEFAULT 'unknown'")
  end
  db_exec(db, "CREATE INDEX IF NOT EXISTS idx_ticket_type ON ticket(type)")
  if not has_last_actor then
    db_exec(db, "ALTER TABLE ticket ADD COLUMN last_actor TEXT")
  end
end

function store.open(path, opts)
  local db = open_db(path)
  if not db then
    return nil, error_envelope("E_DB_OPEN", "Failed to open database: " .. tostring(path))
  end
  migrate(db)
  return setmetatable({ db = db }, { __index = store })
end

function store.close(self)
  sqlite3.close(self.db)
end

-- Create a ticket. Returns (ticket, nil) or (nil, envelope).
function store.add(self, args)
  local todo = args.todo
  local md_content = args.md_content or ""
  local session_id = args.session_id
  local ttype = args.type or "unknown"

  local corrected = { todo = todo, session_id = session_id, type = ttype }
  if md_content ~= "" then corrected.md_content = md_content end

  if not session_id or session_id == "" then
    return nil, error_envelope("E_ADD_NO_SESSION_ID",
      "no session id found — ticket_add requires the caller's session_id", corrected)
  end
  if not todo or todo == "" then
    return nil, error_envelope("E_ADD_MISSING_TODO",
      "ticket_add requires 'todo' (the one-line summary)", corrected)
  end
  if not VALID_TYPES[ttype] then
    return nil, error_envelope("E_ADD_BAD_TYPE",
      "ticket_add: 'type' must be one of " .. TYPES_STR .. ", got \"" .. tostring(ttype) .. "\"", corrected)
  end

  local ts = now_ts()
  local ok, err = db_exec(self.db,
    "INSERT INTO ticket (created_at, updated_at, todo, md_content, status, session_id, type) VALUES (?, ?, ?, ?, 'pending', ?, ?)",
    { ts, ts, todo, md_content, session_id, ttype })
  if not ok then
    return nil, error_envelope("E_DB_ERROR", "Database error: " .. tostring(err))
  end

  local rows = db_query(self.db, "SELECT MAX(id) AS id FROM ticket")
  local id = rows[1].id
  local t = self.get(self, id)
  if not t then
    return nil, error_envelope("E_NO_TICKET", "Ticket not found after insert")
  end
  return t, nil
end

-- Get a ticket by id, or nil. get returns soft-deleted rows too (the
-- reference does: only list hides them).
function store.get(self, id)
  local rows = db_query(self.db,
    "SELECT * FROM ticket WHERE id = ?", { id })
  if #rows == 0 then return nil end
  return row_to_ticket(rows[1])
end

-- List tickets. Filters: session_id (required unless all), status, type
-- (single), types (multi), include_deleted (reveal soft-deleted), all.
function store.list(self, args)
  local session_id = args.session_id
  local status = args.status
  local ttype = args.type
  local types = args.types
  local all = args.all
  local include_deleted = args.include_deleted

  local where = {}
  local params = {}

  if not include_deleted then
    where[#where + 1] = "deleted = 0"
  end

  if not all then
    if not session_id or session_id == "" then
      return nil, error_envelope("E_LIST_MISSING_SESSION_ID",
        "ticket_list requires 'session_id' (the session id to query) — or all=true for every session's tickets",
        { session_id = "<fill: the session id to query>", all = true })
    end
    where[#where + 1] = "session_id = ?"
    params[#params + 1] = session_id
  end

  if status then
    where[#where + 1] = "status = ?"
    params[#params + 1] = status
  end

  if ttype then
    where[#where + 1] = "type = ?"
    params[#params + 1] = ttype
  elseif types and #types > 0 then
    local count = #types
    local marks = {}
    for i = 1, count do
      marks[i] = "?"
      params[#params + 1] = types[i]
    end
    where[#where + 1] = "type IN (" .. table.concat(marks, ",") .. ")"
  end

  local sql = "SELECT * FROM ticket"
  if #where > 0 then
    sql = sql .. " WHERE " .. table.concat(where, " AND ")
  end
  sql = sql .. " ORDER BY id"
  local rows = db_query(self.db, sql, params)

  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = row_to_ticket(r)
  end
  return out, nil
end

-- Append a comment. Returns (comment_row, nil) or (nil, envelope). Any
-- session may append; the author is the session_id param (stamped).
function store.comment(self, args)
  local id = args.id
  local content = args.content
  local session_id = args.session_id

  local corrected = { id = id, content = content, session_id = session_id }

  if not session_id or session_id == "" then
    return nil, error_envelope("E_COMMENT_MISSING_SESSION_ID",
      "ticket_comment requires 'session_id' (the author session id)", corrected)
  end
  if not id then
    return nil, error_envelope("E_COMMENT_TICKET_NOT_FOUND",
      "ticket_comment requires 'id' (the ticket number)", corrected)
  end
  local t = self.get(self, id)
  if not t then
    return nil, error_envelope("E_COMMENT_TICKET_NOT_FOUND",
      "no ticket with number " .. tostring(id), corrected)
  end
  if not content or content == "" then
    return nil, error_envelope("E_COMMENT_MISSING_CONTENT",
      "ticket_comment requires 'content' — a short go/no-go note", corrected)
  end
  if #content > 1000 then
    return nil, error_envelope("E_COMMENT_TOO_LONG",
      "a comment is a short go/no-go note — done / not done / blocked (1000 chars max). Long reports never go on the ticket: put the detail in your final response (or a gist)",
      { id = id, content = "<fill: short note>", session_id = session_id })
  end

  local ts = now_ts()
  local ok, err = db_exec(self.db,
    "INSERT INTO ticket_comment (ticket_id, created_at, content, author_session_id) VALUES (?, ?, ?, ?)",
    { id, ts, content, session_id })
  if not ok then
    return nil, error_envelope("E_DB_ERROR", "Database error: " .. tostring(err))
  end

  local rows = db_query(self.db, "SELECT MAX(id) AS id FROM ticket_comment")
  local crows = db_query(self.db,
    "SELECT id, ticket_id, created_at, content, author_session_id FROM ticket_comment WHERE id = ?",
    { rows[1].id })
  return crows[1], nil
end

-- Set status. The ONLY mutation. Owner-gated: session_id must be the
-- ticket's owner. superseded marks the ticket soft-deleted (deleted=1).
-- last_actor is stamped with the caller's session id.
function store.status(self, args)
  local id = args.id
  local session_id = args.session_id
  local status = args.status

  if not session_id or session_id == "" then
    return nil, error_envelope("E_STATUS_MISSING_SESSION_ID",
      "ticket_status requires 'session_id' — the ticket's owner session id",
      { id = id, session_id = "<fill: the ticket's owner session id>", status = status })
  end
  if not id then
    return nil, error_envelope("E_NO_TICKET", "ticket_status requires 'id' (the ticket number)")
  end
  local t = self.get(self, id)
  if not t then
    return nil, error_envelope("E_NO_TICKET", "no ticket with number " .. tostring(id),
      { id = id })
  end
  if not VALID_STATUSES[status] then
    return nil, error_envelope("E_STATUS_BAD_STATUS",
      "ticket_status: 'status' must be one of " .. STATUSES_STR .. ", got \"" .. tostring(status) .. "\"",
      { id = id, session_id = session_id, status = "pending" })
  end
  if t.session_id ~= session_id then
    return nil, error_envelope("E_STATUS_REFUSED",
      "ticket_status refused: ticket " .. id .. " belongs to session \"" .. t.session_id .. "\", not \"" .. session_id .. "\" — the owner session id is \"" .. t.session_id .. "\"",
      { id = id, session_id = t.session_id, status = status })
  end

  local deleted = t.deleted
  if status == "superseded" then deleted = 1 end

  local ok, err = db_exec(self.db,
    "UPDATE ticket SET status = ?, updated_at = ?, last_actor = ?, deleted = ? WHERE id = ?",
    { status, now_ts(), session_id, deleted, id })
  if not ok then
    return nil, error_envelope("E_DB_ERROR", "Database error: " .. tostring(err))
  end
  return self.get(self, id), nil
end

-- Return the caller's session id (echo), for the ticket_session_id tool.
function store.session_id(self, args)
  local session_id = args.session_id
  if not session_id or session_id == "" then
    return nil, error_envelope("E_SESSION_NO_ID", "no session id found — the session id for this call")
  end
  return { session_id = session_id }, nil
end

function store.comments(self, id)
  local rows = db_query(self.db,
    "SELECT * FROM ticket_comment WHERE ticket_id = ? ORDER BY id", { id })
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = {
      id = r.id,
      ticket_id = r.ticket_id,
      created_at = r.created_at,
      content = r.content,
      author_session_id = r.author_session_id,
    }
  end
  return out
end

-- Aggregate stats for the about/stats view.
function store.stats(self)
  local rows = db_query(self.db, [[
    SELECT
      COUNT(*) AS total,
      COUNT(CASE WHEN deleted = 0 THEN 1 END) AS active,
      MAX(updated_at) AS latest_updated,
      MAX(created_at) AS latest_created
    FROM ticket
  ]])
  local s = rows[1] or {}
  local by_type = {}
  local by_status = {}
  for _, r in ipairs(db_query(self.db,
    "SELECT type, COUNT(*) AS n FROM ticket WHERE deleted = 0 GROUP BY type")) do
    by_type[r.type] = r.n
  end
  for _, r in ipairs(db_query(self.db,
    "SELECT status, COUNT(*) AS n FROM ticket WHERE deleted = 0 GROUP BY status")) do
    by_status[r.status] = r.n
  end
  return {
    total = s.total or 0,
    active = s.active or 0,
    latest_updated = s.latest_updated,
    latest_created = s.latest_created,
    by_type = by_type,
    by_status = by_status,
  }
end

function store.valid_types()
  return TYPES_STR
end

function store.valid_statuses()
  return STATUSES_STR
end

return store
