const std = @import("std");
const Allocator = std.mem.Allocator;

const nbt = @import("nbt.zig");
const types = @import("types.zig");

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

    sections: []Section,

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

    pub const Section = struct {
        ypos: i8,
        block_states: Palette(BlockState),
        biomes: Palette(Biome),
        /// amount of block-emitted light for each block. (4 bits per block)
        block_light: [2048]u8,
        /// amount of sun/moonlight hitting each block. (4 bits per block)
        sky_light: [2048]u8,
    };

    pub const BlockState = struct {
        name: []u8,
        properties: []struct {
            name: []u8,
            value: []u8,
        },
    };

    pub const Biome = struct {
        name: []const u8,
    };

    pub const ParseError = error{ InvalidNBT, MalformedNBT };

    fn readTag(reader: anytype) !nbt.Tag {
        const byte = try reader.readByte();
        return std.meta.intToEnum(nbt.Tag, byte) catch return ParseError.MalformedNBT;
    }

    const NamedTag = struct {
        tag: nbt.Tag,
        name: []u8,

        pub fn read(reader: anytype, allocator: Allocator) !NamedTag {
            const tag = try readTag(reader);
            if (tag == .end) return NamedTag{ .tag = tag, .name = "" };
            return NamedTag{
                .tag = tag,
                .name = try readString(reader, allocator),
            };
        }
    };

    /// if the thing you're skipping is named make sure to read that name before calling this.
    fn skipTag(reader: anytype, tag: nbt.Tag) anyerror!void {
        switch (tag) {
            .end => unreachable,
            .byte => try reader.skipBytes(1, .{}),
            .short => try reader.skipBytes(2, .{}),
            .int => try reader.skipBytes(4, .{}),
            .long => try reader.skipBytes(8, .{}),
            .float => try reader.skipBytes(4, .{}),
            .double => try reader.skipBytes(8, .{}),
            .byte_array => {
                const array_len = @intCast(usize, try reader.readIntBig(i32));
                try reader.skipBytes(array_len * 1, .{});
            },
            .string => {
                const string_len = @intCast(usize, try reader.readIntBig(u16));
                try reader.skipBytes(string_len, .{});
            },
            .list => {
                const elem_tag = try readTag(reader);
                const list_len = @intCast(usize, try reader.readIntBig(i32));
                var i: usize = 0;
                while (i < list_len) : (i += 1) try skipTag(reader, elem_tag);
            },
            .compound => {
                while (true) {
                    const entry_tag = try readTag(reader);
                    if (entry_tag == .end) break;
                    try skipTag(reader, .string);
                    try skipTag(reader, entry_tag);
                }
            },
            .int_array => {
                const array_len = @intCast(usize, try reader.readIntBig(i32));
                try reader.skipBytes(array_len * 4, .{});
            },
            .long_array => {
                const array_len = @intCast(usize, try reader.readIntBig(i32));
                try reader.skipBytes(array_len * 8, .{});
            },
        }
    }

    fn readString(reader: anytype, allocator: Allocator) ![]u8 {
        const str_len = try reader.readIntBig(u16);
        var string = try allocator.alloc(u8, str_len);
        _ = try reader.read(string);
        return string;
    }

    fn readBlock(reader: anytype, allocator: Allocator) !BlockState {
        var block: BlockState = undefined;
        while (true) {
            const entry = try NamedTag.read(reader, allocator);
            if (entry.tag == .end) break;

            if (std.mem.eql(u8, entry.name, "Name")) {
                if (entry.tag != .string) return ParseError.InvalidNBT;
                block.name = try readString(reader, allocator);
            } else if (std.mem.eql(u8, entry.name, "Properties")) {
                if (entry.tag != .compound) return ParseError.InvalidNBT;
                const Property = std.meta.Child(@TypeOf(block.properties));
                var properties = std.ArrayList(Property).init(allocator);
                while (true) {
                    const property_entry = try NamedTag.read(reader, allocator);
                    if (property_entry.tag == .end) break;
                    if (property_entry.tag != .string) return ParseError.InvalidNBT;
                    const property = Property{
                        .name = property_entry.name,
                        .value = try readString(reader, allocator),
                    };
                    try properties.append(property);
                }
                block.properties = properties.toOwnedSlice();
            } else {
                std.debug.print("unknow entry in Block NBT: '{s}'. skipping\n", .{entry.name});
                try skipTag(reader, entry.tag);
            }
        }
        return block;
    }

    fn readBiome(reader: anytype, allocator: Allocator) !Biome {
        var biome: Biome = undefined;
        while (true) {
            const entry = try NamedTag.read(reader, allocator);
            if (entry.tag == .end) break;

            if (std.mem.eql(u8, entry.name, "Name")) {
                if (entry.tag != .string) return ParseError.InvalidNBT;
                biome.name = try readString(reader, allocator);
            } else {
                std.debug.print("unknow entry in Biome NBT: '{s}'. skipping\n", .{entry.name});
                try skipTag(reader, entry.tag);
            }
        }
        return biome;
    }

    fn readPalettedContainer(
        comptime InnerType: type,
        reader: anytype,
        allocator: Allocator,
    ) !Palette(InnerType) {
        var container: Palette(InnerType) = undefined;
        while (true) {
            const entry = try NamedTag.read(reader, allocator);
            if (entry.tag == .end) break;

            if (std.mem.eql(u8, entry.name, "palette")) {
                if (entry.tag != .list) return ParseError.InvalidNBT;
                const list_tag = try readTag(reader);
                const list_len = try reader.readIntBig(i32);
                container.palette = try allocator.alloc(InnerType, @intCast(usize, list_len));
                switch (InnerType) {
                    BlockState => {
                        if (list_tag != .compound) return ParseError.InvalidNBT;
                        for (container.palette) |*palette_entry| {
                            palette_entry.* = try readBlock(reader, allocator);
                        }
                    },
                    Biome => {
                        if (list_tag != .string) return ParseError.InvalidNBT;
                        for (container.palette) |*palette_entry| {
                            palette_entry.* = Biome{ .name = try readString(reader, allocator) };
                        }
                    },
                    else => @compileError(@typeName(InnerType)),
                }
            } else if (std.mem.eql(u8, entry.name, "data")) {
                if (entry.tag != .long_array) return ParseError.InvalidNBT;
                const list_len = try reader.readIntBig(i32);
                container.data = try allocator.alloc(u64, @intCast(usize, list_len));
                for (container.data) |*long| long.* = try reader.readIntBig(u64);
            } else {
                std.debug.print(
                    "unknow entry in {s} NBT: '{s}'. skipping\n",
                    .{ @typeName(InnerType), entry.name },
                );
                try skipTag(reader, entry.tag);
            }
        }
        return container;
    }

    fn readSection(reader: anytype, allocator: Allocator) !Section {
        var section: Section = undefined;
        while (true) {
            const entry = try NamedTag.read(reader, allocator);
            if (entry.tag == .end) break;

            if (std.mem.eql(u8, entry.name, "Y")) {
                if (entry.tag != .byte) return ParseError.InvalidNBT;
                section.ypos = try reader.readIntBig(i8);
            } else if (std.mem.eql(u8, entry.name, "block_states")) {
                if (entry.tag != .compound) return ParseError.InvalidNBT;
                section.block_states = try readPalettedContainer(BlockState, reader, allocator);
            } else if (std.mem.eql(u8, entry.name, "biomes")) {
                if (entry.tag != .compound) return ParseError.InvalidNBT;
                section.biomes = try readPalettedContainer(Biome, reader, allocator);
            } else {
                std.debug.print("unknow entry in Section NBT: '{s}'. skipping\n", .{entry.name});
                try skipTag(reader, entry.tag);
            }
        }

        return section;
    }

    pub fn fromNBT(reader: anytype, allocator: Allocator) !Chunk {
        const start_compound = try NamedTag.read(reader, allocator);
        if (start_compound.tag != .compound) return ParseError.MalformedNBT;
        if (start_compound.name.len != 0) return ParseError.InvalidNBT;

        var chunk: Chunk = undefined;

        while (true) {
            const entry = try NamedTag.read(reader, allocator);
            if (entry.tag == .end) break;

            if (std.mem.eql(u8, entry.name, "DataVersion")) {
                if (entry.tag != .int) return ParseError.InvalidNBT;
                chunk.data_version = try reader.readIntBig(i32);
            } else if (std.mem.eql(u8, entry.name, "xPos")) {
                if (entry.tag != .int) return ParseError.InvalidNBT;
                chunk.xpos = try reader.readIntBig(i32);
            } else if (std.mem.eql(u8, entry.name, "zPos")) {
                if (entry.tag != .int) return ParseError.InvalidNBT;
                chunk.zpos = try reader.readIntBig(i32);
            } else if (std.mem.eql(u8, entry.name, "yPos")) {
                if (entry.tag != .int) return ParseError.InvalidNBT;
                chunk.ypos = try reader.readIntBig(i32);
            } else if (std.mem.eql(u8, entry.name, "Status")) {
                if (entry.tag != .string) return ParseError.InvalidNBT;
                const status = try readString(reader, allocator);
                chunk.status = std.meta.stringToEnum(GenerationStatus, status) orelse unreachable;
            } else if (std.mem.eql(u8, entry.name, "LastUpdate")) {
                if (entry.tag != .long) return ParseError.InvalidNBT;
                chunk.last_update = try reader.readIntBig(i64);
            } else if (std.mem.eql(u8, entry.name, "InhabitedTime")) {
                if (entry.tag != .long) return ParseError.InvalidNBT;
                chunk.inhabited_time = try reader.readIntBig(i64);
            } else if (std.mem.eql(u8, entry.name, "sections")) {
                if (entry.tag != .list) return ParseError.InvalidNBT;
                const list_tag = try readTag(reader);
                if (list_tag != .compound) return ParseError.InvalidNBT;
                const list_len = try reader.readIntBig(i32);
                chunk.sections = try allocator.alloc(Section, @intCast(usize, list_len));
                for (chunk.sections) |*section| section.* = try readSection(reader, allocator);
            } else {
                std.debug.print("unknow entry in Chunk NBT: '{s}'. skipping\n", .{entry.name});
                try skipTag(reader, entry.tag);
            }
        }

        return chunk;
    }

    fn resourceLocationToId(resloc: []u8) u15 {
        const Pair = struct { loc: []const u8, id: u15 };
        const map = [_]Pair{
            .{ .loc = "air", .id = 0 },
            .{ .loc = "amethyst_block", .id = 17664 },
            .{ .loc = "amethyst_cluster", .id = 17666 },
            .{ .loc = "bedrock", .id = 33 },
            .{ .loc = "budding_amethyst", .id = 17665 },
            .{ .loc = "calcite", .id = 17715 },
            .{ .loc = "cave_air", .id = 9916 },
            .{ .loc = "cobblestone", .id = 14 },
            .{ .loc = "cobweb", .id = 1397 },
            .{ .loc = "copper_ore", .id = 17818 },
            .{ .loc = "deepslate", .id = 18683 },
            .{ .loc = "deepslate_copper_ore", .id = 17819 },
            .{ .loc = "deepslate_diamond_ore", .id = 3411 },
            .{ .loc = "deepslate_gold_ore", .id = 70 },
            .{ .loc = "deepslate_iron_ore", .id = 72 },
            .{ .loc = "deepslate_lapis_ore", .id = 264 },
            .{ .loc = "deepslate_redstone_ore", .id = 3954 },
            .{ .loc = "diorite", .id = 4 },
            .{ .loc = "dirt", .id = 10 },
            .{ .loc = "glow_lichen", .id = 4893 },
            .{ .loc = "granite", .id = 2 },
            .{ .loc = "gravel", .id = 68 },
            .{ .loc = "iron_ore", .id = 71 },
            .{ .loc = "mossy_cobblestone", .id = 1489 },
            .{ .loc = "oak_fence", .id = 4035 },
            .{ .loc = "oak_planks", .id = 15 },
            .{ .loc = "rail", .id = 3702 },
            .{ .loc = "seagrass", .id = 1401 },
            .{ .loc = "smooth_basalt", .id = 20336 },
            .{ .loc = "stone", .id = 1 },
            .{ .loc = "tall_seagrass", .id = 1402 },
            .{ .loc = "tuff", .id = 17714 },
            .{ .loc = "water", .id = 34 },
        };

        std.debug.assert(std.mem.eql(u8, resloc[0..10], "minecraft:"));
        const loc = resloc[10..];

        const id = blk: {
            for (map) |pair| {
                if (std.mem.eql(u8, loc, pair.loc)) break :blk pair.id;
            } else {
                std.debug.print("missing id for resource location '{s}'\n", .{resloc});
                break :blk 0;
            }
        };
        std.debug.print("{s}=>{d}\n", .{ loc, id });
        return id;
    }

    fn doOneSection(writer: anytype, section: Section) !void {
        const palette = section.block_states.palette;
        const block_data = section.block_states.data;
        const bits_per_block = @maximum(4, @floatToInt(u8, std.math.ceil(std.math.log2(@intToFloat(f32, palette.len)))));

        if (palette.len == 1) {
            const block_id = resourceLocationToId(palette[0].name);
            std.debug.print("section Y={d} only has {s} (id={d})\n", .{ section.ypos, palette[0].name, block_id });
            try writer.writeIntBig(i16, 0x100); // number of non-air blocks
            { // block states
                try writer.writeByte(0); // bits per block
                { // palette
                    try types.VarInt.encode(writer, @intCast(i32, block_id));
                    try types.VarInt.encode(writer, 0); // data entries
                }
            }
        } else {
            const b_per_long = (64 / bits_per_block);
            std.debug.print(
                "section Y={d}: bits/block={d}, blocks/long={d}, data len={d} -> {d}\n",
                .{ section.ypos, bits_per_block, b_per_long, block_data.len, b_per_long * block_data.len },
            );
            try writer.writeIntBig(i16, 0x100); // number of non-air blocks
            { // block states
                // bits per block
                try writer.writeByte(bits_per_block);
                // palette
                try types.VarInt.encode(writer, @intCast(i32, palette.len));
                for (palette) |entry| try types.VarInt.encode(writer, resourceLocationToId(entry.name));
                // chunk block data
                try types.VarInt.encode(writer, @intCast(i32, block_data.len));
                for (block_data) |long| try writer.writeIntBig(u64, long);
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
            try types.VarInt.encode(writer, 0);
            //const biomes = [_]u64{0x0000_0000_0000_0001} ** 26; // why 26???
            //for (biomes) |entry| try writer.writeIntBig(u64, entry);
        }
    }

    pub fn makeIntoPacketFormat(self: *Chunk, allocator: Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 0xa0000); // 640KB. ought to be enough :)
        const writer = std.io.fixedBufferStream(buf).writer();

        for (self.sections) |section| try doOneSection(writer, section);

        const blob = writer.context.getWritten();
        buf = allocator.resize(buf, blob.len).?;
        return blob;
    }
};

pub fn Palette(comptime Type: type) type {
    return struct {
        palette: []Type,
        data: []u64,
    };
}