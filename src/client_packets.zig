//! These packet types are 'serverbound' (i.e. sent from the client to the server)

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");

pub const State = enum(i32) {
    /// All connection start in this state. Not part of the protocol.
    handshaking,

    status = 1,
    login = 2,
    play = 3,

    /// Not part of the protocol, used to signal that we're meant to close the connection.
    close_connection,
};

pub const Packet = union(enum) {
    handshaking: HandshakingData,
    status: StatusData,
    login: LoginData,
    play: PlayData,

    const Self = @This();

    /// Call `deinit` to cleanup resources.
    pub fn decode(reader: anytype, allocator: Allocator, state: State) !Packet {
        _ = try types.VarInt.decode(reader); // id+data length
        const raw_id = (try types.VarInt.decode(reader)).value;

        switch (state) {
            .handshaking => {
                const id = @intToEnum(HandshakingId, raw_id);
                return Packet{ .handshaking = try HandshakingData.decode(id, reader, allocator) };
            },
            .status => {
                const id = @intToEnum(StatusId, raw_id);
                return Packet{ .status = try StatusData.decode(id, reader, allocator) };
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
            u8, u16, u32, u64, i8, i16, i32, i64 => try reader.readIntBig(field.field_type),
            types.VarInt => try types.VarInt.decode(reader),
            types.String => try types.String.decode(reader, allocator),
            State => @intToEnum(State, (try types.VarInt.decode(reader)).value),
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
        protocol_version: types.VarInt,
        server_addr: types.String,
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
            .request => return StatusData{ .request = {} },
            .ping => return genericDecodeById(StatusData, .ping, reader, allocator),
        }
    }
};

pub const LoginId = enum(u7) {
    login_start = 0x00,
};

pub const LoginData = union(LoginId) {
    login_start: void,
};

pub const PlayId = enum(u7) {
    teleport_confirm = 0x00,
};

pub const PlayData = union(PlayId) {
    teleport_confirm: void,
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
