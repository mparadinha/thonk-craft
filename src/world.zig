const std = @import("std");
const Allocator = std.mem.Allocator;

pub const types = @import("types.zig");
pub const Session = @import("Session.zig");
pub const Chunk = @import("chunk.zig").Chunk;
pub const PlayPacket = @import("client_packets.zig").PlayData;
pub const block_constants = @import("block_constants.zig");
pub const specialMod = @import("WorldState.zig").specialMod;

pub const Manager = struct {
    ticks_done: u64,
    overworld: Dimension,
    unprocessed_packets: std.ArrayList(PlayerPacket),
    players: std.ArrayList(*Player),

    allocator: Allocator,
    mutex: std.Thread.Mutex,

    const PlayerPacket = struct { packet: PlayPacket, player: *Player };

    pub fn init(region_filepath: []const u8, allocator: Allocator) !Manager {
        _ = region_filepath;
        var self = Manager{
            .ticks_done = 0,
            .overworld = Dimension.init(.overworld, allocator),
            .unprocessed_packets = std.ArrayList(PlayerPacket).init(allocator),
            .players = std.ArrayList(*Player).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };

        { // just load the (0, 0) chunk for now
            const WorldState = @import("WorldState.zig");
            const chunk = try WorldState.getChunkFromRegionFile("r.0.0.mca", allocator, 0, 0);
            try self.overworld.loaded_chunks.append(chunk);
        }

        return self;
    }

    pub fn deinit(self: *Manager) void {
        self.overworld.deinit();
        self.unprocessed_packets.deinit();
    }

    pub fn startLoop(self: *Manager) void {
        const mspt = 50;
        while (true) {
            const tick_start_time = std.time.nanoTimestamp();
            self.tick();
            const tick_end_time = std.time.nanoTimestamp();
            const elapsed = tick_end_time - tick_start_time;
            const ns_left = (mspt * std.time.ns_per_ms) - elapsed;
            std.time.sleep(@intCast(u64, ns_left));
        }
    }

    pub fn tick(self: *Manager) void {
        // https://minecraft.fandom.com/wiki/Tick#Game_process

        // Functions with tick or load tag are executed

        // Each dimension is ticked in order of overworld, the nether, and the end:
        for ([_]Dimension{self.overworld}) |*dimension| dimension.tick();

        // Player entities are processed
        // The game will try to autosave if it has been 6000 ticks

        // Packets from client are processed
        for (self.unprocessed_packets.items) |player_packet| {
            var player = player_packet.player;
            const packet = player_packet.packet;
            switch (packet) {
                .player_position => |data| {
                    player.pos.x = data.x;
                    player.pos.y = data.feet_y;
                    player.pos.z = data.z;
                },
                .player_position_and_rotation => |data| {
                    player.pos.x = data.x;
                    player.pos.y = data.feet_y;
                    player.pos.z = data.z;
                },
                .player_digging => |data| {
                    std.debug.print("dig: status={}, loc={}, face={}\n", data);
                    const pos = data.location;
                    const status = data.status.value;
                    if (status == 0 or status == 1) {
                        self.overworld.changeBlock(
                            @intCast(i32, pos.x),
                            @intCast(i32, pos.y),
                            @intCast(i32, pos.z),
                            block_constants.idFromState(.{ .air = {} }),
                        );

                        // TODO: update all other players of the change
                    }
                },
                .player_block_placement => |data| {
                    std.debug.print("block place: hand={}, loc={}, face={}, cursor_pos=({},{},{}), inside_block={}\n", data);

                    var pos = data.location;
                    switch (data.face.value) {
                        0 => pos.y -= 1, // clicked on -Y face
                        1 => pos.y += 1, // clicked on +Y face
                        2 => pos.z -= 1, // clicked on -Z face
                        3 => pos.z += 1, // clicked on +Z face
                        4 => pos.x -= 1, // clicked on -X face
                        5 => pos.x += 1, // clicked on +X face
                        else => unreachable,
                    }
                    const new_block = player.slots[player.active_slot];
                    std.debug.print("placing {} @ ({d}, {d}, {d})\n", .{ new_block, pos.x, pos.y, pos.z });
                    self.overworld.changeBlock(@intCast(i32, pos.x), @intCast(i32, pos.y), @intCast(i32, pos.z), new_block);
                },
                else => {
                    std.debug.print(
                        "TODO: unprocessed_packet: {s}\n",
                        .{std.meta.activeTag(player_packet.packet)},
                    );
                },
            }
        }
        self.unprocessed_packets.clearRetainingCapacity();

        self.ticks_done += 1;
    }

    /// This should be called after a client has completed the login sequence and is
    /// ready to start receiving chunk information. This function will send the initial
    /// `.join_game`, `.chunk_update_and_light`, and `.player_position_and_look` packets.
    // TODO: return a player ID and use that instead of having to keep track the pointer everywhere
    pub fn addPlayer(self: *Manager, player: *Player) !void {
        std.debug.print("TODO add player\n", .{});

        self.players.append(player) catch unreachable;

        // TODO: load saved player information
        // TODO: see which dimension they're in, to add `player` to it

        const Packet = @import("server_packets.zig").PlayData;

        var overworld_id = types.String{ .value = "minecraft:overworld" };
        var dimension_names = [_]types.String{overworld_id};
        const WorldState = @import("WorldState.zig");
        try player.session.sendPacketData(Packet{ .join_game = .{
            .entity_id = 0,
            .is_hardcore = false,
            .gamemode = 1,
            .previous_gamemode = 1,
            .world_count = types.VarInt{ .value = @intCast(i32, dimension_names.len) },
            .dimension_names = &dimension_names,
            .dimension_codec = try WorldState.genDimensionCodecBlob(self.allocator),
            .dimension = try WorldState.genDimensionBlob(self.allocator),
            .dimension_name = overworld_id,
            .hashed_seed = 0,
            .max_players = types.VarInt{ .value = 420 },
            .view_distance = types.VarInt{ .value = 32 },
            .simulation_distance = types.VarInt{ .value = 32 },
            .reduced_debug_info = false,
            .enable_respawn = false,
            .is_debug = false,
            .is_flat = true,
        } });

        const chunk = self.overworld.loaded_chunks.items[0];
        const chunk_data = try chunk.makeIntoPacketFormat(self.allocator);
        const heightmap_blob = try WorldState.genHeightmapSingleHeight(self.allocator, 64);
        defer self.allocator.free(heightmap_blob.blob);
        try player.session.sendPacketData(Packet{ .chunk_data_and_update_light = .{
            .chunk_x = 0,
            .chunk_z = 0,
            .heightmaps = heightmap_blob,
            .size = types.VarInt{ .value = @intCast(i32, chunk_data.len) },
            .data = chunk_data,
            .trust_edges = true,
            .sky_light_mask = 0,
            .block_light_mask = 0,
            .empty_sky_light_mask = 0,
            .empty_block_light_mask = 0,
        } });

        try player.session.sendPacketData(Packet{ .player_position_and_look = .{
            .x = 0,
            .y = 70,
            .z = 0,
            .yaw = 0,
            .pitch = 0,
            .flags = 0,
            .teleport_id = types.VarInt{ .value = 0 },
            .dismount_vehicle = false,
        } });
    }

    /// Safe to call from multiple threads concurrently 
    pub fn addPlayerPacket(self: *Manager, packet: PlayPacket, player: *Player) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.unprocessed_packets.append(.{ .packet = packet, .player = player });
    }
};

const Dimension = struct {
    @"type": Type,
    scheduled_block_ticks: std.ArrayList(BlockUpdate), // TODO: priorities
    loaded_chunks: std.ArrayList(Chunk),

    mutex: std.Thread.Mutex,

    const Type = enum { overworld, nether, end };

    /// Deinitialize with `deinit`
    pub fn init(@"type": Type, allocator: Allocator) Dimension {
        return Dimension{
            .@"type" = @"type",
            .scheduled_block_ticks = std.ArrayList(BlockUpdate).init(allocator),
            .loaded_chunks = std.ArrayList(Chunk).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Dimension) void {
        self.scheduled_block_ticks.deinit();
        self.loaded_chunks.deinit();
    }

    pub fn tick(self: *Dimension) void {
        // https://minecraft.fandom.com/wiki/Tick#Game_process

        // The time is sent to the client
        // The world border is updated
        // Weather logic
        // Player sleeping logic

        // If this dimension is overworld:
        if (self.@"type" == .overworld) {
            // The game-time and day-time increase
            // Scheduled functions are executed
        }
        // For each loaded chunk:
        for (self.loaded_chunks.items) |*chunk| self.tickChunk(chunk);

        // Phantoms, pillagers, cats, and zombie sieges will try to spawn
        // Entity changes are sent to the client
        // Chunks try to unload
        // Scheduled ticks are processed
        {
            // Scheduled block ticks
            for (self.scheduled_block_ticks.items) |block_tick| {
                std.debug.print("TODO scheduled_block_tick: {any}\n", .{block_tick});
            }
            self.scheduled_block_ticks.clearRetainingCapacity();
            // Scheduled fluid ticks
        }
        // Raid logic
        // Wandering traders try to spawn
        // Block events are processed
        // Entities are processed
        // Block entities are processed
    }

    pub fn changeBlock(self: *Dimension, x: i32, y: i32, z: i32, new_id: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.print("changing block @ ({}, {}, {}) to {}\n", .{ x, y, z, new_id });
        const chunk_x = @divFloor(x, 16);
        const chunk_y = @divFloor(y, 16);
        const chunk_z = @divFloor(z, 16);
        std.debug.print("changing block @ chunk_section({}, {}, {})\n", .{ chunk_x, chunk_y, chunk_z });
        const local_x = @intCast(u4, specialMod(x, 16));
        const local_y = @intCast(u4, specialMod(y, 16));
        const local_z = @intCast(u4, specialMod(z, 16));
        std.debug.print("chunk_local block pos ({}, {}, {})\n", .{ local_x, local_y, local_z });
        self.loaded_chunks.items[0].changeBlock(local_x, y, local_z, new_id) catch unreachable;
    }

    fn tickChunk(self: *Dimension, chunk: *Chunk) void {
        _ = self;
        _ = chunk;
        // Chunk info is sent to the client
        // Chunk tick logic
    }
};

pub const Player = struct {
    session: *Session,
    pos: Position,
    last_sent_pos: Position,
    dimension: Dimension.Type,
    active_slot: usize = 0,
    slots: [9]u16 = [_]u16{0} ** 9,

    const Position = struct { x: f64, y: f64, z: f64 };
};

const BlockUpdate = struct {
    // just "neightbor changed" updates for now
    origin_block: block_constants.BlockState,
    origin_pos: BlockPosition,

    const BlockPosition = struct { x: i32, y: i32, z: i32 };
};
