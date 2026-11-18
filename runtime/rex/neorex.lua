-- neorex's actions for the Rex server. neorex copies this file to
-- ~/.local/state/neorex/rex.lua each time it starts, and asks Rex to reload
-- its configuration when the copy changes. Load it from Rex's init.lua
-- (~/.config/rex/init.lua) with:
--
--   pcall(dofile, os.getenv('HOME') .. '/.local/state/neorex/rex.lua')
--
-- Rex only lets an action from its configuration ask a question, so this
-- can't be sent over neorex's connection instead.

-- Matches `version` in neorex's lua/neorex/prompt.lua. A neorex newer than
-- the copy Rex loaded gets `outdated`, and shows Neovim's own prompt.
local version = 1

rex.action {
  name = 'neorex_prompt',
  title = 'neorex: prompt',
  -- args: { version, kind = 'input' | 'pick', prompt = rex.ui's table },
  -- or { probe = true } to learn this file's version without asking
  run = function(_, args)
    args = args or {}
    if args.probe then return { version = version } end
    if args.version ~= version then return { failed = 'outdated' } end
    -- no pcall: prompts fail inside one. A prompt Rex refuses raises an
    -- error, which neorex takes as a reason to fall back.
    local r, why
    if args.kind == 'input' then
      r, why = rex.ui.input(args.prompt)
    else
      r, why = rex.ui.pick(args.prompt)
    end
    if r == nil then return { failed = why } end
    if type(r) == 'string' then
      if args.kind == 'input' then return { text = r } end
      return { ids = { r } }
    end
    -- allow_other: what the person typed instead of an item
    if r.text then return { text = r.text } end
    -- multiple: the chosen ids
    return { ids = r }
  end,
}
