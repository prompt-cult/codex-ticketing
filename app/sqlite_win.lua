-- Minimal SQLite adapter for Windows.
--
-- Lunet v0.19.0's sqlite3core.dll exits during sqlite3_open on Windows.
-- Use the official sqlite3.dll through LuaJIT FFI instead; the ticket store
-- only needs prepared statements, scalar binds, rows, and simple writes.

local ffi = require("ffi")

ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef void (*sqlite3_destructor_type)(void*);
int sqlite3_open_v2(const char*, sqlite3**, int, const char*);
int sqlite3_close(sqlite3*);
int sqlite3_busy_timeout(sqlite3*, int);
const char *sqlite3_errmsg(sqlite3*);
int sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
int sqlite3_step(sqlite3_stmt*);
int sqlite3_finalize(sqlite3_stmt*);
int sqlite3_bind_null(sqlite3_stmt*, int);
int sqlite3_bind_int64(sqlite3_stmt*, int, long long);
int sqlite3_bind_double(sqlite3_stmt*, int, double);
int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, sqlite3_destructor_type);
int sqlite3_column_count(sqlite3_stmt*);
const char *sqlite3_column_name(sqlite3_stmt*, int);
int sqlite3_column_type(sqlite3_stmt*, int);
long long sqlite3_column_int64(sqlite3_stmt*, int);
double sqlite3_column_double(sqlite3_stmt*, int);
const unsigned char *sqlite3_column_text(sqlite3_stmt*, int);
int sqlite3_changes(sqlite3*);
long long sqlite3_last_insert_rowid(sqlite3*);
]]

local sqlite = ffi.load("sqlite3")
local M = {}

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_OPEN_READWRITE = 0x00000002
local SQLITE_OPEN_CREATE = 0x00000004
local SQLITE_TRANSIENT = ffi.cast("sqlite3_destructor_type", -1)

local function errmsg(db)
  return ffi.string(sqlite.sqlite3_errmsg(db.ptr))
end

local function prepare(db, sql)
  local out = ffi.new("sqlite3_stmt*[1]")
  local rc = sqlite.sqlite3_prepare_v2(db.ptr, sql, -1, out, nil)
  if rc ~= SQLITE_OK then return nil, errmsg(db) end
  return out[0]
end

local function bind(stmt, params)
  for i, value in ipairs(params or {}) do
    local rc
    if value == nil then
      rc = sqlite.sqlite3_bind_null(stmt, i)
    elseif type(value) == "number" then
      if value == math.floor(value) then
        rc = sqlite.sqlite3_bind_int64(stmt, i, value)
      else
        rc = sqlite.sqlite3_bind_double(stmt, i, value)
      end
    else
      rc = sqlite.sqlite3_bind_text(stmt, i, tostring(value), -1, SQLITE_TRANSIENT)
    end
    if rc ~= SQLITE_OK then return false end
  end
  return true
end

local function value(stmt, col)
  local kind = sqlite.sqlite3_column_type(stmt, col)
  if kind == 1 then return tonumber(sqlite.sqlite3_column_int64(stmt, col)) end
  if kind == 2 then return tonumber(sqlite.sqlite3_column_double(stmt, col)) end
  if kind == 5 then return nil end
  local text = sqlite.sqlite3_column_text(stmt, col)
  return text == nil and nil or ffi.string(text)
end

function M.open(path)
  local out = ffi.new("sqlite3*[1]")
  local rc = sqlite.sqlite3_open_v2(path, out,
    SQLITE_OPEN_READWRITE + SQLITE_OPEN_CREATE, nil)
  if rc ~= SQLITE_OK or out[0] == nil then
    return nil
  end
  local db = { kind = "windows-ffi", ptr = out[0], path = path }
  sqlite.sqlite3_busy_timeout(db.ptr, 5000)
  return db
end

function M.close(db)
  if db and db.ptr ~= nil then
    sqlite.sqlite3_close(db.ptr)
    db.ptr = nil
  end
end

function M.exec(db, sql, params)
  local stmt, err = prepare(db, sql)
  if not stmt then return nil, err end
  if not bind(stmt, params) then
    sqlite.sqlite3_finalize(stmt)
    return nil, errmsg(db)
  end
  local rc
  repeat rc = sqlite.sqlite3_step(stmt) until rc ~= SQLITE_ROW
  sqlite.sqlite3_finalize(stmt)
  if rc ~= SQLITE_DONE then return nil, errmsg(db) end
  return {
    affected_rows = tonumber(sqlite.sqlite3_changes(db.ptr)),
    last_insert_id = tonumber(sqlite.sqlite3_last_insert_rowid(db.ptr)),
  }, nil
end

function M.query(db, sql, params)
  local stmt, err = prepare(db, sql)
  if not stmt then return {}, err end
  if not bind(stmt, params) then
    sqlite.sqlite3_finalize(stmt)
    return {}, errmsg(db)
  end
  local count = sqlite.sqlite3_column_count(stmt)
  local names = {}
  for col = 0, count - 1 do names[col] = ffi.string(sqlite.sqlite3_column_name(stmt, col)) end
  local rows = {}
  while true do
    local rc = sqlite.sqlite3_step(stmt)
    if rc == SQLITE_DONE then break end
    if rc ~= SQLITE_ROW then
      local message = errmsg(db)
      sqlite.sqlite3_finalize(stmt)
      return {}, message
    end
    local row = {}
    for col = 0, count - 1 do row[names[col]] = value(stmt, col) end
    rows[#rows + 1] = row
  end
  sqlite.sqlite3_finalize(stmt)
  return rows, nil
end

return M
