//! These packet types are 'clientbound' (i.e. sent from the server to the client)

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const VarInt = types.VarInt;
const String = types.String;
const Position = types.Position;
const NBT = types.NBT;
const State = @import("Session.zig").State;

pub const Packet = union(enum) {
    status: StatusData,
    login: LoginData,
    play: PlayData,

    pub fn encode(self: Packet, writer: anytype) !void {
        const raw_id = self.rawDataId();
        const packet_size = VarInt.encodedSize(raw_id) + self.encodedDataSize();

        try VarInt.encode(writer, @intCast(i32, packet_size));
        try VarInt.encode(writer, raw_id);
        try self.encodeData(writer);
    }

    fn rawDataId(self: Packet) i32 {
        return @intCast(i32, switch (self) {
            .status => |data| @enumToInt(std.meta.activeTag(data)),
            .login => |data| @enumToInt(std.meta.activeTag(data)),
            .play => |data| @enumToInt(std.meta.activeTag(data)),
        });
    }

    fn encodedDataSize(self: Packet) usize {
        return switch (self) {
            .status => |data| data.encodedSize(),
            .login => |data| data.encodedSize(),
            .play => |data| data.encodedSize(),
        };
    }

    fn encodeData(self: Packet, writer: anytype) !void {
        switch (self) {
            .status => |data| try data.encode(writer),
            .login => |data| try data.encode(writer),
            .play => |data| try data.encode(writer),
        }
    }
};

pub fn genericEncodedDataSize(data: anytype) usize {
    const DataType = @TypeOf(data);
    if (DataType == void) return 0;

    const type_info = @typeInfo(DataType);
    if (std.meta.activeTag(type_info) != .Struct) @panic("genericEncodedDataSize only on structs");
    const struct_info = type_info.Struct;

    var data_size: usize = 0;
    inline for (struct_info.fields) |field| {
        const field_data = @field(data, field.name);
        const field_type = field.field_type;
        data_size += switch (field_type) {
            u8, u16, u32, u64, u128, i8, i16, i32, i64 => @sizeOf(field_type),
            []u8 => field_data.len,
            f32, f64 => @sizeOf(field_type),
            bool => 1,
            VarInt => VarInt.encodedSize(field_data.value),
            String => String.encodedSize(field_data.value),
            []String => blk: {
                var total: usize = 0;
                for (field_data) |string| total += String.encodedSize(string.value);
                break :blk total;
            },
            Position => 8,
            NBT => field_data.blob.len,
            else => @panic("TODO encoded size for type " ++ @typeName(field_type)),
        };
    }

    return data_size;
}

pub fn genericEncodeData(data: anytype, writer: anytype) !void {
    const DataType = @TypeOf(data);
    if (DataType == void) return;

    const type_info = @typeInfo(DataType);
    if (std.meta.activeTag(type_info) != .Struct) @panic("genericEncodeData only on structs");
    const struct_info = type_info.Struct;

    inline for (struct_info.fields) |field| {
        const field_data = @field(data, field.name);
        const field_type = field.field_type;

        switch (field_type) {
            u8, u16, u32, u64, u128, i8, i16, i32, i64 => {
                try writer.writeIntBig(field_type, field_data);
            },
            []u8 => _ = try writer.write(field_data),
            f32, f64 => {
                const IntType = std.meta.Int(.unsigned, @bitSizeOf(field_type));
                try writer.writeIntBig(IntType, @bitCast(IntType, field_data));
            },
            bool => try writer.writeByte(@intCast(u8, @boolToInt(field_data))),
            VarInt => try VarInt.encode(writer, field_data.value),
            String => try String.encode(writer, field_data.value),
            []String => {
                for (field_data) |string| try String.encode(writer, string.value);
            },
            Position => try field_data.encode(writer),
            NBT => try field_data.encode(writer),
            else => @panic("TODO encode type " ++ @typeName(field_type)),
        }
    }
}

pub const StatusId = enum(u7) {
    response = 0x00,
    pong = 0x01,
};

pub const StatusData = union(StatusId) {
    response: struct {
        json_response: String,
    },
    pong: struct {
        payload: i64,
    },

    pub fn encodedSize(self: StatusData) usize {
        return switch (self) {
            .response => |data| genericEncodedDataSize(data),
            .pong => |data| genericEncodedDataSize(data),
        };
    }

    pub fn encode(self: StatusData, writer: anytype) !void {
        switch (self) {
            .response => |data| try genericEncodeData(data, writer),
            .pong => |data| try genericEncodeData(data, writer),
        }
    }
};

pub const LoginId = enum(u7) {
    login_success = 0x02,
};

pub const LoginData = union(LoginId) {
    login_success: struct {
        uuid: u128,
        username: String,
    },

    pub fn encodedSize(self: LoginData) usize {
        return switch (self) {
            .login_success => |data| genericEncodedDataSize(data),
        };
    }

    pub fn encode(self: LoginData, writer: anytype) !void {
        switch (self) {
            .login_success => |data| try genericEncodeData(data, writer),
        }
    }
};

pub const PlayId = enum(u7) {
    keep_alive = 0x21,
    chunk_data_and_update_light = 0x22,
    join_game = 0x26,
    player_position_and_look = 0x38,
    spawn_position = 0x4b,
};

pub const PlayData = union(PlayId) {
    keep_alive: struct {
        keep_alive_id: i64,
    },
    chunk_data_and_update_light: struct {
        chunk_x: i32,
        chunk_z: i32,
        heightmaps: NBT,
        size: VarInt,
        data: []u8,
        number_of_block_entities: VarInt = VarInt{ .value = 0 },
        //block_entities: []struct {
        //    packed_xz: u8,
        //    y: i16,
        //    @"type": VarInt,
        //    data: NBT,
        //},
        trust_edges: bool,
        sky_light_mask: u8,
        block_light_mask: u8,
        empty_sky_light_mask: u8,
        empty_block_light_mask: u8,
        sky_light_array_count: VarInt = VarInt{ .value = 0 },
        //sky_light_arrays: []struct {
        //    length: VarInt,
        //    sky_light_array: [2048]u8,
        //},
        block_light_array_count: VarInt = VarInt{ .value = 0 },
        //block_light_arrays: []struct {
        //    length: VarInt,
        //    block_light_array: [2048]u8,
        //},
    },
    join_game: struct {
        entity_id: i32,
        is_hardcore: bool,
        gamemode: u8,
        previous_gamemode: i8,
        world_count: VarInt,
        dimension_names: []String,
        dimension_codec: NBT,
        dimension: NBT,
        dimension_name: String,
        hashed_seed: i64,
        max_players: VarInt,
        view_distance: VarInt,
        simulation_distance: VarInt,
        reduced_debug_info: bool,
        enable_respawn: bool,
        is_debug: bool,
        is_flat: bool,
    },
    player_position_and_look: struct {
        x: f64,
        y: f64,
        z: f64,
        yaw: f32,
        pitch: f32,
        flags: u8,
        teleport_id: VarInt,
        dismount_vehicle: bool,
    },
    spawn_position: struct {
        location: Position,
        angle: f32,
    },

    pub fn encodedSize(self: PlayData) usize {
        return switch (self) {
            .keep_alive => |data| genericEncodedDataSize(data),
            .chunk_data_and_update_light => |data| genericEncodedDataSize(data),
            .join_game => |data| genericEncodedDataSize(data),
            .player_position_and_look => |data| genericEncodedDataSize(data),
            .spawn_position => |data| genericEncodedDataSize(data),
        };
    }

    pub fn encode(self: PlayData, writer: anytype) !void {
        switch (self) {
            .keep_alive => |data| try genericEncodeData(data, writer),
            .chunk_data_and_update_light => |data| try genericEncodeData(data, writer),
            .join_game => |data| try genericEncodeData(data, writer),
            .player_position_and_look => |data| try genericEncodeData(data, writer),
            .spawn_position => |data| try genericEncodeData(data, writer),
        }
    }
};

/// Right now all the packet ID's fit in 7 or less bits, which means
/// we can always use a single byte VarInt to represent it.
/// Wherever we make that assumption we can check at compile time
/// that this variable is `true`, to avoid future confusion.
pub const packet_id_fits_in_7_bits =
    @bitSizeOf(StatusId) < 8 and
    @bitSizeOf(LoginId) < 8 and
    @bitSizeOf(PlayId) < 8;
comptime {
    if (!packet_id_fits_in_7_bits) @compileError("Packet ID's need more than a single byte VarInt");
}
