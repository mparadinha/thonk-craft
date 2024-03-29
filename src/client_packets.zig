//! These packet types are 'serverbound' (i.e. sent from the client to the server)

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const VarInt = types.VarInt;
const String = types.String;
const Position = types.Position;
const Slot = types.Slot;
const State = @import("Session.zig").State;

pub const Packet = union(enum) {
    handshaking: HandshakingData,
    status: StatusData,
    login: LoginData,
    play: PlayData,

    const Self = @This();

    pub const DecodeError = error{ UnknownId, IncorrectPacketSize };

    /// Call `deinit` to cleanup resources.
    pub fn decode(reader: anytype, allocator: Allocator, state: State, compressed: bool) !Packet {
        const packet_len = (try VarInt.decode(reader)).value;
        const id_data_len = if (compressed) (try VarInt.decode(reader)).value else packet_len;

        // read the whole packet into a buffer first
        const readbuf = try allocator.alloc(u8, @intCast(usize, id_data_len));
        defer allocator.free(readbuf);
        if (compressed) {
            var zlib_stream = try std.compress.zlib.zlibStream(allocator, reader);
            defer zlib_stream.deinit();
            const bytes_read = try zlib_stream.read(readbuf);
            if (bytes_read != readbuf.len) return DecodeError.IncorrectPacketSize;
        } else {
            const bytes_read = try reader.read(readbuf);
            if (bytes_read != readbuf.len) return DecodeError.IncorrectPacketSize;
        }

        var stream = std.io.fixedBufferStream(readbuf);
        const packet_reader = stream.reader();

        const raw_id = (try VarInt.decode(packet_reader)).value;
        const data_len = @intCast(usize, id_data_len - types.VarInt.encodedSize(raw_id));

        switch (state) {
            .handshaking => {
                const id = std.meta.intToEnum(HandshakingId, raw_id) catch unreachable;
                return Packet{ .handshaking = try HandshakingData.decode(id, packet_reader, allocator) };
            },
            .status => {
                const id = std.meta.intToEnum(StatusId, raw_id) catch unreachable;
                return Packet{ .status = try StatusData.decode(id, packet_reader, allocator) };
            },
            .login => {
                const id = std.meta.intToEnum(LoginId, raw_id) catch {
                    std.debug.print("unknown login packet (id=0x{x}). skiping.\n", .{raw_id});
                    try packet_reader.skipBytes(data_len, .{});
                    return DecodeError.UnknownId;
                };
                return Packet{ .login = try LoginData.decode(id, packet_reader, allocator) };
            },
            .play => {
                const id = std.meta.intToEnum(PlayId, raw_id) catch {
                    std.debug.print("unknown play packet (id=0x{x}). skiping.\n", .{raw_id});
                    try packet_reader.skipBytes(data_len, .{});
                    return DecodeError.UnknownId;
                };
                return Packet{ .play = try PlayData.decode(id, packet_reader, allocator) };
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
        @field(data, field.name) = switch (field.type) {
            bool => (try reader.readByte()) == 1,
            u8, u16, u32, u64, u128, i8, i16, i32, i64 => try reader.readIntBig(field.type),
            f32 => @bitCast(f32, try reader.readIntBig(u32)),
            f64 => @bitCast(f64, try reader.readIntBig(u64)),
            VarInt => try VarInt.decode(reader),
            String => try String.decode(reader, allocator),
            State => @intToEnum(State, (try VarInt.decode(reader)).value),
            Position => try Position.decode(reader),
            Slot => try Slot.decode(reader),
            else => @compileError("TODO decode type " ++ @typeName(field.type)),
        };
    }

    return data;
}

pub fn genericDecodeById(
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
            inline else => |tag| return genericDecodeById(HandshakingData, tag, reader, allocator),
        }
    }
};

pub const StatusId = enum(u7) {
    status_request = 0x00,
    ping_request = 0x01,
};

pub const StatusData = union(StatusId) {
    status_request: void,
    ping_request: struct {
        payload: i64,
    },

    pub fn decode(id: StatusId, reader: anytype, allocator: Allocator) !StatusData {
        switch (id) {
            inline else => |tag| return genericDecodeById(StatusData, tag, reader, allocator),
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
            inline else => |tag| return genericDecodeById(LoginData, tag, reader, allocator),
        }
    }
};

pub const PlayId = enum(u7) {
    confirm_teleportation = 0x00,
    client_information = 0x08,
    keep_alive = 0x12,
    set_player_position = 0x14,
    set_player_position_and_rotation = 0x15,
    set_player_rotation = 0x16,
    player_abilities = 0x1c,
    player_action = 0x1d,
    player_command = 0x1e,
    set_held_item = 0x28,
    set_creative_mode_slot = 0x2b,
    swing_arm = 0x2f,
    use_item_on = 0x31,
};

pub const PlayData = union(PlayId) {
    confirm_teleportation: struct {
        teleport_id: VarInt,
    },
    client_information: struct {
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
    keep_alive: struct {
        keep_alive_id: i64,
    },
    set_player_position: struct {
        x: f64,
        feet_y: f64,
        z: f64,
        on_ground: bool,
    },
    set_player_position_and_rotation: struct {
        x: f64,
        feet_y: f64,
        z: f64,
        yaw: f32,
        pitch: f32,
        on_ground: bool,
    },
    set_player_rotation: struct {
        yaw: f32,
        pitch: f32,
        on_ground: bool,
    },
    player_abilities: struct {
        /// bit mask, 0x02 = is flying.
        flags: i8,
    },
    player_action: struct {
        status: VarInt, // enum. see: https://wiki.vg/Protocol#Player_Digging
        location: Position,
        /// values 0 to 5 map to: -Y, +Y, -Z, +Z, -X, +X
        face: i8,
    },
    player_command: struct {
        entity_id: VarInt,
        action_id: VarInt, // enum. see: https://wiki.vg/Protocol#Entity_Action
        jump_boost: VarInt,
    },
    set_held_item: struct {
        slot: i16,
    },
    set_creative_mode_slot: struct {
        slot: i16,
        clicked_item: Slot,
    },
    swing_arm: struct {
        hand: VarInt, // 0 for main hand, 1 for off hand
    },
    use_item_on: struct {
        hand: VarInt, // 0 for main hand, 1 for off hand
        location: Position,
        face: VarInt, // same meaning as `face` in `player_digging` packet
        /// these cursor position are of the block the player clicked on
        /// while placing. used to determine which version of slab (top or bottom)
        /// to place, for example.
        cursor_pos_x: f32,
        cursor_pos_y: f32,
        cursor_pos_z: f32,
        /// used for placing blocks while on scaffolding
        inside_block: bool, // if player's head is inside a block
    },

    pub fn decode(id: PlayId, reader: anytype, allocator: Allocator) !PlayData {
        switch (id) {
            inline else => |tag| return genericDecodeById(PlayData, tag, reader, allocator),
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
