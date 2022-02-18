const std = @import("std");
const Allocator = std.mem.Allocator;
const StreamServer = std.net.StreamServer;

const client_packets = @import("client_packets.zig");
const State = client_packets.State;
const ClientPacket = client_packets.Packet;
const types = @import("types.zig");

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var server = StreamServer.init(.{
        // I shouldn't need this here. but sometimes we crash and this way we don't have
        // to wait for timeout after TIME_WAIT to run the program again.
        .reuse_address = true,
    });
    defer server.deinit();

    const local_server_ip = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 25565);
    try server.listen(local_server_ip);
    std.debug.print("listening on localhost:{d}...\n", .{local_server_ip.getPort()});
    defer server.close();
    errdefer server.close();

    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();
        std.debug.print("connection: {}\n", .{connection});

        try handleConnection(connection, gpa);
    }
}

fn handleConnection(connection: StreamServer.Connection, allocator: Allocator) !void {
    var state = State.handshaking;

    while (true) {
        var packetbuf: [0x4000]u8 = undefined;
        const conn_read = try connection.stream.read(&packetbuf);
        std.debug.assert(conn_read < packetbuf.len);
        var reader = std.io.fixedBufferStream(&packetbuf).reader();

        // handle legacy ping
        if (state == State.handshaking and packetbuf[0] == 0xfe) {
            std.debug.print("got a legacy ping packet. sending kick packet...\n", .{});
            var kick_packet_data = [_]u8{
                0xff, // kick packet ID
                0x00, 0x0c, // length of string (big endian u16)
                0x00, '§', 0x00, '1', 0x00, 0x00, // string start ("§1")
                0x00, '7', 0x00, '2', 0x00, '1', 0x00, 0x00, // protocol version ("127")
                0x00, 0x00, // message of the day ("")
                0x00, '0', 0x00, 0x00, // current player count ("0")
                0x00, '0', 0x00, 0x00, // max players ("0")
            };
            _ = try connection.stream.write(&kick_packet_data);
            break;
        }

        const packet = try ClientPacket.decode(reader, allocator, state);
        const inner_tag_name = switch (packet) {
            .handshaking => |data| @tagName(data),
            .status => |data| @tagName(data),
            .login => |data| @tagName(data),
            .play => |data| @tagName(data),
        };
        std.debug.print("got a {s}::{s} packet\n", .{ @tagName(packet), inner_tag_name });

        switch (packet) {
            .handshaking => |data| try handleHandshakingPacket(data, &state, connection, allocator),
            .status => |data| try handleStatusPacket(data, &state, connection, allocator),
            else => unreachable,
        }

        if (state == State.close_connection) break;
    }
}

fn handleHandshakingPacket(
    packet_data: client_packets.HandshakingData,
    state: *State,
    connection: StreamServer.Connection,
    allocator: Allocator,
) !void {
    _ = connection;
    _ = allocator;

    switch (packet_data) {
        .handshake => |data| {
            state.* = data.next_state;
        },
    }
}

fn handleStatusPacket(
    packet_data: client_packets.StatusData,
    state: *State,
    connection: StreamServer.Connection,
    allocator: Allocator,
) !void {
    _ = state;
    _ = allocator;

    switch (packet_data) {
        .request => {
            try sendHandshakeResponse(connection);
        },
        .ping => |data| {
            var databuf: [8]u8 = undefined;
            var databuf_stream = std.io.fixedBufferStream(&databuf);
            _ = try databuf_stream.writer().writeIntBig(i64, data.payload);
            try sendPacket(connection, 1, databuf_stream.getWritten());
            state.* = .close_connection;
        },
    }
}

fn sendHandshakeResponse(connection: StreamServer.Connection) !void {
    const thonk_png_data = @embedFile("../thonk_64x64.png");
    var base64_buffer: [0x4000]u8 = undefined;
    const base64_png = std.base64.standard.Encoder.encode(&base64_buffer, thonk_png_data);

    const response_str_fmt =
        \\{{
        \\    "version": {{
        \\        "name": "1.18.1",
        \\        "protocol": 757
        \\    }},
        \\    "players": {{
        \\        "max": 420,
        \\        "online": 69
        \\    }},
        \\    "description": {{
        \\        "text": "rly makes u think (powered by Zig!)"
        \\    }},
        \\    "favicon": "data:image/png;base64,{s}"
        \\}}
    ;
    var tmpbuf: [0x4000]u8 = undefined;
    const response_str = try std.fmt.bufPrint(&tmpbuf, response_str_fmt, .{base64_png});

    var databuf: [0x4000]u8 = undefined;
    var databuf_writer = std.io.fixedBufferStream(&databuf).writer();
    try types.String.encode(databuf_writer, types.String{ .value = response_str });
    const data_slice = databuf[0..databuf_writer.context.pos];

    var sendbuf: [0x4000]u8 = undefined;
    var writer = std.io.fixedBufferStream(&sendbuf).writer();
    try encodePacket(writer, 0, data_slice);

    const packet_slice = sendbuf[0..writer.context.pos];
    const bytes_sent = try connection.stream.write(packet_slice);
    std.debug.print("sent {d} bytes\n", .{bytes_sent});
}

// tmp hack. do not use
fn sendPacket(connection: StreamServer.Connection, id: i32, encoded_packet_data: []u8) !void {
    var sendbuf: [0x4000]u8 = undefined;
    var writer = std.io.fixedBufferStream(&sendbuf).writer();
    try encodePacket(writer, id, encoded_packet_data);

    const packet_slice = sendbuf[0..writer.context.pos];
    const bytes_sent = try connection.stream.write(packet_slice);
    std.debug.print("sent {d} bytes\n", .{bytes_sent});
}

fn encodePacket(writer: anytype, id: i32, encoded_packet_data: []u8) !void {
    const id_varint = types.VarInt{ .value = id };
    const total_size = types.VarInt{
        .value = @intCast(i32, id_varint.encodedSize() + encoded_packet_data.len),
    };
    try types.VarInt.encode(writer, total_size);
    try types.VarInt.encode(writer, id_varint);
    _ = try writer.write(encoded_packet_data);
}
