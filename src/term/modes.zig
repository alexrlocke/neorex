//! Terminal modes for running an editor, and how to undo them.

const input = @import("input.zig");

/// Alternate screen, bracketed paste, focus reports, mouse (1002 drags, 1006
/// SGR encoding), the kitty keyboard flags, then theme reports and a query
/// for the theme now, so 'background' starts right.
pub const editor_on = "\x1b[?1049h\x1b[?2004h\x1b[?1004h\x1b[?1002h\x1b[?1006h" ++ input.kitty_push ++
    input.theme_reports_on ++ input.theme_query;

/// Undoes `editor_on` in reverse, and resets colors and the cursor's shape
/// and visibility, which Neovim may have changed.
pub const editor_off = input.theme_reports_off ++ input.kitty_pop ++ "\x1b[?1006l\x1b[?1002l\x1b[?1004l\x1b[?2004l\x1b[0m\x1b[0 q\x1b[?25h\x1b[?1049l";
