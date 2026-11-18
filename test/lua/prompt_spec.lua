-- Tests for runtime/lua/neorex: run with `nvim --headless --clean -l` from
-- the repository's root (src/lua_spec.zig does, in `zig build test`). A
-- fake `rex` stands in for Rex: it records its arguments and stdin, and
-- prints a reply the test chose.
vim.opt.rtp:prepend('runtime')

local prompt = require('neorex.prompt')
local ui = require('neorex.ui')
local pick = require('neorex.pick')

local failures = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    io.stdout:write('ok   ', name, '\n')
  else
    failures = failures + 1
    io.stdout:write('FAIL ', name, '\n     ', tostring(err), '\n')
  end
end

local function eq(want, got, what)
  if not vim.deep_equal(want, got) then
    error(('%s: want %s, got %s'):format(what or 'value', vim.inspect(want), vim.inspect(got)), 2)
  end
end

-- the fake rex
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local fake = dir .. '/rex'
local f = assert(io.open(fake, 'w'))
f:write([[#!/bin/sh
d=$(dirname "$0")
echo "$*" >> "$d/argv"
case "$*" in *client.action*) cat > "$d/stdin" ;; esac
cat "$d/reply" 2>/dev/null
exit $(cat "$d/code" 2>/dev/null || echo 0)
]])
f:close()
vim.fn.setfperm(fake, 'rwxr-xr-x')
prompt.rex = fake

local function write(name, s)
  local h = assert(io.open(dir .. '/' .. name, 'w'))
  h:write(s)
  h:close()
end

local function read(name)
  local h = io.open(dir .. '/' .. name, 'r')
  if not h then return nil end
  local s = h:read('*a')
  h:close()
  return s
end

-- Rex answers with `result` (a table, encoded as client.action's answer),
-- or exits with `code` and prints nothing.
local function rex_answers(result, code)
  os.remove(dir .. '/stdin')
  os.remove(dir .. '/argv')
  write('reply', result and vim.json.encode({ result = result, client_actions = {} }) or '')
  write('code', tostring(code or 0))
end

local function sent()
  return vim.json.decode(read('stdin'))
end

-- Waits for an async callback to have run.
local function wait(cond)
  assert(vim.wait(3000, cond, 10), 'timed out')
end

test('outcome: what each answer means', function()
  local cases = {
    { name = 'ids', code = 0, out = { result = { ids = { '2' } } }, want = { ids = { '2' } } },
    { name = 'text', code = 0, out = { result = { text = 'x' } }, want = { text = 'x' } },
    { name = 'empty text', code = 0, out = { result = { text = '' } }, want = { text = '' } },
    { name = 'closed', code = 0, out = { result = { failed = 'cancelled' } }, want = { cancelled = true } },
    { name = 'timed out', code = 0, out = { result = { failed = 'timeout' } }, want = { cancelled = true } },
    { name = 'no app', code = 0, out = { result = { failed = 'no_client' } }, want = nil },
    { name = 'apps too old', code = 0, out = { result = { failed = 'unsupported' } }, want = nil },
    { name = 'apps busy', code = 0, out = { result = { failed = 'busy' } }, want = nil },
    { name = 'rex.lua outdated', code = 0, out = { result = { failed = 'outdated' } }, want = nil },
    { name = 'no result', code = 0, out = { client_actions = {} }, want = nil },
    { name = 'rex failed', code = 3, out = { result = { text = 'x' } }, want = nil },
  }
  for _, c in ipairs(cases) do
    eq(c.want, prompt.outcome(c.code, vim.json.encode(c.out)), c.name)
  end
  eq(nil, prompt.outcome(0, 'not json'), 'not json')
  eq(nil, prompt.outcome(0, ''), 'nothing printed')
end)

test('title: Neovim prompts become Rex titles', function()
  eq('Rename to', prompt.title('Rename to: ', 'x'))
  eq('Pick one', prompt.title('Pick one', 'x'))
  eq('x', prompt.title('', 'x'))
  eq('x', prompt.title(nil, 'x'))
  eq('x', prompt.title(' : ', 'x'))
end)

test('run: sends the action, its version and the prompt', function()
  rex_answers({ text = 'hi' })
  local got
  prompt.run('input', { title = 'T', value = 'v' }, function(r) got = r end)
  wait(function() return got end)
  eq({ text = 'hi' }, got)
  eq('api call --timeout 1h client.action -\n', read('argv'))
  eq({ action = 'neorex_prompt', args = { version = prompt.version, kind = 'input', prompt = { title = 'T', value = 'v' } } }, sent())
end)

test('run: an empty list is sent as a list', function()
  rex_answers({ failed = 'cancelled' })
  local got
  prompt.run('pick', { title = 'T', items = {} }, function(r) got = r end)
  wait(function() return got end)
  assert(read('stdin'):find('"items":%[%]'), read('stdin'))
end)

test('run: more items than Rex lists falls back without asking', function()
  rex_answers({ ids = { '1' } })
  local items = {}
  for i = 1, prompt.max_items + 1 do items[i] = { id = tostring(i), title = 'x' } end
  local called, got = false, 'unset'
  prompt.run('pick', { title = 'T', items = items }, function(r) called, got = true, r end)
  wait(function() return called end)
  eq(nil, got)
  eq(nil, read('argv'), 'rex not run')
end)

test('run: no rex to run falls back', function()
  prompt.rex = dir .. '/no-such-rex'
  local called, got = false, 'unset'
  prompt.run('input', { title = 'T' }, function(r) called, got = true, r end)
  wait(function() return called end)
  prompt.rex = fake
  eq(nil, got)
end)

-- vim.ui.select and vim.ui.input, with a stand-in for what ours replaces
local before = {}
local function stub_vim_ui()
  before = {}
  vim.ui.select = function(items, opts, on_choice) before.select = { items, opts }; on_choice(items[1], 1) end
  vim.ui.input = function(opts, on_confirm) before.input = opts; on_confirm('from before') end
end

test('ui.select: Rex picks an item', function()
  stub_vim_ui()
  ui.set('select', true)
  rex_answers({ ids = { '2' } })
  local got
  vim.ui.select({ 'a', 'b' }, { prompt = 'Pick: ', kind = 'codeaction', format_item = string.upper }, function(item, i) got = { item, i } end)
  wait(function() return got end)
  eq({ 'b', 2 }, got)
  eq({ title = 'Pick', items = { { id = '1', title = 'A', icon = 'code' }, { id = '2', title = 'B', icon = 'code' } } }, sent().args.prompt)
  ui.set('select', false)
end)

test('ui.select: closing the palette chooses nothing', function()
  stub_vim_ui()
  ui.set('select', true)
  rex_answers({ failed = 'cancelled' })
  local got
  vim.ui.select({ 'a' }, {}, function(item, i) got = { item or 'nil', i or 'nil' } end)
  wait(function() return got end)
  eq({ 'nil', 'nil' }, got)
  eq(nil, before.select, 'no fallback')
  ui.set('select', false)
end)

test('ui.select: Rex unable to ask falls back to what it replaced', function()
  for _, why in ipairs({ 'no_client', 'unsupported', 'busy', 'outdated' }) do
    stub_vim_ui()
    ui.set('select', true)
    rex_answers({ failed = why })
    local got
    vim.ui.select({ 'a', 'b' }, { prompt = 'P' }, function(item) got = item end)
    wait(function() return got end)
    eq('a', got, why)
    eq({ 'a', 'b' }, before.select[1], why)
    ui.set('select', false)
  end
end)

test('ui.input: Rex answers, closes, or can\'t ask', function()
  stub_vim_ui()
  ui.set('input', true)
  local cases = {
    { name = 'answered', reply = { text = 'new name' }, want = 'new name' },
    { name = 'empty answer', reply = { text = '' }, want = '' },
    { name = 'closed', reply = { failed = 'cancelled' }, want = 'nil' },
    { name = 'no app', reply = { failed = 'no_client' }, want = 'from before' },
  }
  for _, c in ipairs(cases) do
    rex_answers(c.reply)
    local got
    vim.ui.input({ prompt = 'Rename to: ', default = 'old' }, function(s) got = s == nil and 'nil' or s end)
    wait(function() return got end)
    eq(c.want, got, c.name)
  end
  eq({ title = 'Rename to', value = 'old' }, sent().args.prompt)
  ui.set('input', false)
end)

test('ui.set: on twice, then off, gives back what it replaced', function()
  stub_vim_ui()
  local original = vim.ui.select
  ui.set('select', true)
  ui.set('select', true)
  eq(ui.select, vim.ui.select, 'ours')
  ui.set('select', false)
  eq(original, vim.ui.select, 'given back')
  ui.set('select', false)
  eq(original, vim.ui.select, 'off twice leaves it')
end)

test('ui.set: off leaves another plugin\'s replacement alone', function()
  stub_vim_ui()
  ui.set('select', true)
  local theirs = function() end
  vim.ui.select = theirs
  ui.set('select', false)
  eq(theirs, vim.ui.select)
end)

test('pick.buffers: lists listed buffers and goes to the chosen one', function()
  stub_vim_ui()
  vim.cmd('silent! %bwipeout!')
  vim.cmd.edit('src/a.zig')
  local a = vim.api.nvim_get_current_buf()
  vim.cmd.edit('README.md')
  vim.bo.modified = true
  local items = pick.buffer_items()
  eq({
    { id = tostring(a), title = 'a.zig', subtitle = 'src', icon = 'document' },
    { id = tostring(vim.api.nvim_get_current_buf()), title = 'README.md', detail = 'modified, current', icon = 'document' },
  }, items)
  rex_answers({ ids = { tostring(a) } })
  pick.buffers()
  wait(function() return vim.api.nvim_get_current_buf() == a end)
  vim.bo[vim.fn.bufnr('README.md')].modified = false
end)

test('pick.buffers: without Rex, vim.ui.select lists the same', function()
  stub_vim_ui()
  rex_answers({ failed = 'no_client' })
  pick.buffers()
  wait(function() return before.select end)
  eq('Buffers', before.select[2].prompt)
  eq('src/a.zig', before.select[2].format_item(before.select[1][1]))
end)

test('pick.file_items: names, directories, and at most max_items', function()
  eq({
    { id = 'build.zig', title = 'build.zig', icon = 'document' },
    { id = 'src/nvim/Nvim.zig', title = 'Nvim.zig', subtitle = 'src/nvim', icon = 'document' },
  }, pick.file_items({ 'build.zig', 'src/nvim/Nvim.zig' }))
  local many = {}
  for i = 1, prompt.max_items + 5 do many[i] = 'f' .. i end
  eq(prompt.max_items, #pick.file_items(many))
end)

test('pick.files: opens the chosen file', function()
  rex_answers({ ids = { 'build.zig' } })
  pick.files()
  wait(function() return vim.fs.basename(vim.api.nvim_buf_get_name(0)) == 'build.zig' end)
  local p = sent().args.prompt
  eq('Files', p.title)
  assert(#p.items > 10, 'git ls-files listed the repository')
end)

test('install: copies rex/neorex.lua once, and reloads Rex\'s config', function()
  prompt.state_path = dir .. '/state/neorex/rex.lua'
  rex_answers(nil)
  eq(true, prompt.install(), 'first copies')
  wait(function() return read('argv') end)
  eq('config reload\n', read('argv'))
  local want = assert(io.open('runtime/rex/neorex.lua')):read('*a')
  eq(want, assert(io.open(prompt.state_path)):read('*a'))
  eq(false, prompt.install(), 'then leaves it')
end)

test('rex/neorex.lua and prompt.lua agree on the version', function()
  local src = assert(io.open('runtime/rex/neorex.lua')):read('*a')
  eq(prompt.version, tonumber(src:match('local version = (%d+)')))
end)

vim.fn.delete(dir, 'rf')
io.stdout:write(failures == 0 and 'all passed\n' or (failures .. ' failed\n'))
os.exit(failures == 0 and 0 or 1)
