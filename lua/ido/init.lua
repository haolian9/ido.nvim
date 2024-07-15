local M = {}

local ropes = require("string.buffer")

local ascii = require("infra.ascii")
local buflines = require("infra.buflines")
local ex = require("infra.ex")
local jelly = require("infra.jellyfish")("ido", "debug")
local ni = require("infra.ni")
local vsel = require("infra.vsel")
local wincursor = require("infra.wincursor")

local anchors = require("ido.anchors")
local collect_routes = require("ido.collect_routes")
local Session = require("ido.Session")
local puff = require("puff")

local ts = vim.treesitter

local resolve_pattern
do
  local rope = ropes.new(64)

  ---transform:
  ---* to fixed string
  ---* add word boundaries
  ---@param keyword string
  function resolve_pattern(keyword)
    keyword = vim.fn.escape(keyword, [[.$*~\]])
    if ascii.is_letter(string.sub(keyword, 1, 1)) then rope:put([[\<]]) end
    rope:put(keyword)
    if ascii.is_letter(string.sub(keyword, -1, -1)) then rope:put([[\>]]) end
    return rope:get()
  end
end

local sessions = {}
do
  ---{bufnr:Session}
  ---@type {[integer]: ido.Session}
  sessions.kv = {}

  ---@param bufnr integer
  ---@return ido.Session?
  function sessions:session(bufnr) return self.kv[bufnr] end

  function sessions:is_active(bufnr) return self.kv[bufnr] ~= nil end

  ---@param ses ido.Session
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

  local ses = Session(winid, cursor, 0, buflines.count(bufnr), resolve_pattern(keyword))
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

  puff.input({ icon = "🎯", prompt = "ido", startinsert = false, default = resolve_pattern(keyword) }, function(pattern)
    if pattern == nil or pattern == "" then return end

    if pcall(ts.get_parser, bufnr) then
      local nodes, paths = collect_routes(bufnr, cursor)
      puff.select(paths, { prompt = "ido regions" }, function(_, index)
        if index == nil then return end
        --todo: potential off-by-one; it seems root-node.stop_lnum is exclusive, but others.stop_lnum are inclusive
        local start_lnum, _, stop_lnum = nodes[index]:range()
        local ses = Session(winid, cursor, start_lnum, stop_lnum, pattern)
        if ses == nil then return end
        sessions:activate(ses)
      end)
    else
      local ses = Session(winid, cursor, 0, buflines.high(bufnr), pattern)
      if ses == nil then return end
      sessions:activate(ses)
    end
  end)
end

do --M.deactivate
  local function select_one_to_deactivate()
    local entries = {}
    local bufs = {}
    for bufnr, ses in pairs(sessions.kv) do
      table.insert(entries, ses:title())
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
