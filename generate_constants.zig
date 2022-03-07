const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var arg_iter = try std.process.argsWithAllocator(gpa);
    defer arg_iter.deinit();
    _ = arg_iter.skip(); // skip executable name (first argument)
    const folder_path = arg_iter.next() orelse @panic("please pass path to generated folder");

    const blocks_json_path = try std.fs.path.join(gpa, &.{ folder_path, "reports/blocks.json" });
    defer gpa.free(blocks_json_path);
    const blocks_json = try std.fs.cwd().openFile(blocks_json_path, .{});
    const blocks_json_data = try blocks_json.readToEndAlloc(gpa, std.math.maxInt(usize));

    const block_infos = try parseBlocksJson(blocks_json_data, gpa);
    defer gpa.free(block_infos);

    // property name => [ property value => # of occurences ]
    var all_properties = std.StringHashMap(std.StringHashMap(usize)).init(gpa);
    defer all_properties.deinit();

    for (block_infos) |block_info| {
        for (block_info.states) |block_state| {
            for (block_state.properties) |property| {
                const name_result = try all_properties.getOrPut(property.name);
                if (!name_result.found_existing) {
                    name_result.value_ptr.* = std.StringHashMap(usize).init(gpa);
                }
                const value_result = try name_result.value_ptr.getOrPut(property.value);
                if (!value_result.found_existing) value_result.value_ptr.* = 0;
                value_result.value_ptr.* += 1;
            }
        }
    }

    const registries_json_path = try std.fs.path.join(gpa, &.{ folder_path, "reports/registries.json" });
    defer gpa.free(registries_json_path);
    const registries_json = try std.fs.cwd().openFile(registries_json_path, .{});
    const registries_json_data = try registries_json.readToEndAlloc(gpa, std.math.maxInt(usize));

    const item_block_ids = try parseRegistries(registries_json_data, gpa);
    defer gpa.free(item_block_ids);

    for (block_infos) |info, i| {
        std.debug.print("block [{d}]{{ .name={s}, .states.len={d} }} (default id = {d})\n", .{
            i,
            info.name,
            info.states.len,
            info.states[info.default_state].id,
        });
    }

    std.debug.print("all unique properties: (and possibe values)\n", .{});
    var map_iterator = all_properties.iterator();
    while (map_iterator.next()) |pair| {
        std.debug.print("'{s}': ", .{pair.key_ptr.*});
        var value_iterator = pair.value_ptr.keyIterator();
        while (value_iterator.next()) |value| std.debug.print("{s}, ", .{value.*});
        std.debug.print("\n", .{});
    }

    for (item_block_ids) |entry| {
        std.debug.print("item_id for '{s}' is {d} (corresponding block id is {d})\n", .{
            entry.name, entry.item_id, entry.block_id,
        });
    }
}

const BlockInfo = struct {
    name: []const u8,
    states: []BlockState,
    default_state: usize,
};

const BlockState = struct {
    properties: []BlockProperty,
    id: u16,
};

const BlockProperty = struct {
    name: []const u8,
    value: []const u8,
};

const __BlockProperties__ = struct {
    powered: bool,
    lit: bool,
    waterlogged: bool,
    persistent: bool,
    has_bottle_0: bool,
    has_bottle_1: bool,
    has_bottle_2: bool,
    hanging: bool,
    in_wall: bool,
    enabled: bool,
    extended: bool,
    drag: bool,
    eye: bool,
    snowy: bool,
    open: bool,
    berries: bool,
    attached: bool,
    bottom: bool,
    has_record: bool,
    inverted: bool,
    unstable: bool,
    up: bool,
    locked: bool,
    triggered: bool,
    occupied: bool,
    hinge: bool,
    down: bool,
    short: bool,
    disarmed: bool,
    conditional: bool,
    signal_fire: bool,
    has_book: bool,
    stage: u8,
    bites: u8,
    honey_level: u8,
    distance: u8,
    power: u8,
    hatch: u8,
    delay: u8,
    level: u8,
    age: u8,
    pickles: u8,
    eggs: u8,
    layers: u8,
    candles: u8,
    note: u8,
    moisture: u8,
    charges: u8,
    rotation: u8,
    part: enum { head, foot },
    thickness: enum { middle, base, tip_merge, tip, frustum },
    shape: enum { south_west, ascending_south, south_east, ascending_west, north_south, north_east, ascending_north, ascending_east, inner_left, inner_right, outer_right, straight, outer_left, north_west, east_west },
    axis: enum { x, y, z },
    leaves: enum { large, none, small },
    sculk_sensor_phase: enum { cooldown, active, inactive },
    facing: enum { down, east, west, up, north, south },
    mode: enum { data, subtract, load, save, compare, corner },
    face: enum { ceiling, wall, floor },
    attachment: enum { ceiling, single_wall, floor, double_wall },
    @"type": enum { right, double, single, normal, top, sticky, bottom, left },
    vertical_direction: enum { up, down },
    instrument: enum { hat, bass, chime, didgeridoo, harp, iron_xylophone, xylophone, banjo, flute, basedrum, snare, bell, cow_bell, bit, pling, guitar },
    tilt: enum { none, partial, unstable },
    orientation: enum { down_south, up_east, east_up, down_west, south_up, down_north, up_west, up_north, up_south, west_up, down_east, north_up },

    south: DirectionProperty,
    east: DirectionProperty,
    west: DirectionProperty,
    north: DirectionProperty,

    const DirectionProperty = enum { side, tall, @"true", @"false", up, none, low };
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
                    block_info.states = state_info.state_list.toOwnedSlice();
                } else if (std.mem.eql(u8, string, "properties")) {
                    // skip the properties list
                    var next_tk = try stream.next();
                    expectToken(next_tk.?, .ObjectBegin);
                    try skipUntilObjectEnd(stream);
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

fn parseBlockStateArray(
    stream: *std.json.TokenStream,
    allocator: Allocator,
) !struct { default_state: usize, state_list: std.ArrayList(BlockState) } {
    var default_idx: usize = 0;
    var states = std.ArrayList(BlockState).init(allocator);

    var token = try stream.next();
    expectToken(token.?, .ArrayBegin);
    //try skipUntilArrayEnd(stream);
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
    block_id: u16,
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
        if (block_id) |id| {
            try item_block_ids_list.append(.{
                .name = item.name,
                .item_id = item.id,
                .block_id = id,
            });
        }
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

fn ReturnPayload(function: anytype) type {
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
