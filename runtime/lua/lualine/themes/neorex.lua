-- lualine theme for the `neorex` colorscheme: each section links to a
-- NeorexLine* group, so the statusline uses the terminal's palette too.
-- Section c (and x, which falls back to it) has no background: components
-- there set only their own text color.
local function mode(name)
  return { a = "NeorexLine" .. name, b = "NeorexLineB", c = "NeorexLineC" }
end

return {
  normal = mode("Normal"),
  insert = mode("Insert"),
  visual = mode("Visual"),
  replace = mode("Replace"),
  command = mode("Command"),
  terminal = mode("Terminal"),
  inactive = { a = "NeorexLineInactive", b = "NeorexLineInactive", c = "NeorexLineInactive" },
}
