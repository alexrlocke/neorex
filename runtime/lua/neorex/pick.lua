-- Pickers in Rex's command palette, for keymaps:
--
--   vim.keymap.set('n', '<leader>fb', require('neorex.pick').buffers)
--   vim.keymap.set('n', '<leader>ff', require('neorex.pick').files)
--
-- When Rex can't ask, each shows the same list with vim.ui.select.
local prompt = require('neorex.prompt')
local ui = require('neorex.ui')

local M = {}

-- Asks with `items` ({ id, title, subtitle?, detail?, icon? }), then calls
-- `on_pick(id)`. Without Rex, vim.ui.select lists the same titles.
local function pick(title, items, on_pick)
  prompt.run('pick', { title = title, items = items }, function(r)
    if r == nil then
      return ui.fallback_select(items, {
        prompt = title,
        format_item = function(it)
          return it.subtitle and (it.subtitle .. '/' .. it.title) or it.title
        end,
      }, function(it)
        if it then on_pick(it.id) end
      end)
    end
    if r.ids and r.ids[1] then on_pick(r.ids[1]) end
  end)
end

-- A path's name, and its directory unless that's '.'.
local function split(path)
  local dir = vim.fs.dirname(path)
  return vim.fs.basename(path), (dir ~= '.' and dir ~= '') and dir or nil
end

function M.buffer_items()
  local items = {}
  local cur = vim.api.nvim_get_current_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      local title, subtitle = '[No Name]', nil
      if name ~= '' then title, subtitle = split(vim.fn.fnamemodify(name, ':~:.')) end
      local detail = vim.bo[b].modified and 'modified' or nil
      if b == cur then detail = detail and (detail .. ', current') or 'current' end
      items[#items + 1] = { id = tostring(b), title = title, subtitle = subtitle, detail = detail, icon = 'document' }
    end
  end
  return items
end

function M.buffers()
  pick('Buffers', M.buffer_items(), function(id)
    local b = tonumber(id)
    if b and vim.api.nvim_buf_is_valid(b) then vim.api.nvim_set_current_buf(b) end
  end)
end

function M.file_items(paths)
  local items = {}
  for i, path in ipairs(paths) do
    if i > prompt.max_items then break end
    local title, subtitle = split(path)
    items[#items + 1] = { id = path, title = title, subtitle = subtitle, icon = 'document' }
  end
  return items
end

-- Files under the working directory: git's, else ripgrep's.
local function list_files(on_paths)
  local function lines(s)
    return vim.split(s or '', '\n', { trimempty = true })
  end
  local function try(cmds)
    local cmd = table.remove(cmds, 1)
    if not cmd then return vim.schedule(function() on_paths(nil) end) end
    local ok = pcall(vim.system, cmd, { text = true }, function(out)
      vim.schedule(function()
        if out.code == 0 then return on_paths(lines(out.stdout)) end
        try(cmds)
      end)
    end)
    if not ok then try(cmds) end
  end
  try({
    { 'git', 'ls-files', '--cached', '--others', '--exclude-standard' },
    { 'rg', '--files' },
  })
end

function M.files()
  list_files(function(paths)
    if not paths then
      return vim.notify('neorex: no git repository, and no rg to list files', vim.log.levels.WARN)
    end
    local title = 'Files'
    if #paths > prompt.max_items then title = ('Files (first %d of %d)'):format(prompt.max_items, #paths) end
    pick(title, M.file_items(paths), function(path) vim.cmd.edit(vim.fn.fnameescape(path)) end)
  end)
end

return M
