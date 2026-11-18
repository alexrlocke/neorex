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

-- window -> its pane's rows and columns, statusline included
local sizes = {}
-- statusline formats we've set, to tell them from ones the user set
local ours = {}

local function local_stl(win)
  return api.nvim_get_option_value('statusline', { win = win, scope = 'local' })
end

-- external windows only show a local statusline: copy the global one
local function give_statusline(win)
  local cur = local_stl(win)
  if cur ~= '' and not ours[cur] then return end
  local want = vim.o.laststatus == 0 and '' or vim.go.statusline
  if want ~= '' then ours[want] = true end
  if cur ~= want then api.nvim_set_option_value('statusline', want, { win = win, scope = 'local' }) end
end

-- the text's height: what's left of the pane after the statusline
local function text_height(win, h)
  return math.max(h - (local_stl(win) ~= '' and 1 or 0), 1)
end

--- Sizes external `win` to fill `w` x `h`, statusline included.
function M.size(win, w, h)
  if not shown(win) then return end
  sizes[win] = { w, h }
  give_statusline(win)
  local th = text_height(win, h)
  -- every resize redraws the window
  if api.nvim_win_get_width(win) == w and api.nvim_win_get_height(win) == th then return end
  api.nvim_win_set_config(win, { width = w, height = th })
end

local function refit()
  for win, s in pairs(sizes) do
    if api.nvim_win_is_valid(win) then M.size(win, s[1], s[2]) else sizes[win] = nil end
  end
end

-- Neovim resized an external window itself (:resize, <C-w>>, a plugin
-- setting its width). Rex owns the layout, so this is only a request: put the
-- window back to its pane's size, and tell the daemon how many columns and
-- rows Neovim wanted it to grow by, so Rex can move the pane's border. Rex's
-- answer comes back as a new pane size, through M.size. Our own resizes
-- already match `sizes`, so they change nothing here and nothing loops.
api.nvim_create_autocmd('WinResized', {
  group = group,
  callback = function()
    for _, win in ipairs(vim.v.event.windows) do
      local s = sizes[win]
      if s and api.nvim_win_is_valid(win) then
        local dw = api.nvim_win_get_width(win) - s[1]
        local dh = api.nvim_win_get_height(win) - text_height(win, s[2])
        M.size(win, s[1], s[2])
        if dw ~= 0 or dh ~= 0 then vim.rpcnotify(chan, 'neorex_resize', win, dw, dh) end
      end
    end
  end,
})

-- <C-w>_ and <C-w>| fill the editor with one window; in neorex, Rex's own
-- zoom does that, so these do nothing
for _, lhs in ipairs({ '<C-w>_', '<C-w>|' }) do
  vim.keymap.set('n', lhs, '<Nop>', { desc = 'neorex: use Rex to zoom a pane' })
end

-- the layout node directly holding `win`, a 'row' or 'col'
local function parent_of(win)
  local function find(node)
    if node[1] == 'leaf' then return end
    for _, c in ipairs(node[2]) do
      if c[1] == 'leaf' and c[2] == win then return node end
      local p = find(c)
      if p then return p end
    end
  end
  return find(vim.fn.winlayout(api.nvim_tabpage_get_number(api.nvim_win_get_tabpage(win))))
end

-- A fixed-size window's size across its split, in cells: columns beside, or rows
-- (statusline included) above or below. Nil for an ordinary window, whose
-- pane splits its origin's in half.
--
-- A heuristic. In Neovim a sidebar or panel opens at the editor's edge (:topleft,
-- :botright, <C-w>H) and keeps its size, but every other window here is
-- external, so the layout looks the same for :vsplit and :topleft vsplit and
-- Neovim never says which it was. 'winfixwidth' / 'winfixheight' stand in for
-- it, since sidebar plugins (nvim-tree, neo-tree, aerial) and the quickfix
-- list set them. So a fixed window Neovim kept beside its origin still goes
-- to the edge, and a sized split that isn't fixed (:vertical 30split, or
-- :topleft vsplit typed by hand) gets half its origin's pane.
local function fixed_cells(win)
  local p = parent_of(win)
  if not p then return end
  if p[1] == 'row' then
    if vim.wo[win].winfixwidth then return api.nvim_win_get_width(win) end
  elseif vim.wo[win].winfixheight then
    give_statusline(win)
    return api.nvim_win_get_height(win) + (local_stl(win) ~= '' and 1 or 0)
  end
end

--- Makes ordinary `win` external at `w` x `h`, giving its tab page an anchor first.
function M.adopt(win, w, h)
  if not shown(win) or api.nvim_win_get_config(win).external then return end
  -- before the anchor below can change the layout; by now any plugin that
  -- opened the window has sized it. Sent ahead of the redraw that shows it
  -- external, so the daemon has it when it makes the window's pane.
  local cells = fixed_cells(win)
  if cells then vim.rpcnotify(chan, 'neorex_fixed', win, cells) end
  local tab = api.nvim_win_get_tabpage(win)
  if not anchor_of(tab) then
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    making_anchor = true
    anchors[tab] = api.nvim_open_win(buf, false, { split = 'left', win = win })
    making_anchor = false
  end
  give_statusline(win)
  api.nvim_win_set_config(win, { external = true, width = w, height = text_height(win, h) })
  sizes[win] = { w, h }
end

--- Closes `win`, whose pane went away. Unsaved changes stay in its buffer.
function M.close(win)
  if api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
end

--- The cells a float's `border` takes: top, right, bottom, left. Neovim
--- gives it back as "none" or all 8 parts, from the top left clockwise; a
--- part may be a { char, highlight } pair, and an empty char takes no cell.
local function border_edges(b)
  if type(b) ~= 'table' then return 0, 0, 0, 0 end
  local function side(i)
    local p = b[i]
    if type(p) == 'table' then p = p[1] end
    return p ~= '' and 1 or 0
  end
  return side(2), side(4), side(6), side(8)
end

--- Floats placed on float `win`, as which-key's footer line is on its box,
--- kept with it when it's resized from `old_w` x `old_h` to `w` x `h`: one
--- against its bottom or right edge stays against it, one as wide as it
--- stays as wide, and none reaches past it. Otherwise they'd stick out of
--- the floating pane, which then asks to grow.
local function carry_hanging(win, old_w, old_h, w, h)
  for _, m in ipairs(api.nvim_list_wins()) do
    local ok, mc = pcall(api.nvim_win_get_config, m)
    if ok and mc.relative == 'win' and mc.win == win then
      local mrow, mcol, mw, mh = mc.row, mc.col, mc.width, mc.height
      if mrow + mh >= old_h then mrow = mrow + h - old_h end
      if mw >= old_w then
        mw = w
      elseif mcol + mw >= old_w then
        mcol = mcol + w - old_w
      end
      mw = math.max(1, math.min(mw, w))
      mh = math.max(1, math.min(mh, h))
      mrow = math.max(0, math.min(mrow, h - mh))
      mcol = math.max(0, math.min(mcol, w - mw))
      pcall(api.nvim_win_set_config, m, { relative = 'win', win = win, row = mrow, col = mcol, width = mw, height = mh })
    end
  end
end

--- Fits the floats hanging from editor floats `tops` to `w` x `h` at `row`,
--- `col` on the screen, as their Rex floating pane was resized to. Anything
--- it moves is redrawn before it returns, so its answer comes after the
--- redraw. A plugin waiting on a key, as which-key does in getchar(), would
--- otherwise have Neovim send the new size but not what is in it.
function M.place_group(tops, row, col, w, h)
  local set = {}
  for _, t in ipairs(tops) do set[t] = true end
  -- a snacks picker lays itself out again from its root box's size
  local ok, Snacks = pcall(require, 'snacks')
  if ok and type(Snacks) == 'table' and Snacks.picker then
    for _, p in ipairs(Snacks.picker.get() or {}) do
      local l = p.layout
      if l and l.root and set[l.root.win] then
        local o = l.opts.layout
        o.width, o.height, o.row, o.col = w, h, row, col
        l:update()
        pcall(vim.cmd.redraw)
        return
      end
    end
  end
  -- one float on its own: set where it goes outright. Not by how far it is
  -- from there: Neovim keeps a float on the screen, so where it shows can
  -- differ from its config, and moving the config by that much never lands.
  if #tops ~= 1 or not api.nvim_win_is_valid(tops[1]) then return end
  local win = tops[1]
  local c = api.nvim_win_get_config(win)
  if c.relative ~= 'editor' then return end
  local top, right, bottom, left = border_edges(c.border)
  local inner_w = math.max(1, w - left - right)
  local inner_h = math.max(1, h - top - bottom)
  local anchor = c.anchor or 'NW'
  -- the config names the corner at its anchor, its border included
  local r = anchor:sub(1, 1) == 'S' and row + inner_h + top + bottom or row
  local cl = anchor:sub(2, 2) == 'E' and col + inner_w + left + right or col
  if c.row == r and c.col == cl and c.width == inner_w and c.height == inner_h then return end
  api.nvim_win_set_config(win, { relative = 'editor', row = r, col = cl, width = inner_w, height = inner_h })
  carry_hanging(win, c.width, c.height, inner_w, inner_h)
  pcall(vim.cmd.redraw)
end

-- neo-tree counts external windows as floats, so it never opens a file in one
-- or remembers one as the last window; here every window it should use is
-- external. Tell it they're ordinary, now or when neo-tree first loads.
local function teach_neo_tree(utils)
  if type(utils) ~= 'table' or type(utils.is_floating) ~= 'function' then return end
  local is_floating = utils.is_floating
  utils.is_floating = function(win)
    local ok, c = pcall(api.nvim_win_get_config, win or 0)
    if ok and c.external then return false end
    return is_floating(win)
  end
end
if package.loaded['neo-tree.utils'] then
  teach_neo_tree(package.loaded['neo-tree.utils'])
else
  package.preload['neo-tree.utils'] = function(name)
    -- load the real module from the path, as if we weren't here
    package.preload[name] = nil
    package.loaded[name] = nil
    local utils = require(name)
    teach_neo_tree(utils)
    return utils
  end
end

-- win_gettype() says 'popup' for external windows, which here are the
-- ordinary ones, so plugins that skip popups skip every window: lualine
-- never refreshes their statuslines. Say '' for them instead, to Lua
-- callers; Vimscript's win_gettype() is Neovim's own.
local win_gettype = vim.fn.win_gettype
vim.fn.win_gettype = function(nr, ...)
  local t = win_gettype(nr, ...)
  if t ~= 'popup' then return t end
  -- {nr} is a window number or a window ID, the current window when left out
  local win = (nr == nil or nr == 0) and api.nvim_get_current_win() or nr
  if win < 1000 then win = vim.fn.win_getid(win) end
  local ok, c = pcall(api.nvim_win_get_config, win)
  if ok and c.external then return '' end
  return t
end

-- the layout node holding `win`: 'row' or 'col', and whether `win` is first
local function placement(win)
  local p = parent_of(win)
  if not p then return end
  local c = p[2][1]
  return p[1], c[1] == 'leaf' and c[2] == win
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
    -- Neovim doesn't keep the scroll when splitting an external window
    if shown(from) and api.nvim_win_get_buf(from) == api.nvim_win_get_buf(win) then
      local view = api.nvim_win_call(from, vim.fn.winsaveview)
      vim.fn.winrestview(view)
    end
    vim.rpcnotify(chan, 'neorex_split', win, dir == 'row', first, shown(from) and from or 0)
  end,
})

-- window -> the title last sent for it: its file name, for its pane's label
local titles = {}

local function title_of(win)
  local name = api.nvim_buf_get_name(api.nvim_win_get_buf(win)):gsub('/+$', '')
  local t = name == '' and '[No Name]' or vim.fn.fnamemodify(name, ':t')
  -- Rex takes up to 128 characters and no control characters
  t = t:gsub('%c', '')
  if vim.fn.strchars(t) > 128 then t = vim.fn.strcharpart(t, 0, 127) .. '…' end
  return t
end

local function report_titles()
  for _, win in ipairs(api.nvim_list_wins()) do
    if shown(win) then
      local t = title_of(win)
      if titles[win] ~= t then
        titles[win] = t
        vim.rpcnotify(chan, 'neorex_title', win, t)
      end
    end
  end
  for win in pairs(titles) do
    if not api.nvim_win_is_valid(win) then titles[win] = nil end
  end
end

local titles_pending = false
local function schedule_titles()
  if titles_pending then return end
  titles_pending = true
  vim.schedule(function()
    titles_pending = false
    report_titles()
  end)
end
api.nvim_create_autocmd({ 'BufWinEnter', 'BufEnter', 'BufFilePost', 'BufWritePost', 'WinNew' }, {
  group = group,
  callback = schedule_titles,
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
  -- a float shows in the pane it floats over, which stays focused, unless
  -- it's in a Rex floating pane: the daemon decides
  if api.nvim_win_get_config(cur).relative ~= '' then
    vim.rpcnotify(chan, 'neorex_float', cur)
    return
  end
  last = cur
  vim.rpcnotify(chan, 'neorex_win', cur)
  report_titles()
end

-- after the command that moved, so :windo and friends report once
local function schedule_report()
  if pending then return end
  pending = true
  vim.schedule(report)
end
api.nvim_create_autocmd('WinEnter', {
  group = group,
  callback = function()
    -- a float taking focus gets its own Rex pane: say so now, before the
    -- redraw that first shows it
    local win = api.nvim_get_current_win()
    if api.nvim_win_get_config(win).relative ~= '' then vim.rpcnotify(chan, 'neorex_entered', win) end
    schedule_report()
  end,
})

-- a window showing a buffer for the first time starts with an empty local
-- statusline, and no OptionSet says so: give it back before the redraw
api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  callback = refit,
})

-- a statusline came, went or changed: fit the windows to their panes again
api.nvim_create_autocmd('OptionSet', {
  group = group,
  pattern = { 'statusline', 'laststatus' },
  callback = function() vim.schedule(refit) end,
})

-- With laststatus=3 Neovim draws one statusline on its own grid, which no
-- pane shows, and none on external windows. 2 gives each pane its window's
-- statusline. lualine sets 3 again whenever it sets itself up, and an
-- OptionSet callback can't change the option it's for, so this waits a tick.
-- OptionSet doesn't fire during startup: VimEnter catches an init.lua's.
local function no_global_statusline()
  if vim.go.laststatus == 3 then vim.go.laststatus = 2 end
end
api.nvim_create_autocmd('OptionSet', {
  group = group,
  pattern = 'laststatus',
  callback = function() vim.schedule(no_global_statusline) end,
})
if vim.v.vim_did_enter == 0 then
  api.nvim_create_autocmd('VimEnter', { group = group, once = true, callback = no_global_statusline })
end
no_global_statusline()

-- each pane keeps 'cmdheight' rows for the command line: tell the daemon
-- now and when it changes, so 0 lets the window reach the pane's bottom
local function report_cmdheight() vim.rpcnotify(chan, 'neorex_cmdheight', vim.o.cmdheight) end
api.nvim_create_autocmd('OptionSet', {
  group = group,
  pattern = 'cmdheight',
  callback = function() vim.schedule(report_cmdheight) end,
})
report_cmdheight()

-- vim.g.neorex_config, the options (src/nvim/Options.zig): tell the daemon
-- now, at VimEnter for an init.lua's, and on neorex.configure. The daemon
-- reads the table and says what's wrong with it.
local function report_options()
  local config = vim.g.neorex_config
  if config == nil then config = vim.NIL end
  -- a table with functions in it can't be sent
  local ok, err = pcall(vim.rpcnotify, chan, 'neorex_options', config)
  if not ok then
    vim.notify('neorex: vim.g.neorex_config: ' .. tostring(err), vim.log.levels.WARN)
  end
end
if vim.v.vim_did_enter == 0 then
  api.nvim_create_autocmd('VimEnter', { group = group, once = true, callback = report_options })
end
report_options()

-- keep Rex's copy of neorex's actions (runtime/rex/neorex.lua) current
pcall(function() require('neorex.prompt').install() end)

-- Sets the options while Neovim runs: vim.g.neorex_config can't tell anyone
-- it changed.
function M.configure(config)
  vim.g.neorex_config = config
  report_options()
end

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
-- send the window at its new size before the answer: the daemon starts
-- drawing on the answer, and would draw it at the old size until then, as
-- wide as the editor when its pane is a split
pcall(vim.cmd.redraw)
return { first, anchor_of(api.nvim_get_current_tabpage()) }
