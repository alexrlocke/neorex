-- The theme's accent: its cursor color, which neorex asks the terminal for
-- and keeps in `g:neorex_accent` ("#rrggbb", or nil). The `neorex`
-- colorscheme sets these groups as it loads, and neorex sets them again when
-- the accent changes, without reloading the colorscheme: a reload makes
-- plugins such as lualine set themselves up again.

local M = {}

local blue = 4

function M.apply()
  local accent = vim.g.neorex_accent
  -- for other configs to link to
  vim.api.nvim_set_hl(0, "NeorexAccent", { fg = accent, ctermfg = blue })
  -- the Normal-mode statusline: the `neorex` lualine theme and
  -- mini.statusline link to it
  vim.api.nvim_set_hl(0, "NeorexLineNormal", { fg = accent, ctermfg = blue, reverse = true, bold = true })
end

return M
