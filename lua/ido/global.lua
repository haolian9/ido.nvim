local M = {}

local ascii = require("infra.ascii")
local augroups = require("infra.augroups")
local buflines = require("infra.buflines")
local feedkeys = require("infra.feedkeys")
local highlighter = require("infra.highlighter")
local itertools = require("infra.itertools")
local jelly = require("infra.jellyfish")("ido.global", "info")
local ni = require("infra.ni")
local VimRegex = require("infra.VimRegex")
local vsel = require("infra.vsel")
local wincursor = require("infra.wincursor")

local beckon_select = require("beckon.select")
local ropes = require("string.buffer")

local uv = vim.uv

local anchor_ns = ni.create_namespace("ido:global:anchors")

do
  local hi = highlighter(0)
  if vim.go.background == "light" then
    hi("IdoTruth", { bg = 15, fg = 9, bold = true })
    hi("IdoReplica", { bg = 222, fg = 0 })
  else
    hi("IdoTruth", { bg = 0, fg = 9, bold = true })
    hi("IdoReplica", { bg = 3, fg = 15 })
  end
end

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

local anchors = {}
do
  ---@class ido.XmarkPos
  ---@field start_lnum integer
  ---@field start_col integer
  ---@field stop_lnum integer
  ---@field stop_col integer

  ---@param bufnr integer
  ---@param xmid integer
  ---@return ido.XmarkPos?
  function anchors.pos(bufnr, xmid)
    local xm = ni.buf_get_extmark_by_id(bufnr, anchor_ns, xmid, { details = true })

    --the .invalid is not reliable here
    if xm[1] == xm[3].end_row and xm[2] == xm[3].end_col then return end

    return { start_lnum = xm[1], start_col = xm[2], stop_lnum = xm[3].end_row, stop_col = xm[3].end_col }
  end

  ---@param bufnr integer
  ---@param id_or_pos integer|ido.XmarkPos
  ---@return string[]|nil
  function anchors.text(bufnr, id_or_pos)
    local pos
    if type(id_or_pos) == "number" then
      pos = anchors.pos(bufnr, id_or_pos)
      if pos == nil then return end
    else
      pos = id_or_pos
    end

    return ni.buf_get_text(bufnr, pos.start_lnum, pos.start_col, pos.stop_lnum, pos.stop_col, {})
  end

  ---@param bufnr integer
  ---@param origin ido.Origin
  ---@param group string
  function anchors.set(bufnr, origin, group)
    --stylua: ignore start
    return ni.buf_set_extmark(bufnr, anchor_ns, origin.lnum, origin.start_col, {
      end_row = origin.lnum, end_col = origin.stop_col,
      hl_group = group, hl_mode = "replace",
      right_gravity = false, end_right_gravity = true,

      ---intended to not use {.invalidate, .undo_restore, .invalid}, see anchors.pos
    })
    --stylua: ignore end
  end

  ---@param bufnr integer
  ---@param xmid integer
  function anchors.del(bufnr, xmid) ni.buf_del_extmark(bufnr, anchor_ns, xmid) end
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

local Session
do
  ---@class ido.Origin
  ---@field lnum integer
  ---@field start_col integer
  ---@field stop_col integer

  ---truth_{idx,xmid} -> truth of source; anchor
  ---
  ---@class ido.Session
  ---
  ---@field winid integer
  ---@field bufnr integer
  ---
  ---@field keyword string
  ---@field origins ido.Origin[]
  ---@field truth_idx integer
  ---
  ---@field xmids integer[]
  ---@field truth_xmid integer @==xmids[truth_idx]
  ---@field aug infra.BufAugroup
  ---@field debounce ido.Debounce
  local Impl = {}
  Impl.__index = Impl

  function Impl:activate() --
    do --place anchors
      for i = 1, #self.origins do
        local origin = self.origins[i]
        local group = i == self.truth_idx and "IdoTruth" or "IdoReplica"
        self.xmids[i] = anchors.set(self.bufnr, origin, group)
      end
      self.truth_xmid = self.xmids[self.truth_idx]
    end

    self.aug = augroups.BufAugroup(self.bufnr, true, string.format("ido://%d", self.bufnr))
    self.debounce = Debounce(125)

    do --sync mechanism
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

      local origin_text = anchors.text(self.bufnr, self.truth_xmid)

      --workaround of undo/redo
      local last_text = {} ---@type string[]

      local function on_change()
        local truth_text = anchors.text(self.bufnr, self.truth_xmid)
        if truth_text == nil then jelly.info("anchor#0 has gone") end
        if truth_text == nil then return true end

        if truth_text == origin_text then return jelly.debug("no changes") end
        if itertools.equals(truth_text, last_text) then return jelly.debug("no changes") end

        self.debounce:start_soon(function()
          last_text = truth_text

          for i = 1, #self.xmids do
            if i == self.truth_idx then goto continue end
            local pos = anchors.pos(self.bufnr, self.xmids[i])
            if pos == nil then goto continue end
            ni.buf_set_text(self.bufnr, pos.start_lnum, pos.start_col, pos.stop_lnum, pos.stop_col, truth_text)
            ::continue::
          end
        end)
      end
      self.aug:repeats({ "TextChanged", "TextChangedI" }, { callback = on_change })
    end

    do --initial cursor
      local pos = assert(anchors.pos(self.bufnr, self.truth_xmid))
      assert(pos.stop_col > 0)
      wincursor.go(self.winid, pos.stop_lnum, pos.stop_col - 1)
      feedkeys("a", "n")
    end
  end

  ---@return string
  function Impl:title()
    local pos = anchors.pos(self.bufnr, self.truth_xmid)
    local lnum = pos and pos.start_lnum or "n/a"
    return string.format("buf#%d:%s '%s'", self.bufnr, lnum, self.keyword)
  end

  function Impl:deactivate()
    self.aug:unlink()
    self.debounce:close()
    for _, xmid in ipairs(self.xmids) do
      anchors.del(self.bufnr, xmid)
    end
  end

  ---@param winid integer
  ---@param keyword string
  ---@return ido.Session?
  function Session(winid, keyword)
    local bufnr = ni.win_get_buf(winid)
    local cursor = wincursor.last_position()

    local origins = {} ---@type ido.Origin[]
    do
      local regex = assert(VimRegex(resolve_pattern(keyword)))
      for lnum = 0, buflines.high(bufnr) do
        for start_col, stop_col in regex:iter_line(bufnr, lnum) do
          table.insert(origins, { lnum = lnum, start_col = start_col, stop_col = stop_col })
        end
      end
      if #origins < 2 then return jelly.warn("no other matches") end
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
      if truth_idx == nil then truth_idx = 1 end
    end

    --stylua: ignore start
    return setmetatable({
      winid = winid, bufnr = bufnr,
      keyword = keyword, origins = origins, truth_idx = truth_idx,
      xmids = {}, truth_xmid = nil,
    }, Impl)
    --stylua: ignore end
  end
end

local sessions = {}
do
  ---{bufnr:Session}
  ---@type {[integer]: ido.Session}
  sessions.kv = {}

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
  sessions:deactivate(bufnr)

  local keyword = vsel.oneline_text(bufnr)
  if keyword == nil then return jelly.info("no selecting keyword") end

  local ses = Session(winid, keyword)
  if ses == nil then return end
  sessions:activate(ses)
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

    beckon_select(entries, { prompt = "ido deactivate" }, function(_, row)
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

---@param winid? integer
function M.toggle(winid)
  winid = winid or ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)

  if sessions:is_active(bufnr) then return sessions:deactivate(bufnr) end

  M.activate(winid)
end

return M
