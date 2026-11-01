//! Rex ids.

const std = @import("std");

/// `block:` and a UUID.
pub const Block = [42]u8;

pub fn block(id: []const u8) error{BadRexBlock}!Block {
    if (id.len != 42) return error.BadRexBlock;
    return id[0..42].*;
}

/// `layer:` and a UUID.
pub const Layer = [42]u8;

pub fn layer(id: []const u8) error{BadRexLayer}!Layer {
    if (id.len != 42) return error.BadRexLayer;
    return id[0..42].*;
}

pub fn sameBlock(a: Block, b: Block) bool {
    return std.mem.eql(u8, &a, &b);
}
