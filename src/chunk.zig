const std = @import("std");
const Allocator = std.mem.Allocator;

const nbt = @import("nbt.zig");
const types = @import("types.zig");
const block_constants = @import("block_constants.zig");

pub const Chunk = struct {
    data_version: i32,
    /// global chunk coordinates
    xpos: i32,
    zpos: i32,
    /// lowest y chunk section in this chunk (-4 in 1.18)
    ypos: i32,
    status: GenerationStatus,
    last_update: i64,
    /// sum of all ticks spent in this chunk by all players (cumulative)
    inhabited_time: i64,

    /// 24 in the overworld, 16 in the nether and end
    sections: []ChunkSection,

    // TODO: block entities, heightmaps, fluid ticks, block ticks, structures

    // TODO all the things that are only used while generating the chunk

    pub const GenerationStatus = enum {
        empty,
        structure_starts,
        structure_references,
        biomes,
        noise,
        surface,
        carvers,
        liquid_carvers,
        features,
        light,
        spawn,
        heightmaps,
        full,
    };

    /// `x` and `z` are chunk relative coords (i.e. 0-15)
    pub fn getBlock(self: *Chunk, x: u4, y: i32, z: u4) u16 {
        const section_idx = @intCast(usize, @divFloor(y, 16) - self.ypos);
        const section_y = @intCast(u4, @import("WorldState.zig").specialMod(y, 16));
        return self.sections[section_idx].getBlock(x, section_y, z);
    }

    /// `x` and `z` are chunk relative coords (i.e. 0-15)
    pub fn changeBlock(self: *Chunk, x: u4, y: i32, z: u4, new_block: u16) !void {
        const section_idx = @intCast(usize, @divFloor(y, 16) - self.ypos);
        const section_y = @intCast(u4, @import("WorldState.zig").specialMod(y, 16));
        try self.sections[section_idx].changeBlock(x, section_y, z, new_block);
    }

    pub fn makeIntoPacketFormat(self: Chunk, allocator: Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 0xa0000); // 640KB. ought to be enough :)

        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        for (self.sections) |section| try section.encode(writer);

        const blob = writer.context.getWritten();
        std.debug.assert(allocator.resize(buf, blob.len));
        return buf;
    }
};

pub fn loadFromNBT(nbt_data: []const u8, allocator: Allocator) !Chunk {
    var chunk: Chunk = undefined;

    var stream = nbt.TokenStream.init(nbt_data);
    var token = try stream.next();
    expectToken(token.?, .compound);

    token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        const tag = std.meta.activeTag(tk.data);
        if (tag == .end) break;

        if (std.mem.eql(u8, tk.name.?, "DataVersion")) {
            chunk.data_version = tk.data.int;
        } else if (std.mem.eql(u8, tk.name.?, "xPos")) {
            chunk.xpos = tk.data.int;
        } else if (std.mem.eql(u8, tk.name.?, "zPos")) {
            chunk.zpos = tk.data.int;
        } else if (std.mem.eql(u8, tk.name.?, "yPos")) {
            chunk.ypos = tk.data.int;
        } else if (std.mem.eql(u8, tk.name.?, "Status")) {
            const status = tk.data.string;
            chunk.status = std.meta.stringToEnum(Chunk.GenerationStatus, status) orelse unreachable;
        } else if (std.mem.eql(u8, tk.name.?, "LastUpdate")) {
            chunk.last_update = tk.data.long;
        } else if (std.mem.eql(u8, tk.name.?, "InhabitedTime")) {
            chunk.inhabited_time = tk.data.long;
        } else if (std.mem.eql(u8, tk.name.?, "sections")) {
            chunk.sections = try allocator.alloc(ChunkSection, tk.data.list.len);
            for (chunk.sections) |*section| section.* = try loadSection(&stream, allocator);
        } else {
            std.debug.print("unknown entry in chunk nbt: '{s}'. skipping\n", .{tk.name orelse "<null>"});
            try stream.skip(tk);
        }
    }

    return chunk;
}

fn loadSection(stream: *nbt.TokenStream, allocator: Allocator) !ChunkSection {
    var section = try ChunkSection.init(allocator);

    var token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        const tag = std.meta.activeTag(tk.data);
        if (tag == .end) break;

        if (std.mem.eql(u8, tk.name.?, "Y")) {
            // we don't need this for anything, as far as I can tell
            try stream.skip(tk);
        } else if (std.mem.eql(u8, tk.name.?, "block_states")) {
            var inner_token = try stream.next();
            while (inner_token) |inner_tk| : (inner_token = try stream.next()) {
                const inner_tag = std.meta.activeTag(inner_tk.data);
                if (inner_tag == .end) break;
                if (std.mem.eql(u8, inner_tk.name.?, "palette")) {
                    const palette = try allocator.alloc(u16, inner_tk.data.list.len);
                    for (palette) |*block| block.* = try loadBlockState(stream);
                    section.block_palette = std.ArrayList(u16).fromOwnedSlice(allocator, palette);
                    section.bits_per_block = section.bitsPerBlockNeeded();
                } else if (std.mem.eql(u8, inner_tk.name.?, "data")) {
                    try section.packed_block_data.ensureTotalCapacity(inner_tk.data.long_array.len);
                    const elems = try inner_tk.data.long_array.getElemsAlloc(allocator);
                    defer allocator.free(elems);
                    for (elems) |elem| {
                        section.packed_block_data.append(@bitCast(u64, elem)) catch unreachable;
                    }
                } else {
                    std.debug.print("unknown entry in block_states nbt: '{s}'. skipping\n", .{inner_tk.name orelse "<null>"});
                    try stream.skip(tk);
                }
            }
        } else if (std.mem.eql(u8, tk.name.?, "biomes")) {
            try loadBiomes(stream, allocator, &section.biome_palette, &section.packed_biome_data);
        } else {
            std.debug.print("unknown entry in section nbt: '{s}'. skipping\n", .{tk.name orelse "<null>"});
            try stream.skip(tk);
        }
    }

    return section;
}

/// assumes these lists have been initialized
fn loadBiomes(
    stream: *nbt.TokenStream,
    allocator: Allocator,
    palette_list: *std.ArrayList(u16),
    packed_data_list: *std.ArrayList(u64),
) !void {
    _ = allocator;
    _ = packed_data_list;

    var token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        const tag = std.meta.activeTag(tk.data);
        if (tag == .end) break;

        if (std.mem.eql(u8, tk.name.?, "palette")) {
            std.debug.assert(tk.data.list.tag == .string);
            try palette_list.resize(tk.data.list.len);
            for (palette_list.items) |*entry| {
                const inner_tk = try stream.nextNameless(tk);
                const biome_name = inner_tk.?.data.string;
                entry.* = translateBiomeResourceLocation(biome_name);
            }
        } else if (std.mem.eql(u8, tk.name.?, "data")) {
            std.debug.print("TODO biome packed data\n", .{});
            try stream.skip(tk);
        } else unreachable;
    }
}

fn translateBiomeResourceLocation(name: []const u8) u16 {
    const Biome = enum(u8) {
        the_void,
        plains,
        sunflower_plains,
        snowy_plains,
        ice_spikes,
        desert,
        swamp,
        forest,
        flower_forest,
        birch_forest,
        dark_forest,
        old_growth_birch_forest,
        old_growth_pine_taiga,
        old_growth_spruce_taiga,
        taiga,
        snowy_taiga,
        savanna,
        savanna_plateu,
        windswept_hills,
        windswept_gravelly_hills,
        windswept_forest,
        windswept_savanna,
        jungle,
        sparse_jungle,
        bamboo_jungle,
        badlands,
        eroded_badlands,
        wooded_badlands,
        meadow,
        grove,
        snowy_slopes,
        frozen_peaks,
        jagged_peaks,
        stony_peaks,
        river,
        frozen_river,
        beach,
        snowy_beach,
        stony_shore,
        warm_ocean,
        lukewarm_ocean,
        deep_lukewarm_ocean,
        ocean,
        deep_ocean,
        cold_ocean,
        deep_cold_ocean,
        frozen_ocean,
        deep_frozen_ocean,
        mushroom_fields,
        dripstone_caves,
        lush_caves,
        nether_wastes,
        warped_forest,
        crimson_forest,
        soul_sand_valley,
        basalt_deltas,
        the_end,
        end_highlands,
        end_midlands,
        small_end_islands,
        end_barrens,
    };
    std.debug.assert(std.mem.eql(u8, name[0..10], "minecraft:"));
    const loc = name[10..];
    const biome = std.meta.stringToEnum(Biome, loc);
    if (biome) |id| {
        return @enumToInt(id);
    } else {
        std.debug.print("missing Biome for '{s}'\n", .{name});
        return 0;
    }
}

fn loadBlockState(stream: *nbt.TokenStream) !u16 {
    var name: ?[]const u8 = null;
    var properties_buf: [10]block_constants.BlockProperty = undefined;
    var properties_n: usize = 0;

    var token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        const tag = std.meta.activeTag(tk.data);
        if (tag == .end) break;

        if (std.mem.eql(u8, tk.name.?, "Name")) {
            name = tk.data.string;
        } else if (std.mem.eql(u8, tk.name.?, "Properties")) {
            var inner_token = try stream.next();
            while (inner_token) |inner_tk| : (inner_token = try stream.next()) {
                const inner_tag = std.meta.activeTag(inner_tk.data);
                if (inner_tag == .end) break;
                expectToken(inner_tk, .string);
                var prop_name = inner_tk.name.?;
                var prop_value = inner_tk.data.string;
                properties_buf[properties_n] = .{ .name = prop_name, .value = prop_value };
                properties_n += 1;
            }
        } else unreachable;
    }

    return translateBlockResourceLocation(name.?, properties_buf[0..properties_n]);
}

fn translateBlockResourceLocation(name: []const u8, properties: []block_constants.BlockProperty) u16 {
    std.debug.assert(std.mem.eql(u8, name[0..10], "minecraft:"));
    const loc = name[10..];
    @setEvalBranchQuota(2_000);
    const block_tag = std.meta.stringToEnum(block_constants.BlockTag, loc);
    if (block_tag) |tag| {
        const state = block_constants.stateFromPropertyList(tag, properties);
        return block_constants.idFromState(state);
    } else {
        std.debug.print("missing BlockTag for '{s}'\n", .{name});
        return block_constants.idFromState(.{ .air = {} });
    }
}

pub fn expectToken(token: nbt.Token, tag: nbt.Tag) void {
    const active = std.meta.activeTag(token.data);
    if (active != tag) {
        std.debug.panic("expected {}, got {} (token.name='{s}')\n", .{ active, tag, token.name orelse "<null>" });
    }
}

pub fn newSingleBlockChunkSection(allocator: Allocator, block_id: u16) !ChunkSection {
    var chunk_section = ChunkSection.init(allocator);
    try chunk_section.block_palette.append(block_id);
    return chunk_section;
}

pub fn new16BlockChunkSection(allocator: Allocator, block_ids: [16]u16, fill_block_idx: u4) !ChunkSection {
    var chunk_section = try ChunkSection.init(allocator);

    try chunk_section.block_palette.appendSlice(&block_ids);

    const two = (@intCast(u8, fill_block_idx) << 4) | @intCast(u8, fill_block_idx);
    const four = (@intCast(u16, two) << 8) | @intCast(u16, two);
    const eight = (@intCast(u32, four) << 16) | @intCast(u32, four);
    const packed_long = (@intCast(u64, eight) << 32) | @intCast(u64, eight);
    try chunk_section.packed_block_data.appendNTimes(packed_long, 256);

    chunk_section.bits_per_block = 4;

    return chunk_section;
}

/// keeps the data in the same u64 packed format that we send over the network
/// because it takes less memory (and to not waste time converting back and forth)
pub const ChunkSection = struct {
    bits_per_block: u4,
    block_palette: std.ArrayList(u16),
    packed_block_data: std.ArrayList(u64),
    biome_palette: std.ArrayList(u16),
    packed_biome_data: std.ArrayList(u64),

    allocator: Allocator,

    /// Call `deinit` to free up resources
    pub fn init(allocator: Allocator) !ChunkSection {
        var self = ChunkSection{
            .bits_per_block = 0,
            .block_palette = std.ArrayList(u16).init(allocator),
            .packed_block_data = std.ArrayList(u64).init(allocator),
            .biome_palette = std.ArrayList(u16).init(allocator),
            .packed_biome_data = std.ArrayList(u64).init(allocator),
            .allocator = allocator,
        };
        try self.biome_palette.append(1);
        return self;
    }

    pub fn deinit(self: *ChunkSection) void {
        self.block_palette.deinit();
        self.packed_block_data.deinit();
        if (self.biome_palette.len != 0) self.allocator.free(self.biome_palette);
        if (self.packed_biome_data.len != 0) self.allocator.free(self.packed_biome_data);
    }

    /// How many bits we need to encode all the different values in the palette.
    /// If we're in the middle of re-packing the packed data (because the palette
    /// grew, for e.g.) this will not be value that correctly un-packs the data that
    /// is currently in the `packed_block_data` field. For that use the `bits_per_block` field.
    fn bitsPerBlockNeeded(self: ChunkSection) u4 {
        return palettedContainerBitsPerBlock(self.block_palette.items);
    }

    /// `x`, `y` and `z` are chunk section relative block coordinates
    pub fn getBlock(self: ChunkSection, x: u4, y: u4, z: u4) u16 {
        std.debug.assert(self.bits_per_block == self.bitsPerBlockNeeded());

        if (self.bits_per_block == 0) {
            if (self.block_palette.items.len == 0) return 0; // air
            return self.block_palette.items[0];
        }

        const blocks_per_long = 64 / @intCast(u8, self.bits_per_block);
        const block_idx = x + (@intCast(usize, z) * 16) + (@intCast(usize, y) * 16 * 16);
        const idx_in_long = block_idx % blocks_per_long;
        const shift_len = @intCast(u6, idx_in_long * self.bits_per_block);

        const unused_bitlen = @intCast(u6, 64 - @intCast(u8, self.bits_per_block));
        const mask = (~@as(u64, 0)) >> unused_bitlen;

        const long = self.packed_block_data.items[block_idx / blocks_per_long];
        const palette_idx = (long >> shift_len) & mask;
        return self.block_palette.items[palette_idx];
    }

    /// `x`, `y` and `z` are chunk section relative block coordinates
    // TODO: make this function thread safe?
    pub fn changeBlock(self: *ChunkSection, x: u4, y: u4, z: u4, new_block: u16) !void {
        if (self.block_palette.items.len == 1 and new_block == self.block_palette.items[0]) return;
        const palette_idx = try self.getOrInsertPaletteEntry(new_block);
        if (self.bitsPerBlockNeeded() > self.bits_per_block) try self.rebuildPackedData();

        const blocks_per_long = 64 / @intCast(u8, self.bits_per_block);
        const block_idx = x + (@intCast(usize, z) * 16) + (@intCast(usize, y) * 16 * 16);
        const idx_in_long = block_idx % blocks_per_long;
        const shift_len = @intCast(u6, idx_in_long * self.bits_per_block);

        const shifted_block = @intCast(u64, palette_idx) << shift_len;
        const unused_bitlen = @intCast(u6, 64 - @intCast(u8, self.bits_per_block));
        const mask = ~(((~@as(u64, 0)) >> unused_bitlen) << shift_len);

        const long = self.packed_block_data.items[block_idx / blocks_per_long];
        const new_long = (long & mask) | shifted_block;
        self.packed_block_data.items[block_idx / blocks_per_long] = new_long;
    }

    fn rebuildPackedData(self: *ChunkSection) !void {
        std.debug.print("rebuild packed data (bits_per_block: {d} -> {d}\n", .{ self.bits_per_block, self.bitsPerBlockNeeded() });
        // unpack all the block data into this array
        var unpacked_data = [_]u16{0} ** 4096;
        if (self.bits_per_block == 0 and self.block_palette.items.len != 0) {
            // all the block are the 0th index in the palette
        } else {
            const blocks_per_long = 64 / @intCast(u8, self.bits_per_block);
            const unused_bitlen = @intCast(u6, 64 - @intCast(u8, self.bits_per_block));
            const mask = (~@as(u64, 0)) >> unused_bitlen;
            for (unpacked_data) |*data, i| {
                const idx_in_long = i % blocks_per_long;
                const shift_len = @intCast(u6, idx_in_long * self.bits_per_block);
                const long = self.packed_block_data.items[i / blocks_per_long];
                data.* = @intCast(u16, (long >> shift_len) & mask);
            }
        }

        self.bits_per_block = self.bitsPerBlockNeeded();

        // repack all the blocks now with the new bits_per_block packing
        const blocks_per_long = 64 / @intCast(u8, self.bits_per_block);
        const longs_needed = std.math.ceil(4096 / @intToFloat(f32, blocks_per_long));
        try self.packed_block_data.resize(@floatToInt(usize, longs_needed));
        for (unpacked_data) |data, i| {
            const idx_in_long = i % blocks_per_long;
            const shift_len = @intCast(u6, idx_in_long * self.bits_per_block);

            const shifted_block = @intCast(u64, data) << shift_len;
            const unused_bitlen = @intCast(u6, 64 - @intCast(u8, self.bits_per_block));
            const mask = ~(((~@as(u64, 0)) >> unused_bitlen) << shift_len);

            const long = self.packed_block_data.items[i / blocks_per_long];
            const new_long = (long & mask) | shifted_block;
            self.packed_block_data.items[i / blocks_per_long] = new_long;
        }
    }

    /// Return the index in the palette that corresponds to this block id.
    /// Inserts a new item in the palette if it's a new block id.
    fn getOrInsertPaletteEntry(self: *ChunkSection, block_id: u16) !usize {
        for (self.block_palette.items) |entry, i| {
            if (entry == block_id) return i;
        } else {
            try self.block_palette.append(block_id);
            return self.block_palette.items.len - 1;
        }
    }

    /// Encode this chunk section data into the format that is sent over the network
    pub fn encode(self: ChunkSection, writer: anytype) !void {
        // TODO actually keep track of the non air blocks.
        try writer.writeIntBig(i16, 4096); // number of non-air blocks

        try encodePalettedContainer(writer, self.block_palette.items, self.packed_block_data.items);
        try encodePalettedContainer(writer, self.biome_palette.items, self.packed_biome_data.items);

        // chunk created w/ `new16BlockChunkSection` needs this to render in. why? dunno
        //// as far as I can tell the equivalent of the block id global palette for biomes
        //// is the dimension codec, sent in the "join game" packet.
        //// entries in the "minecraft:worldgen/biome" part of that NBT data have an 'id'
        //// field. the biome palette for chunk sections maps to these 'id's.
        //{ // biomes (paletted container)
        //    try writer.writeByte(0); // bits per block
        //    // palette
        //    try types.VarInt.encode(writer, 1); // plains
        //    // biome data
        //    const biomes = [_]u64{0x0000_0000_0000_0001} ** 26; // why 26???
        //    for (biomes) |entry| try writer.writeIntBig(u64, entry);
        //}
    }
};

fn palettedContainerBitsPerBlock(palette: []u16) u4 {
    if (palette.len <= 1) return 0;
    var n_bits: u4 = 4;
    while ((@as(usize, 1) << n_bits) < palette.len) n_bits += 1;
    return n_bits;
}

fn encodePalettedContainer(writer: anytype, palette: []u16, packed_data: []u64) !void {
    const bits_per_block = palettedContainerBitsPerBlock(palette);

    if (bits_per_block == 0) {
        if (palette.len < 1) @panic("TODO implement full air chunk");
        try writer.writeByte(0); // bits per block
        try types.VarInt.encode(writer, @intCast(i32, palette[0])); // single entry type
        try types.VarInt.encode(writer, 0); // size of data array (empty)
    } else {
        try writer.writeByte(bits_per_block);
        try types.VarInt.encode(writer, @intCast(i32, palette.len));
        for (palette) |entry| try types.VarInt.encode(writer, entry);
        try types.VarInt.encode(writer, @intCast(i32, packed_data.len));
        for (packed_data) |entry| try writer.writeIntBig(u64, entry);
    }
}
