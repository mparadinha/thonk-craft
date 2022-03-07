const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WorldState = @import("WorldState.zig");

pub const Manager = struct {
    state: WorldState,
    pending_block_updates: std.ArrayList(BlockUpdate),
    allocator: Allocator,

    const BlockUpdate = struct {};

    pub fn init(region_filepath: []const u8, allocator: Allocator) !Manager {
        _ = region_filepath;
        _ = allocator;
        var manager: Manager = undefined;
        return manager;
    }
};
