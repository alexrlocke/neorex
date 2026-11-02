-- neorex: a colorscheme made only of the terminal's 16 palette colors.
--
-- Every color is a palette index (ctermfg/ctermbg), never RGB, and Normal is
-- left unset, so the terminal draws its own theme's colors. When the theme
-- changes, the colors change with it without a reload.
--
-- neorex draws these indices as palette colors with 'termguicolors' on. In
-- Neovim's own TUI, use it with 'notermguicolors'.
--
-- The 16 colors don't include subtle background tints, so the few background
-- colors depend on 'background'. neorex sets 'background' from the terminal's
-- light/dark reports (mode 2031), and setting it reloads this file.

vim.cmd("highlight clear")
vim.g.colors_name = "neorex"

local dark = vim.o.background == "dark"
-- a faint background (cursor line, menus) and a stronger one (selection)
local faint = dark and 0 or 7
local strong = dark and 8 or 7

local red, green, yellow, blue, magenta, cyan = 1, 2, 3, 4, 5, 6
local grey = 8

---@type table<string, vim.api.keyset.highlight>
local groups = {
  -- editor
  Normal = {},
  NormalFloat = {},
  NormalNC = {},
  FloatBorder = { ctermfg = grey },
  FloatTitle = { ctermfg = blue, bold = true },
  FloatFooter = { ctermfg = grey },
  Cursor = { reverse = true },
  CursorLine = { ctermbg = faint },
  CursorColumn = { ctermbg = faint },
  ColorColumn = { ctermbg = faint },
  CursorLineNr = { bold = true },
  LineNr = { ctermfg = grey },
  SignColumn = {},
  FoldColumn = { ctermfg = grey },
  Folded = { ctermfg = grey, ctermbg = faint },
  Conceal = { ctermfg = grey },
  NonText = { ctermfg = grey },
  Whitespace = { ctermfg = grey },
  SpecialKey = { ctermfg = grey },
  EndOfBuffer = { ctermfg = grey },
  WinSeparator = { ctermfg = grey },
  Visual = { ctermbg = strong },
  VisualNOS = { ctermbg = strong },
  Search = { ctermfg = yellow, reverse = true },
  CurSearch = { ctermfg = cyan, reverse = true, bold = true },
  IncSearch = { ctermfg = cyan, reverse = true, bold = true },
  Substitute = { ctermfg = red, reverse = true },
  MatchParen = { bold = true, underline = true },
  QuickFixLine = { bold = true },
  Directory = { ctermfg = blue },
  Title = { ctermfg = blue, bold = true },

  -- statusline, tabline, winbar
  StatusLine = { ctermbg = faint },
  StatusLineNC = { ctermfg = grey, ctermbg = faint },
  TabLine = { ctermfg = grey, ctermbg = faint },
  TabLineFill = { ctermbg = faint },
  TabLineSel = { bold = true },
  WinBar = { bold = true },
  WinBarNC = { ctermfg = grey },

  -- menus
  Pmenu = { ctermbg = faint },
  PmenuSel = { reverse = true },
  PmenuKind = { ctermfg = grey, ctermbg = faint },
  PmenuExtra = { ctermfg = grey, ctermbg = faint },
  PmenuMatch = { ctermfg = blue, ctermbg = faint, bold = true },
  PmenuSbar = { ctermbg = faint },
  PmenuThumb = { ctermbg = grey },
  WildMenu = { reverse = true },

  -- messages
  ModeMsg = { bold = true },
  MoreMsg = { ctermfg = green },
  Question = { ctermfg = green },
  ErrorMsg = { ctermfg = red },
  WarningMsg = { ctermfg = yellow },

  -- syntax
  Comment = { ctermfg = grey, italic = true },
  Constant = { ctermfg = yellow },
  String = { ctermfg = green },
  Character = { ctermfg = green },
  Identifier = {},
  Function = { ctermfg = blue },
  Statement = { ctermfg = magenta },
  Operator = { ctermfg = cyan },
  PreProc = { ctermfg = magenta },
  Type = { ctermfg = cyan },
  Special = { ctermfg = cyan },
  Delimiter = {},
  Underlined = { underline = true },
  Error = { ctermfg = red },
  Todo = { ctermfg = yellow, reverse = true, bold = true },
  Added = { ctermfg = green },
  Changed = { ctermfg = yellow },
  Removed = { ctermfg = red },
  DiffAdd = { ctermfg = green },
  DiffChange = { ctermfg = yellow },
  DiffDelete = { ctermfg = red },
  DiffText = { ctermfg = yellow, reverse = true },

  -- treesitter: most captures already link to the groups above
  ["@variable"] = {},
  ["@variable.builtin"] = { ctermfg = red },
  ["@variable.parameter"] = {},
  ["@variable.member"] = {},
  ["@property"] = {},
  ["@module"] = { ctermfg = cyan },
  ["@constructor"] = { ctermfg = cyan },
  ["@punctuation"] = {},
  ["@tag"] = { ctermfg = blue },
  ["@tag.attribute"] = { ctermfg = cyan },
  ["@markup.heading"] = { ctermfg = blue, bold = true },
  ["@markup.link"] = { ctermfg = blue, underline = true },
  ["@markup.raw"] = { ctermfg = green },
  ["@markup.strong"] = { bold = true },
  ["@markup.italic"] = { italic = true },

  -- diagnostics and LSP
  DiagnosticError = { ctermfg = red },
  DiagnosticWarn = { ctermfg = yellow },
  DiagnosticInfo = { ctermfg = blue },
  DiagnosticHint = { ctermfg = cyan },
  DiagnosticOk = { ctermfg = green },
  DiagnosticUnderlineError = { undercurl = true },
  DiagnosticUnderlineWarn = { undercurl = true },
  DiagnosticUnderlineInfo = { underline = true },
  DiagnosticUnderlineHint = { underline = true },
  DiagnosticUnnecessary = { ctermfg = grey },
  DiagnosticDeprecated = { strikethrough = true },
  LspReferenceText = { ctermbg = faint },
  LspReferenceRead = { ctermbg = faint },
  LspReferenceWrite = { ctermbg = faint, bold = true },
  LspInlayHint = { ctermfg = grey, italic = true },
  LspSignatureActiveParameter = { bold = true, underline = true },
  SpellBad = { undercurl = true },
  SpellCap = { underline = true },
  SpellLocal = { underline = true },
  SpellRare = { underline = true },

  -- plugins that would otherwise keep a previous colorscheme's RGB colors
  FlashLabel = { ctermfg = magenta, reverse = true, bold = true },
  SnacksIndent = { ctermfg = faint },
  SnacksIndentScope = { ctermfg = grey },
  WhichKeyNormal = {},
  WhichKeyBorder = { ctermfg = grey },

  -- the `neorex` lualine theme links to these
  NeorexLineNormal = { ctermfg = blue, reverse = true, bold = true },
  NeorexLineInsert = { ctermfg = green, reverse = true, bold = true },
  NeorexLineVisual = { ctermfg = magenta, reverse = true, bold = true },
  NeorexLineReplace = { ctermfg = red, reverse = true, bold = true },
  NeorexLineCommand = { ctermfg = yellow, reverse = true, bold = true },
  NeorexLineTerminal = { ctermfg = cyan, reverse = true, bold = true },
  NeorexLineB = { ctermbg = faint },
  NeorexLineC = {},
  NeorexLineInactive = { ctermfg = grey },
}

for name, hl in pairs(groups) do
  vim.api.nvim_set_hl(0, name, hl)
end
