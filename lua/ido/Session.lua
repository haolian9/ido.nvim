local augroups = require("infra.augroups")
local feedkeys = require("infra.feedkeys")
local itertools = require("infra.itertools")
local jelly = require("infra.jellyfish")("ido.Session", "debug")
local ni = require("infra.ni")
local VimRegex = require("infra.VimRegex")
local wincursor = require("infra.wincursor")

local anchors = require("ido.anchors")

local uv = vim.uv

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
---@field pattern string
---@field origins ido.Origin[]
---@field truth_idx integer
---
---@field xmids integer[]
---@field truth_xmid integer @==xmids[truth_idx]
---@field aug infra.BufAugroup
---@field debounce ido.Debounce
local Session = {}
Session.__index = Session

function Session:activate()
  do --place anchors
    for i = 1, #self.origins do
      local origin = self.origins[i]
      local group = i == self.truth_idx and "IdoTruth" or "IdoReplica"
      self.xmids[i] = anchors.set(self.bufnr, origin, group)
    end
    self.truth_xmid = self.xmids[self.truth_idx]
  end

  self.aug = augroups.BufAugroup(self.bufnr, "ido", true)
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
        ---intended to do nothing on undo block, IMO this is the most nature behavior
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
function Session:title()
  local pos = anchors.pos(self.bufnr, self.truth_xmid)
  local lnum = pos and pos.start_lnum or "n/a"
  return string.format("buf#%d:%s '%s'", self.bufnr, lnum, self.pattern)
end

function Session:deactivate()
  self.aug:unlink()
  self.debounce:close()
  for _, xmid in ipairs(self.xmids) do
    anchors.del(self.bufnr, xmid)
  end
end

---@param winid integer
---@param cursor infra.wincursor.Position
---@param pattern string
---@param start_lnum integer @0-based; inclusive
---@param stop_lnum integer @0-based; exclusive
---@return ido.Session?
return function(winid, cursor, start_lnum, stop_lnum, pattern)
  local bufnr = ni.win_get_buf(winid)

  local origins = {} ---@type ido.Origin[]
  do
    local regex = assert(VimRegex(pattern))
    for lnum = start_lnum, stop_lnum - 1 do
      for start_col, stop_col in regex:iter_line(bufnr, lnum) do
        local prev = origins[#origins]
        if prev and prev.lnum == lnum and prev.stop_col == start_col then --
          return jelly.fatal("RuntimeError", "found two contiguous origins: (%d,%d), (%d,%d)", prev.start_col, prev.stop_col, start_col, stop_col)
        end
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
      pattern= pattern, origins = origins, truth_idx = truth_idx,
      xmids = {}, truth_xmid = nil,
    }, Session)
  --stylua: ignore end
end
