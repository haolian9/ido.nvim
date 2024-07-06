local M = {}

local augroups = require("infra.augroups")
local buflines = require("infra.buflines")
local feedkeys = require("infra.feedkeys")
local itertools = require("infra.itertools")
local jelly = require("infra.jellyfish")("ido.global", "info")
local ni = require("infra.ni")
local VimRegex = require("infra.VimRegex")
local vsel = require("infra.vsel")
local wincursor = require("infra.wincursor")

local beckon_select = require("beckon.select")

local uv = vim.uv

local anchor_ns = ni.create_namespace("ido:global:anchors")

local xmarks = {}
do
  ---@class ido.XmarkPos
  ---@field start_lnum integer
  ---@field start_col integer
  ---@field stop_lnum integer
  ---@field stop_col integer

  ---@param bufnr integer
  ---@param xmid integer
  ---@return ido.XmarkPos?
  function xmarks.pos(bufnr, xmid)
    local xm = ni.buf_get_extmark_by_id(bufnr, anchor_ns, xmid, { details = true })
    if xm[3].invalid then return end
    return { start_lnum = xm[1], start_col = xm[2], stop_lnum = xm[3].end_row, stop_col = xm[3].end_col }
  end

  ---@param bufnr integer
  ---@param id_or_pos integer|ido.XmarkPos
  ---@return string[]|nil
  function xmarks.text(bufnr, id_or_pos)
    local pos
    if type(id_or_pos) == "number" then
      pos = xmarks.pos(bufnr, id_or_pos)
      if pos == nil then return end
    else
      pos = id_or_pos
    end

    return ni.buf_get_text(bufnr, pos.start_lnum, pos.start_col, pos.stop_lnum, pos.stop_col, {})
  end
end

local Debounce
do
  ---@diagnostic disable: undefined-field

  ---@class ido.Debounce
  ---@field timer ffi.cdata*
  ---@field delay integer @in milliseconds
  local Impl = {}
  Impl.__index = Impl

  function Impl:start_soon(logic)
    self.timer:stop()
    self.timer:start(self.delay, 0, vim.schedule_wrap(logic))
  end

  function Impl:close()
    self.timer:stop()
    self.timer:close()
  end

  ---@param delay integer @in milliseconds
  ---@return ido.Debounce
  function Debounce(delay)
    local timer = uv.new_timer()
    return setmetatable({ timer = timer, delay = delay }, Impl)
  end
end

local sessions = {}
do
  ---@class ido.Session
  ---@field title string @used for M.deactive.select_one_to_deactive
  ---@field deactive fun()

  ---{bufnr:Session}
  ---@type {[integer]: ido.Session}
  sessions.kv = {}

  function sessions:is_active(bufnr) return self.kv[bufnr] ~= nil end

  function sessions:activate(bufnr, ses)
    assert(self.kv[bufnr] == nil, "this buf has already activated a session")
    self.kv[bufnr] = ses
  end

  function sessions:deactivate(bufnr)
    local ses = self.kv[bufnr]
    if ses == nil then return end
    self.kv[bufnr] = nil
    ses.deactive()
  end
end

---@class ido.Origin
---@field lnum integer
---@field start_col integer
---@field stop_col integer

---@param winid integer
function M.activate(winid)
  winid = winid or ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)
  local cursor = wincursor.last_position()

  sessions:deactivate(bufnr)

  local keyword = vsel.oneline_text(bufnr)
  if keyword == nil then return jelly.info("no selecting keyword") end
  keyword = vim.fn.escape(keyword, [[.$*~\]])

  ni.buf_clear_namespace(bufnr, anchor_ns, 0, -1)

  local origins = {} ---@type ido.Origin[]
  do
    local regex = assert(VimRegex(string.format([[\<%s\>]], keyword)))
    for lnum = 0, buflines.high(bufnr) do
      for start_col, stop_col in regex:iter_line(bufnr, lnum) do
        table.insert(origins, { lnum = lnum, start_col = start_col, stop_col = stop_col })
      end
    end
    if #origins < 2 then return jelly.info("no other matches") end
  end

  local truth_idx
  do
    local min_dis
    for i = 1, #origins do
      local origin = origins[i]
      if origin.lnum ~= cursor.lnum then goto continue end
      local dis = math.min(math.abs(origin.start_col - cursor.col), math.abs(origin.stop_col - cursor.col))
      if min_dis == nil or dis < min_dis then
        min_dis = dis
        truth_idx = i
      end
      ::continue::
    end
    if truth_idx == nil then return jelly.fatal("unreachable", "no truth_idx found: cursor=%s; origins: %s", cursor, origins) end
  end

  local xmids = {} ---@type integer[]
  local truth_xmid
  for i = 1, #origins do
    local origin = origins[i]
    --todo: dedicated hlgroups for ido
    local group = i == truth_idx and "Todo" or "Search"
    --stylua: ignore start
    local xmid = ni.buf_set_extmark(bufnr, anchor_ns, origin.lnum, origin.start_col, {
      end_row = origin.lnum, end_col = origin.stop_col,
      hl_group = group, hl_mode = "replace",
      right_gravity = false, end_right_gravity = true,
    })
    --stylua: ignore end
    xmids[i] = xmid
    if i == truth_idx then truth_xmid = xmid end
  end

  local aug = augroups.BufAugroup(bufnr, true, string.format("ido://%d", bufnr))
  local debounce = Debounce(125)
  do
    ---known facts:
    ---* buf_set_text wont trigger TextChanged/I in insert/normal mode
    ---* undo also triggers TextChanged and buf_set_text here creates undo blocks, this leads infinite undo
    ---
    ---design choices
    ---* only sync changes from truth_xm
    ---* allow change other xms, but no syncing
    ---
    ---workaround for undo/redo
    ---* compare last_text and truth_text to avoid replicate triggering

    local origin_text = xmarks.text(bufnr, truth_xmid)

    --workaround of undo/redo
    local last_text = {} ---@type string[]

    local function on_change()
      local truth_text = xmarks.text(bufnr, truth_xmid)
      if truth_text == nil then jelly.info("anchor#0 has gone") end
      if truth_text == nil then return true end

      if truth_text == origin_text then return jelly.debug("no changes") end
      if itertools.equals(truth_text, last_text) then return jelly.debug("no changes") end

      debounce:start_soon(function()
        last_text = truth_text

        for i = 1, #xmids do
          if i == truth_idx then goto continue end
          local pos = xmarks.pos(bufnr, xmids[i])
          if pos == nil then goto continue end
          ni.buf_set_text(bufnr, pos.start_lnum, pos.start_col, pos.stop_lnum, pos.stop_col, truth_text)
          ::continue::
        end
      end)
    end
    aug:repeats({ "TextChanged", "TextChangedI" }, { callback = on_change })
  end

  sessions:activate(bufnr, {
    title = function()
      local pos = xmarks.pos(bufnr, truth_xmid)
      local lnum = pos and pos.start_lnum or "n/a"
      return string.format("buf#%d:%s '%s'", bufnr, lnum, keyword)
    end,
    deactive = function()
      aug:unlink()
      debounce:close()
      ni.buf_clear_namespace(bufnr, anchor_ns, 0, -1)
    end,
  })

  do
    local pos = assert(xmarks.pos(bufnr, truth_xmid))
    assert(pos.stop_col > 0)
    wincursor.go(winid, pos.stop_lnum, pos.stop_col - 1)
    feedkeys("a", "n")
  end
end

do --M.deactive
  local function select_one_to_deactive()
    local entries = {}
    local bufs = {}
    for bufnr, ses in pairs(sessions.kv) do
      table.insert(entries, ses.title())
      table.insert(bufs, bufnr)
    end
    if #entries == 0 then return jelly.info("no active sessions") end

    beckon_select(entries, { prompt = "ido deactive" }, function(_, row)
      local nr = assert(bufs[row])
      sessions:deactivate(nr)
    end)
  end

  function M.deactive(winid)
    winid = winid or ni.get_current_win()
    local bufnr = ni.win_get_buf(winid)

    if sessions:is_active(bufnr) then return sessions:deactivate(bufnr) end

    select_one_to_deactive()
  end
end

function M.toggle(winid)
  winid = winid or ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)

  if sessions:is_active(bufnr) then return sessions:deactivate(bufnr) end

  M.activate(winid)
end

return M
