# neorex: `<C-w>` window controls

**Date:** 2026-11-10
**Repo:** `itisbryan/neorex`, branch `feat/window-controls` (upstream `alexrlocke/neorex`)
**Status:** design approved in session; implementation follows this document.

## Context

neorex maps Neovim windows to Rex blocks: each external nvim window is drawn in
its own Rex pane. `<C-w>H/J/K/L`, `<C-w>+/-/</>`, and `<C-w>=` change only
Neovim's internal layout, which neorex does not mirror to Rex, so the README
lists them as doing nothing. The panes keep their positions and sizes.

Rex's server API exposes what is needed (`rex api describe`, rex 0.1.0 build
1853 on this machine):

| Method | Input | Purpose here |
|---|---|---|
| `session.view` | `session_id` | layout tree per window: `rect` (fractional), `direction`, `ratio`, `before`/`after`, `block_id` |
| `session.swap_blocks` | `session_id`, `block_id`, `other_block_id` | swap the places of two blocks, sizes preserved |
| `session.resize_pane` | `session_id`, `before_block_id`, `after_block_id`, `direction` (`horizontal`/`vertical`), `ratio` | move the border between two blocks |
| `session.focus_block` | `session_id`, `block_id` | keep the cursor's pane focused |

## Goal

Make the `<C-w>` commands that Rex makes impossible actually move and resize
Rex panes, while Neovim stays authoritative for keymaps, counts, and
`winlayout()`.

## Decision: observe and forward (option B, corrected)

neorex never swallows a key. The input path keeps forwarding every byte to
Neovim exactly as today (`Daemon.zig:268` → `Forwarder.feed`). A parallel
observer recognizes the `<C-w>` prefix and the following key; for the mapped
set it performs the Rex-side operation in addition to Neovim's own handling.

Why this shape:

- **State stays consistent.** Neovim executes the command, so `winlayout()`,
  `:wincmd` bookkeeping, and counts match what the user asked for. Pure
  interception would leave Neovim's layout at the old order while Rex shows the
  new one, and later plugin layouts would be placed against stale geometry.
- **Remaps keep working.** A key that reaches Neovim is still subject to the
  user's mappings; we only add the Rex side effect for the default commands.
- **No config edits.** Nothing is injected into the user's LazyVim/init.

Rejected alternatives:

- **Lua shim + reverse RPC.** Would need a request dispatcher, which today
  refuses everything (`Daemon.zig:378` `respondError(r.id, "neorex serves no
  requests")`), and injects Lua into the user's editor.
- **Layout reconciliation** (diff `winlayout()` after the fact): destructive
  `move_block` churn, flicker, and a feedback loop with the existing
  `session.resize_pane` push-back (`Daemon.zig:408–430`).

## Scope

**In**

- `<C-w>H`, `<C-w>J`, `<C-w>K`, `<C-w>L` — swap the current block with the
  block at that window edge, using `session.swap_blocks`.
- `<C-w>+`, `<C-w>-`, `<C-w>>`, `<C-w><` — move the shared border by `count`
  cells (default 1), using `session.resize_pane`.
- `<C-w>=` — set every split in the current window to ratio 0.5.
- Counts on resize (`3<C-w>+`).
- Multi-split windows; the current (focused) Rex block only.
- `NEOREX_WINDOW_KEYS=off` disables the observer (escape hatch for users whose
  own mappings already handle this).

**Out**

- `<C-w>r` (rotate), `<C-w>x` (exchange) — different semantics, not in the
  reported gap.
- `<C-w>T`, `:tabnew`, tabpages ↔ Rex tabs — separate design.
- `:wincmd` invoked from scripts or plugins — no key is observed; stays a
  no-op, as today.
- Cross-window moves, floating layers, and resizing a pane against a window
  edge that has no neighbour.

## Details

### 1. Observer — `src/term/window_keys.zig`

```zig
pub const Axis = enum { vertical, horizontal };
pub const Direction = enum { left, right, up, down };
pub const Op = union(enum) {
    swap: struct { direction: Direction, count: u16 = 1 },
    resize: struct { axis: Axis, grow: bool, count: u16 = 1 },
    equalize,
};

pub fn observe(self: *WindowKeys, ev: input.KeyEvent) void
```

A state machine over already-decoded keys (`src/term/input.zig`), no
allocation. Paste text and mouse events are separate event kinds, so they
never reach it. `<C-w>` is codepoint `w` with ctrl. The key after it selects
the operation:

  | key | op |
  |---|---|
  | `H` | swap left |
  | `J` | swap down |
  | `K` | swap up |
  | `L` | swap right |
  | `+` | grow the current block's height (`resize_pane` direction `vertical`) |
  | `-` | shrink the current block's height (same border) |
  | `>` | grow the current block's width (`resize_pane` direction `horizontal`) |
  | `<` | shrink the current block's width (same border) |
  | `=` | equalize |

Shifted keys arrive as the unshifted codepoint plus the shift flag under the
kitty keyboard protocol (`h` + shift, not `H`), so both forms are accepted.

- Digits `1`–`9` immediately before `<C-w>` accumulate into `count`; the digits
  are still forwarded to Neovim, so its own count handling is untouched.
  Iterating a key that Neovim ignores a count for (swap) ignores the count.
- Resets on any other byte. While a CSI/SS3/kitty key sequence is open, bytes
  are skipped (the prefix byte inside a sequence must not fire).
- While bracketed paste is on (`?2004h` … `?2004l`, tracked in the same
  observer), no ops are produced.

### 2. Mode gate

`<C-w>` is a delete-word key in insert and terminal modes. neorex already
receives `mode_change` redraw events (`src/screen/Grids.zig:214`); expose the
last mode name and act only when it is `normal`, `visual`, `select`, or
`operator` (the prefix of the reported mode string, which may carry a
sub-mode). Everything else forwards untouched.

### 3. Wiring

`Forwarder` owns the observer pointer (`window_keys`) and calls
`observe` for each decoded key at `Forwarder.zig:70`, on the same event
stream it uses for `nvim_input`; the bytes themselves are forwarded exactly
as before. After `feed` returns, `Daemon.onInput` drains the ops and applies
them. Forwarding is never delayed or modified.

### 4. Apply — `Daemon.applyWindowOp(op)`

Works from the cached layout tree (`self.rex_layout`, refreshed from each
`session.view`). A command typed before the next view arrives sees the old
rects, so it can be a no-op; the daemon never guesses a neighbour it can't
see.

**swap** (same window as the focused block, tiled layer only):

1. Collect blocks with their `rect` from the focused window.
2. Target = the block whose rect is furthest in that direction, requiring
   `rect.x < cur.x` (left) / `> cur.x` (right) / `y < cur.y` (up) /
   `> cur.y` (down); ties go to the nearest edge. No candidate → no-op.
3. `session.swap_blocks { session_id, block_id: cur, other_block_id: target }`.
4. `session.focus_block { session_id, block_id: cur }` — keeps the cursor's pane
   focused regardless of `swap_blocks`' own focus behaviour.

**resize**:

1. Find the split touching the current block's edge in that direction from the
   layout tree (`src/rex/LayoutTree.zig` already models `direction`, `ratio`,
   `before`, `after`, `rect`).
2. `span` = that split's rect size in cells along the axis (fraction × the
   window's terminal size, from `com.superlogical.terminal.size`).
3. `ratio = sizing.movedRatio(split.ratio, deltaCells, span, blockIsBefore)`
   (`src/daemon/sizing.zig:73`), clamped to 0.05–0.95 as that helper does.
4. No change → no request. Otherwise
   `session.resize_pane { session_id, before_block_id, after_block_id,
   direction, ratio }`.

**equalize**: post-order walk of the focused window's layout; for each split
with `ratio != 0.5`, send `session.resize_pane` (deepest splits first, so parent
geometry settles last). A window without splits is a no-op.

**Errors**: any failure is logged as
`neorex daemon: window op <op> failed: <err>`; the daemon keeps running. Keys
were already forwarded, so no input is lost.

### 5. Rex client

`src/rex/Session.zig`: add `.swap_blocks` to the `Request` union and to the
ignored-response group (`Session.zig:205`); `Daemon` sends the request
directly, as it already does for `resize_pane`, and errors go through the
existing logging.

## Acceptance

- Two-pane window, `<C-w>H`: the two Rex blocks swap places, the cursor stays in
  the same buffer, and `rex api call session.view` shows swapped rects.
- `<C-w>L` with the rightmost block focused: no Rex request is sent.
- `<C-w>+` grows the current pane by one cell; `3<C-w>+` by three;
  `<C-w>=` sets every split ratio in the window to 0.5.
- Insert and terminal modes: `<C-w>` still deletes the previous word; the
  observer produces no ops.
- `NEOREX_WINDOW_KEYS=off`: zero Rex calls, byte-identical behaviour to today.
- `zig build test` passes; golden tests unchanged.

## Test plan

1. **`WindowKeys` unit tests** (raw bytes): `\x17H`, `\x17+`, `3\x17>`,
   `\x17` followed by an unmapped key, a sequence split across two feeds,
   a paste body containing `\x17H`, a kitty CSI sequence containing `0x17`.
2. **Layout math unit tests**: swap-target choice on a fixture 2×2 layout;
   resize ratio and clamping at the edges; equalize plan order for nested
   splits.
3. **Integration** against a local fake Rex server: assert the exact method
   names and params for swap, resize, and equalize (the client already has a
   test harness style at `src/rex/Client.zig:409`).
4. **Live smoke**: two neorex panes in one Rex window, `<C-w>H`, then
   `rex api call session.view` to confirm swapped rects.

## Risks / open questions

- `session.swap_blocks` focus behaviour: **verified** on rex 0.1.0 build 1853 —
  the swap exchanges the two rects exactly (sizes preserved) and leaves focus
  on the same block. The handler still sends `session.focus_block`, which is a
  no-op when the block already has focus, so it stays correct if that changes.
- `session.resize_pane`'s `ratio` is the `before` block's share: **verified**
  (`0.3` gave rects `[0,0,0.3,1]` and `[0.3,0,0.7,1]`).
- The observer must not see paste payloads. Neovim paste goes through the
  `Forwarder` paste path (`Forwarder.zig:123`), not the raw key feed, so the
  observer never sees it; the paste test in `window_keys.zig` documents that
  boundary.
- Windows attached through `nvim_paste`-style paths in other integrations are
  out of scope.
- Two window commands typed faster than the next `session.view` round-trip act
  on the cached layout, so the second one can be a no-op or use the old
  neighbour. The op is dropped rather than guessed when a request is in
  flight; a later keypress retries.

## Verification environment

`build.zig.zon` requires Zig 0.17.0; Homebrew on this machine ships 0.16.0, so
tests run with a local Zig 0.17.1 (`/tmp/zig-x/zig`, tarball from
`https://ziglang.org/download/0.17.1/zig-aarch64-macos-0.17.1.tar.xz`).
