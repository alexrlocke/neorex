-- Tests for runtime/lua/neorex: run with `nvim --headless --clean -l` from
-- the repository's root (src/lua_spec.zig does, in `zig build test`). A
-- fake `rex` stands in for Rex: it records its arguments and stdin, and
-- answers as the test chose.
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

-- The fake rex. Its Nth call answers with reply.N, stderr.N and code.N when
-- they exist, else reply, stderr and code.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local fake = dir .. '/rex'
local f = assert(io.open(fake, 'w'))
f:write([[#!/bin/sh
d=$(dirname "$0")
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
echo $n > "$d/count"
echo "$*" >> "$d/argv"
case "$*" in *client.action*) cat > "$d/stdin.$n" ; cp "$d/stdin.$n" "$d/stdin" ;; esac
pick() { if [ -f "$d/$1.$n" ]; then cat "$d/$1.$n"; else cat "$d/$1" 2>/dev/null; fi; }
pick reply
pick stderr >&2
code=$(pick code); exit ${code:-0}
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

local function reset()
  for _, name in ipairs(vim.fn.readdir(dir)) do
    if name ~= 'rex' then os.remove(dir .. '/' .. name) end
  end
end

-- client.action's answer: `result` encoded as Rex sends it.
local function answer(result)
  return vim.json.encode({ result = result, client_actions = {} })
end

-- Every call answers with `result`.
local function rex_answers(result)
  reset()
  write('reply', answer(result))
end

-- Every call fails the way the rex CLI does.
local function rex_fails(code, stderr)
  reset()
  write('code', tostring(code))
  write('stderr', stderr)
end

local function sent()
  return vim.json.decode(read('stdin'))
end

local function calls()
  return tonumber(read('count') or '0')
end

-- Waits for an async callback to have run.
local function wait(cond)
  assert(vim.wait(3000, cond, 10), 'timed out')
end

-- What vim.notify was told.
local notes = {}
vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end

local not_found = 'Error: stream response "control-1" failed: the configuration file defines no action "neorex_prompt" (status=404 code=not_found)'

test('classify: what each answer means', function()
  local cases = {
    { name = 'ids', out = answer({ ids = { '2' } }), want = { ids = { '2' } } },
    { name = 'text', out = answer({ text = 'x' }), want = { text = 'x' } },
    { name = 'empty text', out = answer({ text = '' }), want = { text = '' } },
    { name = 'closed', out = answer({ failed = 'cancelled' }), want = { cancelled = true } },
    { name = 'timed out', out = answer({ failed = 'timeout' }), want = { cancelled = true } },
    { name = 'no app', out = answer({ failed = 'no_client' }), want = { fallback = true } },
    { name = 'apps too old', out = answer({ failed = 'unsupported' }), want = { fallback = true } },
    { name = 'apps busy', out = answer({ failed = 'busy' }), want = { busy = true } },
    { name = 'rex.lua outdated', out = answer({ failed = 'outdated' }), want = { outdated = true } },
    { name = 'failed', out = answer({ failed = 'failed', detail = 'd' }), want = { error = "Rex couldn't ask: failed (d)" } },
    { name = 'not set up', code = 3, err = not_found, want = { not_set_up = true } },
    { name = 'prompt refused', code = 1, err = 'Error: rex.lua:7: rex.ui.input: title is required (status=500 code=internal)',
      want = { error = 'Error: rex.lua:7: rex.ui.input: title is required (status=500 code=internal)' } },
    { name = 'no output', code = 2, err = '', want = { error = 'rex exited with 2' } },
    { name = 'no result', out = vim.json.encode({ client_actions = {} }), want = { error = 'Rex answered without a result: {"client_actions":[]}' } },
    { name = 'not json', out = 'nope', want = { error = 'Rex answered without a result: nope' } },
  }
  for _, c in ipairs(cases) do
    eq(c.want, prompt.classify(c.code or 0, c.out or '', c.err or ''), c.name)
  end
end)

test('title: Neovim prompts become Rex titles', function()
  eq('Rename to', prompt.title('Rename to: ', 'x'))
  eq('Pick one', prompt.title('Pick one', 'x'))
  eq('x', prompt.title('', 'x'))
  eq('x', prompt.title(nil, 'x'))
  eq('x', prompt.title(' : ', 'x'))
end)

-- Runs a prompt and returns what on_done got ('fallback' for nil).
local function run(kind, spec)
  local got
  prompt.run(kind, spec, function(r) got = r == nil and 'fallback' or r end)
  wait(function() return got end)
  return got
end

test('run: sends the action, its version and the prompt', function()
  rex_answers({ text = 'hi' })
  eq({ text = 'hi' }, run('input', { title = 'T', value = 'v' }))
  eq('api call --timeout 1h client.action -\n', read('argv'))
  eq({ action = 'neorex_prompt', args = { version = prompt.version, kind = 'input', prompt = { title = 'T', value = 'v' } } }, sent())
end)

test('run: an empty list is sent as a list', function()
  rex_answers({ failed = 'cancelled' })
  run('pick', { title = 'T', items = {} })
  assert(read('stdin'):find('"items":%[%]'), read('stdin'))
end)

test('run: only "no app can show it" falls back, silently', function()
  for _, why in ipairs({ 'no_client', 'unsupported' }) do
    rex_answers({ failed = why })
    notes = {}
    eq('fallback', run('input', { title = 'T' }), why)
    eq({}, notes, why)
  end
end)

test('run: closing or a timeout is a cancel, silently', function()
  for _, why in ipairs({ 'cancelled', 'timeout' }) do
    rex_answers({ failed = why })
    notes = {}
    eq({ cancelled = true }, run('input', { title = 'T' }), why)
    eq({}, notes, why)
  end
end)

test('run: busy says so, and asks nothing else', function()
  rex_answers({ failed = 'busy' })
  notes = {}
  eq({ cancelled = true }, run('input', { title = 'T' }))
  eq({ { msg = 'neorex: Rex is already asking something.', level = vim.log.levels.INFO } }, notes)
end)

test('run: not set up says what to add to Rex\'s config', function()
  rex_fails(3, not_found)
  notes = {}
  eq({ cancelled = true }, run('input', { title = 'T' }))
  eq(1, #notes)
  assert(notes[1].msg:find(prompt.setup_line, 1, true), notes[1].msg)
end)

test('run: outdated reloads Rex\'s config and asks again', function()
  reset()
  write('reply.1', answer({ failed = 'outdated' }))
  write('reply.3', answer({ text = 'after reload' }))
  notes = {}
  eq({ text = 'after reload' }, run('input', { title = 'T' }))
  eq('api call --timeout 1h client.action -\nconfig reload\napi call --timeout 1h client.action -\n', read('argv'))
  eq({}, notes)
end)

test('run: outdated after a reload is an error', function()
  rex_answers({ failed = 'outdated' })
  notes = {}
  eq({ cancelled = true }, run('input', { title = 'T' }))
  eq(3, calls())
  eq(vim.log.levels.ERROR, notes[1].level)
end)

test('run: a prompt Rex refuses is an error', function()
  rex_fails(1, 'Error: rex.ui.pick: duplicate id "1" (status=500 code=internal)')
  notes = {}
  eq({ cancelled = true }, run('pick', { title = 'T', items = {} }))
  eq({ { msg = 'neorex: Error: rex.ui.pick: duplicate id "1" (status=500 code=internal)', level = vim.log.levels.ERROR } }, notes)
end)

test('run: no rex to run is an error', function()
  prompt.rex = dir .. '/no-such-rex'
  notes = {}
  local got = run('input', { title = 'T' })
  prompt.rex = fake
  eq({ cancelled = true }, got)
  assert(notes[1] and notes[1].msg:find("couldn't run", 1, true), vim.inspect(notes))
end)

test('run: more items than Rex lists sends the first max_items, and says so', function()
  rex_answers({ ids = { '1' } })
  local items = {}
  for i = 1, prompt.max_items + 3 do items[i] = { id = tostring(i), title = 'x' } end
  eq({ ids = { '1' } }, run('pick', { title = 'Files', items = items }))
  local p = sent().args.prompt
  eq(prompt.max_items, #p.items)
  eq(('Files (first %d of %d)'):format(prompt.max_items, prompt.max_items + 3), p.title)
  eq(prompt.max_items + 3, #items, "the caller's list is left alone")
end)

test('probe: the version Rex runs, without asking', function()
  rex_answers({ version = 7 })
  local got
  prompt.probe(function(v) got = v end)
  wait(function() return got end)
  eq(7, got)
  eq({ action = 'neorex_prompt', args = { probe = true } }, sent())
end)

-- vim.ui.select and vim.ui.input, with a stand-in for what ours replaces
local before = {}
local function stub_vim_ui()
  before = {}
  vim.ui.select = function(items, opts, on_choice) before.select = { items, opts }; on_choice(items[1], 1) end
  vim.ui.input = function(opts, on_confirm) before.input = opts; on_confirm('from before') end
end

-- Calls vim.ui.select (or `select`) and returns what on_choice got.
local function choose(items, opts, select)
  local got
  ;(select or vim.ui.select)(items, opts, function(item, i) got = { item == nil and 'nil' or item, i == nil and 'nil' or i } end)
  wait(function() return got end)
  return got
end

test('ui.select: Rex picks an item', function()
  stub_vim_ui()
  ui.set('select', true)
  rex_answers({ ids = { '2' } })
  eq({ 'b', 2 }, choose({ 'a', 'b' }, { prompt = 'Pick: ', kind = 'codeaction', format_item = string.upper }))
  eq({ title = 'Pick', items = { { id = '1', title = 'A', icon = 'code' }, { id = '2', title = 'B', icon = 'code' } } }, sent().args.prompt)
  ui.set('select', false)
end)

test('ui.select: what only Rex shows, from opts.rex', function()
  rex_answers({ ids = { '1' } })
  local items = { { name = 'a.zig', dir = 'src' } }
  choose(items, {
    prompt = 'Files',
    format_item = function(it) return it.dir .. '/' .. it.name end,
    rex = {
      title = function(it) return it.name end,
      subtitle = function(it) return it.dir end,
      detail = function() return 'M' end,
      icon = function() return 'folder' end,
      placeholder = 'File',
    },
  }, ui.select)
  eq({ title = 'Files', placeholder = 'File', items = { { id = '1', title = 'a.zig', subtitle = 'src', detail = 'M', icon = 'folder' } } }, sent().args.prompt)
end)

test('ui.select: multiple gives a list of items and indexes', function()
  rex_answers({ ids = { '1', '3' } })
  eq({ { 'a', 'c' }, { 1, 3 } }, choose({ 'a', 'b', 'c' }, { rex = { multiple = true } }, ui.select))
  eq(true, sent().args.prompt.multiple)
  rex_answers({ ids = {} })
  eq({ {}, {} }, choose({ 'a' }, { rex = { multiple = true } }, ui.select), 'none chosen')
end)

test('ui.select: allow_other gives typed text and no index', function()
  rex_answers({ text = 'my own' })
  eq({ 'my own', 'nil' }, choose({ 'a' }, { rex = { allow_other = true } }, ui.select))
  eq(true, sent().args.prompt.allow_other)
end)

test('ui.select: closing the palette chooses nothing', function()
  stub_vim_ui()
  ui.set('select', true)
  rex_answers({ failed = 'cancelled' })
  eq({ 'nil', 'nil' }, choose({ 'a' }, {}))
  eq(nil, before.select, 'no fallback')
  ui.set('select', false)
end)

test('ui.select: with no app to ask, the vim.ui.select it replaced asks', function()
  stub_vim_ui()
  ui.set('select', true)
  rex_answers({ failed = 'no_client' })
  eq({ 'a', 1 }, choose({ 'a', 'b' }, { prompt = 'P' }))
  eq({ 'a', 'b' }, before.select[1])
  ui.set('select', false)
end)

test('ui.select: called directly, with no app to ask, vim.ui.select asks', function()
  stub_vim_ui()
  rex_answers({ failed = 'unsupported' })
  eq({ 'a', 1 }, choose({ 'a', 'b' }, { prompt = 'P' }, ui.select))
  eq({ 'a', 'b' }, before.select[1])
end)

test('ui.select: busy chooses nothing, and doesn\'t fall back', function()
  stub_vim_ui()
  rex_answers({ failed = 'busy' })
  eq({ 'nil', 'nil' }, choose({ 'a' }, {}, ui.select))
  eq(nil, before.select)
end)

test('ui.input: Rex answers, closes, or has no app to ask', function()
  stub_vim_ui()
  ui.set('input', true)
  local cases = {
    { name = 'answered', reply = { text = 'new name' }, want = 'new name' },
    { name = 'empty answer', reply = { text = '' }, want = '' },
    { name = 'closed', reply = { failed = 'cancelled' }, want = 'nil' },
    { name = 'busy', reply = { failed = 'busy' }, want = 'nil' },
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
  eq(true, ui.active('select'))
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

test('ui.set: a plugin replacing vim.ui.select as Neovim starts doesn\'t undo the choice', function()
  stub_vim_ui()
  ui.set('select', true)
  -- as snacks.nvim does
  local theirs_asked = false
  local theirs = function(items, _, on_choice) theirs_asked = true; on_choice(items[1], 1) end
  vim.api.nvim_create_autocmd('UIEnter', { once = true, callback = function() vim.ui.select = theirs end })
  vim.api.nvim_exec_autocmds('UIEnter', {})
  wait(function() return ui.active('select') end)
  -- and theirs is what asks when no app can
  rex_answers({ failed = 'no_client' })
  eq({ 'a', 1 }, choose({ 'a' }, {}))
  eq(true, theirs_asked)
  ui.set('select', false)
  eq(theirs, vim.ui.select, 'off gives theirs back')
  -- once Neovim has started, a later replacement is left alone
  ui.set('select', true)
  local later = function() end
  vim.ui.select = later
  vim.api.nvim_exec_autocmds('UIEnter', {})
  vim.wait(50)
  eq(later, vim.ui.select)
  vim.ui.select = theirs
  ui.set('select', false)
end)

test('pick.buffers: lists listed buffers and goes to the chosen one', function()
  stub_vim_ui()
  vim.cmd('silent! %bwipeout!')
  vim.cmd.edit('src/a.zig')
  local a = vim.api.nvim_get_current_buf()
  vim.cmd.edit('README.md')
  vim.bo.modified = true
  rex_answers({ ids = { '1' } })
  pick.buffers()
  wait(function() return vim.api.nvim_get_current_buf() == a end)
  eq({
    title = 'Buffers',
    placeholder = 'Buffer',
    items = {
      { id = '1', title = 'a.zig', subtitle = 'src', icon = 'document' },
      { id = '2', title = 'README.md', detail = 'modified, current', icon = 'document' },
    },
  }, sent().args.prompt)
  vim.bo[vim.fn.bufnr('README.md')].modified = false
end)

test('pick.buffers: with no app to ask, vim.ui.select lists the same', function()
  stub_vim_ui()
  rex_answers({ failed = 'no_client' })
  pick.buffers()
  wait(function() return before.select end)
  eq('Buffers', before.select[2].prompt)
  eq('src/a.zig', before.select[2].format_item(before.select[1][1]))
end)

test('pick.files: opens the chosen file', function()
  rex_answers({ ids = { '1' } })
  pick.files({ cmd = { 'printf', 'build.zig\\nsrc/main.zig\\n' } })
  wait(function() return vim.fs.basename(vim.api.nvim_buf_get_name(0)) == 'build.zig' end)
  eq({
    title = 'Files',
    placeholder = 'File',
    items = {
      { id = '1', title = 'build.zig', icon = 'document' },
      { id = '2', title = 'main.zig', subtitle = 'src', icon = 'document' },
    },
  }, sent().args.prompt)
end)

test('pick.files: lists git\'s files by default', function()
  rex_answers({ failed = 'cancelled' })
  pick.files()
  wait(function() return read('stdin') end)
  assert(#sent().args.prompt.items > 10, 'git ls-files listed the repository')
end)

test('pick.files: a command that fails says so', function()
  notes = {}
  pick.files({ cmd = { 'false' } })
  wait(function() return #notes > 0 end)
  eq("neorex: couldn't list files with false", notes[1].msg)
end)

test('install: copies rex/neorex.lua once, and reloads Rex\'s config', function()
  prompt.state_path = dir .. '/state/neorex/rex.lua'
  reset()
  eq(true, prompt.install(), 'first copies')
  wait(function() return read('argv') end)
  eq('config reload\n', read('argv'))
  local want = assert(io.open('runtime/rex/neorex.lua')):read('*a')
  eq(want, assert(io.open(prompt.state_path)):read('*a'))
  eq(false, prompt.install(), 'then leaves it')
end)

-- :checkhealth neorex, with vim.health recorded
local function health()
  local out = {}
  local h = {}
  for _, kind in ipairs({ 'start', 'ok', 'info', 'warn', 'error' }) do
    h[kind] = function(msg) out[#out + 1] = kind .. ': ' .. msg end
  end
  local real = vim.health
  vim.health = h
  local ok, err = pcall(require('neorex.health').check)
  vim.health = real
  assert(ok, err)
  return out
end

local function has(lines, want)
  for _, l in ipairs(lines) do
    if l:find(want, 1, true) then return end
  end
  error(('no line with %q in %s'):format(want, vim.inspect(lines)), 2)
end

test('health: set up, with an app connected', function()
  prompt.install()
  reset()
  write('reply.1', answer({ version = prompt.version }))
  write('reply.2', vim.json.encode({ clients = { { info = { kind = 'app' }, connection_state = 'connected' } } }))
  local lines = health()
  has(lines, 'ok: ' .. prompt.state_path .. ' is current')
  has(lines, "ok: Rex runs neorex's actions, version " .. prompt.version)
  has(lines, 'ok: 1 Rex app(s) connected')
end)

test('health: not set up, and no app', function()
  reset()
  write('code.1', '3')
  write('stderr.1', not_found)
  write('reply.2', vim.json.encode({ clients = {} }))
  local lines = health()
  has(lines, "error: Rex's config doesn't load neorex's actions")
  has(lines, 'warn: no Rex app is connected')
end)

test('health: Rex runs an older version', function()
  reset()
  write('reply.1', answer({ version = prompt.version - 1 }))
  write('reply.2', vim.json.encode({ clients = {} }))
  has(health(), ('warn: Rex runs version %d'):format(prompt.version - 1))
end)

test('rex/neorex.lua and prompt.lua agree on the version', function()
  local src = assert(io.open('runtime/rex/neorex.lua')):read('*a')
  eq(prompt.version, tonumber(src:match('local version = (%d+)')))
end)

vim.fn.delete(dir, 'rf')
io.stdout:write(failures == 0 and 'all passed\n' or (failures .. ' failed\n'))
os.exit(failures == 0 and 0 or 1)
