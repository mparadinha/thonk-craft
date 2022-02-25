const std = @import("std");
const Allocator = std.mem.Allocator;
const StreamServer = std.net.StreamServer;
const Connection = StreamServer.Connection;

const types = @import("types.zig");
const nbt = @import("nbt.zig");
const client_packets = @import("client_packets.zig");
const ClientPacket = client_packets.Packet;
const server_packets = @import("server_packets.zig");
const ServerPacket = server_packets.Packet;
const Session = @import("Session.zig");

pub const State = enum(u8) {
    /// All connection start in this state. Not part of the protocol.
    handshaking,

    status = 1,
    login = 2,
    play = 3,

    /// Not part of the protocol, used to signal that we're meant to close the connection.
    close_connection,
};

/// contains all global state of the server. info on player connections, as well as the actual
/// minecraft world data
pub const ServerState = struct {
    world_state: WorldState,
};

pub const EntityPos = struct { x: f32, feet_y: f32, z: f32 };

/// all the actual 'stuff' in a minecraft world. player info, block/chunks info, etc.
/// note: don't modify directly, use member functions to be thread-safe
pub const WorldState = struct {
    the_chunk: [4096]BlockId,
    mutex: std.Thread.Mutex,
    players: std.ArrayList(EntityPos),

    /// `x`, `y` and `z` are the block coords relative to the chunk section
    pub fn changeBlock(self: *WorldState, x: u4, y: u4, z: u4, new_id: BlockId) void {
        self.mutex.lock();
        defer self.mutex.release();
        self.the_chunk[y * 64 + z * 16 + x] = new_id;
    }

    pub fn removeBlock(self: *WorldState, x: u4, y: u4, z: u4) void {
        self.changeBlock(x, y, z, BlockId.air);
    }
};

const BlockId = enum(u15) {
    air = 0,
    stone = 1,
    dirt = 10,
    glass = 106,
};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var world_state = WorldState{
        .the_chunk = [_]BlockId{.stone} ** 4096,
        .mutex = std.Thread.Mutex{},
        .players = std.ArrayList(EntityPos).init(gpa),
    };
    defer {
        world_state.players.deinit();
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

    while (true) {
        std.debug.print("waiting for connection...\n", .{});
        const connection = try server.accept();
        std.debug.print("connection: {}\n", .{connection});

        const thread = try std.Thread.spawn(.{}, Session.start, .{ connection, gpa, &world_state });
        thread.detach();
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
pub fn sendPacketData(connection: Connection, data: anytype) !void {
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

fn sendPacket(connection: Connection, packet: ServerPacket) !void {
    const inner_tag_name = switch (packet) {
        .status => |data| @tagName(data),
        .login => |data| @tagName(data),
        .play => |data| @tagName(data),
    };
    std.debug.print("sending a {s}::{s} packet... ", .{ @tagName(packet), inner_tag_name });
    try packet.encode(connection.stream.writer());
    std.debug.print("done.\n", .{});
}

pub fn genDimensionCodecBlob(allocator: Allocator) !types.NBT {
    const blob = @import("binary_blobs.zig").witchcraft_dimension_codec_nbt;
    return types.NBT{ .blob = try allocator.dupe(u8, &blob) };
}

// same as overworld element in dimension codec for now
pub fn genDimensionBlob(allocator: Allocator) !types.NBT {
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

pub fn genHeighmapBlob(allocator: Allocator) !types.NBT {
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
pub fn genSingleChunkSectionDataBlob(allocator: Allocator) ![]u8 {
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
        const data_array = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } ** (0x100);
        // `data array length` is the number of *longs* in the array
        const data_array_len = @sizeOf(@TypeOf(data_array)) / @sizeOf(u64);
        //try types.VarInt.encode(writer, @intCast(i32, 0x200)); // 0x200=8004 ???? (not 0x1000??)
        try types.VarInt.encode(writer, @intCast(i32, data_array_len));
        for (data_array) |entry| try writer.writeIntBig(u8, entry);
    }

    // as far as I can tell the equivalent of the block id global palette for biomes
    // is the dimension codec, sent in the "join game" packet.
    // entries in the "minecraft:worldgen/biome" part of that NBT data have an 'id'
    // field. the biome palette for chunk sections maps to these 'id's.
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

pub fn genSingleBlockTypeChunkSection(allocator: Allocator, global_palette_block_id: u15) ![]u8 {
    var buf = try allocator.alloc(u8, 0x4000);
    const writer = std.io.fixedBufferStream(buf).writer();

    if (global_palette_block_id == 0x00) @panic("if the chunk is all air, just don't send it");

    try writer.writeIntBig(i16, 0x1000); // number of non-air blocks
    { // block states (paletted container)
        try writer.writeByte(0); // bits per block
        { // palette
            try types.VarInt.encode(writer, @intCast(i32, global_palette_block_id));
            try types.VarInt.encode(writer, 0); // data entries
        }
    }
    { // biomes (paletted container)
        try writer.writeByte(0); // bits per block
        { // palette
            //try types.VarInt.encode(writer, 1); // plains
            try types.VarInt.encode(writer, 2);
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
