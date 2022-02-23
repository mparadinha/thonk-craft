const std = @import("std");
const Allocator = std.mem.Allocator;
const StreamServer = std.net.StreamServer;

const types = @import("types.zig");
const nbt = @import("nbt.zig");
const client_packets = @import("client_packets.zig");
const ClientPacket = client_packets.Packet;
const server_packets = @import("server_packets.zig");
const ServerPacket = server_packets.Packet;

pub const State = enum(u8) {
    /// All connection start in this state. Not part of the protocol.
    handshaking,

    status = 1,
    login = 2,
    play = 3,

    /// Not part of the protocol, used to signal that we're meant to close the connection.
    close_connection,
};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var server = StreamServer.init(.{
        // I shouldn't need this here. but sometimes we crash and this way we don't have
        // to wait for timeout after TIME_WAIT to run the program again.
        .reuse_address = true,
    });
    defer server.deinit();

    const local_server_ip = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 25565);
    try server.listen(local_server_ip);
    std.debug.print("listening on localhost:{d}...\n", .{local_server_ip.getPort()});
    defer server.close();

    while (true) {
        std.debug.print("waiting for connection...\n", .{});
        const connection = try server.accept();
        defer connection.stream.close();
        std.debug.print("connection: {}\n", .{connection});

        handleConnection(connection, gpa) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
    }
}

var waiting_for_client_keep_alive = false;
var last_keep_alive_id_sent: i64 = undefined;
fn keep_alive_loop(connection: StreamServer.Connection, is_alive: *bool) !void {
    while (true) {
        const time_of_send = std.time.milliTimestamp();
        try send_packet_data(connection, server_packets.PlayData{ .keep_alive = .{
            .keep_alive_id = time_of_send,
        } });
        waiting_for_client_keep_alive = true;
        last_keep_alive_id_sent = time_of_send;

        std.time.sleep(20 * std.time.ns_per_s);

        // TODO: check that the last keep alive was reciprocated by client
    }
    is_alive.* = false;
}

fn handleConnection(connection: StreamServer.Connection, allocator: Allocator) !void {
    var state = State.handshaking;

    var is_alive = true;
    var keep_alive_thread: ?std.Thread = null;
    defer if (keep_alive_thread) |thread| thread.join();

    while (true) {
        var peek_conn_stream = std.io.peekStream(1, connection.stream.reader());
        var reader = peek_conn_stream.reader();

        if (state == State.play and keep_alive_thread == null) {
            std.debug.print("spawning new keep alive loop thread\n", .{});
            keep_alive_thread = try std.Thread.spawn(.{}, keep_alive_loop, .{ connection, &is_alive });
        }

        std.debug.print("waiting for data from connection...\n", .{});

        const first_byte = try peek_conn_stream.reader().readByte();
        try peek_conn_stream.putBackByte(first_byte);

        // handle legacy ping
        if (first_byte == 0xfe and state == State.handshaking) {
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
            _ = try connection.stream.write(&kick_packet_data);
            break;
        }

        const packet = try ClientPacket.decode(reader, allocator, state);

        const inner_tag_name = switch (packet) {
            .handshaking => |data| @tagName(data),
            .status => |data| @tagName(data),
            .login => |data| @tagName(data),
            .play => |data| @tagName(data),
        };
        std.debug.print("got a {s}::{s} packet\n", .{ @tagName(packet), inner_tag_name });

        switch (packet) {
            .handshaking => |data| try handleHandshakingPacket(data, &state, connection, allocator),
            .status => |data| try handleStatusPacket(data, &state, connection, allocator),
            .login => |data| try handleLoginPacket(data, &state, connection, allocator),
            .play => |data| try handlePlayPacket(data, &state, connection, allocator),
        }

        if (state == State.close_connection) break;
    }
}

fn handleHandshakingPacket(
    packet_data: std.meta.TagPayload(ClientPacket, .handshaking),
    state: *State,
    connection: StreamServer.Connection,
    allocator: Allocator,
) !void {
    _ = connection;
    _ = allocator;
    switch (packet_data) {
        .handshake => |data| {
            state.* = data.next_state;
        },
    }
}

fn handleStatusPacket(
    packet_data: std.meta.TagPayload(ClientPacket, .status),
    state: *State,
    connection: StreamServer.Connection,
    allocator: Allocator,
) !void {
    _ = state;
    _ = allocator;

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

            try sendPacket(connection, ServerPacket{ .status = .{ .response = .{
                .json_response = types.String{ .value = response_str },
            } } });
        },
        .ping => |data| {
            try sendPacket(connection, ServerPacket{ .status = .{ .pong = .{
                .payload = data.payload,
            } } });
            state.* = .close_connection;
        },
    }
}

fn handleLoginPacket(
    packet_data: std.meta.TagPayload(ClientPacket, .login),
    state: *State,
    connection: StreamServer.Connection,
    allocator: Allocator,
) !void {
    _ = allocator;

    // https://wiki.vg/Protocol#Login
    switch (packet_data) {
        .login_start => |data| {
            std.debug.print("player name: {s}\n", .{data.name.value});

            // start the login sequence.
            // see "https://wiki.vg/Protocol_FAQ#What.27s_the_normal_login_sequence_for_a_client.3F"
            // more information.

            try sendPacket(connection, ServerPacket{ .login = .{ .login_success = .{
                .uuid = 0,
                .username = try types.String.fromLiteral(allocator, "OfflinePlayer"),
            } } });
            state.* = .play;

            try send_login_packets(connection, allocator);
        },
    }
}

fn send_login_packets(connection: StreamServer.Connection, allocator: Allocator) !void {
    const blobs = @import("binary_blobs.zig");
    _ = blobs;

    var overworld_id = types.String{ .value = "minecraft:overworld" };
    var dimension_names = [_]types.String{overworld_id};
    try send_packet_data(connection, server_packets.PlayData{ .join_game = .{
        .entity_id = 0,
        .is_hardcore = false,
        .gamemode = 1,
        .previous_gamemode = 1,
        .world_count = types.VarInt{ .value = @intCast(i32, dimension_names.len) },
        .dimension_names = &dimension_names,
        .dimension_codec = try genDimensionCodecBlob(allocator),
        .dimension = try genDimensionBlob(allocator),
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

    const chunk_data = try genSingleChunkSectionDataBlob(allocator);
    defer allocator.free(chunk_data);
    const chunk_positions = [_][2]i32{
        // zig fmt: off
        [2]i32{ -1, -1 }, [2]i32{ -1, 0 }, [2]i32{ -1, 1 },
        [2]i32{  0, -1 }, [2]i32{  0, 0 }, [2]i32{  0, 1 },
        [2]i32{  1, -1 }, [2]i32{  1, 0 }, [2]i32{  1, 1 },
        // zig fmt: on
    };
    for (chunk_positions) |pos| {
        const data = server_packets.PlayData{ .chunk_data_and_update_light = .{
            .chunk_x = pos[0],
            .chunk_z = pos[1],
            .heightmaps = try genHeighmapBlob(allocator),
            .size = types.VarInt{ .value = @intCast(i32, chunk_data.len) },
            .data = chunk_data,
            .trust_edges = true,
            .sky_light_mask = 0,
            .block_light_mask = 0,
            .empty_sky_light_mask = 0,
            .empty_block_light_mask = 0,
        } };
        defer allocator.free(data.chunk_data_and_update_light.heightmaps.blob);
        try send_packet_data(connection, data);
    }

    try send_packet_data(connection, server_packets.PlayData{ .player_position_and_look = .{
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
    packet_data: std.meta.TagPayload(ClientPacket, .play),
    state: *State,
    connection: StreamServer.Connection,
    allocator: Allocator,
) !void {
    _ = state;
    _ = connection;
    _ = allocator;

    switch (packet_data) {
        .teleport_confirm => |data| {
            std.debug.print("teleport_id={d}\n", .{data.teleport_id});
        },
        .player_position => |data| {
            std.debug.print("player_position=({}, {}, {}, on_ground={})\n", data);
        },
        .player_digging => |data| {
            std.debug.print("digging {{status={}, location={}, face={}}}\n", .{
                data.status.value, data.location, data.face
            });
        },
        .animation => |data| {
            const hand = if (data.hand.value == 0) "main hand"  else "off hand";
            std.debug.print("animation: {s}\n", .{hand});
        },

        // ignore everything else right now, cause our server doesn't do shit yet
        else => {},
    }
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
fn send_packet_data(connection: StreamServer.Connection, data: anytype) !void {
    std.debug.print("sending a ??::{s} packet...", .{@tagName(std.meta.activeTag(data))});
    try encode_packet_data(connection.stream.writer(), data);
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

fn sendPacket(connection: StreamServer.Connection, packet: ServerPacket) !void {
    const inner_tag_name = switch (packet) {
        .status => |data| @tagName(data),
        .login => |data| @tagName(data),
        .play => |data| @tagName(data),
    };
    std.debug.print("sending a {s}::{s} packet... ", .{ @tagName(packet), inner_tag_name });
    try packet.encode(connection.stream.writer());
    std.debug.print("done.\n", .{});
}

fn genDimensionCodecBlob(allocator: Allocator) !types.NBT {
    const blob = @import("binary_blobs.zig").witchcraft_dimension_codec_nbt;
    return types.NBT{ .blob = try allocator.dupe(u8, &blob) };
}

// same as overworld element in dimension codec for now
fn genDimensionBlob(allocator: Allocator) !types.NBT {
    var buf = try allocator.alloc(u8, 0x4000);
    const writer = std.io.fixedBufferStream(buf).writer();

    {
        try nbt.Compound.startNamed(writer, "");
        defer nbt.Compound.end(writer) catch unreachable;

        try nbt.Byte.addNamed(writer, "piglin_safe", 0);
        try nbt.Byte.addNamed(writer, "natural", 1);
        try nbt.Float.addNamed(writer, "ambient_light", 0);
        try nbt.String.addNamed(writer, "infiniburn", "minecraft:infiniburn_overworld");
        try nbt.Byte.addNamed(writer, "respawn_anchor_works", 0);
        try nbt.Byte.addNamed(writer, "has_skylight", 1);
        try nbt.Byte.addNamed(writer, "bed_works", 1);
        try nbt.String.addNamed(writer, "effects", "minecraft:overworld");
        try nbt.Byte.addNamed(writer, "has_raids", 1);
        try nbt.Int.addNamed(writer, "min_y", -64);
        try nbt.Int.addNamed(writer, "height", 384);
        try nbt.Int.addNamed(writer, "logical_height", 384);
        try nbt.Double.addNamed(writer, "coordinate_scale", 1);
        try nbt.Byte.addNamed(writer, "ultrawarm", 0);
        try nbt.Byte.addNamed(writer, "has_ceiling", 0);
    }

    const blob = writer.context.getWritten();
    buf = allocator.resize(buf, blob.len).?;
    return types.NBT{ .blob = blob };
}

fn genHeighmapBlob(allocator: Allocator) !types.NBT {
    var buf = try allocator.alloc(u8, 0x4000);
    const writer = std.io.fixedBufferStream(buf).writer();

    // lifted from https://git.sakamoto.pl/domi/Witchcraft/-/blob/meow/src/packet.sh#L37
    {
        try nbt.Compound.startNamed(writer, "");
        defer nbt.Compound.end(writer) catch unreachable;

        // see https://wiki.vg/Chunk_Format#Heightmaps_structure for more info on this encoding
        const array_values = [_]i64{0x0100_8040_2010_0804} ** 36 ++ [_]i64{0x0000_0000_2010_0804};
        try nbt.LongArray.addNamed(writer, "MOTION_BLOCKING", &array_values);
    }

    const blob = writer.context.getWritten();
    buf = allocator.resize(buf, blob.len).?;
    return types.NBT{ .blob = blob };
}

// huge thanks to http://sdomi.pl/weblog/15-witchcraft-minecraft-server-in-bash/
fn genSingleChunkSectionDataBlob(allocator: Allocator) ![]u8 {
    var buf = try allocator.alloc(u8, 0x4000);
    const writer = std.io.fixedBufferStream(buf).writer();

    // see https://wiki.vg/Chunk_Format#Chunk_Section_structure for more information

    const block_ids_palette = [_]i32{
        0x00, // air
        0x01, // stone
        0x09, // grass block
        0x0a, // dirt
        0x0e, // cobblestone
        0x0f, // planks
        0x15, // sapling
        0x21, // bedrock
        0x31, // water
        0x41, // lava
        0x42, // sand
        0x44, // gravel
        0x45, // gold ore
        0x47, // iron ore
        0x49, // coal ore
        0x4d, // wood
        0x94, // leaves
        0x104, // sponge
        0x106, // glass
        0x107, // lapis ore
        0x109,
        0x116, // sandstone
        0x576, // tallgrass
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    };

    try writer.writeIntBig(i16, 0x7fff); // number of non-air blocks
    { // block states (paletted container)
        try writer.writeByte(8); // bits per block
        { // palette
            try types.VarInt.encode(writer, @intCast(i32, block_ids_palette.len));
            for (block_ids_palette) |entry| try types.VarInt.encode(writer, entry);
        }

        // 4096 entries (# of blocks in chunk section)
        const data_array = [_]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15} ** (0x100);
        try types.VarInt.encode(writer, @intCast(i32, 0x200)); // 0x200=8004 ???? (not 0x1000??)
        //try types.VarInt.encode(writer, @intCast(i32, data_array.len));
        for (data_array) |entry| try writer.writeIntBig(u8, entry);
    }

    { // biomes (paletted container)
        try writer.writeByte(0); // bits per block
        { // palette
            try types.VarInt.encode(writer, 1); // plains
        }
        const biomes = [_]u64{0x0000_0000_0000_0001} ** 26; // why 26???
        for (biomes) |entry| try writer.writeIntBig(u64, entry);
    }

    const blob = writer.context.getWritten();
    buf = allocator.resize(buf, blob.len).?;
    return blob;
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
