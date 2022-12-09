const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DecodeError = error{VarIntTooBig};

/// essentially this is just wrapping some normal types (like i32)
/// in a structure, just so I can switch on a type and have VarInt
/// be distinct from i32 (that way I can write a generic decode
/// function for packets.
pub const VarInt = struct {
    value: i32,

    /// Returns how many bytes this VarInt would take when encoded.
    pub fn encodedSize(raw_value: i32) u8 {
        var byte_count: u8 = 0;
        var value = @bitCast(u32, raw_value);
        while (true) {
            if (value & ~@as(u32, 0x7f) == 0) return byte_count + 1;
            byte_count += 1;
            value >>= 7;
        }
    }

    /// Result is guaranteed to be, at most, 5 bytes.
    pub fn encode(writer: anytype, raw_value: i32) !void {
        var value = @bitCast(u32, raw_value);
        while (true) {
            if (value & ~@as(u32, 0x7f) == 0) {
                try writer.writeByte(@truncate(u8, value));
                return;
            }
            try writer.writeByte(@truncate(u8, (value & 0x7f) | 0x80));
            value >>= 7;
        }
    }

    pub fn decode(reader: anytype) !VarInt {
        var value: i32 = 0;
        var bytes_so_far: u8 = 0;
        while (true) {
            const byte = try reader.readByte();
            value |= @intCast(i32, (byte & 0x7f)) << @intCast(u5, (bytes_so_far * 7));
            if (byte & 0x80 == 0) return VarInt{ .value = value };
            bytes_so_far += 1;
            if (bytes_so_far == 5) return DecodeError.VarIntTooBig;
        }
    }
};

pub const String = struct {
    value: []const u8,

    pub fn fromLiteral(allocator: Allocator, literal: []const u8) !String {
        _ = allocator;
        return String{ .value = literal };
        //var str = String{ .value = try allocator.alloc(u8, literal.len) };
        //for (literal) |byte, i| str.value[i] = byte;
        //return str;
    }

    pub fn encodedSize(value: []const u8) usize {
        return VarInt.encodedSize(@intCast(i32, value.len)) + value.len;
    }

    pub fn encode(writer: anytype, value: []const u8) !void {
        try VarInt.encode(writer, @intCast(i32, value.len));
        _ = try writer.write(value);
    }

    pub fn decode(reader: anytype, allocator: Allocator) !String {
        const len = @intCast(usize, (try VarInt.decode(reader)).value);
        var str = try allocator.alloc(u8, len);
        const read_len = try reader.read(str);
        std.debug.assert(read_len == len);
        return String{ .value = str };
    }
};

pub const Position = struct {
    x: i26,
    z: i26,
    y: i12,

    pub fn encode(self: Position, writer: anytype) !void {
        const as_uint =
            ((@bitCast(u64, @intCast(i64, self.x)) << 38) & 0xffff_ffc0_0000_0000) |
            ((@bitCast(u64, @intCast(i64, self.z)) << 12) & 0x0000_003f_ffff_f000) |
            ((@bitCast(u64, @intCast(i64, self.y)) << 0) & 0x0000_0000_0000_0fff);
        try writer.writeIntBig(u64, as_uint);
    }

    pub fn decode(reader: anytype) !Position {
        const as_uint = try reader.readIntBig(u64);
        return Position{
            .x = @bitCast(i26, @truncate(u26, (as_uint & 0xffff_ffc0_0000_0000) >> 38)),
            .z = @bitCast(i26, @truncate(u26, (as_uint & 0x0000_003f_ffff_f000) >> 12)),
            .y = @bitCast(i12, @truncate(u12, (as_uint & 0x0000_0000_0000_0fff))),
        };
    }
};

pub const NBT = struct {
    blob: []u8,

    pub fn encode(self: NBT, writer: anytype) !void {
        _ = try writer.write(self.blob);
    }
};

pub const Slot = struct {
    /// the fields below are only valid if this is true
    present: bool,

    item_id: VarInt,
    item_count: i8,
    nbt: NBT,

    pub fn decode(reader: anytype) !Slot {
        var self: Slot = undefined;
        self.present = (try reader.readByte()) != 0;
        if (self.present) {
            self.item_id = try VarInt.decode(reader);
            self.item_count = @intCast(i8, try reader.readByte());
            const first_nbt_byte = try reader.readByte();
            std.debug.assert(first_nbt_byte == 0); // (TAG_end, empty NBT)
        }
        return self;
    }
};
