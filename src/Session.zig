//! This struct handles a single connection to a single client.
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
world: *WorldState,

keep_alive_thread: ?std.Thread = null,
keep_alive_ids: [2]?i64 = [2]?i64{ null, null },
/// set to `true` by the keep alive loop if the client doesn't respond for 30 seconds
timed_out: bool = false,

active_slot: usize = 0,
player_slots: [9]u16 = [_]u16{0} ** 9,

/// After this call `connection` is owned by this object and will be cleaned up.
pub fn start(connection: Connection, allocator: Allocator, world: *WorldState) void {
    var self = Self{
        .connection = connection,
        .allocator = allocator,
        .world = world,
    };
    defer self.deinit();

    self.handleConnection() catch |err| {
        std.debug.print("err={}\n", .{err});
    };

    self.state = .close_connection;

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

        //const inner_tag_name = switch (packet) {
        //    .handshaking => |data| @tagName(data),
        //    .status => |data| @tagName(data),
        //    .login => |data| @tagName(data),
        //    .play => |data| @tagName(data),
        //};
        //std.debug.print("got a {s}::{s} packet\n", .{ @tagName(packet), inner_tag_name });

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

            try self.sendPacketData(server_packets.StatusData{ .response = .{
                .json_response = types.String{ .value = response_str },
            } });
        },
        .ping => |data| {
            try self.sendPacketData(server_packets.StatusData{ .pong = .{
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

            // TODO: there's no *compression* into zlib streams in the std lib, only decompression
            //       so I would have to write a zlib compressor first.
            // enable compression for all following packets (given they pass a size threshold)
            //const compression_threshold = 256;
            //try self.sendPacketData(server_packets.LoginData{ .set_compression = .{
            //    .threshold = compression_threshold,
            //} });

            try self.sendPacketData(server_packets.LoginData{ .login_success = .{
                .uuid = 0,
                .username = try types.String.fromLiteral(self.allocator, "OfflinePlayer"),
            } });
            self.state = .play;

            self.keep_alive_thread = try std.Thread.spawn(.{}, Self.keepAliveLoop, .{self});

            try self.sendLoginPackets();
        },
    }
}

fn sendLoginPackets(self: *Self) !void {
    const blobs = @import("binary_blobs.zig");
    _ = blobs;

    var overworld_id = types.String{ .value = "minecraft:overworld" };
    var dimension_names = [_]types.String{overworld_id};
    try self.sendPacketData(server_packets.PlayData{ .join_game = .{
        .entity_id = 0,
        .is_hardcore = false,
        .gamemode = 1,
        .previous_gamemode = 1,
        .world_count = types.VarInt{ .value = @intCast(i32, dimension_names.len) },
        .dimension_names = &dimension_names,
        .dimension_codec = try WorldState.genDimensionCodecBlob(self.allocator),
        .dimension = try WorldState.genDimensionBlob(self.allocator),
        .dimension_name = overworld_id,
        .hashed_seed = 0,
        .max_players = types.VarInt{ .value = 420 },
        .view_distance = types.VarInt{ .value = 32 },
        .simulation_distance = types.VarInt{ .value = 32 },
        .reduced_debug_info = false,
        .enable_respawn = false,
        .is_debug = false,
        .is_flat = true,
    } });

    const test_chunk_data = try WorldState.genSingleChunkSectionDataBlob(self.allocator, 1);
    defer self.allocator.free(test_chunk_data);
    //const all_stone_chunk = try WorldState.genSingleBlockTypeChunkSection(self.allocator, 0x01);
    //var official_chunk = try WorldState.getChunkFromRegionFile("r.0.0.mca", self.allocator, 0, 0);
    var official_chunk = try WorldState.getChunkFromRegionFile("nether_r.0.0.mca", self.allocator, 0, 0);
    const official_chunk_data = try official_chunk.makeIntoPacketFormat(self.allocator);
    defer self.allocator.free(official_chunk_data);
    //const chunk_positions = [_][2]i32{
    //    // zig fmt: off
    //    [2]i32{ -1, -1 }, [2]i32{ -1, 0 }, [2]i32{ -1, 1 },
    //    [2]i32{  0, -1 }, [2]i32{  0, 0 }, [2]i32{  0, 1 },
    //    [2]i32{  1, -1 }, [2]i32{  1, 0 }, [2]i32{  1, 1 },
    //    // zig fmt: on
    //};
    const chunk_positions = [_][2]i32{
        // zig fmt: off
        [2]i32{ 0, 0 }, [2]i32{ 0, 1 }, [2]i32{ 0, 2 },
        [2]i32{ 1, 0 }, [2]i32{ 1, 1 }, [2]i32{ 1, 2 },
        [2]i32{ 2, 0 }, [2]i32{ 2, 1 }, [2]i32{ 2, 2 },
        // zig fmt: on
    };
    for (chunk_positions) |pos| {
        //const chunk = try WorldState.getChunkFromRegionFile("r.0.0.mca", self.allocator, pos[0], pos[1]);
        //const chunk_data = try chunk.makeIntoPacketFormat(self.allocator);
        const chunk_data = try self.world.encodeChunkSectionData();
        //const chunk_data = blk: {
        //    if (pos[0] == 0 and pos[1] == 0) {
        //        //break :blk try self.world.encodeChunkSectionData();
        //        break :blk test_chunk_data;
        //    } else if (pos[0] == 1 and pos[1] == 1) {
        //        break :blk official_chunk_data;
        //    } else break :blk test_chunk_data;
        //};
        const data = server_packets.PlayData{
            .chunk_data_and_update_light = .{
                .chunk_x = pos[0],
                .chunk_z = pos[1],
                //.heightmaps = try WorldState.genHeighmapBlob(self.allocator),
                .heightmaps = try WorldState.genHeightmapSingleHeight(self.allocator, 64),
                //.heightmaps = try WorldState.genHeightmapSeaLevel(self.allocator),
                .size = types.VarInt{ .value = @intCast(i32, chunk_data.len) },
                .data = chunk_data,
                .trust_edges = true,
                .sky_light_mask = 0,
                .block_light_mask = 0,
                .empty_sky_light_mask = 0,
                .empty_block_light_mask = 0,
            },
        };
        defer self.allocator.free(data.chunk_data_and_update_light.heightmaps.blob);
        try self.sendPacketData(data);
    }

    try self.sendPacketData(server_packets.PlayData{ .player_position_and_look = .{
        .x = 0,
        .y = 70,
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
    const specialMod = @import("WorldState.zig").specialMod;
    switch (packet_data) {
        // sent as confirmation that the client got our 'player position and look' packet
        // maybe we should check for this and resend that packet if this one never arrives?
        .teleport_confirm => {},

        .keep_alive => |data| {
            const is_alive = self.checkKeepAliveId(data.keep_alive_id);
            if (!is_alive) {
                self.timed_out = true;
                self.state = .close_connection;
            }
        },

        .player_digging => |data| {
            std.debug.print("dig: status={}, loc={}, face={}\n", data);
            const pos = data.location;
            const chunk_x = @truncate(u4, specialMod(pos.x, 16));
            const chunk_y = @truncate(u4, specialMod(pos.y, 16));
            const chunk_z = @truncate(u4, specialMod(pos.z, 16));
            const status = data.status.value;
            if (status == 0 or status == 1) {
                self.world.removeBlock(chunk_x, chunk_y, chunk_z);

                // TODO: update all other players of the change
            }
        },

        .held_item_change => |data| {
            std.debug.print("held item change: slot={}\n", data);
            self.active_slot = @intCast(usize, data.slot);
        },

        .creative_inventory_action => |data| {
            std.debug.print("creative_inventory_action: {any}\n", .{data});

            if (data.clicked_item.present and data.slot >= 36) {
                const slot = @intCast(usize, data.slot - 36);
                const raw_item_id = data.clicked_item.item_id.value;
                const block_id = WorldState.itemIdToBlockId(raw_item_id);
                self.player_slots[slot] = block_id;
                std.debug.print("player_slot[{d}] = {}\n", .{ slot, block_id });
            }
        },

        .player_block_placement => |data| {
            std.debug.print("block place: hand={}, loc={}, face={}, cursor_pos=({},{},{}), inside_block={}\n", data);

            const click_pos = data.location;
            var pos = click_pos;
            switch (data.face.value) {
                0 => pos.y -= 1, // clicked on -Y face
                1 => pos.y += 1, // clicked on +Y face
                2 => pos.z -= 1, // clicked on -Z face
                3 => pos.z += 1, // clicked on +Z face
                4 => pos.x -= 1, // clicked on -X face
                5 => pos.x += 1, // clicked on +X face
                else => unreachable,
            }
            const chunk_x = @truncate(u4, specialMod(pos.x, 16));
            const chunk_y = @truncate(u4, specialMod(pos.y, 16));
            const chunk_z = @truncate(u4, specialMod(pos.z, 16));
            const new_block = self.player_slots[self.active_slot];
            std.debug.print("placing {} @ ({d}, {d}, {d})\n", .{ new_block, chunk_x, chunk_y, chunk_z });
            self.world.changeBlock(chunk_x, chunk_y, chunk_z, new_block);
        },

        // ignore everything else right now, cause our server doesn't do shit yet
        else => {},
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
        self.sendPacketData(server_packets.PlayData{ .keep_alive = .{
            .keep_alive_id = time_of_send,
        } }) catch {
            return;
        };

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
    return false;
    //unreachable;
}

// this is a workaround. if we try to use the main Packet.encode we hit a stage1
// compiler bug where the union tag value is getting overwritten (only for PlayData member)
// when copying over the actual data when doing ServerPacket{ .play = data }.
// looks like a codegen error.
// also:
// I'm getting a compiler crash (codegen.cpp:8603 in gen_const_val) when I try to
// send `ServerPacket.play` packets using the a normal `sendPacket` function.
// (this is a known stage1 bug with deeply nested annonymous structures)
// I have no idea why only that specific enum in the ServerPacket union crashes though.
fn sendPacketData(self: *Self, data: anytype) !void {
    std.debug.print("sending a ??::{s} packet...", .{@tagName(std.meta.activeTag(data))});
    try encode_packet_data(self.connection.stream.writer(), data);
    std.debug.print("done.\n", .{});
}

fn encode_packet_data(writer: anytype, data: anytype) !void {
    const raw_id = @intCast(i32, @enumToInt(std.meta.activeTag(data)));
    const data_encode_size = data.encodedSize();
    const packet_size = types.VarInt.encodedSize(raw_id) + data_encode_size;

        try types.VarInt.encode(writer, @intCast(i32, packet_size));
        try types.VarInt.encode(writer, raw_id);
        try data.encode(writer);
}

fn sendPacket(self: *Self, packet: ServerPacket) !void {
    const inner_tag_name = switch (packet) {
        .status => |data| @tagName(data),
        .login => |data| @tagName(data),
        .play => |data| @tagName(data),
    };
    std.debug.print("sending a {s}::{s} packet... ", .{ @tagName(packet), inner_tag_name });
    try packet.encode(self.connection.stream.writer());
    std.debug.print("done.\n", .{});
}
