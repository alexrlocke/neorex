-- neorex in Neovim: every window except one hidden anchor per tab page is
-- external, shown in its own Rex pane. Run once with nvim_exec_lua(chan,
-- cols, rows); returns { first window, its anchor }.
local chan, cols, rows = ...
local api = vim.api
local M = {}
_G.neorex = M

-- tab page -> anchor window
local anchors = {}
-- the window last reported as current
local last
local group = api.nvim_create_augroup('neorex', {})

local function is_anchor(win)
  for _, a in pairs(anchors) do
    if a == win then return true end
  end
  return false
end

local function anchor_of(tab)
  local a = anchors[tab]
  if a and api.nvim_win_is_valid(a) then return a end
  anchors[tab] = nil
end

-- a window a pane shows: external, or ordinary and not an anchor
local function shown(win)
  if not api.nvim_win_is_valid(win) or is_anchor(win) then return false end
  local c = api.nvim_win_get_config(win)
  return c.external or c.relative == ''
end

local function others_shown(win)
  for _, w in ipairs(api.nvim_list_wins()) do
    if w ~= win and shown(w) then return true end
  end
  return false
end

local making_anchor = false

--- Makes ordinary `win` external at `w` x `h`, giving its tab page an anchor first.
function M.adopt(win, w, h)
  if not shown(win) or api.nvim_win_get_config(win).external then return end
  local tab = api.nvim_win_get_tabpage(win)
  if not anchor_of(tab) then
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    making_anchor = true
    anchors[tab] = api.nvim_open_win(buf, false, { split = 'left', win = win })
    making_anchor = false
  end
  api.nvim_win_set_config(win, { external = true, width = w, height = h })
end

--- Closes `win`, whose pane went away. Unsaved changes stay in its buffer.
function M.close(win)
  if api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
end

-- the layout node holding `win`: 'row' or 'col', and whether `win` is first
local function placement(win)
  local function find(node)
    if node[1] == 'leaf' then return end
    for i, c in ipairs(node[2]) do
      if c[1] == 'leaf' and c[2] == win then return node[1], i == 1 end
      local dir, first = find(c)
      if dir then return dir, first end
    end
  end
  return find(vim.fn.winlayout(api.nvim_tabpage_get_number(api.nvim_win_get_tabpage(win))))
end

-- before it's adopted, so its pane opens where Neovim put the window
api.nvim_create_autocmd('WinNew', {
  group = group,
  callback = function()
    if making_anchor then return end
    local win = api.nvim_get_current_win()
    local dir, first = placement(win)
    if not dir then return end
    local from = vim.fn.win_getid(vim.fn.winnr('#'))
    vim.rpcnotify(chan, 'neorex_split', win, dir == 'row', first, shown(from) and from or 0)
  end,
})

local pending = false
local function report()
  pending = false
  local cur = api.nvim_get_current_win()
  if is_anchor(cur) then
    -- never shown: move on the way <C-w>w or <C-w>W was going
    local wins = vim.tbl_filter(shown, api.nvim_tabpage_list_wins(0))
    if #wins == 0 then return end
    local prev = vim.fn.win_getid(vim.fn.winnr('#'))
    local to = (last and shown(last)) and last or wins[1]
    if prev == wins[#wins] then
      to = wins[1]
    elseif prev == wins[1] then
      to = wins[#wins]
    end
    api.nvim_set_current_win(to)
    return
  end
  last = cur
  vim.rpcnotify(chan, 'neorex_win', cur)
end

-- after the command that moved, so :windo and friends report once
local function schedule_report()
  if pending then return end
  pending = true
  vim.schedule(report)
end
api.nvim_create_autocmd('WinEnter', { group = group, callback = schedule_report })

-- :q in the last window quits Neovim: make it the tab's only ordinary window
-- first. If Neovim then refuses (unsaved changes), the daemon adopts it again.
api.nvim_create_autocmd('QuitPre', {
  group = group,
  callback = function()
    local cur = api.nvim_get_current_win()
    local tab = api.nvim_get_current_tabpage()
    local anchor = anchor_of(tab)
    if not anchor or not shown(cur) or others_shown(cur) then return end
    api.nvim_win_set_config(cur, { split = 'left', win = anchor })
    anchors[tab] = nil
    api.nvim_win_close(anchor, true)
  end,
})

-- Neovim never closes its last window, but the anchor lets :close do it. So
-- reopen it, and the daemon gives the new window the same pane.
api.nvim_create_autocmd('WinClosed', {
  group = group,
  callback = function(ev)
    local win = tonumber(ev.match)
    if vim.v.exiting ~= vim.NIL or not shown(win) or others_shown(win) then return end
    local c = api.nvim_win_get_config(win)
    if not c.external then return end
    local buf = api.nvim_win_get_buf(win)
    local view = api.nvim_win_call(win, vim.fn.winsaveview)
    vim.rpcnotify(chan, 'neorex_reopen', win)
    vim.schedule(function()
      if not api.nvim_buf_is_valid(buf) then buf = api.nvim_create_buf(true, false) end
      local new = api.nvim_open_win(buf, true, { external = true, width = c.width, height = c.height })
      api.nvim_win_call(new, function() vim.fn.winrestview(view) end)
    end)
  end,
})

local first = api.nvim_get_current_win()
M.adopt(first, cols, rows)
schedule_report()
return { first, anchor_of(api.nvim_get_current_tabpage()) }
