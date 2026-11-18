-- vim.ui.select and vim.ui.input in Rex's command palette. When Rex can't
-- ask, they call the vim.ui functions they replaced.
local prompt = require('neorex.prompt')

local M = {}

-- What each replaced, by name. Neovim's own when nothing had replaced it.
local replaced = {}

-- An icon for vim.ui.select's `kind`, which callers set to say what they list.
local icons = {
  codeaction = 'code',
  file = 'document',
  buffer = 'document',
  color = 'star',
}

local function previous(name)
  return replaced[name] or vim.ui[name]
end

function M.select(items, opts, on_choice)
  opts = opts or {}
  local format = opts.format_item or tostring
  local list = {}
  for i, item in ipairs(items) do
    list[i] = { id = tostring(i), title = tostring(format(item)), icon = icons[opts.kind] }
  end
  prompt.run('pick', { title = prompt.title(opts.prompt, 'Select one'), items = list }, function(r)
    if r == nil then return previous('select')(items, opts, on_choice) end
    local i = r.ids and tonumber(r.ids[1])
    if i and items[i] ~= nil then return on_choice(items[i], i) end
    on_choice(nil, nil)
  end)
end

function M.input(opts, on_confirm)
  opts = opts or {}
  prompt.run('input', { title = prompt.title(opts.prompt, 'Input'), value = opts.default }, function(r)
    if r == nil then return previous('input')(opts, on_confirm) end
    on_confirm(r.text)
  end)
end

-- Puts our `name` ('select' or 'input') in vim.ui, or gives back what it
-- replaced.
function M.set(name, on)
  if on then
    if vim.ui[name] == M[name] then return end
    replaced[name] = vim.ui[name]
    vim.ui[name] = M[name]
  else
    if vim.ui[name] ~= M[name] then return end
    vim.ui[name] = replaced[name]
    replaced[name] = nil
  end
end

-- Asks with Neovim's own vim.ui.select, or what ran before ours: for pickers
-- when Rex can't ask.
function M.fallback_select(items, opts, on_choice)
  local f = vim.ui.select == M.select and replaced.select or vim.ui.select
  f(items, opts, on_choice)
end

return M
