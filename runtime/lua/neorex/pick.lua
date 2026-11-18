-- Pickers in Rex's command palette. Map the ones you choose:
--
--   vim.keymap.set('n', '<leader>fb', function() require('neorex.pick').buffers() end)
--   vim.keymap.set('n', '<leader>ff', function() require('neorex.pick').files() end)
--
-- For a list of your own, call require('neorex.ui').select. When no
-- connected Rex app can show a prompt, these ask with vim.ui.select.
local ui = require('neorex.ui')

local M = {}

-- A path's name, and its directory unless that's '.'.
local function split(path)
  local dir = vim.fs.dirname(path)
  return vim.fs.basename(path), (dir ~= '.' and dir ~= '') and dir or nil
end

local function display(b)
  local name = vim.api.nvim_buf_get_name(b)
  return name == '' and '[No Name]' or vim.fn.fnamemodify(name, ':~:.')
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
      subtitle = function(b)
        local _, dir = split(display(b))
        return dir
      end,
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
  ui.select(bufs, opts, function(b)
    if b and vim.api.nvim_buf_is_valid(b) then vim.api.nvim_set_current_buf(b) end
  end)
end

-- How `files` shows paths.
M.file_opts = {
  prompt = 'Files',
  kind = 'file',
  rex = {
    title = function(p) return (split(p)) end,
    subtitle = function(p)
      local _, dir = split(p)
      return dir
    end,
    placeholder = 'File',
  },
}

-- The command `files` lists with: git's files, else ripgrep's. `opts.cmd`
-- replaces both, such as { 'fd', '--type', 'f', '--hidden' }.
local function list_files(opts, on_paths)
  local cmds = opts.cmd and { opts.cmd } or {
    { 'git', 'ls-files', '--cached', '--others', '--exclude-standard' },
    { 'rg', '--files' },
  }
  local function try(i)
    local cmd = cmds[i]
    if not cmd then return on_paths(nil) end
    local ok = pcall(vim.system, cmd, { text = true }, function(out)
      vim.schedule(function()
        if out.code ~= 0 then return try(i + 1) end
        on_paths(vim.split(out.stdout or '', '\n', { trimempty = true }))
      end)
    end)
    if not ok then vim.schedule(function() try(i + 1) end) end
  end
  try(1)
end

-- Files under the working directory. `opts.cmd`: see list_files.
function M.files(opts)
  opts = opts or {}
  list_files(opts, function(paths)
    if not paths then
      local what = opts.cmd and table.concat(opts.cmd, ' ') or 'git or rg'
      return vim.notify('neorex: couldn\'t list files with ' .. what, vim.log.levels.WARN)
    end
    ui.select(paths, M.file_opts, function(path)
      if path then vim.cmd.edit(vim.fn.fnameescape(path)) end
    end)
  end)
end

return M
