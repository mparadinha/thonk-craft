const std = @import("std");
const Allocator = std.mem.Allocator;
const StreamServer = std.net.StreamServer;
const Connection = StreamServer.Connection;

const Session = @import("Session.zig");
const WorldState = @import("WorldState.zig");

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var world_state = WorldState.init(gpa);
    defer world_state.deinit();

    var server = StreamServer.init(.{
        // I shouldn't need this here. but sometimes we crash and this way we don't have
        // to wait for timeout after TIME_WAIT to run the program again.
        .reuse_address = true,
    });
    defer server.deinit();

    const local_server_ip = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 25565);
    try server.listen(local_server_ip);
    std.debug.print("listening on 127.0.0.1:25565...\n", .{});
    defer server.close();

    while (true) {
        std.debug.print("waiting for connection...\n", .{});
        const connection = try server.accept();
        std.debug.print("connection: {}\n", .{connection});

        const thread = try std.Thread.spawn(.{}, Session.start, .{ connection, gpa, &world_state });
        thread.detach();
    }
}

/// usefull for testing
fn cmp_slices_test(testing: []const u8, ground_truth: []const u8) bool {
    if (testing.len != ground_truth.len) {
        std.debug.print("different lengths: {} should be {}\n", .{ testing.len, ground_truth.len });
        return false;
    }
    for (testing) |byte, i| {
        if (byte != ground_truth[i]) {
            std.debug.print(
                "byte 0x{x} is different: 0x{x} should be 0x{x}\n",
                .{ i, byte, ground_truth[i] },
            );
            return false;
        }
    }
    return true;
}
