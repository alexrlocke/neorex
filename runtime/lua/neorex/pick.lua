-- Pickers in Rex's command palette, named as snacks.nvim names its own. Map
-- the ones you choose:
--
--   vim.keymap.set('n', '<leader>ff', require('neorex.pick').files)
--   vim.keymap.set('n', 'grr', require('neorex.pick').lsp_references)
--
-- Each picker only gathers its list and says what choosing does; the shared
-- parts below show the list, open files, go to locations and report errors.
-- For a list of your own, call require('neorex.ui').select. When no
-- connected Rex app can show a prompt, these ask with vim.ui.select.
local ui = require('neorex.ui')

local M = {}

-- Shared parts.

local function notify(msg, level)
  vim.notify('neorex: ' .. msg, level or vim.log.levels.WARN)
end

-- Says `what` when `items` is empty. Returns whether there is something to list.
local function any(items, what)
  if #items > 0 then return true end
  notify(what, vim.log.levels.INFO)
  return false
end

-- Calls `f(...)`, showing the error if it fails.
local function attempt(f, ...)
  local ok, err = pcall(f, ...)
  if not ok then
    err = tostring(err)
    -- Vim's errors come after where Lua called it from: show only Vim's
    notify(err:match('Vim:(.*)$') or err, vim.log.levels.ERROR)
  end
end

-- Asks with `opts` (vim.ui.select's) and calls `act(item)` on the chosen one.
local function choose(items, opts, act)
  ui.select(items, opts, function(item)
    if item ~= nil then attempt(act, item) end
  end)
end

-- Runs `cmd`. On an exit code in `opts.ok` ({ [0] = true } by default) it
-- calls `on_out(stdout)` on the main loop; otherwise `on_fail(why)`, which
-- by default shows why. `opts.cwd` runs it elsewhere.
local function run(cmd, opts, on_out, on_fail)
  opts = opts or {}
  local ok_codes = opts.ok or { [0] = true }
  on_fail = on_fail or function(why) notify(why) end
  local ok, err = pcall(vim.system, cmd, { text = true, cwd = opts.cwd }, function(out)
    vim.schedule(function()
      if ok_codes[out.code] then return on_out(out.stdout or '') end
      local why = vim.trim(out.stderr or '')
      on_fail(cmd[1] .. ' failed' .. (why ~= '' and (': ' .. why) or ''))
    end)
  end)
  if not ok then
    vim.schedule(function() on_fail('couldn\'t run ' .. cmd[1] .. ': ' .. tostring(err)) end)
  end
end

-- A path's name, and its directory unless that's '.'.
local function split(path)
  local dir = vim.fs.dirname(path)
  return vim.fs.basename(path), (dir ~= '.' and dir ~= '') and dir or nil
end

-- A path as it's shown: relative to the working directory, or to ~.
local function short(path)
  return vim.fn.fnamemodify(path, ':~:.')
end

-- Line `lnum` of buffer `b`, trimmed, if it's loaded.
local function line_of(b, lnum)
  if not (b and b ~= 0 and vim.api.nvim_buf_is_loaded(b)) then return nil end
  local l = vim.api.nvim_buf_get_lines(b, lnum - 1, lnum, false)[1]
  return l and vim.trim(l) or nil
end

-- Puts `keys` in the typeahead, as if typed. Tests replace it.
function M.feed(keys)
  vim.api.nvim_feedkeys(keys, 'n', false)
end

-- Files: picks one of `items` and opens it. `opts.path(item)` gives an
-- item's path (the item itself by default) and `opts.detail(item)` its
-- detail, such as git's status.
local function file_list(items, title, opts)
  opts = opts or {}
  local path = opts.path or function(it) return it end
  local detail = opts.detail or function() return nil end
  choose(items, {
    prompt = title,
    kind = 'file',
    format_item = function(it)
      local d = detail(it)
      return (d and (d .. ' ') or '') .. short(path(it))
    end,
    rex = {
      title = function(it) return (split(short(path(it)))) end,
      subtitle = function(it) return select(2, split(short(path(it)))) end,
      detail = detail,
      placeholder = 'File',
    },
  }, function(it) vim.cmd.edit(vim.fn.fnameescape(path(it))) end)
end

-- Locations: quickfix items, as grep, LSP requests and Neovim's lists give
-- them. An item's `detail` field, if any, is shown at the row's end.

-- Goes to a quickfix item, leaving a mark in the jumplist.
function M.jump(item)
  vim.cmd("normal! m'")
  local b = item.bufnr
  if b and b ~= 0 and vim.api.nvim_buf_is_valid(b) then
    vim.bo[b].buflisted = true
    vim.api.nvim_set_current_buf(b)
  else
    vim.cmd.edit(vim.fn.fnameescape(item.filename))
  end
  local lnum = math.max(1, math.min(item.lnum or 1, vim.api.nvim_buf_line_count(0)))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, math.max(0, (item.col or 1) - 1) })
  pcall(vim.cmd, 'normal! zv')
end

local function where(item)
  local name = item.filename
  if (not name or name == '') and item.bufnr then name = vim.api.nvim_buf_get_name(item.bufnr) end
  return short(name or '') .. ':' .. (item.lnum or 1)
end

-- A symbol's text is '[Kind] name in container': the title leaves out the kind.
local function text(item)
  local s = vim.trim(item.text or '')
  if item.kind then s = s:gsub('^%[' .. vim.pesc(item.kind) .. '%]%s*', '') end
  return s
end

-- How `locations` shows quickfix items.
function M.location_opts(title)
  return {
    prompt = title,
    kind = 'location',
    format_item = function(item) return where(item) .. ': ' .. text(item) end,
    rex = {
      title = function(item)
        local t = text(item)
        return t ~= '' and t or where(item)
      end,
      subtitle = where,
      detail = function(item) return item.detail or item.kind end,
      icon = function(item) return item.kind and 'code' or 'document' end,
    },
  }
end

-- Picks one of `items` (quickfix items) and goes to it, or calls `on_pick`.
function M.locations(items, title, on_pick)
  choose(items, M.location_opts(title), on_pick or M.jump)
end

-- Like `locations`, but says `empty` instead when there are no items.
local function location_list(items, title, empty)
  if any(items, empty) then M.locations(items, title) end
end

-- Files and buffers.

local function display(b)
  local name = vim.api.nvim_buf_get_name(b)
  return name == '' and '[No Name]' or short(name)
end

-- The listed buffers, and how each is shown.
function M.buffer_list()
  local bufs = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted then bufs[#bufs + 1] = b end
  end
  local cur = vim.api.nvim_get_current_buf()
  return bufs, {
    prompt = 'Buffers',
    kind = 'buffer',
    format_item = display,
    rex = {
      title = function(b) return (split(display(b))) end,
      subtitle = function(b) return select(2, split(display(b))) end,
      detail = function(b)
        local d = vim.bo[b].modified and 'modified' or nil
        if b == cur then d = d and (d .. ', current') or 'current' end
        return d
      end,
      placeholder = 'Buffer',
    },
  }
end

function M.buffers()
  local bufs, opts = M.buffer_list()
  choose(bufs, opts, function(b)
    if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_set_current_buf(b) end
  end)
end

-- Files under the working directory: git's, else ripgrep's. `opts.cmd`
-- lists with your own command instead, such as { 'fd', '--type', 'f', '--hidden' }.
function M.files(opts)
  opts = opts or {}
  local cmds = opts.cmd and { opts.cmd } or {
    { 'git', 'ls-files', '--cached', '--others', '--exclude-standard' },
    { 'rg', '--files' },
  }
  local function try(i)
    if not cmds[i] then
      local what = opts.cmd and table.concat(opts.cmd, ' ') or 'git or rg'
      return notify('couldn\'t list files with ' .. what)
    end
    run(cmds[i], nil, function(out)
      file_list(vim.split(out, '\n', { trimempty = true }), 'Files')
    end, function() try(i + 1) end)
  end
  try(1)
end

-- Files git tracks, under the working directory. `opts`: see files.
function M.git_files(opts)
  M.files(vim.tbl_extend('keep', opts or {}, { cmd = { 'git', 'ls-files', '--cached', '--exclude-standard' } }))
end

-- Files from v:oldfiles that still exist, most recent first.
function M.recent()
  local cur = vim.api.nvim_buf_get_name(0)
  local paths, seen = {}, {}
  for _, p in ipairs(vim.v.oldfiles) do
    if not seen[p] and p ~= cur and vim.fn.filereadable(p) == 1 then
      seen[p] = true
      paths[#paths + 1] = p
    end
  end
  if any(paths, 'no recent files') then file_list(paths, 'Recent') end
end

-- Files from `git status --porcelain=v1 -z` output under `root`, each with
-- its two-letter status, trimmed.
function M.parse_git_status(out, root)
  local items = {}
  local fields = vim.split(out, '\0', { plain = true })
  local i = 1
  while i <= #fields do
    local f = fields[i]
    if #f > 3 then
      local xy = f:sub(1, 2)
      items[#items + 1] = { path = vim.fs.joinpath(root, f:sub(4)), status = vim.trim(xy) }
      -- a rename or copy is followed by the path it came from
      if xy:find('[RC]') then i = i + 1 end
    end
    i = i + 1
  end
  return items
end

-- Files git status lists as changed or untracked, from the repository's root.
function M.git_status()
  run({ 'git', 'rev-parse', '--show-toplevel' }, nil, function(top)
    local root = vim.trim(top)
    run({ 'git', 'status', '--porcelain=v1', '-z', '-uall' }, { cwd = root }, function(out)
      local items = M.parse_git_status(out, root)
      if not any(items, 'no changes') then return end
      file_list(items, 'Git status', {
        path = function(it) return it.path end,
        detail = function(it) return it.status end,
      })
    end)
  end)
end

-- Grep.

-- Quickfix items from `path:line:column:text` lines, as `rg --vimgrep` and
-- `git grep -n --column` print them. Paths are relative to `cwd`, if given.
function M.parse_grep(lines, cwd)
  local items = {}
  for _, line in ipairs(lines) do
    local path, lnum, col, rest = line:match('^(.-):(%d+):(%d+):(.*)$')
    if path then
      items[#items + 1] = {
        filename = cwd and vim.fs.joinpath(cwd, path) or path,
        lnum = tonumber(lnum),
        col = tonumber(col),
        text = rest,
      }
    end
  end
  return items
end

-- The command that searches for `query`: ripgrep, else git grep, both
-- ignoring case unless the query has a capital.
function M.grep_cmd(query)
  if vim.fn.executable('rg') == 1 then
    return { 'rg', '--vimgrep', '--smart-case', '--', query }
  end
  local cmd = { 'git', 'grep', '-n', '--column', '-I', '-E', '--untracked' }
  if not query:find('%u') then cmd[#cmd + 1] = '-i' end
  vim.list_extend(cmd, { '-e', query })
  return cmd
end

-- Searches the working directory for `query` and picks a match.
-- `opts.cmd(query)` replaces grep_cmd; `opts.cwd` searches elsewhere.
function M.search(query, opts)
  opts = opts or {}
  if not query or query == '' then return end
  -- rg and git grep exit 1 for no matches
  run((opts.cmd or M.grep_cmd)(query), { cwd = opts.cwd, ok = { [0] = true, [1] = true } }, function(out)
    local items = M.parse_grep(vim.split(out, '\n', { trimempty = true }), opts.cwd)
    location_list(items, 'Grep: ' .. query, 'no matches for ' .. query)
  end)
end

-- Asks what to search for, then picks a match. `opts`: see search.
function M.grep(opts)
  ui.input({ prompt = 'Grep' }, function(query) M.search(query, opts) end)
end

-- Searches for the word under the cursor. `opts`: see search.
function M.grep_word(opts)
  M.search(vim.fn.expand('<cword>'), opts)
end

-- LSP: like vim.lsp.buf's, listing in Rex. As Neovim does, one definition,
-- declaration or type definition is gone to without asking, and going puts
-- the place you came from on the tag stack, for CTRL-T.

local function lsp(request, title, always_ask)
  return function()
    local win = vim.api.nvim_get_current_win()
    local from = vim.fn.getpos('.')
    from[1] = vim.api.nvim_get_current_buf()
    local tagname = vim.fn.expand('<cword>')
    local function go(item)
      vim.fn.settagstack(win, { items = { { tagname = tagname, from = from } } }, 't')
      M.jump(item)
    end
    request({
      on_list = function(what)
        local items = what.items or {}
        if #items == 1 and not always_ask then return go(items[1]) end
        M.locations(items, title, go)
      end,
    })
  end
end

M.lsp_definitions = lsp(function(o) vim.lsp.buf.definition(o) end, 'Definitions')
M.lsp_declarations = lsp(function(o) vim.lsp.buf.declaration(o) end, 'Declarations')
M.lsp_type_definitions = lsp(function(o) vim.lsp.buf.type_definition(o) end, 'Type definitions')
M.lsp_implementations = lsp(function(o) vim.lsp.buf.implementation(o) end, 'Implementations', true)
M.lsp_references = lsp(function(o) vim.lsp.buf.references(nil, o) end, 'References', true)
M.lsp_symbols = lsp(function(o) vim.lsp.buf.document_symbol(o) end, 'Symbols', true)

-- Asks for a query, then lists the workspace's symbols matching it.
function M.lsp_workspace_symbols()
  ui.input({ prompt = 'Workspace symbols' }, function(query)
    if query == nil then return end
    lsp(function(o) vim.lsp.buf.workspace_symbol(query, o) end, 'Symbols: ' .. query, true)()
  end)
end

-- Lists Neovim keeps.

local function valid(items)
  return vim.tbl_filter(function(it) return it.valid ~= 0 end, items)
end

function M.qflist()
  location_list(valid(vim.fn.getqflist()), 'Quickfix', 'the quickfix list is empty')
end

function M.loclist()
  location_list(valid(vim.fn.getloclist(0)), 'Location list', 'the location list is empty')
end

local severities = { 'error', 'warning', 'info', 'hint' }

local function diagnostics(bufnr)
  local list = vim.diagnostic.get(bufnr)
  table.sort(list, function(a, b)
    if a.severity ~= b.severity then return a.severity < b.severity end
    if a.bufnr ~= b.bufnr then return a.bufnr < b.bufnr end
    return a.lnum < b.lnum
  end)
  local items = {}
  for _, d in ipairs(list) do
    items[#items + 1] = {
      bufnr = d.bufnr,
      lnum = d.lnum + 1,
      col = d.col + 1,
      text = d.message:match('[^\n]*'),
      detail = severities[d.severity],
    }
  end
  location_list(items, 'Diagnostics', 'no diagnostics')
end

-- Every buffer's diagnostics, errors first.
function M.diagnostics() diagnostics(nil) end

-- The current buffer's diagnostics, errors first.
function M.diagnostics_buffer() diagnostics(0) end

-- The current buffer's marks a-z, then marks A-Z and 0-9.
function M.marks()
  local b = vim.api.nvim_get_current_buf()
  local items = {}
  local function add(list)
    for _, m in ipairs(list) do
      local name = m.mark:sub(2)
      if name:match('^%w$') then
        local mb = m.pos[1] ~= 0 and m.pos[1] or b
        items[#items + 1] = {
          bufnr = mb,
          filename = m.file and vim.fn.expand(m.file) or nil,
          lnum = m.pos[2],
          col = m.pos[3],
          text = line_of(mb, m.pos[2]) or '',
          detail = name,
        }
      end
    end
  end
  add(vim.fn.getmarklist(b))
  add(vim.fn.getmarklist())
  location_list(items, 'Marks', 'no marks')
end

-- The window's jumplist, most recent first.
function M.jumps()
  local list = vim.fn.getjumplist()[1]
  local items, seen = {}, {}
  for i = #list, 1, -1 do
    local j = list[i]
    local key = j.bufnr .. ':' .. j.lnum
    if not seen[key] and vim.api.nvim_buf_is_valid(j.bufnr) then
      seen[key] = true
      items[#items + 1] = { bufnr = j.bufnr, lnum = j.lnum, col = j.col + 1, text = line_of(j.bufnr, j.lnum) or '' }
    end
  end
  location_list(items, 'Jumps', 'the jumplist is empty')
end

-- The current buffer's lines that aren't blank.
function M.lines()
  local items = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find('%S') then items[#items + 1] = { lnum = i, text = l } end
  end
  if not any(items, 'the buffer is empty') then return end
  choose(items, {
    prompt = 'Lines',
    format_item = function(it) return it.lnum .. ': ' .. it.text end,
    rex = {
      title = function(it) return vim.trim(it.text) end,
      detail = function(it) return tostring(it.lnum) end,
      placeholder = 'Line',
    },
  }, function(it)
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { it.lnum, (it.text:find('%S') or 1) - 1 })
    pcall(vim.cmd, 'normal! zv')
  end)
end

-- Registers that hold something. Choosing one puts it after the cursor.
function M.registers()
  local names = vim.split('"0123456789abcdefghijklmnopqrstuvwxyz-.:%/#', '')
  if vim.fn.has('clipboard') == 1 then vim.list_extend(names, { '+', '*' }, 1) end
  local items = {}
  for _, r in ipairs(names) do
    local ok, s = pcall(vim.fn.getreg, r)
    if ok and type(s) == 'string' and s ~= '' then items[#items + 1] = { name = r, text = s } end
  end
  if not any(items, 'every register is empty') then return end
  local function oneline(it) return vim.trim(it.text:gsub('\n', ' ↵ ')):sub(1, 200) end
  choose(items, {
    prompt = 'Registers',
    format_item = function(it) return '"' .. it.name .. '  ' .. oneline(it) end,
    rex = {
      title = oneline,
      detail = function(it) return '"' .. it.name end,
      placeholder = 'Register',
    },
  }, function(it) vim.cmd('normal! "' .. it.name .. 'p') end)
end

-- `kind`'s history ('cmd' or 'search'), most recent first and without
-- repeats, each shown after `prefix`. Choosing one calls `act` with it.
local function history(kind, title, prefix, act)
  local out, seen = {}, {}
  for i = vim.fn.histnr(kind), 1, -1 do
    local h = vim.fn.histget(kind, i)
    if h ~= '' and not seen[h] then
      seen[h] = true
      out[#out + 1] = h
    end
  end
  if not any(out, 'the ' .. title:lower() .. ' is empty') then return end
  local function show(h) return prefix .. h end
  local placeholder = kind == 'cmd' and 'Command' or 'Search'
  choose(out, { prompt = title, format_item = show, rex = { title = show, placeholder = placeholder } }, function(h)
    vim.fn.histadd(kind, h)
    act(h)
  end)
end

-- Commands run before. Choosing one runs it again.
function M.command_history()
  history('cmd', 'Command history', ':', vim.cmd)
end

-- Searches made before. Choosing one searches for it again.
function M.search_history()
  history('search', 'Search history', '/', function(s)
    vim.fn.setreg('/', s)
    vim.v.searchforward = 1
    local ok, err = pcall(vim.cmd, 'normal! n')
    vim.v.hlsearch = 1
    if not ok then error(err, 0) end
  end)
end

-- Installed colorschemes. Choosing one applies it.
function M.colorschemes()
  local names = vim.fn.getcompletion('', 'color')
  if not any(names, 'no colorschemes') then return end
  local cur = vim.g.colors_name
  choose(names, {
    prompt = 'Colorschemes',
    kind = 'color',
    rex = {
      detail = function(n) return n == cur and 'current' or nil end,
      placeholder = 'Colorscheme',
    },
  }, vim.cmd.colorscheme)
end

-- Ex commands. Choosing a user command that takes no arguments runs it;
-- choosing another starts typing it in the cmdline.
function M.commands()
  local defs = vim.tbl_extend('force', vim.api.nvim_get_commands({}), vim.api.nvim_buf_get_commands(0, {}))
  local names = vim.fn.getcompletion('', 'command')
  if not any(names, 'no commands') then return end
  local function about(n)
    local d = defs[n] and vim.trim((defs[n].desc ~= '' and defs[n].desc) or defs[n].definition or '')
    return d ~= '' and d or nil
  end
  local function show(n) return ':' .. n end
  choose(names, {
    prompt = 'Commands',
    format_item = show,
    rex = { title = show, subtitle = about, placeholder = 'Command' },
  }, function(n)
    if defs[n] and defs[n].nargs == '0' then return vim.cmd(n) end
    M.feed(':' .. n .. ' ')
  end)
end

return M
