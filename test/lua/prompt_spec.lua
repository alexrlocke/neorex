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
pick() { if [ -f "$d/$1.$n" ]; then cat "$d/$1.$n"; else cat "$d/$1" 2>/dev/null; fi; }
# read the whole answer before recording stdin: a test that sees stdin may
# change the answer for the next call at once
reply=$(pick reply); err=$(pick stderr); code=$(pick code)
case "$*" in *client.action*) cat > "$d/stdin.$n" ; cp "$d/stdin.$n" "$d/stdin" ;; esac
[ -n "$reply" ] && printf '%s\n' "$reply"
[ -n "$err" ] && printf '%s\n' "$err" >&2
exit ${code:-0}
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

test('run: a list bigger than Rex takes sends the first items that fit, and says so', function()
  rex_answers({ ids = { '1' } })
  -- 2,000 items of about 690 bytes is about 1.4 MB: well over Rex's 1 MiB
  local deep = string.rep('deep/', 120) .. '<path>'
  local items = {}
  for i = 1, 2000 do
    items[i] = { id = tostring(i), title = ('file_%04d.rb'):format(i), subtitle = deep, icon = 'document' }
  end
  eq({ ids = { '1' } }, run('pick', { title = 'Files', items = items }))
  local stdin = read('stdin')
  -- as Rex's CLI encodes it: <, > and & as < and so on
  local _, specials = stdin:gsub('[<>&]', '')
  local size = #stdin + 5 * specials
  assert(size <= prompt.max_bytes, ('sent %d bytes'):format(size))
  assert(size > prompt.max_bytes - 1000, ('sent only %d bytes'):format(size))
  local p = sent().args.prompt
  assert(#p.items > 100 and #p.items < 2000, #p.items)
  eq(('Files (first %d of 2000)'):format(#p.items), p.title)
  eq(tostring(#p.items), p.items[#p.items].id, 'the first items, in order')
  eq(2000, #items, "the caller's list is left alone")
end)

test('fit: a list that fits is sent as it is', function()
  local spec = { title = 'T', items = { { id = '1', title = 'a' } } }
  eq(spec, prompt.fit('pick', spec))
  eq({ title = 'T', value = string.rep('x', 100000) }, prompt.fit('input', { title = 'T', value = string.rep('x', 100000) }))
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

test('filter: every word, in title, subtitle or detail, ignoring case unless capitalized', function()
  local rows = {
    { id = '1', title = 'user.rb', subtitle = 'packs/billing/app/models' },
    { id = '2', title = 'User.rb', subtitle = 'app/models' },
    { id = '3', title = 'invoice.rb', subtitle = 'packs/billing/app/models', detail = 'M' },
  }
  local ids = function(q) return vim.tbl_map(function(r) return r.id end, ui.filter(rows, q)) end
  eq({ '1', '2' }, ids('user'))
  eq({ '2' }, ids('User'))
  eq({ '1' }, ids('billing user'))
  eq({ '1', '3' }, ids('  billing  '))
  eq({ '3' }, ids('m invoice'))
  eq({}, ids('nothing'))
  eq({ '1', '2', '3' }, ids(''))
end)

-- 2,500 paths, more than Rex lists, and the opts files use.
local function many()
  local paths = {}
  for i = 1, 2500 do
    paths[i] = ('packs/pack_%04d/app/models/%s.rb'):format(i, i == 1500 and 'needle_model' or 'model')
  end
  return paths, {
    prompt = 'Files',
    rex = {
      title = function(p) return vim.fs.basename(p) end,
      subtitle = function(p) return vim.fs.dirname(p) end,
    },
  }
end

test('ui.select: a list too big for Rex asks for a search term, then lists the matches', function()
  reset()
  write('reply.1', answer({ text = 'needle' }))
  write('reply.2', answer({ ids = { '1500' } }))
  local paths, opts = many()
  eq({ paths[1500], 1500 }, choose(paths, opts, ui.select))
  local ask = vim.json.decode(read('stdin.1')).args
  eq('input', ask.kind)
  eq({ title = 'Files', placeholder = 'Too many to list (2500): type part of one' }, ask.prompt)
  local p = vim.json.decode(read('stdin.2')).args.prompt
  eq('Files: needle', p.title)
  eq({ { id = '1500', title = 'needle_model.rb', subtitle = 'packs/pack_1500/app/models' } }, p.items)
end)

test('ui.select: a search term that still matches too many lists the first that fit', function()
  reset()
  write('reply.1', answer({ text = 'model' }))
  write('reply.2', answer({ failed = 'cancelled' }))
  local paths, opts = many()
  eq({ 'nil', 'nil' }, choose(paths, opts, ui.select))
  local p = vim.json.decode(read('stdin.2')).args.prompt
  assert(p.title:match('^Files: model %(first 2000 of 2500%)$'), p.title)
end)

test('ui.select: a list too big for Rex: closing, no match, and no app', function()
  stub_vim_ui()
  local paths, opts = many()
  rex_answers({ failed = 'cancelled' })
  eq({ 'nil', 'nil' }, choose(paths, opts, ui.select), 'closed')
  eq(1, calls(), 'no list after closing')
  rex_answers({ text = 'nothing like this' })
  notes = {}
  eq({ 'nil', 'nil' }, choose(paths, opts, ui.select), 'no match')
  eq(1, calls(), 'no list without matches')
  eq('neorex: nothing matches nothing like this', notes[1].msg)
  rex_answers({ failed = 'no_client' })
  eq({ paths[1], 1 }, choose(paths, opts, ui.select), 'no app')
  eq(2500, #before.select[1], 'Neovim lists them all')
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

test('parse_grep: rg --vimgrep and git grep --column lines', function()
  local cases = {
    { name = 'match', lines = { 'src/a.zig:12:5:  const x = 1;' },
      want = { { filename = 'src/a.zig', lnum = 12, col = 5, text = '  const x = 1;' } } },
    { name = 'colons in the text', lines = { 'a.lua:1:1:x = { a: 1 }' },
      want = { { filename = 'a.lua', lnum = 1, col = 1, text = 'x = { a: 1 }' } } },
    { name = 'empty text', lines = { 'a:3:1:' }, want = { { filename = 'a', lnum = 3, col = 1, text = '' } } },
    { name = 'not a match', lines = { 'warning: something', '' }, want = {} },
    { name = 'under cwd', lines = { 'a.zig:1:2:x' }, cwd = '/r',
      want = { { filename = '/r/a.zig', lnum = 1, col = 2, text = 'x' } } },
  }
  for _, c in ipairs(cases) do
    eq(c.want, pick.parse_grep(c.lines, c.cwd), c.name)
  end
end)

test('grep_cmd: smart case for git grep', function()
  if vim.fn.executable('rg') == 1 then
    eq({ 'rg', '--vimgrep', '--smart-case', '--', 'Foo' }, pick.grep_cmd('Foo'))
    return
  end
  eq({ 'git', 'grep', '-n', '--column', '-I', '-E', '--untracked', '-i', '-e', 'foo' }, pick.grep_cmd('foo'))
  eq({ 'git', 'grep', '-n', '--column', '-I', '-E', '--untracked', '-e', 'Foo' }, pick.grep_cmd('Foo'))
end)

-- A file to grep and jump in.
local grep_dir = dir .. '-grep'
vim.fn.mkdir(grep_dir .. '/sub', 'p')
do
  local h = assert(io.open(grep_dir .. '/sub/b.txt', 'w'))
  h:write('one\n  two needle\nthree\n')
  h:close()
end

test('grep: asks in Rex, lists the matches, and goes to the chosen one', function()
  reset()
  write('reply.1', answer({ text = 'needle' }))
  write('reply.2', answer({ ids = { '1' } }))
  pick.grep({ cwd = grep_dir, cmd = function(q) return { 'printf', 'sub/b.txt:2:7:  two %s\\n', q } end })
  wait(function() return vim.api.nvim_buf_get_name(0):find('b.txt', 1, true) end)
  eq({ 2, 6 }, vim.api.nvim_win_get_cursor(0))
  eq({ action = 'neorex_prompt', args = { version = prompt.version, kind = 'input', prompt = { title = 'Grep' } } },
    vim.json.decode(read('stdin.1')))
  eq({
    title = 'Grep: needle',
    items = { { id = '1', title = 'two needle', subtitle = vim.fn.fnamemodify(grep_dir .. '/sub/b.txt', ':~:.') .. ':2', icon = 'document' } },
  }, sent().args.prompt)
end)

test('search: the default command finds matches in this repository', function()
  rex_answers({ failed = 'cancelled' })
  pick.search('neorex_prompt')
  wait(function() return read('stdin') end)
  local items = sent().args.prompt.items
  assert(#items > 0, 'no matches')
  for _, it in ipairs(items) do assert(it.subtitle:match(':%d+$'), it.subtitle) end
end)

test('search: no matches, and a failing command, say so', function()
  rex_answers({ failed = 'cancelled' })
  notes = {}
  pick.search('x', { cmd = function() return { 'sh', '-c', 'exit 1' } end })
  wait(function() return #notes > 0 end)
  eq('neorex: no matches for x', notes[1].msg)
  notes = {}
  pick.search('x', { cmd = function() return { 'sh', '-c', 'echo bad regex >&2; exit 2' } end })
  wait(function() return #notes > 0 end)
  eq('neorex: sh failed: bad regex', notes[1].msg)
  eq(0, calls(), 'Rex was never asked')
end)

-- vim.lsp.buf, answering with `items`
local function stub_lsp(items)
  local got = {}
  for _, name in ipairs({ 'definition', 'declaration', 'type_definition', 'implementation', 'document_symbol' }) do
    vim.lsp.buf[name] = function(opts) got[#got + 1] = name; opts.on_list({ title = name, items = items }) end
  end
  vim.lsp.buf.references = function(_, opts) got[#got + 1] = 'references'; opts.on_list({ title = 'r', items = items }) end
  vim.lsp.buf.workspace_symbol = function(q, opts) got[#got + 1] = 'workspace_symbol ' .. q; opts.on_list({ title = 'w', items = items }) end
  return got
end

local b_txt = grep_dir .. '/sub/b.txt'

test('lsp: one definition is gone to without asking, with CTRL-T back', function()
  vim.cmd.edit(vim.fn.fnameescape(b_txt))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  rex_answers({ failed = 'cancelled' })
  local got = stub_lsp({ { filename = b_txt, lnum = 3, col = 2, text = 'three' } })
  pick.lsp_definitions()
  eq({ 'definition' }, got)
  eq({ 3, 1 }, vim.api.nvim_win_get_cursor(0))
  eq(0, calls(), 'Rex was never asked')
  vim.cmd('pop')
  eq({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
end)

test('lsp: references always ask, even for one', function()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  rex_answers({ ids = { '1' } })
  stub_lsp({ { filename = b_txt, lnum = 2, col = 3, text = '  two needle' } })
  pick.lsp_references()
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 2 end)
  eq('References', sent().args.prompt.title)
end)

test('lsp: symbols show their kind as detail, not in the title', function()
  rex_answers({ ids = { '2' } })
  stub_lsp({
    { filename = b_txt, lnum = 1, col = 1, kind = 'Function', text = '[Function] one' },
    { filename = b_txt, lnum = 3, col = 1, kind = 'Variable', text = '[Variable] three in M' },
  })
  pick.lsp_symbols()
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  local items = sent().args.prompt.items
  eq({ 'one', 'Function', 'code' }, { items[1].title, items[1].detail, items[1].icon })
  eq({ 'three in M', 'Variable' }, { items[2].title, items[2].detail })
end)

test('lsp: workspace symbols asks for a query first', function()
  reset()
  write('reply.1', answer({ text = 'thr' }))
  write('reply.2', answer({ ids = { '1' } }))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local got = stub_lsp({ { filename = b_txt, lnum = 3, col = 1, kind = 'Variable', text = '[Variable] three' } })
  pick.lsp_workspace_symbols()
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  eq({ 'workspace_symbol thr' }, got)
  eq('Symbols: thr', sent().args.prompt.title)
end)

test('lsp: with no app to ask, vim.ui.select lists locations readably', function()
  stub_vim_ui()
  rex_answers({ failed = 'no_client' })
  stub_lsp({ { filename = b_txt, lnum = 2, col = 3, text = '  two needle' }, { filename = b_txt, lnum = 3, col = 1, text = 'three' } })
  pick.lsp_references()
  wait(function() return before.select end)
  local first = before.select[2].format_item(before.select[1][1])
  assert(first:match('b%.txt:2: two needle$'), first)
end)

-- Opens picker `open` once to see its rows, then again answering with the
-- first row `want` accepts. Returns that row and all the rows.
local function choose_row(open, want)
  rex_answers({ failed = 'cancelled' })
  open()
  wait(function() return read('stdin') end)
  local rows = sent().args.prompt.items
  for _, row in ipairs(rows) do
    if want(row) then
      rex_answers({ ids = { row.id } })
      open()
      return row, rows
    end
  end
  error('no row matched in ' .. vim.inspect(rows), 2)
end

local function titled(t) return function(row) return row.title == t end end

-- A buffer of its own holding `lines`.
local function scratch(lines)
  vim.cmd.enew()
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  return vim.api.nvim_get_current_buf()
end

test('qflist and loclist: go to the chosen entry; empty says so', function()
  vim.fn.setqflist({ { text = 'a line that is not a location' }, { filename = b_txt, lnum = 1, text = 'one' }, { filename = b_txt, lnum = 3, col = 2, text = 'three' } })
  local _, qrows = choose_row(pick.qflist, titled('three'))
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  eq('Quickfix', sent().args.prompt.title)
  eq(2, #qrows, 'only valid entries')
  vim.fn.setloclist(0, { { filename = b_txt, lnum = 2, text = 'two' } })
  choose_row(pick.loclist, titled('two'))
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 2 end)
  vim.fn.setqflist({})
  reset()
  notes = {}
  pick.qflist()
  eq('neorex: the quickfix list is empty', notes[1].msg)
  eq(0, calls())
end)

test('diagnostics: errors first, severity as detail, first line of the message', function()
  vim.cmd.edit(vim.fn.fnameescape(b_txt))
  local ns = vim.api.nvim_create_namespace('neorex_test')
  vim.diagnostic.set(ns, 0, {
    { lnum = 2, col = 0, severity = vim.diagnostic.severity.ERROR, message = 'broken' },
    { lnum = 0, col = 1, severity = vim.diagnostic.severity.WARN, message = 'careful\nmore' },
  })
  local _, rows = choose_row(pick.diagnostics, titled('broken'))
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  eq({ { 'broken', 'error' }, { 'careful', 'warning' } }, vim.tbl_map(function(r) return { r.title, r.detail } end, rows))
  choose_row(pick.diagnostics_buffer, titled('careful'))
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 1 end)
  eq({ 1, 1 }, vim.api.nvim_win_get_cursor(0))
  vim.diagnostic.reset(ns)
end)

test('git_files: lists what git tracks', function()
  rex_answers({ failed = 'cancelled' })
  pick.git_files()
  wait(function() return read('stdin') end)
  assert(#sent().args.prompt.items > 10)
  assert(read('argv') == nil or not read('argv'):find('ls%-files'), 'git ran, not rex')
end)

test('recent: v:oldfiles that exist, without repeats or the current file', function()
  assert(io.open(grep_dir .. '/sub/current.txt', 'w')):close()
  vim.cmd.edit(vim.fn.fnameescape(grep_dir .. '/sub/current.txt'))
  vim.v.oldfiles = { b_txt, dir .. '/gone.txt', vim.api.nvim_buf_get_name(0), b_txt }
  local _, rows = choose_row(pick.recent, titled('b.txt'))
  wait(function() return vim.api.nvim_buf_get_name(0) == b_txt end)
  eq(1, #rows)
end)

test('lines: the buffer\'s lines that aren\'t blank, with their number', function()
  scratch({ 'alpha', '', '   beta' })
  local _, rows = choose_row(pick.lines, titled('beta'))
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  eq({ 3, 3 }, vim.api.nvim_win_get_cursor(0))
  eq({ { 'alpha', '1' }, { 'beta', '3' } }, vim.tbl_map(function(r) return { r.title, r.detail } end, rows))
end)

test('marks: the mark as detail and its line as title', function()
  vim.cmd.edit(vim.fn.fnameescape(b_txt))
  vim.api.nvim_buf_set_mark(0, 'q', 3, 0, {})
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local row = choose_row(pick.marks, function(r) return r.detail == 'q' end)
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  eq('three', row.title)
end)

test('jumps: most recent first', function()
  vim.cmd.edit(vim.fn.fnameescape(b_txt))
  vim.cmd('clearjumps')
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd('normal! G')
  vim.cmd('normal! gg')
  local _, rows = choose_row(pick.jumps, titled('three'))
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  eq({ 'three', 'one' }, vim.tbl_map(function(r) return r.title end, rows))
end)

test('registers: one line each, and choosing puts it', function()
  scratch({ 'ab' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.fn.setreg('k', 'X')
  vim.fn.setreg('j', 'two\nlines')
  local _, rows = choose_row(pick.registers, function(r) return r.detail == '"k' end)
  wait(function() return vim.api.nvim_get_current_line() == 'aXb' end)
  local j
  for _, r in ipairs(rows) do if r.detail == '"j' then j = r end end
  eq('two ↵ lines', j.title)
end)

test('command_history: runs the chosen command again', function()
  vim.fn.histadd('cmd', 'let g:neorex_ran = 1')
  local row = choose_row(pick.command_history, titled(':let g:neorex_ran = 1'))
  wait(function() return vim.g.neorex_ran == 1 end)
  eq('1', row.id, 'most recent first')
end)

test('a chosen action that fails shows its error', function()
  vim.fn.histadd('cmd', 'NoSuchCommand')
  notes = {}
  choose_row(pick.command_history, titled(':NoSuchCommand'))
  wait(function() return #notes > 0 end)
  eq({ { msg = 'neorex: E492: Not an editor command: NoSuchCommand', level = vim.log.levels.ERROR } }, notes)
end)

test('search_history: searches for the chosen pattern', function()
  vim.cmd.edit(vim.fn.fnameescape(b_txt))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.fn.histadd('search', 'thr')
  choose_row(pick.search_history, titled('/thr'))
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  eq('thr', vim.fn.getreg('/'))
end)

test('colorschemes: marks the current one, and applies the chosen one', function()
  vim.cmd.colorscheme('default')
  local _, rows = choose_row(pick.colorschemes, titled('blue'))
  wait(function() return vim.g.colors_name == 'blue' end)
  for _, r in ipairs(rows) do
    eq(r.title == 'default' and 'current' or nil, r.detail, r.title)
  end
  vim.cmd.colorscheme('default')
end)

test('commands: runs one without arguments, starts typing one with', function()
  vim.api.nvim_create_user_command('NeorexTestRun', function() vim.g.neorex_run = 1 end, { desc = 'Run the test' })
  vim.api.nvim_create_user_command('NeorexTestArgs', function() end, { nargs = 1 })
  local row = choose_row(pick.commands, titled(':NeorexTestRun'))
  wait(function() return vim.g.neorex_run == 1 end)
  eq('Run the test', row.subtitle)
  local fed
  local feed = pick.feed
  pick.feed = function(keys) fed = keys end
  choose_row(pick.commands, titled(':NeorexTestArgs'))
  wait(function() return fed end)
  pick.feed = feed
  eq(':NeorexTestArgs ', fed)
end)

test('parse_git_status: status, path, and renames', function()
  eq({
    { path = '/r/a.zig', status = 'M' },
    { path = '/r/new file.txt', status = '??' },
    { path = '/r/src/new.zig', status = 'R' },
    { path = '/r/b.zig', status = 'MM' },
  }, pick.parse_git_status(' M a.zig\0?? new file.txt\0R  src/new.zig\0old.zig\0MM b.zig\0', '/r'))
  eq({}, pick.parse_git_status('', '/r'))
end)

test('git_status: lists changed files from the repository\'s root, and opens one', function()
  local repo = dir .. '-repo'
  vim.fn.mkdir(repo .. '/sub', 'p')
  vim.system({ 'git', 'init', '-q', repo }):wait()
  assert(io.open(repo .. '/sub/c.txt', 'w')):close()
  local cwd = vim.fn.getcwd()
  vim.fn.chdir(repo .. '/sub')
  local ok, row = pcall(function()
    local r = choose_row(pick.git_status, titled('c.txt'))
    wait(function() return vim.fs.basename(vim.api.nvim_buf_get_name(0)) == 'c.txt' end)
    return r
  end)
  vim.fn.chdir(cwd)
  assert(ok, row)
  eq('??', row.detail)
  vim.cmd('silent! %bwipeout!')
  vim.fn.delete(repo, 'rf')
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

vim.fn.delete(dir, "rf")
vim.fn.delete(grep_dir, "rf")
io.stdout:write(failures == 0 and 'all passed\n' or (failures .. ' failed\n'))
os.exit(failures == 0 and 0 or 1)
