//! These packet types are 'serverbound' (i.e. sent from the client to the server)

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const VarInt = types.VarInt;
const String = types.String;
const State = @import("main.zig").State;

pub const Packet = union(enum) {
    handshaking: HandshakingData,
    status: StatusData,
    login: LoginData,
    play: PlayData,

    const Self = @This();

    /// Call `deinit` to cleanup resources.
    pub fn decode(reader: anytype, allocator: Allocator, state: State) !Packet {
        const id_data_len = (try VarInt.decode(reader)).value;
        const raw_id = (try VarInt.decode(reader)).value;
        std.debug.print("raw_id=0x{x}\n", .{raw_id});

        switch (state) {
            .handshaking => {
                const id = @intToEnum(HandshakingId, raw_id);
                return Packet{ .handshaking = try HandshakingData.decode(id, reader, allocator) };
            },
            .status => {
                const id = @intToEnum(StatusId, raw_id);
                return Packet{ .status = try StatusData.decode(id, reader, allocator) };
            },
            .login => {
                const id = @intToEnum(LoginId, raw_id);
                return Packet{ .login = try LoginData.decode(id, reader, allocator) };
            },
            .play => {
                const id = @intToEnum(PlayId, raw_id);
                // ignore these packets for now, we don't need them yet
                if (id == PlayId.plugin_message) {
                    try reader.skipBytes(@intCast(u64, id_data_len - VarInt.encodedSize(raw_id)), .{});
                    return Packet{ .play = .{ .plugin_message = {} } };
                }
                return Packet{ .play = try PlayData.decode(id, reader, allocator) };
            },
            else => unreachable,
        }
    }

    //pub fn deinit(self: Self, allocator: Allocator) void {
    //    @compileError("TODO generic Packet deinit");
    //}
};

pub fn genericDecodeData(comptime DataType: type, reader: anytype, allocator: Allocator) !DataType {
    if (DataType == void) return;

    var data: DataType = undefined;

    const type_info = @typeInfo(DataType);
    if (std.meta.activeTag(type_info) != .Struct) @panic("genericDecodeData only on structs");
    const struct_info = type_info.Struct;

    inline for (struct_info.fields) |field| {
        @field(data, field.name) = switch (field.field_type) {
            bool => (try reader.readByte()) == 1,
            u8, u16, u32, u64, i8, i16, i32, i64 => try reader.readIntBig(field.field_type),
            f32 => @bitCast(f32, try reader.readIntBig(u32)),
            f64 => @bitCast(f64, try reader.readIntBig(u64)),
            VarInt => try VarInt.decode(reader),
            String => try String.decode(reader, allocator),
            State => @intToEnum(State, (try VarInt.decode(reader)).value),
            else => @panic("TODO decode type " ++ @typeName(field.field_type)),
        };
    }

    return data;
}

fn genericDecodeById(
    comptime DataType: type,
    comptime Id: std.meta.Tag(DataType),
    reader: anytype,
    allocator: Allocator,
) !DataType {
    const inner_data_type = std.meta.TagPayload(DataType, Id);
    return @unionInit(
        DataType,
        @tagName(Id),
        try genericDecodeData(inner_data_type, reader, allocator),
    );
}

pub const HandshakingId = enum(u7) {
    handshake = 0x00,
};

pub const HandshakingData = union(HandshakingId) {
    handshake: struct {
        protocol_version: VarInt,
        server_addr: String,
        server_port: u16,
        next_state: State,
    },

    pub fn decode(id: HandshakingId, reader: anytype, allocator: Allocator) !HandshakingData {
        switch (id) {
            .handshake => return genericDecodeById(HandshakingData, .handshake, reader, allocator),
        }
    }
};

pub const StatusId = enum(u7) {
    request = 0x00,
    ping = 0x01,
};

pub const StatusData = union(StatusId) {
    request: void,
    ping: struct {
        payload: i64,
    },

    pub fn decode(id: StatusId, reader: anytype, allocator: Allocator) !StatusData {
        switch (id) {
            .request => return genericDecodeById(StatusData, .request, reader, allocator),
            .ping => return genericDecodeById(StatusData, .ping, reader, allocator),
        }
    }
};

pub const LoginId = enum(u7) {
    login_start = 0x00,
};

pub const LoginData = union(LoginId) {
    login_start: struct {
        name: String,
    },

    pub fn decode(id: LoginId, reader: anytype, allocator: Allocator) !LoginData {
        switch (id) {
            .login_start => return genericDecodeById(LoginData, .login_start, reader, allocator),
        }
    }
};

pub const PlayId = enum(u7) {
    teleport_confirm = 0x00,
    client_settings = 0x05,
    plugin_message = 0x0a,
    player_position = 0x11,
    player_position_and_rotation = 0x12,
    player_rotation = 0x13,
    player_abilities = 0x19,
    entity_action = 0x1b,
};

pub const PlayData = union(PlayId) {
    teleport_confirm: struct {
        teleport_id: VarInt,
    },
    client_settings: struct {
        locale: String,
        view_distance: i8,
        /// enum: 0=enable, 1=commands only, 2=hidden
        chat_mode: VarInt,
        chat_colors: bool,
        /// bit mask. the body parts are: (from bit 0 (0x01) to bit 6 (0x40))
        /// cape, jacket, left sleeve, right sleeve, left pants, right pants, hat
        displayed_skin_parts: u8,
        /// enum: 0=left, 1=right
        main_hand: VarInt,
        enable_text_filtering: bool,
        allow_server_listing: bool,
    },
    plugin_message: void,
    player_position: struct {
        x: f64,
        feet_y: f64,
        z: f64,
        on_ground: bool,
    },
    player_position_and_rotation: struct {
        x: f64,
        feet_y: f64,
        z: f64,
        yaw: f32,
        pitch: f32,
        on_ground: bool,
    },
    player_rotation: struct {
        yaw: f32,
        pitch: f32,
        on_ground: bool,
    },
    player_abilities: struct {
        /// bit mask, 0x02 = is flying.
        flags: i8,
    },
    entity_action: struct {
        entity_id: VarInt,
        action_id: VarInt, // enum. see: https://wiki.vg/Protocol#Entity_Action
        jump_boost: VarInt,
    },

    pub fn decode(id: PlayId, reader: anytype, allocator: Allocator) !PlayData {
        _ = reader;
        _ = allocator;
        switch (id) {
            .teleport_confirm => return genericDecodeById(PlayData, .teleport_confirm, reader, allocator),
            .client_settings => return genericDecodeById(PlayData, .client_settings, reader, allocator),
            .plugin_message => return genericDecodeById(PlayData, .plugin_message, reader, allocator),
            .player_position => return genericDecodeById(PlayData, .player_position, reader, allocator),
            .player_position_and_rotation => return genericDecodeById(PlayData, .player_position_and_rotation, reader, allocator),
            .player_rotation => return genericDecodeById(PlayData, .player_rotation, reader, allocator),
            .player_abilities => return genericDecodeById(PlayData, .player_abilities, reader, allocator),
            .entity_action => return genericDecodeById(PlayData, .entity_action, reader, allocator),
        }
    }
};

/// Right now all the packet ID's fit in 7 or less bits, which means
/// we can always use a single byte VarInt to represent it.
/// Wherever we make that assumption we can check at compile time
/// that this variable is `true`, to avoid future confusion.
pub const packet_id_fits_in_7_bits =
    @bitSizeOf(HandshakingId) < 8 and
    @bitSizeOf(StatusId) < 8 and
    @bitSizeOf(LoginId) < 8 and
    @bitSizeOf(PlayId) < 8;
comptime {
    if (!packet_id_fits_in_7_bits) @compileError("Packet ID's need more than a single byte VarInt");
}
