-- vim.ui.select and vim.ui.input in Rex's command palette. Call them
-- directly to ask in Rex, or turn on the vim.ui replacements with
-- vim.g.neorex_config = { ui = { select = 'rex', input = 'rex' } }.
-- When no connected Rex app can show a prompt, they call the vim.ui
-- functions they replaced, or Neovim's own.
local prompt = require('neorex.prompt')

local M = {}

-- What each replaced, by name.
local replaced = {}

-- An icon for vim.ui.select's `kind`, which callers set to say what they list.
local icons = {
  codeaction = 'code',
  file = 'document',
  buffer = 'document',
  color = 'star',
}

local function previous(name)
  if vim.ui[name] == M[name] then return replaced[name] end
  return vim.ui[name]
end

local function call(f, item)
  if type(f) == 'function' then return f(item) end
  return f
end

-- vim.ui.select, plus what only Rex shows, in `opts.rex`:
--   title(item)     the row's title; else format_item's
--   subtitle(item)  text under the title
--   detail(item)    short text at the row's far end
--   icon            a Rex icon name, or icon(item); else one for `opts.kind`
--   placeholder     the filter field's hint
--   multiple        choose any number: on_choice gets a list of items and a
--                   list of their indexes
--   allow_other     answer with typed text: on_choice gets it and no index
-- Neovim's vim.ui.select, asked when Rex can't, ignores `opts.rex`.
function M.select(items, opts, on_choice)
  opts = opts or {}
  local rex = opts.rex or {}
  local format = opts.format_item or tostring
  local list = {}
  for i, item in ipairs(items) do
    list[i] = {
      id = tostring(i),
      title = tostring(rex.title and rex.title(item) or format(item)),
      subtitle = rex.subtitle and rex.subtitle(item) or nil,
      detail = rex.detail and rex.detail(item) or nil,
      icon = call(rex.icon, item) or icons[opts.kind],
    }
  end
  local spec = {
    title = prompt.title(opts.prompt, 'Select one'),
    placeholder = rex.placeholder,
    items = list,
    multiple = rex.multiple or nil,
    allow_other = rex.allow_other or nil,
  }
  prompt.run('pick', spec, function(r)
    if r == nil then
      local f = previous('select')
      if f then return f(items, opts, on_choice) end
      return on_choice(nil, nil)
    end
    if r.text then return on_choice(r.text, nil) end
    if rex.multiple then
      if not r.ids then return on_choice(nil, nil) end
      local chosen, idx = {}, {}
      for _, id in ipairs(r.ids) do
        local i = tonumber(id)
        if i and items[i] ~= nil then
          chosen[#chosen + 1], idx[#idx + 1] = items[i], i
        end
      end
      return on_choice(chosen, idx)
    end
    local i = r.ids and tonumber(r.ids[1])
    if i and items[i] ~= nil then return on_choice(items[i], i) end
    on_choice(nil, nil)
  end)
end

function M.input(opts, on_confirm)
  opts = opts or {}
  prompt.run('input', { title = prompt.title(opts.prompt, 'Input'), value = opts.default }, function(r)
    if r == nil then
      local f = previous('input')
      if f then return f(opts, on_confirm) end
      return on_confirm(nil)
    end
    on_confirm(r.text)
  end)
end

-- What `set` was last asked for, by name.
local wanted = {}

local function install(name)
  if vim.ui[name] == M[name] then return end
  replaced[name] = vim.ui[name]
  vim.ui[name] = M[name]
end

-- Plugins that replace vim.ui while Neovim starts, as snacks.nvim does on
-- UIEnter, would undo a choice made in the config: take it back once they
-- have. A replacement made later is left alone.
local group = vim.api.nvim_create_augroup('neorex_ui', {})
vim.api.nvim_create_autocmd('UIEnter', {
  group = group,
  once = true,
  callback = function()
    vim.schedule(function()
      for name, on in pairs(wanted) do
        if on then install(name) end
      end
    end)
  end,
})

-- Puts our `name` ('select' or 'input') in vim.ui, or gives back what it
-- replaced. Leaves a replacement another plugin made after ours alone.
function M.set(name, on)
  wanted[name] = on
  if on then
    install(name)
  else
    if vim.ui[name] ~= M[name] then return end
    vim.ui[name] = replaced[name]
    replaced[name] = nil
  end
end

-- Whether vim.ui.<name> is ours.
function M.active(name)
  return vim.ui[name] == M[name]
end

return M
