local M = {}

local ropes = require("string.buffer")

local ascii = require("infra.ascii")
local buflines = require("infra.buflines")
local ex = require("infra.ex")
local jelly = require("infra.jellyfish")("ido", "info")
local ni = require("infra.ni")
local vsel = require("infra.vsel")
local wincursor = require("infra.wincursor")

local anchors = require("ido.anchors")
local collect_routes = require("ido.collect_routes")
local CoredSession = require("ido.CoredSession")
local FixedSession = require("ido.FixedSession")
local puff = require("puff")

local ts = vim.treesitter

local resolve_as_fixed_pattern
do
  local rope = ropes.new(64)

  ---transform:
  ---* to fixed string
  ---* add word boundaries
  ---@param keyword string
  function resolve_as_fixed_pattern(keyword)
    keyword = vim.fn.escape(keyword, [[.$*~\]])
    if ascii.is_letter(string.sub(keyword, 1, 1)) then rope:put([[\<]]) end
    rope:put(keyword)
    if ascii.is_letter(string.sub(keyword, -1, -1)) then rope:put([[\>]]) end
    return rope:get()
  end
end

---CAUTION: it uses the current window internally
---@param expr string
---@return integer start_lnum @0-based
---@return integer stop_lnum @0-based, exclusive
local function eval_range_expr(expr)
  local parsed = ni.parse_cmd(expr .. "w", {})
  local start_lnum, stop_lnum = unpack(assert(parsed.range))
  start_lnum = start_lnum - 1
  if stop_lnum == nil then stop_lnum = start_lnum + 1 end

  return start_lnum, stop_lnum
end

local sessions = {}
do
  ---{bufnr:Session}
  ---@type {[integer]: ido.FixedSession|ido.CoredSession}
  sessions.kv = {}

  ---@param bufnr integer
  ---@return ido.FixedSession|ido.CoredSession?
  function sessions:session(bufnr)
    local ses = self.kv[bufnr]
    if ses == nil then return end
    assert(ses.status ~= "created")
    if ses.status == "active" then return ses end
    self.kv[bufnr] = nil
  end

  ---@param bufnr integer
  ---@return boolean
  function sessions:is_active(bufnr)
    local ses = self.kv[bufnr]
    if ses == nil then return false end
    assert(ses.status ~= "created")
    if ses.status == "active" then return true end
    self.kv[bufnr] = nil
    return false
  end

  ---@param ses ido.FixedSession|ido.CoredSession
  function sessions:activate(ses)
    assert(self.kv[ses.bufnr] == nil, "this buf has already activated a session")
    self.kv[ses.bufnr] = ses
    ses:activate()
  end

  function sessions:deactivate(bufnr)
    local ses = self.kv[bufnr]
    if ses == nil then return end
    self.kv[bufnr] = nil
    ses:deactivate()
  end
end

---@param winid? integer
function M.activate(winid)
  winid = winid or ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)
  local cursor = wincursor.last_position()

  sessions:deactivate(bufnr)

  local keyword = vsel.oneline_text(bufnr)
  if keyword == nil then return jelly.info("no selecting keyword") end

  local ses = FixedSession(winid, cursor, 0, buflines.count(bufnr), resolve_as_fixed_pattern(keyword))
  if ses == nil then return end
  sessions:activate(ses)
end

---@param winid? integer
function M.activate_interactively(winid)
  winid = winid or ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)
  local cursor = wincursor.last_position()

  sessions:deactivate(bufnr)

  local keyword = vsel.oneline_text(bufnr)
  if keyword == nil then return jelly.info("no selecting keyword") end

  local default_pattern = resolve_as_fixed_pattern(keyword)
  puff.input({ icon = "🎯", prompt = "ido", startinsert = false, default = default_pattern }, function(pattern)
    if pattern == nil or pattern == "" then return end

    local SessionImpl = pattern == default_pattern and FixedSession or CoredSession

    if pcall(ts.get_parser, bufnr) then
      local nodes, paths = collect_routes(bufnr, cursor)
      puff.select(paths, { prompt = "ido regions" }, function(_, index)
        if index == nil then return end
        --todo: potential off-by-one; it seems root-node.stop_lnum is exclusive, but others.stop_lnum are inclusive
        local start_lnum, _, stop_lnum = nodes[index]:range()
        stop_lnum = stop_lnum + 1
        local ses = SessionImpl(winid, cursor, start_lnum, stop_lnum, pattern)
        if ses == nil then return end
        sessions:activate(ses)
      end)
    else
      puff.select({ ".", ".,$", "1,.", "1,$" }, { prompt = "ido ranges" }, function(expr)
        if expr == nil then return end
        local start_lnum, stop_lnum = eval_range_expr(expr)
        local ses = SessionImpl(winid, cursor, start_lnum, stop_lnum, pattern)
        if ses == nil then return end
        sessions:activate(ses)
      end)
    end
  end)
end

do --M.deactivate
  local function select_one_to_deactivate()
    local entries = {}
    local bufs = {}
    for bufnr, ses in pairs(sessions.kv) do
      table.insert(entries, ses.title)
      table.insert(bufs, bufnr)
    end
    if #entries == 0 then return jelly.info("no active sessions") end

    puff.select(entries, { prompt = "ido deactivate" }, function(_, row)
      local nr = assert(bufs[row])
      sessions:deactivate(nr)
    end)
  end

  ---@param winid? integer
  function M.deactivate(winid)
    winid = winid or ni.get_current_win()
    local bufnr = ni.win_get_buf(winid)

    if sessions:is_active(bufnr) then return sessions:deactivate(bufnr) end

    select_one_to_deactivate()
  end
end

function M.goto_truth(winid)
  winid = winid or ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)

  local ses = sessions:session(bufnr)
  if ses == nil then return jelly.info("no active session") end

  local pos = anchors.pos(bufnr, ses.truth_xmid)
  if pos == nil then return jelly.debug("invald truth xmark") end
  wincursor.go(winid, pos.stop_lnum, pos.stop_col)
  ex("startinsert")
end

return M
