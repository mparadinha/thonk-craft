const std = @import("std");
const Allocator = std.mem.Allocator;
const Connection = std.net.StreamServer.Connection;
const State = @import("main.zig").State;
const WorldState = @import("main.zig").WorldState;

const types = @import("types.zig");
const nbt = @import("nbt.zig");
const client_packets = @import("client_packets.zig");
const ClientPacket = client_packets.Packet;
const server_packets = @import("server_packets.zig");
const ServerPacket = server_packets.Packet;

const sendPacketData = @import("main.zig").sendPacketData;

const Self = @This();

connection: Connection,
allocator: Allocator,
state: State = .handshaking,
world: *WorldState,

keep_alive_ids: [2]?i64 = [2]?i64{ null, null },
/// set to `true` by the keep alive loop if the client doesn't respond for 30 seconds
timed_out: bool = false,

/// After this call `connection` is owned by this object and will be cleaned up.
pub fn start(connection: Connection, allocator: Allocator, world: *WorldState) void {
    var self = Self{
        .connection = connection,
        .allocator = allocator,
        .world = world,
    };
    defer self.deinit();

    self.handleConnection() catch |err| switch (err) {
        error.EndOfStream => {},
        else => unreachable,
    };
}

pub fn deinit(self: *Self) void {
    self.connection.stream.close();
}

fn handleConnection(self: *Self) !void {
    while (true) {
        var peek_conn_stream = std.io.peekStream(1, self.connection.stream.reader());
        var reader = peek_conn_stream.reader();

        std.debug.print("waiting for data from connection...\n", .{});

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

        const packet = ClientPacket.decode(reader, self.allocator, self.state) catch |err| switch (err) {
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
        .request => {
            const response_str_fmt =
                \\{{
                \\    "version": {{
                \\        "name": "1.18.1",
                \\        "protocol": 757
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
            const thonk_png_data = @embedFile("../thonk_64x64.png");
            var base64_buffer: [0x4000]u8 = undefined;
            const base64_png = std.base64.standard.Encoder.encode(&base64_buffer, thonk_png_data);
            var tmpbuf: [0x4000]u8 = undefined;
            const response_str = try std.fmt.bufPrint(&tmpbuf, response_str_fmt, .{base64_png});

            try sendPacketData(self.connection, server_packets.StatusData{ .response = .{
                .json_response = types.String{ .value = response_str },
            } });
        },
        .ping => |data| {
            try sendPacketData(self.connection, server_packets.StatusData{ .pong = .{
                .payload = data.payload,
            } });
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

            try sendPacketData(self.connection, server_packets.LoginData{ .login_success = .{
                .uuid = 0,
                .username = try types.String.fromLiteral(self.allocator, "OfflinePlayer"),
            } });
            self.state = .play;

            const thread = try std.Thread.spawn(.{}, Self.keepAliveLoop, .{self});
            thread.detach();

            try self.sendLoginPackets();
        },
    }
}

fn sendLoginPackets(self: *Self) !void {
    const blobs = @import("binary_blobs.zig");
    _ = blobs;

    var overworld_id = types.String{ .value = "minecraft:overworld" };
    var dimension_names = [_]types.String{overworld_id};
    try sendPacketData(self.connection, server_packets.PlayData{ .join_game = .{
        .entity_id = 0,
        .is_hardcore = false,
        .gamemode = 1,
        .previous_gamemode = 1,
        .world_count = types.VarInt{ .value = @intCast(i32, dimension_names.len) },
        .dimension_names = &dimension_names,
        .dimension_codec = try @import("main.zig").genDimensionCodecBlob(self.allocator),
        .dimension = try @import("main.zig").genDimensionBlob(self.allocator),
        .dimension_name = overworld_id,
        .hashed_seed = 0,
        .max_players = types.VarInt{ .value = 420 },
        .view_distance = types.VarInt{ .value = 10 },
        .simulation_distance = types.VarInt{ .value = 10 },
        .reduced_debug_info = false,
        .enable_respawn = false,
        .is_debug = false,
        .is_flat = true,
    } });

    const test_chunk_data = try @import("main.zig").genSingleChunkSectionDataBlob(self.allocator);
    defer self.allocator.free(test_chunk_data);
    const chunk_positions = [_][2]i32{
        // zig fmt: off
        [2]i32{ -1, -1 }, [2]i32{ -1, 0 }, [2]i32{ -1, 1 },
        [2]i32{  0, -1 }, [2]i32{  0, 0 }, [2]i32{  0, 1 },
        [2]i32{  1, -1 }, [2]i32{  1, 0 }, [2]i32{  1, 1 },
        // zig fmt: on
    };
    for (chunk_positions) |pos| {
        const chunk_data = if (pos[0] == 0 and pos[1] == 0)
            try @import("main.zig").genSingleBlockTypeChunkSection(self.allocator, 0x01) else test_chunk_data;
        const data = server_packets.PlayData{ .chunk_data_and_update_light = .{
            .chunk_x = pos[0],
            .chunk_z = pos[1],
            .heightmaps = try @import("main.zig").genHeighmapBlob(self.allocator),
            .size = types.VarInt{ .value = @intCast(i32, chunk_data.len) },
            .data = chunk_data,
            .trust_edges = true,
            .sky_light_mask = 0,
            .block_light_mask = 0,
            .empty_sky_light_mask = 0,
            .empty_block_light_mask = 0,
        } };
        defer self.allocator.free(data.chunk_data_and_update_light.heightmaps.blob);
        try sendPacketData(self.connection, data);
    }

    try sendPacketData(self.connection, server_packets.PlayData{ .player_position_and_look = .{
        .x = 0,
        .y = 0,
        .z = 0,
        .yaw = 0,
        .pitch = 0,
        .flags = 0,
        .teleport_id = types.VarInt{ .value = 0 },
        .dismount_vehicle = false,
    } });
}

fn handlePlayPacket(
    self: *Self,
    packet_data: std.meta.TagPayload(ClientPacket, .play),
) !void {
    _ = self;
    switch (packet_data) {
        .keep_alive => |data| {
            const is_alive = self.checkKeepAliveId(data.keep_alive_id);
            if (!is_alive) {
                self.timed_out = true;
                self.state = .close_connection;
            }
        },
        //.teleport_confirm => |data| {
        //    std.debug.print("teleport_id={d}\n", .{data.teleport_id});
        //},
        //.player_position => |data| {
        //    std.debug.print("player_position=({}, {}, {}, on_ground={})\n", data);
        //},
        //.player_digging => |data| {
        //    std.debug.print("digging {{status={}, location={}, face={}}}\n", .{
        //        data.status.value, data.location, data.face
        //    });
        //},
        //.animation => |data| {
        //    const hand = if (data.hand.value == 0) "main hand"  else "off hand";
        //    std.debug.print("animation: {s}\n", .{hand});
        //},

        // ignore everything else right now, cause our server doesn't do shit yet
        else => {},
    }
}

/// Send a `keep_alive` packet every 20 seconds, check that the client response takes less
/// then 30 seconds. Set `timed_out` to true if not.
fn keepAliveLoop(self: *Self) void {
    // there can only be two of these packets in flight at the same time

    while (true) {
        const time_of_send = std.time.milliTimestamp();
        sendPacketData(self.connection, server_packets.PlayData{ .keep_alive = .{
            .keep_alive_id = time_of_send,
        } }) catch { return; };

        for (self.keep_alive_ids) |*id| {
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
    unreachable;
}