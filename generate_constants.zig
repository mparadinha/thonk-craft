const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var arg_iter = try std.process.argsWithAllocator(gpa);
    defer arg_iter.deinit();
    _ = arg_iter.skip(); // skip executable name (first argument)
    const folder_path = arg_iter.next() orelse @panic("please pass path to generated folder");

    const blocks_json_data = try readWholeFile(folder_path, "reports/blocks.json", gpa);
    const block_infos = try parseBlocksJson(blocks_json_data, gpa);
    defer gpa.free(block_infos);

    const registries_json_data = try readWholeFile(folder_path, "reports/registries.json", gpa);
    const item_block_ids = try parseRegistries(registries_json_data, gpa);
    defer gpa.free(item_block_ids);

    // check that all states for a given block have contiguous id's
    for (block_infos) |block| {
        std.debug.assert(block.states.len != 0);
        if (block.states.len == 1) continue;

        var min_id: u16 = std.math.maxInt(u16);
        var max_id: u16 = std.math.minInt(u16);
        for (block.states) |state| {
            if (state.id < min_id) min_id = state.id;
            if (state.id > max_id) max_id = state.id;
        }
        // note: all block state id's have to be unique
        std.debug.assert(block.states.len == max_id + 1 - min_id);
    }

    // reorder `block_infos` so everything is in order of increasing block state id
    for (block_infos) |block| {
        const stateLessThan = (struct {
            pub fn lessThan(_: void, lhs: BlockState, rhs: BlockState) bool {
                return lhs.id < rhs.id;
            }
        }).lessThan;
        std.sort.sort(BlockState, block.states, {}, stateLessThan);
    }
    const blockLessThan = (struct {
        pub fn lessThan(_: void, lhs: BlockInfo, rhs: BlockInfo) bool {
            return lhs.states[0].id < rhs.states[0].id;
        }
    }).lessThan;
    std.sort.sort(BlockInfo, block_infos, {}, blockLessThan);

    // fill in mapping information from item id to block index
    // for example: minecraft:stone might use the protocol id 12 when being in item form
    // but protocol id 20 when in block form. the `block index` is neither of these. it
    // is the index of the corresponding block in the `block_infos` array from above
    // (if it exists; pickaxe, for e.g., has no corresponding block)
    for (item_block_ids) |*entry| {
        for (block_infos, 0..) |block, block_idx| {
            if (std.mem.eql(u8, entry.name, block.name)) {
                entry.block_mapping_idx = block_idx;
                break;
            }
        } else entry.block_mapping_idx = null;
    }

    // for (block_infos) |info, i| {
    //     std.debug.print("block [{d}]{{ .name={s}, .states.len={d} }} (default id = {d})\n", .{
    //         i,
    //         info.name,
    //         info.states.len,
    //         info.states[info.default_state].id,
    //     });
    // }

    //for (block_infos) |info, i| {
    //    if (info.possible_properties.len != 0) {
    //        std.debug.print("possible properties for block [{d}] {s}:\n", .{ i, info.name });
    //    }
    //    for (info.possible_properties) |property| {
    //        std.debug.print("  {s} (type to use: {s}): {s}\n", .{
    //            property.name,
    //            @tagName(property.typeToUse()),
    //            property.values,
    //        });
    //    }
    //}

    // // property name => [ property value => # of occurences ]
    // var all_properties = std.StringHashMap(std.StringHashMap(usize)).init(gpa);
    // defer all_properties.deinit();
    // for (block_infos) |block_info| {
    //     for (block_info.states) |block_state| {
    //         for (block_state.properties) |property| {
    //             const name_result = try all_properties.getOrPut(property.name);
    //             if (!name_result.found_existing) {
    //                 name_result.value_ptr.* = std.StringHashMap(usize).init(gpa);
    //             }
    //             const value_result = try name_result.value_ptr.getOrPut(property.value);
    //             if (!value_result.found_existing) value_result.value_ptr.* = 0;
    //             value_result.value_ptr.* += 1;
    //         }
    //     }
    // }
    // std.debug.print("all unique properties: (and possibe values)\n", .{});
    // var map_iterator = all_properties.iterator();
    // while (map_iterator.next()) |pair| {
    //     std.debug.print("'{s}': ", .{pair.key_ptr.*});
    //     var value_iterator = pair.value_ptr.keyIterator();
    //     while (value_iterator.next()) |value| std.debug.print("{s}, ", .{value.*});
    //     std.debug.print("\n", .{});
    // }

    // for (item_block_ids) |entry| {
    //     std.debug.print("item_id for '{s}' is {d} (block_id={?}) (corresponding block index is {?})\n", .{
    //         entry.name, entry.item_id, entry.block_id, entry.block_mapping_idx,
    //     });
    // }

    // below is the zig code generation

    const writer = std.io.getStdOut().writer();

    _ = try writer.write(
        \\//! This file was generated using the `reports/blocks.json` file which is provided
        \\//! by the mojang minecraft server, by running the official `server.jar`
        \\//! with the following command line options:
        \\//! $ java -DbundlerMainClass=net.minecraft.data.Main -jar server.jar --all
        \\//! (see https://wiki.vg/Data_Generators for more information)
        \\//!
        \\//! This file contains the following declaration/functions:
        \\//! * the `BlockState` union, which maps every unique block to an anonymous struct
        \\//!   representing its possible block states (default values match default block state)
        \\//! * `idFromState` function. given a `BlockState` return its corresponding block
        \\//!   state numeric id
        \\//! * the `block_states` array lists every single block state for every single
        \\//!   block type, sorted by its numeric id. it has over 20,000 entries.
        \\//! * the `block_states_info` maps the `BlockState` tag to a usize "start/end"
        \\//!   pair, which gives a range in the `block_states` array ("end" is exclusive)
        \\//!   and a `default` which gives the default block state (via `block_states`)
        \\//! * the `item_block_ids` array maps an item id (different from block id) to its
        \\//!   corresponding `BlockTag`, or `null` if that item has no corresponding block (like
        \\//!   a saddle or music discs, for e.g). example: the tuff item has an item id of 12,
        \\//!   so item_blocks_ids[12] is `BlockTag.tuff`
        \\//! * the `stateFromPropertyList` function, which builds a `BlockState` from a list
        \\//!   of name/value strings, where `name` is the property name (such as "snowy") and
        \\//!   `value` the corresponding value to set for that property (such as "true")
        \\//!
        \\//! (fun fact: `minecraft:redstone_wire` has 1296 unique block states)
        \\
    );
    _ = try writer.write("\n");
    _ = try writer.write("const std = @import(\"std\");\n");
    _ = try writer.write("\n");
    _ = try writer.write(
        \\pub fn idFromState(block_state: BlockState) u16 {
        \\    @setEvalBranchQuota(2_000);
        \\    const info = block_states_info[@enumToInt(block_state)];
        \\    for (block_states[info.start..info.end], 0..) |cmp_state, i| {
        \\        if (std.meta.eql(block_state, cmp_state)) return @intCast(u16, i + info.start);
        \\    } else unreachable;
        \\}
        \\
    );
    _ = try writer.write("\n");
    _ = try writer.write("pub const BlockTag = std.meta.Tag(BlockState);\n");
    _ = try writer.write("\n");
    _ = try writer.write("pub const BlockState = union(enum(u16)) {\n");
    for (block_infos) |info| {
        try writer.print("    {s}", .{afterColon(info.name)});
        if (info.states.len == 1) {
            _ = try writer.write(": void,\n");
            continue;
        }
        const properties = info.possible_properties;
        const oneline = (properties.len == 1 and properties[0].typeToUse() != .Enum);
        const endline_char: u8 = if (oneline) ' ' else '\n';
        try writer.print(": struct {{{c}", .{endline_char});
        for (properties) |property| {
            if (!oneline) _ = try writer.write("        ");
            try writeIdentifier(writer, property.name);
            _ = try writer.write(": ");
            const default_value = blk: {
                for (info.states[info.default_state].properties) |state_property| {
                    if (std.mem.eql(u8, state_property.name, property.name))
                        break :blk state_property.value;
                } else unreachable;
            };
            switch (property.typeToUse()) {
                .Int => try writer.print("u8 = {s}", .{default_value}),
                .Bool => try writer.print("bool = {s}", .{default_value}),
                .Enum => {
                    std.debug.assert(property.values.len <= 256);
                    _ = try writer.write("enum { ");
                    for (property.values, 0..) |value, i| {
                        try writeIdentifier(writer, value);
                        if (i != property.values.len - 1) _ = try writer.write(", ");
                    }
                    try writer.print(" }} = .{s}", .{default_value});
                },
                else => unreachable,
            }
            if (!oneline) _ = try writer.write(",\n");
        }
        if (!oneline) _ = try writer.write("   ");
        _ = try writer.write(" },\n");
    }
    _ = try writer.write("};\n"); // close `BlockState`
    _ = try writer.write("\n");
    _ = try writer.write("pub const block_states = [_]BlockState{\n");
    var next_block_state_id: u16 = 0; // to make sure the Id's are sequential
    for (block_infos) |info| {
        const block_name = afterColon(info.name);
        if (info.states.len == 1) {
            std.debug.assert(next_block_state_id == info.states[0].id);
            next_block_state_id += 1;
            try writer.print("    .{{ .{s} = {{}} }},\n", .{block_name});
            continue;
        }
        for (info.states) |state| {
            std.debug.assert(next_block_state_id == state.id);
            next_block_state_id += 1;
            try writer.print("    .{{ .{s} = .{{ ", .{block_name});
            for (state.properties, 0..) |property, i| {
                _ = try writer.write(".");
                try writeIdentifier(writer, property.name);
                _ = try writer.write(" = ");
                if (info.typeForProperty(property.name) == .Enum) _ = try writer.write(".");
                _ = try writer.write(property.value);
                if (i != state.properties.len - 1) _ = try writer.write(", ");
            }
            _ = try writer.write(" } },\n");
        }
    }
    _ = try writer.write("};\n"); // close `block_states`
    _ = try writer.write("\n");
    _ = try writer.write("pub const BlockStateInfo = struct { start: usize, end: usize, default: usize };\n");
    _ = try writer.write("\n");
    _ = try writer.write("pub const block_states_info = [_]BlockStateInfo{\n");
    var last_range_end: u16 = 0;
    for (block_infos) |info| {
        const start = info.states[0].id;
        const end = start + info.states.len;
        std.debug.assert(start == last_range_end);
        last_range_end = @intCast(u16, end);
        try writer.print("    .{{ .start = {d}, .end = {d}, .default = {d} }},\n", .{
            start, end, info.states[info.default_state].id,
        });
    }
    _ = try writer.write("};\n"); // close `block_state_ranges`
    _ = try writer.write("\n");
    _ = try writer.write("pub const item_block_ids = [_]?BlockTag{\n");
    for (item_block_ids) |entry| {
        if (entry.block_id) |_| {
            try writer.print("    .{s},\n", .{afterColon(entry.name)});
        } else {
            try writer.print("    null, // {s}\n", .{afterColon(entry.name)});
        }
    }
    _ = try writer.write("};\n"); // close `item_block_ids`
    _ = try writer.write("\n");
    _ = try writer.write(
        \\pub const BlockProperty = struct { name: []const u8, value: []const u8 };
        \\
        \\pub fn stateFromPropertyList(tag: BlockTag, property_list: []const BlockProperty) BlockState {
        \\    const tag_info = block_states_info[@enumToInt(tag)];
        \\    var state = block_states[tag_info.default];
        \\    switch (state) {
        \\
    );
    for (block_infos) |info| {
        if (info.states.len == 1) continue;
        try printIndent(writer, 2, ".{s} => |*data| {{\n", .{afterColon(info.name)});
        if (info.possible_properties.len == 1) {
            const property = info.possible_properties[0];
            try printIndent(writer, 3, "std.debug.assert(std.mem.eql(u8, property_list[0].name, \"{s}\"));\n", .{property.name});
            try writeIndent(writer, 3, "data.");
            try writeIdentifier(writer, property.name);
            _ = try writer.write(" = ");
            switch (property.typeToUse()) {
                .Bool => _ = try writer.write("std.mem.eql(u8, property_list[0].value, \"true\");\n"),
                .Int => _ = try writer.write("std.fmt.parseInt(u8, property_list[0].value, 0) catch unreachable;\n"),
                .Enum => try writer.print("std.meta.stringToEnum(@TypeOf(data.{s}), property_list[0].value) orelse unreachable;\n", .{property.name}),
                else => unreachable,
            }
        } else {
            try writeIndent(writer, 3, "for (property_list) |property| {\n");
            for (info.possible_properties, 0..) |property, i| {
                try writeIndent(writer, 4, "");
                if (i > 0) _ = try writer.write("} else ");
                try writer.print("if (std.mem.eql(u8, property.name, \"{s}\")) {{\n", .{property.name});
                try writeIndent(writer, 5, "data.");
                try writeIdentifier(writer, property.name);
                _ = try writer.write(" = ");
                switch (property.typeToUse()) {
                    .Bool => _ = try writer.write("std.mem.eql(u8, property.value, \"true\");\n"),
                    .Int => _ = try writer.write("std.fmt.parseInt(u8, property.value, 0) catch unreachable;\n"),
                    .Enum => try writer.print("std.meta.stringToEnum(@TypeOf(data.{s}), property.value) orelse unreachable;\n", .{property.name}),
                    else => unreachable,
                }
            }
            try writeIndent(writer, 4, "} else unreachable;\n");
            try writeIndent(writer, 3, "}\n");
        }
        try writeIndent(writer, 2, "},\n");
    }
    _ = try writer.write(
        \\        else => {},
        \\    }
        \\    return state;
        \\}
        \\
    ); // close 'stateFromPropertyList
    _ = try writer.write("\n");
    _ = try writer.write(
        \\test "idFromState" {
        \\    try std.testing.expect(idFromState(.{ .air = {} }) == 0);
        \\    try std.testing.expect(idFromState(.{ .redstone_wire = .{
        \\        .east = .up,
        \\        .north = .up,
        \\        .power = 0,
        \\        .south = .up,
        \\        .west = .up,
        \\    } }) == 2114);
        \\    try std.testing.expect(idFromState(.{ .redstone_wire = .{} }) == 3274);
        \\}
        \\
        \\test "stateFromPropertyList" {
        \\    @setEvalBranchQuota(2_000);
        \\
        \\    const air = BlockState{ .air = .{} };
        \\    const air_list = [_]BlockProperty{};
        \\    try std.testing.expectEqual(air, stateFromPropertyList(.air, &air_list));
        \\
        \\    const snowy_grass = BlockState{ .grass_block = .{ .snowy = true } };
        \\    const snowy_grass_list = [_]BlockProperty{ .{ .name = "snowy", .value = "true" }};
        \\    try std.testing.expectEqual(snowy_grass, stateFromPropertyList(.grass_block, &snowy_grass_list));
        \\
        \\    const bamboo = BlockState{ .bamboo = .{ .age = 4, .leaves = .small } };
        \\    const bamboo_list = [_]BlockProperty{
        \\        .{ .name = "age", .value = "4" },
        \\        .{ .name = "leaves", .value = "small" },
        \\    };
        \\    try std.testing.expectEqual(bamboo, stateFromPropertyList(.bamboo, &bamboo_list));
        \\}
        \\
    );
}

/// `indent` measure multiples of 4 spaces. i.e. indent=2 will write 8 spaces
fn writeIndent(writer: anytype, comptime indent: u8, str: []const u8) !void {
    const spaces = [_]u8{' '} ** (4 * indent);
    _ = try writer.write(&spaces);
    _ = try writer.write(str);
}
fn printIndent(writer: anytype, comptime indent: u8, comptime fmt: []const u8, args: anytype) !void {
    const spaces = [_]u8{' '} ** (4 * indent);
    _ = try writer.write(&spaces);
    try writer.print(fmt, args);
}

/// wraps the identifier in @"" if needed
fn writeIdentifier(writer: anytype, identifier: []const u8) !void {
    if (isValidIdentifier(identifier)) {
        _ = try writer.write(identifier);
    } else {
        try writer.print("@\"{s}\"", .{identifier});
    }
}

fn afterColon(string: []const u8) []const u8 {
    const colon_pos = blk: {
        for (string, 0..) |char, i| if (char == ':') break :blk i;
        break :blk 0;
    };
    return string[colon_pos + 1 ..];
}

fn readWholeFile(folder_path: []const u8, file_path: []const u8, allocator: Allocator) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ folder_path, file_path });
    defer allocator.free(path);

    const file = try std.fs.cwd().openFile(path, .{});
    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    return data;
}

/// basically check that this string isn't a Zig keyword, or a type
fn isValidIdentifier(identifier: []const u8) bool {
    const zig_keywords = [_][]const u8{ "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "false", "fn", "for", "if", "inline", "noalias", "nosuspend", "null", "or", "orelse", "packed", "pub", "resume", "return", "linksection", "struct", "suspend", "switch", "test", "threadlocal", "true", "try", "undefined", "union", "unreachable", "usingnamespace", "var", "volatile", "while" };
    for (zig_keywords) |keyword| {
        if (std.mem.eql(u8, identifier, keyword)) return false;
    }
    if (std.mem.eql(u8, identifier, "type")) return false;
    if (identifier.len > 0 and (identifier[0] == 'i' or identifier[0] == 'u')) {
        if (std.fmt.parseInt(u16, identifier[1..], 0)) |_| {
            return false;
        } else |_| {}
    }
    if (identifier.len > 0 and identifier[0] == 'f') {
        if (std.fmt.parseInt(u8, identifier[1..], 0)) |bits| {
            if (bits == 16 or bits == 32 or bits == 64 or bits == 80) return false;
        } else |_| {}
    }
    return true;
}

const BlockInfo = struct {
    name: []const u8,
    states: []BlockState,
    default_state: usize,
    possible_properties: []BlockPossiblePropertyValues,

    pub fn typeForProperty(self: BlockInfo, property_name: []const u8) std.builtin.TypeId {
        for (self.possible_properties) |property| {
            if (std.mem.eql(u8, property_name, property.name)) {
                return property.typeToUse();
            }
        }
        unreachable;
    }
};

const BlockState = struct {
    properties: []BlockProperty,
    id: u16,
};

const BlockProperty = struct {
    name: []const u8,
    value: []const u8,
};

const BlockPossiblePropertyValues = struct {
    name: []const u8,
    values: [][]const u8,

    pub fn typeToUse(property: BlockPossiblePropertyValues) std.builtin.TypeId {
        // no property has mixed possible types. in other words, the first value
        // is enough to determine the overall type of the property
        std.debug.assert(property.values.len > 0);
        const value = property.values[0];

        // try integer first
        const parse_result = std.fmt.parseInt(u64, value, 0);
        if (!std.meta.isError(parse_result)) {
            std.debug.assert(property.values.len <= 256);
            return .Int;
        }
        // then bool
        if (property.values.len == 2) {
            const second_value = property.values[1];
            if ((std.mem.eql(u8, value, "true") and std.mem.eql(u8, second_value, "false")) or
                (std.mem.eql(u8, value, "false") and std.mem.eql(u8, second_value, "true")))
                return .Bool;
        }
        // and if its neither integer nor boolean then use enum
        return .Enum;
    }
};

fn parseBlocksJson(json_data: []const u8, allocator: Allocator) ![]BlockInfo {
    var block_info_list = std.ArrayList(BlockInfo).init(allocator);

    var json_stream = std.json.TokenStream.init(json_data);
    var token = try json_stream.next();
    expectToken(token.?, .ObjectBegin);
    token = try json_stream.next();
    while (token) |tk| : (token = try json_stream.next()) {
        switch (tk) {
            .ObjectEnd => break,
            .String => |data| {
                const block_info = try parseBlockInfo(&json_stream, data, allocator);
                try block_info_list.append(block_info);
            },
            else => {
                std.debug.print("got tk={any}, i={}\n", .{ tk, json_stream.i });
                unreachable;
            },
        }
    }

    return block_info_list.toOwnedSlice();
}

fn parseBlockInfo(
    stream: *std.json.TokenStream,
    name_tk: std.meta.TagPayload(std.json.Token, .String),
    allocator: Allocator,
) !BlockInfo {
    var block_info: BlockInfo = undefined;
    block_info.name = getSlice(name_tk, stream);
    block_info.states.len = 0;
    block_info.possible_properties.len = 0;

    var token = try stream.next();
    expectToken(token.?, .ObjectBegin);
    //try skipUntilObjectEnd(stream);
    token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        switch (tk) {
            .ObjectEnd => break,
            .String => |data| {
                const string = getSlice(data, stream);
                if (std.mem.eql(u8, string, "states")) {
                    var state_info = try parseBlockStateArray(stream, allocator);
                    block_info.default_state = state_info.default_state;
                    block_info.states = try state_info.state_list.toOwnedSlice();
                } else if (std.mem.eql(u8, string, "properties")) {
                    const properties = try parseBlockPossibleProperties(stream, allocator);
                    block_info.possible_properties = properties;
                } else {
                    std.debug.print("unknown string '{s}'\n", .{string});
                    @panic("");
                }
            },
            else => {
                std.debug.print("got tk={any}, i={}\n", .{ tk, stream.i });
                unreachable;
            },
        }
    }

    return block_info;
}

fn parseBlockPossibleProperties(
    stream: *std.json.TokenStream,
    allocator: Allocator,
) ![]BlockPossiblePropertyValues {
    var properties = std.ArrayList(BlockPossiblePropertyValues).init(allocator);

    var token = try stream.next();
    expectToken(token.?, .ObjectBegin);
    token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        switch (tk) {
            .ObjectEnd => break,
            .String => |data| {
                const property_name = getSlice(data, stream);
                var possible_values = std.ArrayList([]const u8).init(allocator);

                var inner_token = try stream.next();
                expectToken(inner_token.?, .ArrayBegin);
                inner_token = try stream.next();
                while (inner_token) |inner_tk| : (inner_token = try stream.next()) {
                    switch (inner_tk) {
                        .ArrayEnd => break,
                        .String => |inner_data| {
                            const property_value = getSlice(inner_data, stream);
                            try possible_values.append(property_value);
                        },
                        else => {
                            std.debug.print("got tk={any}, i={}\n", .{ inner_tk, stream.i });
                            unreachable;
                        },
                    }
                }

                const property = BlockPossiblePropertyValues{
                    .name = property_name,
                    .values = try possible_values.toOwnedSlice(),
                };
                try properties.append(property);
            },
            else => {
                std.debug.print("got tk={any}, i={}\n", .{ tk, stream.i });
                unreachable;
            },
        }
    }

    return properties.toOwnedSlice();
}

fn parseBlockStateArray(
    stream: *std.json.TokenStream,
    allocator: Allocator,
) !struct { default_state: usize, state_list: std.ArrayList(BlockState) } {
    var default_idx: usize = 0;
    var states = std.ArrayList(BlockState).init(allocator);

    var token = try stream.next();
    expectToken(token.?, .ArrayBegin);
    token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        switch (tk) {
            .ArrayEnd => break,
            .ObjectBegin => {
                const state_result = try parseBlockState(stream, allocator);
                if (state_result.is_default) default_idx = states.items.len;
                try states.append(state_result.block_state);
            },
            else => {
                std.debug.print("got tk={any}, i={}\n", .{ tk, stream.i });
                unreachable;
            },
        }
    }

    return ReturnPayload(parseBlockStateArray){ .default_state = default_idx, .state_list = states };
}

fn parseBlockState(
    stream: *std.json.TokenStream,
    allocator: Allocator,
) !struct { is_default: bool, block_state: BlockState } {
    var is_default = false;
    var state: BlockState = undefined;
    state.properties = &[0]BlockProperty{};

    var token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        switch (tk) {
            .ObjectEnd => break,
            .String => |data| {
                const string = getSlice(data, stream);
                if (std.mem.eql(u8, string, "id")) {
                    const next_tk = try stream.next();
                    expectToken(next_tk.?, .Number);
                    state.id = @intCast(u16, getInt(next_tk.?.Number, stream));
                } else if (std.mem.eql(u8, string, "default")) {
                    const next_tk = try stream.next();
                    expectToken(next_tk.?, .True);
                    is_default = true;
                } else if (std.mem.eql(u8, string, "properties")) {
                    state.properties = try parseBlockProperties(stream, allocator);
                } else {
                    std.debug.print("unknown string '{s}'\n", .{string});
                    unreachable;
                }
            },
            else => {
                std.debug.print("got tk={any}, i={}\n", .{ tk, stream.i });
                unreachable;
            },
        }
    }

    return ReturnPayload(parseBlockState){ .is_default = is_default, .block_state = state };
}

fn parseBlockProperties(
    stream: *std.json.TokenStream,
    allocator: Allocator,
) ![]BlockProperty {
    var property_list = std.ArrayList(BlockProperty).init(allocator);

    var token = try stream.next();
    expectToken(token.?, .ObjectBegin);
    token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        switch (tk) {
            .ObjectEnd => break,
            .String => |data| {
                const name = getSlice(data, stream);
                const next_tk = try stream.next();
                expectToken(next_tk.?, .String);
                const value = getSlice(next_tk.?.String, stream);
                try property_list.append(.{ .name = name, .value = value });
            },
            else => {
                std.debug.print("got tk={any}, i={}\n", .{ tk, stream.i });
                unreachable;
            },
        }
    }

    return property_list.toOwnedSlice();
}

const ItemBlockIds = struct {
    name: []const u8,
    item_id: u16,
    block_id: ?u16,
    block_mapping_idx: ?usize, // filled later
};

const NamedId = struct { name: []const u8, id: u16 };

fn parseRegistries(json_data: []const u8, allocator: Allocator) ![]ItemBlockIds {
    var item_block_ids_list = std.ArrayList(ItemBlockIds).init(allocator);

    var maybe_item_ids: ?[]NamedId = null;
    var maybe_block_ids: ?[]NamedId = null;

    var json_stream = std.json.TokenStream.init(json_data);
    var token = try json_stream.next();
    expectToken(token.?, .ObjectBegin);
    token = try json_stream.next();
    while (token) |tk| : (token = try json_stream.next()) {
        switch (tk) {
            .ObjectEnd => break,
            .String => |data| {
                const string = getSlice(data, &json_stream);
                if (std.mem.eql(u8, string, "minecraft:item")) {
                    maybe_item_ids = try getNamedIds(&json_stream, allocator);
                } else if (std.mem.eql(u8, string, "minecraft:block")) {
                    maybe_block_ids = try getNamedIds(&json_stream, allocator);
                } else {
                    const next_tk = try json_stream.next();
                    expectToken(next_tk.?, .ObjectBegin);
                    try skipUntilObjectEnd(&json_stream);
                }
            },
            else => {
                std.debug.print("got tk={any}, i={}\n", .{ tk, json_stream.i });
                unreachable;
            },
        }
    }

    var item_ids = if (maybe_item_ids) |ids| ids else unreachable;
    var block_ids = if (maybe_block_ids) |ids| ids else unreachable;

    for (item_ids) |item| {
        const block_id = blk: {
            for (block_ids) |block| {
                if (std.mem.eql(u8, item.name, block.name)) {
                    break :blk block.id;
                }
            } else {
                //std.debug.print("couldn't find '{s}' in block_ids\n", .{item.name});
                //unreachable;
                break :blk null;
            }
        };
        try item_block_ids_list.append(.{
            .name = item.name,
            .item_id = item.id,
            .block_id = block_id,
            .block_mapping_idx = null,
        });
    }

    return item_block_ids_list.toOwnedSlice();
}

fn getNamedIds(stream: *std.json.TokenStream, allocator: Allocator) ![]NamedId {
    var entries: []NamedId = undefined;

    var token = try stream.next();
    expectToken(token.?, .ObjectBegin);
    token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        switch (tk) {
            .ObjectEnd => break,
            .String => |data| {
                const string = getSlice(data, stream);
                if (std.mem.eql(u8, string, "entries")) {
                    entries = try getNamedIdEntries(stream, allocator);
                } else {
                    const next_tk = try stream.next();
                    assertNotToken(next_tk.?, .ObjectBegin);
                    assertNotToken(next_tk.?, .ArrayBegin);
                }
            },
            else => {
                std.debug.print("got tk={any}, i={}\n", .{ tk, stream.i });
                unreachable;
            },
        }
    }

    return entries;
}

fn getNamedIdEntries(stream: *std.json.TokenStream, allocator: Allocator) ![]NamedId {
    var entries = std.ArrayList(NamedId).init(allocator);

    var token = try stream.next();
    expectToken(token.?, .ObjectBegin);
    token = try stream.next();
    while (token) |tk| : (token = try stream.next()) {
        switch (tk) {
            .ObjectEnd => break,
            .String => |data| {
                const name = getSlice(data, stream);

                var next_tk = try stream.next();
                expectToken(next_tk.?, .ObjectBegin);

                next_tk = try stream.next();
                expectToken(next_tk.?, .String);
                const string = getSlice(next_tk.?.String, stream);
                std.debug.assert(std.mem.eql(u8, string, "protocol_id"));

                next_tk = try stream.next();
                expectToken(next_tk.?, .Number);
                const id = getInt(next_tk.?.Number, stream);

                next_tk = try stream.next();
                expectToken(next_tk.?, .ObjectEnd);

                try entries.append(.{ .name = name, .id = @intCast(u16, id) });
            },
            else => {
                std.debug.print("got tk={any}, i={}\n", .{ tk, stream.i });
                unreachable;
            },
        }
    }

    return entries.toOwnedSlice();
}

fn ReturnPayload(comptime function: anytype) type {
    const ReturnType = @typeInfo(@TypeOf(function)).Fn.return_type.?;
    return @typeInfo(ReturnType).ErrorUnion.payload;
}

fn skipUntilObjectEnd(json_stream: *std.json.TokenStream) !void {
    var token = try json_stream.next();
    var nesting: u32 = 1;
    while (token) |tk| : (token = try json_stream.next()) {
        //std.debug.print("skipping {any}\n", .{tk});
        switch (tk) {
            .ObjectBegin => nesting += 1,
            .ObjectEnd => nesting -= 1,
            else => {},
        }
        if (nesting == 0) return;
    }
}

fn skipUntilArrayEnd(json_stream: *std.json.TokenStream) !void {
    var token = try json_stream.next();
    var nesting: u32 = 1;
    while (token) |tk| : (token = try json_stream.next()) {
        //std.debug.print("skipping {any}\n", .{tk});
        switch (tk) {
            .ArrayBegin => nesting += 1,
            .ArrayEnd => nesting -= 1,
            else => {},
        }
        if (nesting == 0) return;
    }
}

fn expectToken(token: std.json.Token, tag: std.meta.Tag(std.json.Token)) void {
    if (std.meta.activeTag(token) != tag) {
        std.debug.print("expected {s}, got {any}\n", .{ @tagName(tag), token });
        unreachable;
    }
}

fn assertNotToken(token: std.json.Token, tag: std.meta.Tag(std.json.Token)) void {
    const active_tag = std.meta.activeTag(token);
    std.debug.assert(active_tag != tag);
}

fn getSlice(
    str_token: std.meta.TagPayload(std.json.Token, .String),
    stream: *std.json.TokenStream,
) []const u8 {
    return str_token.slice(stream.slice, stream.i - 1);
}

fn getInt(
    int_token: std.meta.TagPayload(std.json.Token, .Number),
    stream: *std.json.TokenStream,
) i64 {
    std.debug.assert(int_token.is_integer);
    const slice = int_token.slice(stream.slice, stream.i - 1);
    return std.fmt.parseInt(i64, slice, 0) catch unreachable;
}
