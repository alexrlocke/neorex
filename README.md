# neorex

A Rex-Native Neovim frontend built in Zig.

One Neovim runs in the background behind all your panes, so buffers,
registers, undo and language servers are shared. `:split` and `:vsplit` open
real Rex panes where Neovim would put the window, and closing a pane in Rex
closes its window. A popup is drawn either in the focused pane or in a Rex
floating pane, never anything in between. Floats on the whole editor that
you go into, such as pickers, and ones you can't go into, such as
which-key and notifications, open in Rex floating panes, along with any
floats attached to them. The completion menu, floats at the cursor or on a
window, and statuslines are drawn inside the pane they belong to.

![neorex demo](assets/demo.gif)

## Status

Very early and rough, bugs / missing features are to be expected.

AI has been used heavily in building neorex due to limits on my available time. A lot of the code needs large improvements, cleanup, better design etc. I will be doing this incrementally - any contributions are welcome.

## Requirements

- macOS or Linux
- [Rex](https://www.superlogical.com/rex), with its setting to auto-balance
  splits turned off. Otherwise Rex evens out every new split, so a sidebar
  such as neo-tree opens at half the window instead of its own width.
- A recent Neovim. It's developed against 0.13-dev; older versions may show
  no statuslines.
- Zig 0.17 to build from source

## Install

Download the latest release for your OS and architecture (macOS or Linux,
x86_64 or arm64):

```sh
curl -fsSL https://raw.githubusercontent.com/alexrlocke/neorex/main/install.sh | sh
```

This puts neorex in `~/.local/share/neorex` and links it from
`~/.local/bin/neorex`. Or download a tarball from the
[releases page](https://github.com/alexrlocke/neorex/releases) yourself.

Release tarballs are signed with [minisign](https://jedisct1.github.io/minisign/).
The install script checks the signature when minisign is installed. To check
a tarball you downloaded yourself:

```sh
minisign -Vm neorex-aarch64-macos.tar.gz -P RWSx8dufrslQk2iEQLeMJnfJIR4h1mg8j6JDo9UBbyzcQIF4cjAA6Z4w
```

### Nix

The flake builds neorex from source for Linux and Apple Silicon Macs:

```sh
nix run github:alexrlocke/neorex             # try it
nix profile install github:alexrlocke/neorex # install it
```

Or add it as a flake input:

```nix
inputs.neorex = {
  url = "github:alexrlocke/neorex";
  inputs.nixpkgs.follows = "nixpkgs"; # reuse your nixpkgs instead of a second copy
};
```

then either use
`inputs.neorex.packages.${pkgs.stdenv.hostPlatform.system}.default`, or add
`inputs.neorex.overlays.default` to your nixpkgs overlays and use
`pkgs.neorex`.

neorex uses the `nvim` on your `PATH`.

## Build from source

```sh
zig build
zig build test
zig build test -Dgolden   # also the golden tests; downloads Ghostty once
```

The golden tests check every frame neorex draws against
[Ghostty](https://github.com/ghostty-org/ghostty)'s terminal emulator, pinned
to one commit.

Run it in a Rex pane, with any Neovim arguments:

```sh
zig-out/bin/neorex some/file.txt
```

`neorex help` lists the debug commands, which run each layer on its own:
keys, Neovim's redraw events, the renderer, and pane hand-off.

## Following Rex's theme

neorex keeps Neovim in step with Rex's theme:

- **Light and dark.** neorex asks Rex to report theme changes (mode 2031)
  and sets `'background'` to match, which reloads your colorscheme. Set
  `vim.g.neorex_follow_theme = false` to keep `'background'` as you set it.
- **Palette colors.** A highlight with only `ctermfg`/`ctermbg` (no RGB
  color) is drawn as that palette color, so Rex fills it in from its current
  theme and it changes when the theme does. Highlights with RGB colors are
  drawn as before.

`runtime/` has a colorscheme and a lualine theme, both named `neorex`, made
only of the 16 palette colors, so Neovim takes on Rex's colors exactly.
neorex installs them beside its binary, in `share/neorex/runtime`, and adds
them to Neovim's `'runtimepath'` itself, so inside neorex `:colorscheme neorex`
works with no setup. Before your `init.lua` runs, neorex also sets
`vim.g.neorex = true`, so your config can use them only when Neovim runs in
neorex (lazy.nvim / LazyVim shown):

```lua
-- set by neorex before init.lua runs
local in_neorex = vim.g.neorex == true

return {
  { "LazyVim/LazyVim", opts = { colorscheme = in_neorex and "neorex" or nil } },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      if not in_neorex then return end
      opts.options.theme = "neorex"
      -- the theme's middle section has no background, so drop the separator glyphs
      opts.options.section_separators = { left = "", right = "" }
    end,
  },
}
```

lazy.nvim rebuilds `'runtimepath'` in `setup()`, which drops the folder neorex
added. neorex also sets `vim.g.neorex_runtime` to that folder, so tell
lazy.nvim to keep it:

```lua
require("lazy").setup({
  -- spec = ...,
  performance = { rtp = { paths = { vim.g.neorex_runtime } } },
})
```

Outside neorex `vim.g.neorex_runtime` is unset, and this adds nothing.
Configs that detect neorex from its socket name (`vim.v.servername`) keep
working.

With mini.statusline instead of lualine, the colorscheme alone is enough: it
gives mini.statusline the same colors as the lualine theme.

Plugins that set their own RGB colors keep them.

## Pickers in Rex's command palette

neorex can ask questions in Rex's command palette instead of in Neovim:
`vim.ui.select` (LSP code actions and many plugins), `vim.ui.input` (LSP
rename), pickers for buffers and files, and lists of your own. Each is
something you choose: nothing moves to Rex until you turn it on or map it.

Rex only lets an action from its own config ask a question, so this needs one
line in Rex's config, `~/.config/rex/init.lua`:

```lua
pcall(dofile, os.getenv("HOME") .. "/.local/state/neorex/rex.lua")
```

neorex writes that file each time it starts and has Rex reload it when it
changes, so it always matches the neorex you run. `:checkhealth neorex` says
whether Rex loads it and whether an app is connected to show prompts.

The `vim.ui` replacements are off until you turn them on. Outside neorex this
does nothing, so it needs no `if`:

```lua
vim.g.neorex_config = { ui = { select = "rex", input = "rex" } }
```

This takes precedence over plugins that replace `vim.ui.select` as Neovim
starts, such as snacks.nvim's picker, which then asks when no Rex app can. A
replacement made later, after startup, is left alone. To change the options
while Neovim runs, call `neorex.configure({ ... })`.

Map the pickers you want in Rex:

```lua
if vim.g.neorex then
  vim.keymap.set("n", "<leader>fb", function() require("neorex.pick").buffers() end)
  vim.keymap.set("n", "<leader>ff", function() require("neorex.pick").files() end)
end
```

`files` lists git's files, or ripgrep's outside a repository;
`files({ cmd = { "fd", "--type", "f", "--hidden" } })` lists with your own
command. Rex shows at most 2,000 items: a longer list shows its first 2,000,
and its title says so.

For a list of your own, call `require("neorex.ui").select`. It takes
`vim.ui.select`'s arguments, and `opts.rex` adds what only Rex shows:
`title`, `subtitle` and `detail` (functions of an item), `icon`, `placeholder`,
`multiple` (choose several: the callback gets a list) and `allow_other`
(answer with typed text).

If no connected Rex app can show a prompt, Neovim asks instead. Anything else
that stops Rex asking, such as Rex already asking something or its config not
loading neorex's actions, shows a message and asks nothing.

## Current limitations

- The `<C-w>` resize, swap and move commands do nothing. Use Rex's own pane
  controls instead.
- Plugins that arrange windows (sidebars, layout managers) don't get the
  placement they expect.
- Only one tab page: Neovim tab pages aren't Rex tabs.
- No external command line or messages: long messages still show
  "Press ENTER".
- No global statusline: neorex sets `laststatus=3` to `2`, so each pane shows
  its own window's statusline. Neovim draws none on neorex's windows with `3`.

## Plans

Much of neorex will be split out into standalone Zig modules, and later into
their own packages:

- a Neovim RPC client (msgpack, message framing, requests)
- a Rex API client (WebSocket and the control protocol)
- terminal key input (the kitty keyboard protocol)

neorex should then be easier to extend to other editors that provide similar processes for running external windows.

## License

MIT
