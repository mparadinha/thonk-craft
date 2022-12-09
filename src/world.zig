const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const Session = @import("Session.zig");
const Chunk = @import("chunk.zig").Chunk;
const ClientPacket = @import("client_packets.zig").Packet;
const ServerPacket = @import("server_packets.zig").Packet;
const block_constants = @import("block_constants.zig");
const specialMod = @import("WorldState.zig").specialMod;

pub const Manager = struct {
    ticks_done: u64,
    overworld: Dimension,
    unprocessed_packets: std.ArrayList(PlayerPacket),
    players: std.ArrayList(*Player),
    updates_to_send: std.ArrayList(Update),

    allocator: Allocator,
    mutex: std.Thread.Mutex,

    const PlayerPacket = struct { packet: ClientPacket, player: *Player };

    const Update = union(enum) {
        block_change: struct {
            pos: struct { x: i32, y: i32, z: i32 },
            block_id: u16,
        },
        player_join: struct {
            player: *Player,
        },
        player_visible: struct {
            player: *Player,
            pos: struct { x: f32, y: f32, z: f32 },
        },
        player_move: struct {
            player: *Player,
        },
    };

    /// Call `startup` after this. `deinit` to cleanup resources.
    pub fn init(region_filepath: []const u8, allocator: Allocator) !Manager {
        _ = region_filepath;
        var self = Manager{
            .ticks_done = 0,
            .overworld = undefined,
            .unprocessed_packets = std.ArrayList(PlayerPacket).init(allocator),
            .players = std.ArrayList(*Player).init(allocator),
            .updates_to_send = std.ArrayList(Update).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };

        return self;
    }

    pub fn startup(self: *Manager) !void {
        self.overworld = Dimension.init(self, .overworld, self.allocator);
        { // just load the (0, 0) chunk for now
            const WorldState = @import("WorldState.zig");
            const chunk = try WorldState.getChunkFromRegionFile("r.0.0.mca", self.allocator, 0, 0);
            try self.overworld.loaded_chunks.append(chunk);
        }
    }

    pub fn deinit(self: *Manager) void {
        self.overworld.deinit();
        self.unprocessed_packets.deinit();
        self.updates_to_send.deinit();
        self.unprocessed_packets.deinit();
    }

    pub fn startLoop(self: *Manager) void {
        const mspt = 50;
        while (true) {
            const tick_start_time = std.time.nanoTimestamp();

            self.tick();
            self.sendUpdatesToPlayers();

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
        self.overworld.tick();

        // Player entities are processed
        // The game will try to autosave if it has been 6000 ticks

        // Packets from client are processed
        self.processPackets();

        self.ticks_done += 1;
    }

    pub fn sendUpdatesToPlayers(self: *Manager) void {
        for (self.players.items) |player| {
            // TODO only send new player positions if they're on the same dimension
            //      (or even better: only if they are within render distance of each other)
            for (self.updates_to_send.items) |update| {
                switch (update) {
                    .block_change => |data| {
                        const pos = types.Position{
                            .x = @intCast(i26, data.pos.x),
                            .y = @intCast(i12, data.pos.y),
                            .z = @intCast(i26, data.pos.z),
                        };
                        player.session.sendPacket(ServerPacket{ .play = .{ .block_change = .{
                            .location = pos,
                            .block_id = .{ .value = data.block_id },
                        } } }) catch unreachable;
                    },
                    .player_join => |data| {
                        if (player == data.player) continue;
                        self.sendTabInfo(player, data.player);
                    },
                    .player_visible => |data| {
                        if (player == data.player) continue;
                        const entity_id = blk: {
                            for (self.players.items) |cmp_player, i| {
                                if (data.player == cmp_player) break :blk i;
                            } else break :blk 0;
                        };
                        player.session.sendPacket(ServerPacket{ .play = .{ .spawn_player = .{
                            .entity_id = .{ .value = @intCast(i32, entity_id) },
                            .player_uuid = 0,
                            .x = data.pos.x,
                            .y = data.pos.y,
                            .z = data.pos.z,
                            .yaw = 0,
                            .pitch = 0,
                        } } }) catch unreachable;
                    },
                    .player_move => |data| {
                        if (data.player == player) continue;
                        const entity_id = blk: {
                            for (self.players.items) |cmp_player, i| {
                                if (data.player == cmp_player) break :blk i;
                            } else break :blk 0;
                        };
                        const delta_pos = Player.Position{
                            .x = (data.player.pos.x * 32 - data.player.last_sent_pos.x * 32) / 128,
                            .y = (data.player.pos.y * 32 - data.player.last_sent_pos.y * 32) / 128,
                            .z = (data.player.pos.z * 32 - data.player.last_sent_pos.z * 32) / 128,
                        };
                        player.session.sendPacket(ServerPacket{ .play = .{ .entity_position = .{
                            .entity_id = .{ .value = @intCast(i32, entity_id) },
                            .delta_x = @floatToInt(i16, delta_pos.x),
                            .delta_y = @floatToInt(i16, delta_pos.y),
                            .delta_z = @floatToInt(i16, delta_pos.z),
                            .on_ground = true,
                        } } }) catch unreachable;
                    },
                }
            }
        }
        self.updates_to_send.clearRetainingCapacity();
    }

    /// This should be called after a client has completed the login sequence and is
    /// ready to start receiving chunk information. This function will send the initial
    /// `.join_game`, `.chunk_update_and_light`, and `.player_position_and_look` packets.
    /// When the client disconnects, call `removePlayer`.
    pub fn addPlayer(self: *Manager, player: *Player) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entity_id = self.players.items.len;
        self.players.append(player) catch unreachable;

        // TODO: load saved player information
        // TODO: see which dimension they're in, to add `player` to it

        var overworld_id = types.String{ .value = "minecraft:overworld" };
        var dimension_names = [_]types.String{overworld_id};
        const WorldState = @import("WorldState.zig");
        try player.session.sendPacket(ServerPacket{ .play = .{ .join_game = .{
            .entity_id = @intCast(i32, entity_id),
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
        } } });

        const chunk = self.overworld.loaded_chunks.items[0];
        const chunk_data = try chunk.makeIntoPacketFormat(self.allocator);
        const heightmap_blob = try WorldState.genHeightmapSingleHeight(self.allocator, 64);
        defer self.allocator.free(heightmap_blob.blob);
        try player.session.sendPacket(ServerPacket{ .play = .{ .chunk_data_and_update_light = .{
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
        } } });

        try player.session.sendPacket(ServerPacket{ .play = .{ .player_position_and_look = .{
            .x = 0,
            .y = 70,
            .z = 0,
            .yaw = 0,
            .pitch = 0,
            .flags = 0,
            .teleport_id = types.VarInt{ .value = 0 },
            .dismount_vehicle = false,
        } } });

        self.updates_to_send.append(.{ .player_join = .{ .player = player } }) catch unreachable;
        self.updates_to_send.append(.{ .player_visible = .{
            .player = player,
            .pos = .{ .x = 0, .y = 70, .z = 0 },
        } }) catch unreachable;
    }

    pub fn removePlayer(self: *Manager, player: *Player) void {
        const idx = blk: {
            for (self.players.items) |cmp_player, i| {
                if (cmp_player == player) break :blk i;
            } else return;
        };
        _ = self.players.orderedRemove(idx);
        // TODO: also update tab info when players leave
    }

    /// Safe to call from multiple threads concurrently
    pub fn addPlayerPacket(self: *Manager, packet: ClientPacket, player: *Player) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.unprocessed_packets.append(.{ .packet = packet, .player = player });
    }

    fn processPackets(self: *Manager) void {
        self.mutex.lock();
        for (self.unprocessed_packets.items) |player_packet| {
            var player = player_packet.player;
            const packet = player_packet.packet;
            switch (packet.play) {
                .player_position => |data| {
                    player.last_sent_pos = player.pos;
                    player.pos.x = data.x;
                    player.pos.y = data.feet_y;
                    player.pos.z = data.z;
                    self.updates_to_send.append(.{ .player_move = .{ .player = player } }) catch unreachable;
                },
                .player_position_and_rotation => |data| {
                    player.last_sent_pos = player.pos;
                    player.pos.x = data.x;
                    player.pos.y = data.feet_y;
                    player.pos.z = data.z;
                    self.updates_to_send.append(.{ .player_move = .{ .player = player } }) catch unreachable;
                },
                .player_digging => |data| {
                    std.debug.print("dig: status={}, loc={}, face={}\n", data);
                    const pos = data.location;
                    const status = data.status.value;
                    if (status != 0) {
                        std.debug.print("dig status={d} not implemented\n", .{data.status.value});
                        continue;
                    }
                    const block_x = @intCast(i32, pos.x);
                    const block_y = @intCast(i32, pos.y);
                    const block_z = @intCast(i32, pos.z);
                    const prev_block_id = self.overworld.getBlock(block_x, block_y, block_z);
                    self.overworld.scheduled_block_ticks.append(.{
                        .origin_block = block_constants.block_states[prev_block_id],
                        .origin_pos = .{ .x = block_x, .y = block_y, .z = block_z },
                    }) catch unreachable;
                    const air_id = block_constants.idFromState(.{ .air = {} });
                    self.overworld.changeBlock(block_x, block_y, block_z, air_id);

                    // TODO: update all other players of the change
                },
                .player_block_placement => |data| {
                    std.debug.print(
                        "block place: hand={}, loc=({},{},{}), face={}, cursor_pos=({},{},{}), inside_block={}\n",
                        .{ data.hand.value, data.location.x, data.location.y, data.location.z, data.face.value, data.cursor_pos_x, data.cursor_pos_y, data.cursor_pos_z, data.inside_block },
                    );

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
                    const block_x = @intCast(i32, pos.x);
                    const block_y = @intCast(i32, pos.y);
                    const block_z = @intCast(i32, pos.z);
                    const prev_block_id = self.overworld.getBlock(block_x, block_y, block_z);
                    self.overworld.scheduled_block_ticks.append(.{
                        .origin_block = block_constants.block_states[prev_block_id],
                        .origin_pos = .{ .x = block_x, .y = block_y, .z = block_z },
                    }) catch unreachable;
                    self.overworld.changeBlock(block_x, block_y, block_z, new_block);
                },
                else => {
                    //std.debug.print(
                    //    "TODO: unprocessed_packet: {s}\n",
                    //    .{std.meta.activeTag(player_packet.packet)},
                    //);
                },
            }
        }
        self.unprocessed_packets.clearRetainingCapacity();
        self.mutex.unlock();
    }

    pub fn sendTabInfo(self: *Manager, player: *Player, tab_player: *Player) void {
        // TODO: use this function to update all the players in the info tab
        _ = self;
        player.session.sendPacket(ServerPacket{ .play = .{ .player_info = .{
            .action = .{ .value = 0 },
            .number_of_players = .{ .value = 1 },
            .uuid = tab_player.uuid,
            .name = .{ .value = tab_player.name },
            .number_of_properties = .{ .value = 0 },
            .gamemode = .{ .value = 1 },
            .ping = .{ .value = 314 },
            .has_display_name = false,
        } } }) catch unreachable;
    }
};

const Dimension = struct {
    manager: *Manager,
    type: Type,
    scheduled_block_ticks: std.ArrayList(BlockUpdate), // TODO: priorities
    loaded_chunks: std.ArrayList(Chunk),

    mutex: std.Thread.Mutex,

    const Type = enum { overworld, nether, end };

    /// Deinitialize with `deinit`
    pub fn init(manager: *Manager, @"type": Type, allocator: Allocator) Dimension {
        return Dimension{
            .manager = manager,
            .type = @"type",
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
        if (self.type == .overworld) {
            // The game-time and day-time increase
            // Scheduled functions are executed
        }
        // For each loaded chunk:
        for (self.loaded_chunks.items) |*chunk| self.tickChunk(chunk);

        // Phantoms, pillagers, cats, and zombie sieges will try to spawn
        // Entity changes are sent to the client
        // Chunks try to unload

        // Scheduled ticks are processed
        // Scheduled block ticks
        for (self.scheduled_block_ticks.items) |block_tick| {
            const tick_pos = block_tick.origin_pos;
            std.debug.print(
                "block_update={{last_block={s}, pos=({},{},{})}}\n",
                .{ @tagName(std.meta.activeTag(block_tick.origin_block)), tick_pos.x, tick_pos.y, tick_pos.z },
            );
            var west = BlockPosition{ .x = tick_pos.x - 1, .y = tick_pos.y, .z = tick_pos.z };
            var east = BlockPosition{ .x = tick_pos.x + 1, .y = tick_pos.y, .z = tick_pos.z };
            var down = BlockPosition{ .x = tick_pos.x, .y = tick_pos.y - 1, .z = tick_pos.z };
            var up = BlockPosition{ .x = tick_pos.x, .y = tick_pos.y + 1, .z = tick_pos.z };
            var north = BlockPosition{ .x = tick_pos.x, .y = tick_pos.y, .z = tick_pos.z - 1 };
            var south = BlockPosition{ .x = tick_pos.x, .y = tick_pos.y, .z = tick_pos.z + 1 };
            for ([_]BlockPosition{ west, east, down, up, north, south }) |block_pos| {
                self.updateBlock(block_pos, block_tick);
            }
        }
        self.scheduled_block_ticks.clearRetainingCapacity();

        // Scheduled fluid ticks
        // Raid logic
        // Wandering traders try to spawn
        // Block events are processed
        // Entities are processed
        // Block entities are processed
    }

    fn updateBlock(self: *Dimension, pos: BlockPosition, update: BlockUpdate) void {
        const cur_block_id = self.getBlock(pos.x, pos.y, pos.z);
        const cur_block = block_constants.block_states[self.getBlock(pos.x, pos.y, pos.z)];
        std.debug.print("updating {d},'{s}' @ ({},{},{})\n", .{ cur_block_id, @tagName(std.meta.activeTag(cur_block)), pos.x, pos.y, pos.z });
        switch (cur_block) {
            .cobblestone_wall => |data| {
                _ = update;
                var new_state = data;
                new_state.up = false;
                new_state.waterlogged = true;
                new_state.west = .tall;
                new_state.south = .low;
                const new_block_state = block_constants.BlockState{ .cobblestone_wall = new_state };
                const new_block_id = block_constants.idFromState(new_block_state);
                std.debug.print("changing to {d}\n", .{new_block_id});
                self.changeBlock(pos.x, pos.y, pos.z, new_block_id);
            },
            else => {},
        }
    }

    fn tickChunk(self: *Dimension, chunk: *Chunk) void {
        _ = self;
        _ = chunk;
        // Chunk info is sent to the client
        // Chunk tick logic
    }

    pub fn getBlock(self: *Dimension, x: i32, y: i32, z: i32) u16 {
        const local_x = @intCast(u4, specialMod(x, 16));
        const local_z = @intCast(u4, specialMod(z, 16));
        return self.loaded_chunks.items[0].getBlock(local_x, y, local_z);
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

        self.manager.updates_to_send.append(.{ .block_change = .{
            .pos = .{ .x = x, .y = y, .z = z },
            .block_id = new_id,
        } }) catch unreachable;
    }
};

pub const Player = struct {
    session: *Session,
    uuid: u128,
    name: []const u8,
    pos: Position,
    last_sent_pos: Position,
    dimension: Dimension.Type,
    active_slot: usize = 0,
    slots: [9]u16 = [_]u16{0} ** 9,

    const Position = struct { x: f64, y: f64, z: f64 };
};

const BlockPosition = struct { x: i32, y: i32, z: i32 };

const BlockUpdate = struct {
    // just "neightbor changed" updates for now
    origin_block: block_constants.BlockState,
    origin_pos: BlockPosition,
};
