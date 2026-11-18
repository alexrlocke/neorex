-- :checkhealth neorex: whether Rex can ask neorex's questions.
local prompt = require('neorex.prompt')

local M = {}

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

-- `rex` with `args`, waiting for it: { code, stdout, stderr }, or nil when
-- it can't run.
local function rex(args, stdin)
  local cmd = { prompt.rex }
  vim.list_extend(cmd, args)
  local ok, job = pcall(vim.system, cmd, { stdin = stdin, text = true })
  if not ok then return nil end
  return job:wait(5000)
end

function M.check()
  local h = vim.health
  h.start('neorex: Rex prompts')

  if vim.g.neorex then
    h.ok('running in neorex')
  else
    h.info('not running in neorex: the prompts and pickers need Rex')
  end

  local src = vim.api.nvim_get_runtime_file('rex/neorex.lua', false)[1]
  if not src then
    return h.error("neorex's runtime isn't on 'runtimepath'", {
      'lazy.nvim users: add vim.g.neorex_runtime to performance.rtp.paths (see the README)',
    })
  end
  local copy = read(prompt.state_path)
  if copy == nil then
    h.error(prompt.state_path .. ' is missing', { 'neorex writes it when it starts: start neorex again' })
  elseif copy ~= read(src) then
    h.warn(prompt.state_path .. ' differs from this neorex', { 'start neorex again to update it' })
  else
    h.ok(prompt.state_path .. ' is current')
  end

  local out = rex({ 'api', 'call', 'client.action', '-' },
    vim.json.encode({ action = 'neorex_prompt', args = { probe = true } }))
  if not out then
    return h.error("couldn't run " .. prompt.rex, { 'put Rex\'s `rex` on PATH' })
  end
  local ok, res = pcall(vim.json.decode, out.stdout or '')
  local v = out.code == 0 and ok and type(res) == 'table' and type(res.result) == 'table' and res.result.version
  if v == prompt.version then
    h.ok('Rex runs neorex\'s actions, version ' .. v)
  elseif v then
    h.warn(('Rex runs version %s of neorex\'s actions; this neorex needs %d'):format(v, prompt.version),
      { 'run `rex config reload`' })
  else
    local c = prompt.classify(out.code, out.stdout, out.stderr)
    if c.not_set_up then
      h.error("Rex's config doesn't load neorex's actions", {
        'add this line to ~/.config/rex/init.lua, then run `rex config reload`:',
        prompt.setup_line,
      })
    elseif c.outdated then
      h.warn('Rex runs an older version of neorex\'s actions', { 'run `rex config reload`' })
    else
      h.error('Rex answered: ' .. (c.error or vim.inspect(c)))
    end
  end

  local apps = 0
  local list = rex({ 'api', 'call', 'client.list' })
  if list and list.code == 0 then
    local okl, clients = pcall(vim.json.decode, list.stdout)
    for _, c in ipairs(okl and clients.clients or {}) do
      if c.info and c.info.kind == 'app' and c.connection_state == 'connected' then apps = apps + 1 end
    end
  end
  if apps > 0 then
    h.ok(('%d Rex app(s) connected to show prompts'):format(apps))
  else
    h.warn('no Rex app is connected: prompts fall back to Neovim\'s')
  end

  for _, name in ipairs({ 'select', 'input' }) do
    if require('neorex.ui').active(name) then
      h.ok('vim.ui.' .. name .. ' asks in Rex')
    else
      h.info('vim.ui.' .. name .. ' is not neorex\'s (set vim.g.neorex_config.ui.' .. name .. " = 'rex' to change that)")
    end
  end
end

return M
