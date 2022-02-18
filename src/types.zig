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
    pub fn encodedSize(self: VarInt) u8 {
        var byte_count: u8 = 0;
        var value = self.value;
        while (true) {
            if (value & @bitCast(i32, ~@as(u32, 0x7f)) == 0) return byte_count + 1;
            byte_count += 1;
            value >>= 7;
        }
        return byte_count;
    }

    /// Result is guaranteed to be, at most, 5 bytes.
    pub fn encode(writer: anytype, varint: VarInt) !void {
        var value = varint.value;
        while (true) {
            if (value & @bitCast(i32, ~@as(u32, 0x7f)) == 0) {
                try writer.writeByte(@bitCast(u8, @truncate(i8, value)));
                return;
            }
            try writer.writeByte(@bitCast(u8, @truncate(i8, (value & 0x7f) | 0x80)));
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
    value: []u8,

    pub fn encode(writer: anytype, string: String) !void {
        try VarInt.encode(writer, VarInt{ .value = @intCast(i32, string.value.len) });
        _ = try writer.write(string.value);
    }

    pub fn decode(reader: anytype, allocator: Allocator) !String {
        const len = @intCast(usize, (try VarInt.decode(reader)).value);
        var str = try allocator.alloc(u8, len);
        const read_len = try reader.read(str);
        std.debug.assert(read_len == len);
        return String{ .value = str };
    }
};
