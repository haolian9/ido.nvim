local M = {}

-- 确定关键字: exact, regex?
-- 确定作用域
-- 选择匹配项
-- 定位到起始位置，sync
-- confirm or cancel

local augroups = require("infra.augroups")
local buflines = require("infra.buflines")
local feedkeys = require("infra.feedkeys")
local itertools = require("infra.itertools")
local jelly = require("infra.jellyfish")("ido.global", "debug")
local ni = require("infra.ni")
local VimRegex = require("infra.VimRegex")
local vsel = require("infra.vsel")
local wincursor = require("infra.wincursor")

local beckon_select = require("beckon.select")

local uv = vim.uv

local anchor_ns = ni.create_namespace("ido:global:anchors")

local xmarks = {}
do
  ---@param bufnr integer
  ---@param xmid integer
  ---@return nil|{start_lnum:integer, start_col:integer, stop_lnum:integer, stop_col:integer}
  function xmarks.pos(bufnr, xmid)
    local xm = ni.buf_get_extmark_by_id(bufnr, anchor_ns, xmid, { details = true })
    if xm[3].invalid then return end
    return { start_lnum = xm[1], start_col = xm[2], stop_lnum = xm[3].end_row, stop_col = xm[3].end_col }
  end

  ---@param bufnr integer
  ---@param xmid integer
  ---@return string[]|nil
  function xmarks.text(bufnr, xmid)
    local pos = xmarks.pos(bufnr, xmid)
    if pos == nil then return end
    return ni.buf_get_text(bufnr, pos.start_lnum, pos.start_col, pos.stop_lnum, pos.stop_col, {})
  end
end

local Debounce
do
  ---@class ido.Debounce
  ---@field timer ffi.cdata*
  ---@field delay integer @in milliseconds
  local Impl = {}
  Impl.__index = Impl

  function Impl:start_soon(logic)
    uv.timer_stop(self.timer)
    uv.timer_start(self.timer, self.delay, 0, vim.schedule_wrap(logic))
  end

  function Impl:close()
    uv.timer_stop(self.timer)
    uv.timer_close(self.timer)
  end

  ---@param delay integer @in milliseconds
  ---@return ido.Debounce
  function Debounce(delay)
    local timer = uv.new_timer()
    return setmetatable({ timer = timer, delay = delay }, Impl)
  end
end

---@type {[integer]: {keyword:string, truth_xmid:integer, deactive:fun()}}
local sessions = {}

function M.active()
  local winid = ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)

  ---deactive previous session if any
  if sessions[bufnr] and ni.buf_is_valid(bufnr) then sessions[bufnr].deactive() end

  local keyword = vsel.oneline_text(bufnr)
  if keyword == nil then return jelly.warn("no selecting keyword") end
  keyword = vim.fn.escape(keyword, [[.$*~\]])

  ni.buf_clear_namespace(bufnr, anchor_ns, 0, -1)

  local origins = {}
  do
    local regex = assert(VimRegex(keyword))
    for lnum = 0, buflines.high(bufnr) do
      for start, stop in regex:iter_line(bufnr, lnum) do
        table.insert(origins, { lnum, start, stop })
      end
    end
    jelly.debug("anchors: %s", origins)
    if #origins < 2 then return jelly.warn("no other matches") end
  end

  local xmids = {}
  do
    local iter = itertools.itern(origins)

    do --the first one
      local lnum, start_col, stop_col = iter()
      --stylua: ignore
      local xmid = ni.buf_set_extmark(bufnr, anchor_ns, lnum, start_col, {
        end_row = lnum, end_col = stop_col,
        hl_group = "Todo", hl_mode = "replace",
        right_gravity = false, end_right_gravity = true,
      })
      table.insert(xmids, xmid)
    end

    for lnum, start_col, stop_col in iter do
      --stylua: ignore
      local xmid = ni.buf_set_extmark(bufnr, anchor_ns, lnum, start_col, {
        end_row = lnum, end_col = stop_col,
        hl_group = "Search", hl_mode = "replace",
        right_gravity = false, end_right_gravity = true,
      })
      table.insert(xmids, xmid)
    end
  end

  --todo: find the one closed to the cursor!
  local truth_xmid = xmids[1]

  local aug = augroups.BufAugroup(bufnr, true, string.format("ido://%d", bufnr))

  do
    local origin_text = xmarks.text(bufnr, truth_xmid)
    local debounce = Debounce(125)

    local function on_change(args)
      assert(args.event ~= "TextChanged", "buf_set_text triggers TextChanged recursively!")

      local text = xmarks.text(bufnr, truth_xmid)
      if text == nil then jelly.info("anchor#0 has gone") end
      if text == nil then return true end

      if text == origin_text then return jelly.debug("no changes") end

      debounce:start_soon(function()
        for i = 2, #xmids do
          local pos = xmarks.pos(bufnr, xmids[i])
          if pos ~= nil then ni.buf_set_text(bufnr, pos.start_lnum, pos.start_col, pos.stop_lnum, pos.stop_col, text) end
        end
      end)
    end

    aug:repeats("TextChangedI", { callback = on_change })
  end

  local pos = assert(xmarks.pos(bufnr, truth_xmid))
  wincursor.go(winid, pos.stop_lnum, pos.stop_col)

  sessions[bufnr] = {
    keyword = keyword,
    truth_xmid = truth_xmid,
    deactive = function()
      aug:unlink()
      ni.buf_clear_namespace(bufnr, anchor_ns, 0, -1)
    end,
  }

  feedkeys("i", "n")
end

do
  local function select_one_to_deactive()
    local entries = {}
    local bufs = {}
    for bufnr, ses in pairs(sessions) do
      local pos = xmarks.pos(bufnr, ses.truth_xmid)
      local lnum = pos and pos.start_lnum or "n/a"
      table.insert(entries, string.format("buf#%d:%s %s", bufnr, lnum, ses.keyword))
      table.insert(bufs, bufnr)
    end

    beckon_select(entries, { prompt = "ido deactive" }, function(_, row)
      local nr = assert(bufs[row])
      local ses = sessions[nr]
      sessions[nr] = nil
      ses.deactive()
    end)
  end

  function M.deactive(bufnr)
    if bufnr == nil then bufnr = ni.get_current_buf() end

    local ses = sessions[bufnr]
    if ses then
      return ses.deactive()
    else
      return select_one_to_deactive()
    end
  end
end

return M
