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

    { // dump nbt data for debugging
        const tmp_file = try std.fs.cwd().createFile("my_nbt_dump.nbt", .{});
        defer tmp_file.close();
        const nbt_dump = try genDimensionCodecBlob(gpa);
        _ = try tmp_file.write(nbt_dump.blob);
    }

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
    errdefer server.close();

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

fn handleConnection(connection: StreamServer.Connection, allocator: Allocator) !void {
    var state = State.handshaking;

    while (true) {
        var peek_conn_stream = std.io.peekStream(1, connection.stream.reader());
        var reader = peek_conn_stream.reader();

        std.debug.print("waiting for data from connection...\n", .{});

        // handle legacy ping
        const first_byte = try peek_conn_stream.reader().readByte();
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
        try peek_conn_stream.putBackByte(first_byte);

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

            try sendPacket(connection, ServerPacket{
                .status = .{ .response = .{ .json_response = types.String{ .value = response_str } } },
            });
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

            const PlayData = @import("server_packets.zig").PlayData;
            _ = PlayData;
            const blobs = @import("binary_blobs.zig");

            //var overworld_id = types.String{ .value = "minecraft:overworld" };
            //var dimension_names = [_]types.String{overworld_id};
            //// zig fmt: off
            //try send_data_hack(connection, PlayData{ .join_game = .{
            //    .entity_id = 0,
            //    .is_hardcore = false,
            //    .gamemode = 1, // creative
            //    .previous_gamemode = -1,
            //    .world_count = types.VarInt{ .value = @intCast(i32, dimension_names.len) },
            //    .dimension_names = &dimension_names,
            //    .dimension_codec = try genDimensionCodecBlob(allocator),
            //    .dimension = try genDimensionBlob(allocator),
            //    .dimension_name = overworld_id,
            //    .hashed_seed = 0,
            //    .max_players = types.VarInt{ .value = 420 },
            //    .view_distance = types.VarInt{ .value = 2 }, // i think 2 is the minimum
            //    .reduced_debug_info = false,
            //    .enable_respawn = true,
            //    .is_debug = false,
            //    .is_flat = false,
            //} }, 0);
            //// zig fmt: on
            std.debug.assert(blobs.witchcraft_join_game_packet_full.len == 23991);
            _ = try connection.stream.write(&blobs.witchcraft_join_game_packet_full);

            // huge thanks to http://sdomi.pl/weblog/15-witchcraft-minecraft-server-in-bash/
            const witchcraft_blob = blobs.witchcraft_chunk_data_packet_data;
            std.debug.assert(witchcraft_blob.len == 4690);
            //try send_packet_data(connection, PlayData{ .chunk_data_and_update_light = .{} });
            try send_packet_raw(
                connection,
                @enumToInt(@import("server_packets.zig").PlayId.chunk_data_and_update_light),
                &witchcraft_blob,
            );
            //const packet_blob = [_]u8{ 0xd3, 0x24, 0x22 } ++ witchcraft_blob;
            //_ = try connection.stream.write(&packet_blob);
            //const chunk_positions = [_][2]i32{
            //    //[2]i32{ -1, -1 }, // var int too big
            //    //[2]i32{ -1, 0 }, // 19
            //    //[2]i32{ -1, 1 }, // 19
            //    //[2]i32{ 0, -1 }, // 20
            //    [2]i32{ 0, 0 }, // 20
            //    //[2]i32{ 0, 1 }, // 20
            //    //[2]i32{ 1, -1 }, // 20
            //    //[2]i32{ 1, 0 }, // 20
            //    //[2]i32{ 1, 1 }, // 20
            //};
            //var chunk_section_data = try genSingleChunkSectionDataBlob(allocator);
            //for (chunk_positions) |pos| {
            //    try send_data_hack(connection, PlayData{ .chunk_data_and_update_light = .{
            //        .chunk_x = pos[0],
            //        .chunk_z = pos[1],
            //        .heigtmaps = try genHeighmapBlob(allocator),
            //        .size = types.VarInt{ .value = @intCast(i32, chunk_section_data.len) },
            //        .data = chunk_section_data,
            //        .trust_edges = true,
            //        .sky_light_mask = 0,
            //        .block_light_mask = 0,
            //        .empty_sky_light_mask = 0,
            //    } }, 0);
            //}

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
            //_ = connection.blobs.witchcraft_pos_and_look_packet_full;
        },
    }
}

// this is a workaround. if we try to use the main Packet.encode we hit a stage1
// compiler bug where the union tag value is getting overwritten (only for PlayData member)
// when copying over the actual data when doing ServerPacket{ .play = data }.
// looks like a codegen error.
fn send_packet_data(connection: StreamServer.Connection, data: anytype) !void {
    std.debug.print("sending a ??::{s} packet...\n", .{@tagName(std.meta.activeTag(data))});
    try encode_packet_data(connection.stream.writer(), data);
}

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
test "player_position_and_look packet encoding" {
    const hardcoded = @import("binary_blobs.zig").witchcraft_pos_and_look_packet_full;

    var buf: [0x4000]u8 = undefined;
    const writer = std.io.fixedBufferStream(&buf).writer();

    const data = server_packets.PlayData{ .player_position_and_look = .{
        .x = 0,
        .y = 0,
        .z = 0,
        .yaw = 0,
        .pitch = 0,
        .flags = 0,
        .teleport_id = types.VarInt{ .value = 0 },
        .dismount_vehicle = false,
    } };
    try encode_packet_data(writer, data);

    const genblob = writer.context.getWritten();
    try std.testing.expect(cmp_slices_test(genblob, &hardcoded));
}

fn encode_packet_data(writer: anytype, data: anytype) !void {
    const raw_id = @intCast(i32, @enumToInt(std.meta.activeTag(data)));
    const packet_size = types.VarInt.encodedSize(raw_id) + data.encodedSize();
    try types.VarInt.encode(writer, @intCast(i32, packet_size));
    try types.VarInt.encode(writer, raw_id);
    try data.encode(writer);
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

        // ignore everything else right now, cause our server doesn't do shit yet
        else => {},
    }
}

fn sendPacket(connection: StreamServer.Connection, packet: ServerPacket) !void {
    var sendbuf: [0x8000]u8 = undefined;
    const writer = std.io.fixedBufferStream(&sendbuf).writer();
    try packet.encode(writer);

    const packet_slice = writer.context.getWritten();

    const inner_tag_name = switch (packet) {
        .status => |data| @tagName(data),
        .login => |data| @tagName(data),
        .play => |data| @tagName(data),
    };
    std.debug.print("sending a {s}::{s} packet... ", .{ @tagName(packet), inner_tag_name });
    const bytes_sent = try connection.stream.write(packet_slice);
    std.debug.print("done. ({d} bytes)\n", .{bytes_sent});
}

fn send_packet_raw(connection: StreamServer.Connection, id: i32, data: []const u8) !void {
    var sendbuf: [0x8000]u8 = undefined;
    const writer = std.io.fixedBufferStream(&sendbuf).writer();

    const packet_size = types.VarInt.encodedSize(id) + data.len;

    try types.VarInt.encode(writer, @intCast(i32, packet_size));
    try types.VarInt.encode(writer, id);
    _ = try writer.write(data);

    const packet_slice = writer.context.getWritten();
    std.debug.print("sending a raw packet (id={}, data.len={})... ", .{ id, data.len });
    const bytes_sent = try connection.stream.write(packet_slice);
    std.debug.print("done. ({d} bytes)\n", .{bytes_sent});
}

// for some reason I'm getting a compiler crash (codegen.cpp:8603 in gen_const_val)
// when I try to send `ServerPacket.play` packets using the a normal `sendPacket`
// function. I have no idea why only that specific enum in the ServerPacket union
// crashes. this is a workaround.
fn send_data_hack(connection: StreamServer.Connection, data: anytype, tmp: i32) !void {
    var sendbuf: [0x8000]u8 = undefined;
    const writer = std.io.fixedBufferStream(&sendbuf).writer();

    const id = std.meta.activeTag(data);
    const raw_id = @intCast(i32, @enumToInt(id));
    const packet_size = types.VarInt.encodedSize(raw_id) + data.encodedSize();

    //try types.VarInt.encode(writer, @intCast(i32, packet_size));
    try types.VarInt.encode(writer, @intCast(i32, packet_size + 1) + tmp);
    // ^ this makes no sense. but if I try to just use packet size, the client crashes like so:
    //   "Internal Exception: io.netty.handler.codec.DecoderException:
    //    java.lang.IndexOutOfBoundsException: readerIndex(`packet_size`) + length(1) exceeds
    //    writerIndex(`packet_size`): PooledUnsafeDirectByteBuf(ridx: `packet_size`, widx: `packet_size`, cap: `packet_size`)"
    try types.VarInt.encode(writer, raw_id);
    try data.encode(writer);

    std.debug.print("packet_size={d}, raw_id={d}\n", .{ packet_size, raw_id });
    std.debug.print("encodedSizes: packet_size => {d}, raw_id => {d}, data => {d}\n", .{
        types.VarInt.encodedSize(@intCast(i32, packet_size)), types.VarInt.encodedSize(raw_id),
        data.encodedSize(),
    });

    const packet_slice = writer.context.getWritten();
    std.debug.print("sending a ??::{s} packet... ", .{@tagName(id)});
    const bytes_sent = try connection.stream.write(packet_slice);
    std.debug.print("done. ({d} bytes)\n", .{bytes_sent});
}

fn genDimensionCodecBlob(allocator: Allocator) !types.NBT {
    const blob = @embedFile("../dimension_codec_blob.nbt")[0..];
    return types.NBT{ .blob = try allocator.dupe(u8, blob) };

    //var buf = try allocator.alloc(u8, 0x4000);
    //const writer = std.io.fixedBufferStream(buf).writer();

    //{
    //    try nbt.Compound.startNamed(writer, "");
    //    defer nbt.Compound.end(writer) catch unreachable;

    //    {
    //        try nbt.Compound.startNamed(writer, "minecraft:dimension_type");
    //        defer nbt.Compound.end(writer) catch unreachable;

    //        try nbt.String.addNamed(writer, "type", "minecraft:dimension_type");
    //        try nbt.List.startNamed(writer, "value", .compound, 1);
    //        {
    //            defer nbt.Compound.end(writer) catch unreachable;

    //            try nbt.String.addNamed(writer, "name", "minecraft:overworld");
    //            try nbt.Int.addNamed(writer, "id", 0);
    //            {
    //                try nbt.Compound.startNamed(writer, "element");
    //                defer nbt.Compound.end(writer) catch unreachable;

    //                try nbt.Byte.addNamed(writer, "piglin_safe", 0);
    //                try nbt.Byte.addNamed(writer, "natural", 1);
    //                try nbt.Float.addNamed(writer, "ambient_light", 0);
    //                try nbt.String.addNamed(writer, "infiniburn", "minecraft:infiniburn_overworld");
    //                try nbt.Byte.addNamed(writer, "respawn_anchor_works", 0);
    //                try nbt.Byte.addNamed(writer, "has_skylight", 1);
    //                try nbt.Byte.addNamed(writer, "bed_works", 1);
    //                try nbt.String.addNamed(writer, "effects", "minecraft:overworld");
    //                try nbt.Byte.addNamed(writer, "has_raids", 1);
    //                try nbt.Int.addNamed(writer, "min_y", -64);
    //                try nbt.Int.addNamed(writer, "height", 384);
    //                try nbt.Int.addNamed(writer, "logical_height", 384);
    //                try nbt.Float.addNamed(writer, "coordinate_scale", 1);
    //                try nbt.Byte.addNamed(writer, "ultrawarm", 0);
    //                try nbt.Byte.addNamed(writer, "has_ceiling", 0);
    //            }
    //        }
    //    }
    //    {
    //        try nbt.Compound.startNamed(writer, "minecraft:worldgen/biome");
    //        defer nbt.Compound.end(writer) catch unreachable;

    //        try nbt.String.addNamed(writer, "type", "minecraft:worldgen/biome");
    //        try nbt.List.startNamed(writer, "value", .compound, 1);
    //        {
    //            defer nbt.Compound.end(writer) catch unreachable;
    //            {
    //                try nbt.String.addNamed(writer, "name", "minecraft:ocean");
    //                try nbt.Int.addNamed(writer, "id", 0);
    //                {
    //                    try nbt.Compound.startNamed(writer, "element");
    //                    defer nbt.Compound.end(writer) catch unreachable;

    //                    try nbt.String.addNamed(writer, "precipitation", "rain");
    //                    // this "depth" field in not present in the packet send from
    //                    // a vanilla server, freshly installed (on 1.18.1), despite
    //                    // what the wiki says.
    //                    //try nbt.Float.addNamed(writer, "depth", -1);
    //                    try nbt.Float.addNamed(writer, "temperature", 0.5);
    //                    // same as "depth"
    //                    //try nbt.Float.addNamed(writer, "scale", 0.1);
    //                    try nbt.Float.addNamed(writer, "downfall", 0.5);
    //                    try nbt.String.addNamed(writer, "category", "ocean");
    //                    {
    //                        try nbt.Compound.startNamed(writer, "effects");
    //                        defer nbt.Compound.end(writer) catch unreachable;

    //                        try nbt.Int.addNamed(writer, "sky_color", 8103167);
    //                        try nbt.Int.addNamed(writer, "water_fog_color", 329011);
    //                        try nbt.Int.addNamed(writer, "fog_color", 12638463);
    //                        try nbt.Int.addNamed(writer, "water_color", 4159204);
    //                    }
    //                }
    //            }
    //        }
    //    }
    //}

    //return types.NBT{ .blob = writer.context.getWritten() };
}

// same as overworld element in dimension codec for now
fn genDimensionBlob(allocator: Allocator) !types.NBT {
    const blob = @embedFile("../dimension_blob.nbt")[0..];
    return types.NBT{ .blob = try allocator.dupe(u8, blob) };

    //var buf = try allocator.alloc(u8, 0x4000);
    //const writer = std.io.fixedBufferStream(buf).writer();

    //{
    //    try nbt.Compound.startNamed(writer, "");
    //    defer nbt.Compound.end(writer) catch unreachable;

    //    try nbt.Byte.addNamed(writer, "piglin_safe", 0);
    //    try nbt.Byte.addNamed(writer, "natural", 1);
    //    try nbt.Float.addNamed(writer, "ambient_light", 0);
    //    try nbt.String.addNamed(writer, "infiniburn", "minecraft:infiniburn_overworld");
    //    try nbt.Byte.addNamed(writer, "respawn_anchor_works", 0);
    //    try nbt.Byte.addNamed(writer, "has_skylight", 1);
    //    try nbt.Byte.addNamed(writer, "bed_works", 1);
    //    try nbt.String.addNamed(writer, "effects", "minecraft:overworld");
    //    try nbt.Byte.addNamed(writer, "has_raids", 1);
    //    try nbt.Int.addNamed(writer, "min_y", -64);
    //    try nbt.Int.addNamed(writer, "height", 384);
    //    try nbt.Int.addNamed(writer, "logical_height", 384);
    //    try nbt.Float.addNamed(writer, "coordinate_scale", 1);
    //    try nbt.Byte.addNamed(writer, "ultrawarm", 0);
    //    try nbt.Byte.addNamed(writer, "has_ceiling", 0);
    //}

    //return types.NBT{ .blob = writer.context.getWritten() };
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

    return types.NBT{ .blob = writer.context.getWritten() };
}

fn genSingleChunkSectionDataBlob(allocator: Allocator) ![]u8 {
    var buf = try allocator.alloc(u8, 0x4000);
    const writer = std.io.fixedBufferStream(buf).writer();
    return writer.context.getWritten();

    //// see https://wiki.vg/Chunk_Format#Chunk_Section_structure for more information

    //const block_ids_palette = [_]i32{
    //    0x00, 0x01, 0x09, 0x0a, 0x0e, 0x0f, 0x15, 0x21,
    //};

    //try writer.writeIntBig(i16, 1); // number of non-air blocks
    //{ // block states (paletted container)
    //    try writer.writeByte(8); // bits per entry
    //    { // palette
    //        try types.VarInt.encode(writer, @intCast(i32, block_ids_palette.len));
    //        for (block_ids_palette) |entry| try types.VarInt.encode(writer, entry);
    //    }

    //    const data_array = [_]u8{1} ** (16 * 0x100);
    //    try types.VarInt.encode(writer, @intCast(i32, data_array.len));
    //    for (data_array) |entry| try writer.writeIntBig(u8, entry);
    //}

    //{ // biomes (paletted container)
    //    try writer.writeIntBig(u16, 0x0001); // palette ??
    //    const biomes = [_]u64{1} ** 26;
    //    for (biomes) |entry| try writer.writeIntBig(u64, entry);

    //    //try writer.writeByte(4); // bits per entry
    //    //try types.VarInt.encode(writer, 1); // single value palette (oops! all plains!)
    //    //try types.VarInt.encode(writer, 64); // data array length
    //    //// data array
    //}

    //return writer.context.getWritten();
}
