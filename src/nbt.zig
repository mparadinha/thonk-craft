const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tag = enum(u8) {
    end,
    byte,
    short,
    int,
    long,
    float,
    double,
    byte_array,
    string,
    list,
    compound,
    int_array,
    long_array,
};

pub const Token = struct {
    name: ?[]const u8,
    data: union(Tag) {
        end: void,
        byte: i8,
        short: i16,
        int: i32,
        long: i64,
        float: f32,
        double: f64,
        byte_array: Array(i8),
        string: []const u8,
        list: struct { tag: Tag, len: usize },
        compound: void,
        int_array: Array(i32),
        long_array: Array(i64),
    },

    pub fn Array(comptime ElementType: type) type {
        return struct {
            len: usize,
            array_data: []const u8,

            const Self = @This();

            pub fn getElemsAlloc(self: Self, allocator: Allocator) ![]ElementType {
                var array = try allocator.alloc(ElementType, self.len);
                var stream = std.io.fixedBufferStream(self.array_data);
                const reader = stream.reader();
                for (array) |*entry| entry.* = try reader.readIntBig(ElementType);
                return array;
            }
        };
    }
};

pub const TokenStream = struct {
    data: []const u8,
    pos: usize,

    pub const Error = error{InvalidTag};

    pub fn init(nbt_data: []const u8) TokenStream {
        return TokenStream{ .data = nbt_data, .pos = 0 };
    }

    pub fn next(self: *TokenStream) Error!?Token {
        if (self.pos == self.data.len) return null;
        const tag = std.meta.intToEnum(Tag, self.readInt(u8)) catch {
            std.debug.print("self.pos=0x{x}\n", .{self.pos});
            return Error.InvalidTag;
        };
        return Token{
            .name = if (tag == .end) "" else self.readString(),
            .data = try self.readData(tag),
        };
    }

    /// For reading the entries of a `Tag.list` token
    pub fn nextNameless(self: *TokenStream, list_tk: Token) Error!?Token {
        if (self.pos == self.data.len) return null;
        const tag = list_tk.data.list.tag;
        std.debug.assert(tag != .end);
        return Token{
            .name = "",
            .data = try self.readData(tag),
        };
    }

    pub fn skip(self: *TokenStream, skip_token: Token) Error!void {
        switch (skip_token.data) {
            .end => unreachable,

            // parsing the tags already reads all the bytes associated with them
            .byte,
            .short,
            .int,
            .long,
            .float,
            .double,
            .byte_array,
            .string,
            .int_array,
            .long_array,
            => {},

            .list => |data| {
                var i: usize = 0;
                while (i < data.len) : (i += 1) {
                    const token = Token{ .name = "", .data = try self.readData(data.tag) };
                    try self.skip(token);
                }
            },
            .compound => {
                var token = try self.next();
                while (token) |tk| : (token = try self.next()) {
                    if (std.meta.activeTag(tk.data) == .end) break;
                    try self.skip(tk);
                }
            },
        }
    }

    fn readInt(self: *TokenStream, comptime T: type) T {
        // NBT numbers are always big endian
        const int: T = @intCast(T, switch (@sizeOf(T)) {
            1 => @bitCast(T, self.data[self.pos]),
            2 => (@intCast(T, self.data[self.pos + 0]) << 8) | self.data[self.pos + 1],
            4 => (@intCast(T, self.data[self.pos + 0]) << 24) |
                (@intCast(T, self.data[self.pos + 1]) << 16) |
                (@intCast(T, self.data[self.pos + 2]) << 8) |
                (@intCast(T, self.data[self.pos + 3]) << 0),
            8 => (@intCast(T, self.data[self.pos + 0]) << 56) |
                (@intCast(T, self.data[self.pos + 1]) << 48) |
                (@intCast(T, self.data[self.pos + 2]) << 40) |
                (@intCast(T, self.data[self.pos + 3]) << 32) |
                (@intCast(T, self.data[self.pos + 4]) << 24) |
                (@intCast(T, self.data[self.pos + 5]) << 16) |
                (@intCast(T, self.data[self.pos + 6]) << 8) |
                (@intCast(T, self.data[self.pos + 7]) << 0),
            else => unreachable,
        });
        self.pos += @sizeOf(T);
        return int;
    }

    fn readString(self: *TokenStream) []const u8 {
        const len = self.readInt(u16);
        const str = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return str;
    }

    fn readArray(self: *TokenStream, comptime T: type) Token.Array(T) {
        const array_len = @intCast(usize, self.readInt(i32));
        const array_size = array_len * @sizeOf(T);
        const data = Token.Array(T){
            .len = array_len,
            .array_data = self.data[self.pos .. self.pos + array_size],
        };
        self.pos += array_size;
        return data;
    }

    // @TypeOf(Token.data) doesn't work???
    const TokenData = @typeInfo(Token).Struct.fields[1].field_type;
    fn readData(self: *TokenStream, tag: Tag) !TokenData {
        switch (tag) {
            .end => return TokenData{ .end = {} },
            .byte => return TokenData{ .byte = self.readInt(i8) },
            .short => return TokenData{ .short = self.readInt(i16) },
            .int => return TokenData{ .int = self.readInt(i32) },
            .long => return TokenData{ .long = self.readInt(i64) },
            .float => return TokenData{ .float = @bitCast(f32, self.readInt(u32)) },
            .double => return TokenData{ .double = @bitCast(f64, self.readInt(u64)) },
            .byte_array => return TokenData{ .byte_array = self.readArray(i8) },
            .string => return TokenData{ .string = self.readString() },
            .list => return TokenData{ .list = .{
                .tag = std.meta.intToEnum(Tag, self.readInt(u8)) catch return Error.InvalidTag,
                .len = @intCast(usize, self.readInt(i32)),
            } },
            .compound => return TokenData{ .compound = {} },
            .int_array => return TokenData{ .int_array = self.readArray(i32) },
            .long_array => return TokenData{ .long_array = self.readArray(i64) },
        }
    }
};

fn Number(comptime T: type, comptime tag: Tag) type {
    return struct {
        const Self = @This();
        pub fn addRaw(writer: anytype, number: T) !void {
            switch (T) {
                i8, i16, i32, i64 => try writer.writeIntBig(T, number),
                f32, f64 => {
                    const IntType = std.meta.Int(.unsigned, @bitSizeOf(T));
                    try writer.writeIntBig(IntType, @bitCast(IntType, number));
                },
                else => @compileError("type " ++ @typeName(T) ++ " not supported"),
            }
        }

        pub fn add(writer: anytype, number: T) !void {
            try writer.writeByte(@enumToInt(tag));
            try Self.addRaw(T, number);
        }
        pub fn addNamed(writer: anytype, name: []const u8, number: T) !void {
            try writer.writeByte(@enumToInt(tag));
            try String.addRaw(writer, name);
            try Self.addRaw(writer, number);
        }
    };
}
pub const Byte = Number(i8, .byte);
pub const Int = Number(i32, .int);
pub const Long = Number(i64, .long);
pub const Float = Number(f32, .float);
pub const Double = Number(f64, .double);

fn NumberArray(comptime T: type, comptime tag: Tag) type {
    return struct {
        const Self = @This();
        pub fn addRaw(writer: anytype, numbers: []const T) !void {
            try writer.writeIntBig(i32, @intCast(i32, numbers.len));
            for (numbers) |int| try writer.writeIntBig(T, int);
        }
        pub fn add(writer: anytype, numbers: []const T) !void {
            try writer.writeByte(@enumToInt(tag));
            try Self.addRaw(numbers);
        }
        pub fn addNamed(writer: anytype, name: []const u8, numbers: []const T) !void {
            try writer.writeByte(@enumToInt(tag));
            try String.addRaw(writer, name);
            try Self.addRaw(writer, numbers);
        }
    };
}
pub const ByteArray = NumberArray(i8, .byte_array);
pub const IntArray = NumberArray(i32, .int_array);
pub const LongArray = NumberArray(i64, .long_array);

pub const String = struct {
    pub fn addRaw(writer: anytype, bytes: []const u8) !void {
        // this is supposed to be a "Modified Utf-8" encoding, but I think
        // for our purposes it might be the same. see:
        // https://docs.oracle.com/javase/8/docs/api/java/io/DataInput.html#modified-utf-8
        try writer.writeIntBig(u16, @intCast(u16, bytes.len));
        _ = try writer.write(bytes);
    }
    pub fn add(writer: anytype, bytes: []const u8) !void {
        try writer.writeByte(@enumToInt(Tag.string));
        try String.addRaw(bytes);
    }
    pub fn addNamed(writer: anytype, name: []const u8, bytes: []const u8) !void {
        try writer.writeByte(@enumToInt(Tag.string));
        try String.addRaw(writer, name);
        try String.addRaw(writer, bytes);
    }
};

pub const List = struct {
    pub fn addRaw(writer: anytype, tag: Tag, len: i32) !void {
        try writer.writeByte(@enumToInt(tag));
        try writer.writeIntBig(i32, len);
    }
    pub fn start(writer: anytype, tag: Tag, len: i32) !void {
        try writer.writeByte(@enumToInt(Tag.list));
        try List.addRaw(tag, len);
    }
    pub fn startNamed(writer: anytype, name: []const u8, tag: Tag, len: i32) !void {
        try writer.writeByte(@enumToInt(Tag.list));
        try String.addRaw(writer, name);
        try List.addRaw(writer, tag, len);
    }
};

pub const Compound = struct {
    pub fn start(writer: anytype) !void {
        try writer.writeByte(@enumToInt(Tag.compound));
    }
    pub fn startNamed(writer: anytype, name: []const u8) !void {
        try writer.writeByte(@enumToInt(Tag.compound));
        try String.addRaw(writer, name);
    }
    pub fn end(writer: anytype) !void {
        try writer.writeByte(@enumToInt(Tag.end));
    }
};
