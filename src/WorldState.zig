//! This struct contains all the actual information about the minecraft
//! world. Block/chunks, player info, entity info.
//! All public functions here can be safely called by multiple threads
//! unless stated otherwise.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const nbt = @import("nbt.zig");

const Self = @This();

the_chunk: [4096]BlockId,
mutex: std.Thread.Mutex,
players: std.ArrayList(EntityPos),
allocator: Allocator,

const BlockId = enum(u15) {
    air = 0,
    stone = 1,
    dirt = 10,
    glass = 106,
};

const EntityPos = struct { x: f32, feet_y: f32, z: f32 };

/// Call `deinit` to cleanup resources.
pub fn init(allocator: Allocator) Self {
    return Self{
        .the_chunk = [_]BlockId{.stone} ** 4096,
        .mutex = std.Thread.Mutex{},
        .players = std.ArrayList(EntityPos).init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.players.deinit();
}

/// `x`, `y` and `z` are the block coords relative to the chunk section
pub fn removeBlock(self: *Self, x: u4, y: u4, z: u4) void {
    std.debug.print("removing block @ ({}, {}, {})\n", .{ x, y, z });
    self.changeBlock(x, y, z, BlockId.air);
}

/// `x`, `y` and `z` are the block coords relative to the chunk section
pub fn changeBlock(self: *Self, x: u4, y: u4, z: u4, new_id: BlockId) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const idx = @intCast(usize, y) * 256 + @intCast(usize, z) * 16 + @intCast(usize, x);
    self.the_chunk[idx] = new_id;
}

pub fn encodeChunkSectionData(self: *Self) ![]u8 {
    var buf = try self.allocator.alloc(u8, 0x4000);
    const writer = std.io.fixedBufferStream(buf).writer();

    const blocks = self.the_chunk;

    // TODO: use the smaller encodings when the chunk has less at most
    // 16 different block types, or if its all the same block

    var block_ids_palette = std.ArrayList(i32).init(self.allocator);
    defer block_ids_palette.deinit();

    var chunk_blocks = std.ArrayList(u8).init(self.allocator);
    defer chunk_blocks.deinit();

    var air_count: u16 = 0;
    for (blocks) |block_id| {
        if (block_id == .air) air_count += 1;
        const global_id = @intCast(i32, @enumToInt(block_id));
        const palette_idx = idx: {
            for (block_ids_palette.items) |id, i| {
                if (id == global_id) break :idx i;
            }
            try block_ids_palette.append(global_id);
            break :idx block_ids_palette.items.len - 1;
        };
        try chunk_blocks.append(@intCast(u8, palette_idx));
    }

    try writer.writeIntBig(i16, @intCast(i16, blocks.len - air_count)); // number of non-air blocks
    { // block states (paletted container)
        try writer.writeByte(8); // bits per block

        // palette
        try types.VarInt.encode(writer, @intCast(i32, block_ids_palette.items.len));
        for (block_ids_palette.items) |entry| try types.VarInt.encode(writer, entry);

        // chunk block data
        const data_array_len = chunk_blocks.items.len * @sizeOf(u8) / @sizeOf(u64);
        try types.VarInt.encode(writer, @intCast(i32, data_array_len));
        std.debug.assert(chunk_blocks.items.len % 8 == 0);
        var i: usize = 0;
        while (i < chunk_blocks.items.len) : (i += 8) {
            const uint: u64 =
                @intCast(u64, chunk_blocks.items[i]) |
                @intCast(u64, chunk_blocks.items[i + 1]) << 8 |
                @intCast(u64, chunk_blocks.items[i + 2]) << 16 |
                @intCast(u64, chunk_blocks.items[i + 3]) << 24 |
                @intCast(u64, chunk_blocks.items[i + 4]) << 32 |
                @intCast(u64, chunk_blocks.items[i + 5]) << 40 |
                @intCast(u64, chunk_blocks.items[i + 6]) << 48 |
                @intCast(u64, chunk_blocks.items[i + 7]) << 56;
            try writer.writeIntBig(u64, uint);
        }
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
