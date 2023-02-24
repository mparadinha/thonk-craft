//! This struct contains all the actual information about the minecraft
//! world. Block/chunks, player info, entity info.
//! All public functions here can be safely called by multiple threads
//! unless stated otherwise.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const nbt = @import("nbt.zig");
const Chunk = @import("chunk.zig").Chunk;
const ChunkSection = @import("chunk.zig").ChunkSection;
const block_constants = @import("block_constants.zig");

const Self = @This();

//the_chunk: ChunkSection,
the_chunk: Chunk,
mutex: std.Thread.Mutex,
players: std.ArrayList(EntityPos),
allocator: Allocator,

const EntityPos = struct { x: f32, feet_y: f32, z: f32 };

pub fn itemIdToBlockId(item_id: i32) u16 {
    const block_tag = block_constants.item_block_ids[@intCast(usize, item_id)];
    if (block_tag) |tag| {
        const tag_int = @enumToInt(tag);
        const state_info = block_constants.block_states_info[tag_int];
        return @intCast(u16, state_info.default);
    } else unreachable;
}

/// Call `deinit` to cleanup resources.
pub fn init(allocator: Allocator) Self {
    var self = Self{
        .the_chunk = undefined,
        .mutex = std.Thread.Mutex{},
        .players = std.ArrayList(EntityPos).init(allocator),
        .allocator = allocator,
    };
    //self.the_chunk = @import("chunk.zig").newSingleBlockChunkSection(
    //    allocator,
    //    //@enumToInt(BlockId.stone),
    //    1404, // extended piston, facing north
    //) catch unreachable;
    //self.the_chunk = @import("chunk.zig").new16BlockChunkSection(
    //    allocator,
    //    [16]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    //    1,
    //) catch unreachable;
    self.the_chunk = getChunkFromRegionFile("r.0.0.mca", allocator, 0, 0) catch unreachable;

    return self;
}

pub fn deinit(self: *Self) void {
    self.players.deinit();
}

pub fn changeBlock(self: *Self, x: i32, y: i32, z: i32, new_id: u16) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    std.debug.print("changing block @ ({}, {}, {}) to {}\n", .{ x, y, z, new_id });

    const chunk_x = @divFloor(x, 16);
    const chunk_y = @divFloor(y, 16);
    const chunk_z = @divFloor(z, 16);
    std.debug.print("changing block @ chunk_section({}, {}, {})\n", .{ chunk_x, chunk_y, chunk_z });

    const local_x = @intCast(u4, specialMod(x, 16));
    const local_y = @intCast(u4, specialMod(y, 16));
    const local_z = @intCast(u4, specialMod(z, 16));
    std.debug.print("chunk_local block pos ({}, {}, {})\n", .{ local_x, local_y, local_z });

    self.the_chunk.changeBlock(local_x, y, local_z, new_id) catch unreachable;

    // TODO check for redstone block and pistons
}

pub fn encodeChunkSectionData(self: *Self) ![]u8 {
    var buf = try self.allocator.alloc(u8, 0x4000);
    const writer = std.io.fixedBufferStream(buf).writer();

    try self.the_chunk.encode(writer);

    const blob = writer.context.getWritten();
    buf = self.allocator.resize(buf, blob.len).?;
    return blob;
}

pub fn genDimensionCodecBlob(allocator: Allocator) !types.NBT {
    const blob = @import("binary_blobs.zig").witchcraft_dimension_codec_nbt;
    return types.NBT{ .blob = try allocator.dupe(u8, &blob) };
}

// same as overworld element in dimension codec for now
pub fn genDimensionBlob(allocator: Allocator) !types.NBT {
    var buf = try allocator.alloc(u8, 0x4000);
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

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
    std.debug.assert(allocator.resize(buf, blob.len));
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
pub fn genSingleChunkSectionDataBlob(allocator: Allocator, biome_id: u16) ![]u8 {
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
            //try types.VarInt.encode(writer, 1); // plains
            try types.VarInt.encode(writer, biome_id);
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

pub fn fullStoneChunk(allocator: Allocator) ![]u8 {
    var full_data = std.ArrayList(u8).init(allocator);

    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const section_data = try genSingleBlockTypeChunkSection(allocator, 1);
        defer allocator.free(section_data);
        try full_data.appendSlice(section_data);
    }

    return full_data.toOwnedSlice();
}

pub fn genHeightmapSeaLevel(allocator: Allocator) !types.NBT {
    var buf = try allocator.alloc(u8, 0x4000);
    const writer = std.io.fixedBufferStream(buf).writer();

    {
        try nbt.Compound.startNamed(writer, "");
        defer nbt.Compound.end(writer) catch unreachable;

        const array_values = [_]i64{0x7ffefcf9f3e7cf1f} ** 37;
        try nbt.LongArray.addNamed(writer, "MOTION_BLOCKING", &array_values);
    }

    const blob = writer.context.getWritten();
    buf = allocator.resize(buf, blob.len).?;
    return types.NBT{ .blob = blob };
}

pub fn genHeightmapSingleHeight(allocator: Allocator, height: u9) !types.NBT {
    var buf = try allocator.alloc(u8, 0x4000);
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    {
        try nbt.Compound.startNamed(writer, "");
        defer nbt.Compound.end(writer) catch unreachable;

        const one_long =
            (@intCast(u64, height) << 55) |
            (@intCast(u64, height) << 46) |
            (@intCast(u64, height) << 37) |
            (@intCast(u64, height) << 28) |
            (@intCast(u64, height) << 19) |
            (@intCast(u64, height) << 10) |
            (@intCast(u64, height) << 1);
        var array_values: [37]i64 = undefined;
        for (&array_values) |*value| value.* = @bitCast(i64, one_long);

        try nbt.LongArray.addNamed(writer, "MOTION_BLOCKING", &array_values);
    }

    const blob = writer.context.getWritten();
    std.debug.assert(allocator.resize(buf, blob.len));
    return types.NBT{ .blob = blob };
}

pub fn specialMod(n: i32, comptime mod: comptime_int) u32 {
    const rem = @rem(n, mod);
    if (rem < 0) {
        return @intCast(u32, mod + rem);
    } else {
        return @intCast(u32, rem);
    }
}

test "specialMod" {
    const expect = std.testing.expect;
    try expect(specialMod(-1, 16) == 15);
    try expect(specialMod(-16, 16) == 0);
}

pub fn getChunkFromRegionFile(
    filename: []const u8,
    allocator: Allocator,
    chunk_x: i32,
    chunk_z: i32,
) !Chunk {
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const file_bytes = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_bytes);
    const location_table: []const u8 = file_bytes[0..0x1000];

    const table_offset = (specialMod(chunk_x, 32) + specialMod(chunk_z, 32) * 32) * 4;
    const loc_start = 0x1000 * (@intCast(u32, location_table[table_offset + 0]) << 16 |
        @intCast(u32, location_table[table_offset + 1]) << 8 |
        @intCast(u32, location_table[table_offset + 2]));
    const loc_size = 0x1000 * @intCast(u32, location_table[3]);

    const chunk_data: []const u8 = file_bytes[loc_start .. loc_start + loc_size];
    const compression_type = chunk_data[4];
    // TODO: gzip isn't used anymore by the official server but we should still accept it
    //       or at least error out instead of asserting here
    std.debug.assert(compression_type == 2); // zlib

    const zlib_data = chunk_data[5..];
    var zlib_data_stream = std.io.fixedBufferStream(zlib_data);
    var zlib_stream = try std.compress.zlib.zlibStream(allocator, zlib_data_stream.reader());
    defer zlib_stream.deinit();
    const decomp_data = try zlib_stream.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(decomp_data);

    //const reader = std.io.fixedBufferStream(decomp_data).reader();
    //const chunk = try Chunk.fromNBT(reader, allocator);
    const dump_file = try std.fs.cwd().createFile("chunk_data.nbt", .{});
    defer dump_file.close();
    _ = try dump_file.write(decomp_data);
    const chunk = try @import("chunk.zig").loadFromNBT(decomp_data, allocator);
    return chunk;
}
