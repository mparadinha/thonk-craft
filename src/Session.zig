//! This struct handles a single connection to a single client.
//! It's job is to take care of player login and checking it's alive,
//! and forwarding received packets to the world manager.
//! This is usually run in its own thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Connection = std.net.StreamServer.Connection;
const WorldState = @import("WorldState.zig");

const types = @import("types.zig");
const nbt = @import("nbt.zig");
const client_packets = @import("client_packets.zig");
const ClientPacket = client_packets.Packet;
const server_packets = @import("server_packets.zig");
const ServerPacket = server_packets.Packet;
const block_constants = @import("block_constants.zig");
//const world = @import("world.zig");
const WorldManager = @import("world.zig").Manager;

const Self = @This();

pub const State = enum(u8) {
    /// All connection start in this state. Not part of the protocol.
    handshaking,

    status = 1,
    login = 2,
    play = 3,

    /// Not part of the protocol, used to signal that we're meant to close the connection.
    close_connection,
};

connection: Connection,
allocator: Allocator,
state: State = .handshaking,
compress_packets: bool = false,
world: *WorldState, // temporary until I replace it with world_manager
//world_manager: *world.Manager,
world_manager: *WorldManager,
player: @import("world.zig").Player,
mutex: std.Thread.Mutex,

keep_alive_thread: ?std.Thread = null,
keep_alive_ids: [2]?i64 = [2]?i64{ null, null },
/// set to `true` by the keep alive loop if the client doesn't respond for 30 seconds
timed_out: bool = false,

/// After this call `connection` is owned by this object and will be cleaned up.
pub fn start(connection: Connection, allocator: Allocator, world: *WorldState, world_manager: *WorldManager) void {
    var self = Self{
        .connection = connection,
        .allocator = allocator,
        .world = world,
        .world_manager = world_manager,
        .player = undefined,
        .mutex = std.Thread.Mutex{},
    };
    defer self.deinit();

    self.handleConnection() catch |err| {
        std.debug.print("err={}\n", .{err});
    };

    // TODO: instead of having a separate thread for the keep alive stuff, just go to sleep
    // with a timer

    self.state = .close_connection;
    self.world_manager.removePlayer(&self.player);
    if (self.keep_alive_thread) |thread| thread.join();
}

pub fn deinit(self: *Self) void {
    self.connection.stream.close();
}

fn handleConnection(self: *Self) !void {
    while (true) {
        var peek_conn_stream = std.io.peekStream(1, self.connection.stream.reader());
        var reader = peek_conn_stream.reader();

        //std.debug.print("waiting for data from connection...\n", .{});

        const first_byte = try peek_conn_stream.reader().readByte();
        try peek_conn_stream.putBackByte(first_byte);

        // handle legacy ping
        if (first_byte == 0xfe and self.state == State.handshaking) {
            std.debug.print("got a legacy ping packet. sending kick packet...\n", .{});
            var kick_packet_data = [_]u8{
                0xff, // kick packet ID
                0x00, 0x0c, // length of string (big endian u16)
                0x00, '§', 0x00, '1', 0x00, 0x00, // string start ("§1")
                0x00, '7', 0x00, '2', 0x00, '1', 0x00, 0x00, // protocol version ("127")
                0x00, 0x00, // message of the day ("")
                0x00, '0', 0x00, 0x00, // current player count ("0")
                0x00, '0', 0x00, 0x00, // max players ("0")
            };
            _ = try self.connection.stream.write(&kick_packet_data);
            self.state = .close_connection;
            break;
        }

        const packet = ClientPacket.decode(reader, self.allocator, self.state, self.compress_packets) catch |err| switch (err) {
            error.UnknownId => continue, // ClientPacket.decode already skips the data
            else => return err,
        };

        const inner_tag_name = switch (packet) {
            .handshaking => |data| @tagName(data),
            .status => |data| @tagName(data),
            .login => |data| @tagName(data),
            .play => |data| @tagName(data),
        };
        std.debug.print("got a {s}::{s} packet\n", .{ @tagName(packet), inner_tag_name });

        switch (packet) {
            .handshaking => |data| self.handleHandshakingPacket(data),
            .status => |data| try self.handleStatusPacket(data),
            .login => |data| try self.handleLoginPacket(data),
            .play => |data| try self.handlePlayPacket(data),
        }

        if (self.state == State.close_connection) break;
    }
}

fn handleHandshakingPacket(
    self: *Self,
    packet_data: std.meta.TagPayload(ClientPacket, .handshaking),
) void {
    switch (packet_data) {
        .handshake => |data| self.state = data.next_state,
    }
}

fn handleStatusPacket(
    self: *Self,
    packet_data: std.meta.TagPayload(ClientPacket, .status),
) !void {
    switch (packet_data) {
        .status_request => {
            const response_str_fmt =
                \\{{
                \\    "version": {{
                \\        "name": "1.19.2",
                \\        "protocol": 760
                \\    }},
                \\    "players": {{
                \\        "max": 420,
                \\        "online": 69
                \\    }},
                \\    "description": {{
                \\        "text": "rly makes u think (powered by Zig!)"
                \\    }},
                \\    "favicon": "data:image/png;base64,{s}"
                \\}}
            ;
            const thonk_png_data = @embedFile("thonk_64x64.png");
            var base64_buffer: [0x4000]u8 = undefined;
            const base64_png = std.base64.standard.Encoder.encode(&base64_buffer, thonk_png_data);
            var tmpbuf: [0x4000]u8 = undefined;
            const response_str = try std.fmt.bufPrint(&tmpbuf, response_str_fmt, .{base64_png});

            try self.sendPacket(ServerPacket{ .status = .{ .status_response = .{
                .json_response = types.String{ .value = response_str },
            } } });
        },
        .ping_request => |data| {
            try self.sendPacket(ServerPacket{ .status = .{ .ping_response = .{
                .payload = data.payload,
            } } });
            self.state = .close_connection;
        },
    }
}

fn handleLoginPacket(
    self: *Self,
    packet_data: std.meta.TagPayload(ClientPacket, .login),
) !void {
    switch (packet_data) {
        .login_start => |data| {
            std.debug.print("player name: {s}\n", .{data.name.value});

            // start the login sequence.
            // see "https://wiki.vg/Protocol_FAQ#What.27s_the_normal_login_sequence_for_a_client.3F"
            // more information.

            // TODO: there's no *compression* into zlib streams in the std lib, only decompression
            //       so I would have to write a zlib compressor first.
            // enable compression for all following packets (given they pass a size threshold)
            //const compression_threshold = 256;
            //try self.sendPacket(ServerPacket{ .login = .{ .set_compression = .{
            //    .threshold = compression_threshold,
            //} });

            var prng = std.rand.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.os.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            const rand = prng.random();
            const player_uuid = rand.int(u128);

            try self.sendPacket(ServerPacket{ .login = .{ .login_success = .{
                .uuid = player_uuid,
                .username = .{ .value = data.name.value },
            } } });
            self.state = .play;

            self.keep_alive_thread = try std.Thread.spawn(.{}, Self.keepAliveLoop, .{self});

            self.player = .{
                .session = self,
                .uuid = player_uuid,
                .name = try self.allocator.dupe(u8, data.name.value),
                .pos = .{ .x = 0, .y = 0, .z = 0 },
                .last_sent_pos = .{ .x = 0, .y = 0, .z = 0 },
                .dimension = .overworld,
            };
            try self.world_manager.addPlayer(&self.player);
        },
    }
}

fn handlePlayPacket(
    self: *Self,
    packet_data: std.meta.TagPayload(ClientPacket, .play),
) !void {
    switch (packet_data) {
        // sent as confirmation that the client got our 'player position and look' packet
        // maybe we should check for this and resend that packet if this one never arrives?
        .confirm_teleportation => {},
        .keep_alive => |data| {
            const is_alive = self.checkKeepAliveId(data.keep_alive_id);
            if (!is_alive) {
                self.timed_out = true;
                self.state = .close_connection;
            }
        },
        .set_held_item => |data| {
            std.debug.print("held item change: slot={}\n", data);
            self.player.active_slot = @intCast(usize, data.slot);
        },
        .set_creative_mode_slot => |data| {
            std.debug.print("creative_inventory_action: {any}\n", .{data});
            if (data.clicked_item.present and data.slot >= 36) {
                const slot = @intCast(usize, data.slot - 36);
                const raw_item_id = data.clicked_item.item_id.value;
                const block_id = WorldState.itemIdToBlockId(raw_item_id);
                self.player.slots[slot] = block_id;
                std.debug.print("player_slot[{d}] = {}\n", .{ slot, block_id });
            }
        },
        else => {
            try self.world_manager.addPlayerPacket(ClientPacket{ .play = packet_data }, &self.player);
        },
    }
}

/// Send a `keep_alive` packet every 20 seconds, check that the client response takes less
/// then 30 seconds. Set `timed_out` to true if not.
fn keepAliveLoop(self: *Self) void {
    // there can only be two of these packets in flight at the same time

    while (true) {
        if (self.state == .close_connection) {
            std.debug.print("state is close_connection. returning from keep alive loop\n", .{});
            return;
        }

        const time_of_send = std.time.milliTimestamp();
        self.sendPacket(ServerPacket{ .play = .{ .keep_alive = .{
            .keep_alive_id = time_of_send,
        } } }) catch return;

        for (&self.keep_alive_ids) |*id| {
            if (id.*) |id_time| {
                if (time_of_send - id_time > 30_000) {
                    self.timed_out = true;
                    return;
                } else {
                    id.* = null;
                }
            }
        }

        if (self.keep_alive_ids[0] == null) {
            self.keep_alive_ids[0] = time_of_send;
        } else {
            self.keep_alive_ids[1] = time_of_send;
        }

        std.time.sleep(20 * std.time.ns_per_s);
    }
}

fn checkKeepAliveId(self: *Self, check_id: i64) bool {
    if (self.keep_alive_ids[0]) |*id| {
        if (check_id == id.*) {
            self.keep_alive_ids[0] = null;
            return true;
        }
        return false;
    }
    if (self.keep_alive_ids[1]) |*id| {
        if (check_id == id.*) {
            self.keep_alive_ids[1] = null;
            return true;
        }
        return false;
    }

    // TODO: if both are null, then the check doesn't make any sense, maybe I should return
    // and error in that case.
    return false;
    //unreachable;
}

pub fn sendPacket(self: *Self, packet: ServerPacket) !void {
    const inner_tag_name = switch (packet) {
        inline else => |data| @tagName(data),
    };
    std.debug.print("sending a {s}::{s} packet... ", .{ @tagName(packet), inner_tag_name });
    try packet.encode(self.connection.stream.writer());
    std.debug.print("done.\n", .{});
}
