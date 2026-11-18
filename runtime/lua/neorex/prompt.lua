-- Asking a question in Rex's command palette. Each question runs
-- `rex api call client.action` with the `neorex_prompt` action that
-- rex/neorex.lua defines, in its own process: the question may stay open for
-- minutes, and Rex runs one action at a time on a connection.
local M = {}

-- Matches `version` in rex/neorex.lua.
M.version = 1

-- The `rex` to run: the one neorex's terminal came from, as the daemon finds
-- it (src/rex/server.zig), else the one on PATH. Tests point it at a fake.
M.rex = vim.env.REX_BIN_DIR and (vim.env.REX_BIN_DIR .. '/rex') or 'rex'

-- Where Rex's init.lua loads neorex's actions from.
M.state_path = (vim.env.HOME or '') .. '/.local/state/neorex/rex.lua'

-- The line that loads them, for Rex's init.lua.
M.setup_line = 'pcall(dofile, os.getenv("HOME") .. "/.local/state/neorex/rex.lua")'

-- Rex lists at most this many items.
M.max_items = 2000

-- Rex refuses a request bigger than 64 KiB, measured as its CLI encodes it:
-- the question plus the request around it. Questions stay under this.
M.max_bytes = 60 * 1024

-- `s`'s size once encoded as Rex's CLI does, which writes <, > and & as
-- < and so on.
local function encoded_size(s)
  local _, n = s:gsub('[<>&]', '')
  return #s + 5 * n
end

local function notify(msg, level)
  vim.notify('neorex: ' .. msg, level or vim.log.levels.WARN)
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

-- Asks Rex to read its configuration again, then calls `on_done(ok)`.
local function reload(on_done)
  local ok = pcall(vim.system, { M.rex, 'config', 'reload' }, { text = true }, function(out)
    vim.schedule(function() on_done(out.code == 0) end)
  end)
  if not ok then vim.schedule(function() on_done(false) end) end
end

-- Copies rex/neorex.lua to `state_path` when it differs, then asks Rex to
-- read its configuration again, so the actions match this neorex. Returns
-- whether it copied.
function M.install()
  local src = vim.api.nvim_get_runtime_file('rex/neorex.lua', false)[1]
  if not src then return false end
  local want = read(src)
  if not want or read(M.state_path) == want then return false end
  vim.fn.mkdir(vim.fs.dirname(M.state_path), 'p')
  local f = io.open(M.state_path, 'wb')
  if not f then return false end
  f:write(want)
  f:close()
  -- harmless when Rex's init.lua doesn't load it
  reload(function() end)
  return true
end

-- What `rex api call client.action` answered, from its exit code and output:
--   { ids = {...} } / { text = '...' }  answered
--   { cancelled = true }  the person closed it, or it timed out
--   { fallback = true }   no connected app can show a prompt
--   { busy = true }       every app is showing a question already
--   { outdated = true }   Rex runs an older rex/neorex.lua
--   { not_set_up = true } Rex's init.lua doesn't load rex/neorex.lua
--   { error = '...' }     anything else, such as a prompt Rex refused
function M.classify(code, stdout, stderr)
  if code ~= 0 then
    stderr = vim.trim(stderr or '')
    if stderr:find('code=not_found', 1, true) and stderr:find('neorex_prompt', 1, true) then
      return { not_set_up = true }
    end
    return { error = stderr ~= '' and stderr or ('rex exited with ' .. code) }
  end
  local ok, res = pcall(vim.json.decode, stdout or '')
  local r = ok and type(res) == 'table' and res.result or nil
  if type(r) ~= 'table' then return { error = 'Rex answered without a result: ' .. vim.trim(stdout or '') } end
  local why = r.failed
  if why == nil then
    if type(r.ids) == 'table' then return { ids = r.ids } end
    if type(r.text) == 'string' then return { text = r.text } end
    return { error = 'Rex answered without ids or text' }
  end
  if why == 'cancelled' or why == 'timeout' then return { cancelled = true } end
  if why == 'no_client' or why == 'unsupported' then return { fallback = true } end
  if why == 'busy' then return { busy = true } end
  if why == 'outdated' then return { outdated = true } end
  return { error = 'Rex couldn\'t ask: ' .. tostring(why) .. (r.detail and (' (' .. r.detail .. ')') or '') }
end

-- Runs one `client.action` and calls `on_class(classify's table)`.
local function call(args, on_class)
  local payload = vim.json.encode({ action = 'neorex_prompt', args = args })
  local ok, err = pcall(vim.system, { M.rex, 'api', 'call', '--timeout', '1h', 'client.action', '-' }, {
    stdin = payload,
    text = true,
  }, function(out)
    vim.schedule(function() on_class(M.classify(out.code, out.stdout, out.stderr)) end)
  end)
  if not ok then
    vim.schedule(function() on_class({ error = 'couldn\'t run ' .. M.rex .. ': ' .. tostring(err) }) end)
  end
end

-- Asks `prompt` (rex.ui.input's or rex.ui.pick's table) and calls
-- `on_done(outcome)` on the main loop:
--   { ids = {...} } or { text = '...' }  answered
--   { cancelled = true }  closed, timed out, or Rex couldn't ask for a reason
--                         neorex has already shown
--   nil                   no connected app can show a prompt: ask in Neovim
-- `prompt` cut to what Rex takes: a pick keeps its first `max_items` items,
-- and only as many of those as fit in `max_bytes`, and then its title says
-- how many it shows. The caller's table is left alone. Also returns whether
-- it cut the list.
function M.fit(kind, prompt)
  local items = prompt.items or {}
  if kind ~= 'pick' or #items == 0 then return prompt, false end
  local all = #items
  local title = ('%s (first %d of %d)'):format(prompt.title, all, all)
  local rest = vim.tbl_extend('force', {}, prompt)
  rest.items, rest.title = nil, title
  local size = encoded_size(vim.json.encode({ action = 'neorex_prompt', args = { version = M.version, kind = kind, prompt = rest } }))
    + #',"items":[]'
  local keep = 0
  for i = 1, math.min(all, M.max_items) do
    -- each item and the comma before it
    size = size + encoded_size(vim.json.encode(items[i])) + 1
    if size > M.max_bytes then break end
    keep = i
  end
  if keep == all then return prompt, false end
  local cut = vim.tbl_extend('force', {}, prompt)
  cut.items = { unpack(items, 1, keep) }
  cut.title = ('%s (first %d of %d)'):format(prompt.title, keep, all)
  return cut, true
end

-- Lists cut by `fit` say so in their title.
function M.run(kind, prompt, on_done)
  prompt = M.fit(kind, prompt)
  local args = { version = M.version, kind = kind, prompt = prompt }
  local retried = false
  local function handle(c)
    if c.ids or c.text then return on_done({ ids = c.ids, text = c.text }) end
    if c.cancelled then return on_done({ cancelled = true }) end
    if c.fallback then return on_done(nil) end
    if c.outdated and not retried then
      -- neorex was upgraded and Rex hasn't read the new file yet
      retried = true
      return reload(function() call(args, handle) end)
    end
    if c.outdated then
      notify('Rex runs an older ' .. M.state_path .. '. Run `rex config reload`.', vim.log.levels.ERROR)
    elseif c.busy then
      notify('Rex is already asking something.', vim.log.levels.INFO)
    elseif c.not_set_up then
      notify('Rex isn\'t set up to ask for neorex. Add this line to ~/.config/rex/init.lua, then run `rex config reload`:\n  ' .. M.setup_line)
    else
      notify(c.error, vim.log.levels.ERROR)
    end
    on_done({ cancelled = true })
  end
  call(args, handle)
end

-- The version of rex/neorex.lua that Rex runs, without asking anything:
-- calls `on_done(version)`, or `on_done(nil, classify's table)`.
function M.probe(on_done)
  local ok = pcall(vim.system, { M.rex, 'api', 'call', 'client.action', '-' }, {
    stdin = vim.json.encode({ action = 'neorex_prompt', args = { probe = true } }),
    text = true,
  }, function(out)
    vim.schedule(function()
      local okj, res = pcall(vim.json.decode, out.stdout or '')
      local v = out.code == 0 and okj and type(res) == 'table' and type(res.result) == 'table' and res.result.version
      if v then return on_done(v) end
      on_done(nil, M.classify(out.code, out.stdout, out.stderr))
    end)
  end)
  if not ok then vim.schedule(function() on_done(nil, { error = 'couldn\'t run ' .. M.rex }) end) end
end

-- A title for Rex from a Neovim prompt such as 'Rename to: '.
function M.title(s, default)
  s = vim.trim(((s or ''):gsub('%s*:?%s*$', '')))
  if s == '' then return default end
  return s
end

return M
