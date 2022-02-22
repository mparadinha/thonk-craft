const std = @import("std");

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

fn Number(comptime T: type, tag: Tag) type {
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

fn NumberArray(comptime T: type, tag: Tag) type {
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
