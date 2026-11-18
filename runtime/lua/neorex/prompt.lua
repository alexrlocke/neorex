-- Asking a question in Rex's command palette. Each question runs
-- `rex api call client.action` with the `neorex_prompt` action that
-- rex/neorex.lua defines, in its own process: the question may stay open for
-- minutes, and Rex runs one action at a time on a connection.
local M = {}

-- Matches `version` in rex/neorex.lua.
M.version = 1

-- The `rex` to run. Tests point it at a fake.
M.rex = 'rex'

-- Where Rex's init.lua loads neorex's actions from.
M.state_path = (vim.env.HOME or '') .. '/.local/state/neorex/rex.lua'

-- Rex lists at most this many items.
M.max_items = 2000

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
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
  -- harmless when Rex's init.lua doesn't load it, or Rex isn't running
  pcall(vim.system, { M.rex, 'config', 'reload' }, { text = true })
  return true
end

-- What a `client.action` answer means for the question:
--   { ids = {...} } or { text = '...' }  answered
--   { cancelled = true }                  the person closed it, or it timed out
--   nil                                   Rex couldn't ask: show Neovim's own
function M.outcome(code, stdout)
  if code ~= 0 then return nil end
  local ok, res = pcall(vim.json.decode, stdout or '')
  if not ok or type(res) ~= 'table' then return nil end
  local r = res.result
  if type(r) ~= 'table' then return nil end
  if r.failed == 'cancelled' or r.failed == 'timeout' then return { cancelled = true } end
  if r.failed ~= nil then return nil end
  if type(r.ids) == 'table' then return { ids = r.ids } end
  if type(r.text) == 'string' then return { text = r.text } end
  return nil
end

-- Asks `prompt` (rex.ui.input's or rex.ui.pick's table) and calls
-- `on_done(outcome)` on the main loop, as `outcome` describes.
function M.run(kind, prompt, on_done)
  if kind == 'pick' and #(prompt.items or {}) > M.max_items then
    return vim.schedule(function() on_done(nil) end)
  end
  local payload = vim.json.encode({
    action = 'neorex_prompt',
    args = { version = M.version, kind = kind, prompt = prompt },
  })
  local ok = pcall(vim.system, { M.rex, 'api', 'call', '--timeout', '1h', 'client.action', '-' }, {
    stdin = payload,
    text = true,
  }, function(out)
    vim.schedule(function() on_done(M.outcome(out.code, out.stdout)) end)
  end)
  -- no `rex` to run
  if not ok then vim.schedule(function() on_done(nil) end) end
end

-- A title for Rex from a Neovim prompt such as 'Rename to: '.
function M.title(s, default)
  s = vim.trim(((s or ''):gsub('%s*:?%s*$', '')))
  if s == '' then return default end
  return s
end

return M
