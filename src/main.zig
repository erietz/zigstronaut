const std = @import("std");
const posix = std.posix;

// ============================================================================
// ZigSpace - An outer space animation in ASCII art
//
// A space-themed terminal animation inspired by asciiquarium.
// Instead of fish and sharks, enjoy stars, spaceships, aliens, and more!
// ============================================================================

const version = "1.0.0";

// --- Terminal Handling ---

const Termios = std.posix.termios;

var orig_termios: Termios = undefined;
var term_initialized = false;

fn enableRawMode() !void {
    orig_termios = try posix.tcgetattr(posix.STDIN_FILENO);
    term_initialized = true;

    var raw = orig_termios;
    // Turn off echo, canonical mode, signals, and input processing
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.oflag.OPOST = false;
    // Set character size to 8 bits
    raw.cflag.CSIZE = .CS8;
    // Set read timeout
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1; // 100ms timeout

    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
}

fn disableRawMode() void {
    if (term_initialized) {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig_termios) catch {};
        term_initialized = false;
    }
}

fn getTermSize() !struct { w: u16, h: u16 } {
    var ws: posix.winsize = undefined;
    // Try stdout, then stdin, then stderr (for piped output scenarios)
    for ([_]i32{ posix.STDOUT_FILENO, posix.STDIN_FILENO, posix.STDERR_FILENO }) |fd| {
        if (std.c.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)) == 0) {
            return .{ .w = ws.col, .h = ws.row };
        }
    }
    return .{ .w = 80, .h = 24 };
}

// --- Output Buffer ---

const OutputBuffer = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) OutputBuffer {
        return .{ .buf = .empty, .allocator = allocator };
    }

    fn deinit(self: *OutputBuffer) void {
        self.buf.deinit(self.allocator);
    }

    fn clear(self: *OutputBuffer) void {
        self.buf.clearRetainingCapacity();
    }

    fn write(self: *OutputBuffer, data: []const u8) void {
        self.buf.appendSlice(self.allocator, data) catch {};
    }

    fn print(self: *OutputBuffer, comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        // Only used for single character printing
        const tuple = args;
        const ch: u8 = tuple[0];
        self.buf.append(self.allocator, ch) catch {};
    }

    fn flush(self: *OutputBuffer) void {
        writeAll(self.buf.items);
        self.clear();
    }
};

fn writeAll(data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.c.write(posix.STDOUT_FILENO, @ptrCast(data[written..].ptr), data.len - written);
        if (rc < 0) break;
        written += @intCast(rc);
    }
}

// --- Colors ---

const Color = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,
    default = 16,

    fn toAnsi(self: Color) []const u8 {
        return switch (self) {
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
            .default => "\x1b[39m",
        };
    }
};

// --- Entity System ---

const MAX_ENTITIES = 256;
const MAX_SHAPE_WIDTH = 80;
const MAX_SHAPE_HEIGHT = 20;

const EntityKind = enum {
    star_field,
    small_ship,
    alien,
    asteroid,
    comet,
    space_station,
    ufo,
    mothership,
    satellite,
    nebula,
    shooting_star,
    planet,
    exhaust,
};

const Entity = struct {
    active: bool = false,
    kind: EntityKind = .star_field,
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    depth: u8 = 10,
    color: Color = .white,
    shape_index: u16 = 0,
    frame: u8 = 0,
    frame_count: u8 = 1,
    frame_timer: f32 = 0,
    frame_speed: f32 = 0.2,
    lifetime: f32 = -1, // -1 = infinite
    age: f32 = 0,
    die_offscreen: bool = true,
    width: u8 = 0,
    height: u8 = 0,
};

// --- Shape Data ---
// Shapes are stored as string literals for each entity type

const star_chars = [_]u8{ '.', '+', '*', 'o', '`', '\'', ',' };

// Small ships going right
const small_ships_right = [_][]const u8{
    \\   /\
    \\  |==>
    \\   \/
    ,
    \\     _
    \\  ]-==#>
    \\     ~
    ,
    \\  -->
    ,
    \\  _____
    \\  \\=====>
    \\  ~~~~~
    ,
    \\  <o))>=<
    ,
    \\              c==o
    \\            _/____\_
    \\     _.,--'" ||^ || "`z._
    \\    /_/^ ___\||  || _/o\ "`-._
    \\  _/  ]. L_| || .||  \_/_  . _`--._
    \\ /_~7  _ . " ||. || /] \ ]. (_)  . "`--.
    \\|__7~.(_)_ []|+--+|/____T_____________L|
    \\|__|  _^(_) /^   __\____ _   _|
    \\|__| (_){_) J ]K{__ L___ _   _]
    \\|__| . _(_) \v     /__________|________
    \\l__l_ (_). []|+-+-<\^   L  . _   - ---L|
    \\ \__\    __. ||^l  \Y] /_]  (_) .  _,--'
    \\   \~_]  L_| || .\ .\\/~.    _,--'"
    \\    \_\ . __/||  |\  \`-+-<'"
    \\      "`---._|J__L|X o~~|[\\
    \\             \____/ \___|[//
    \\              `--'   `--+-'
    ,
};

// Small ships going left
const small_ships_left = [_][]const u8{
    \\   /\
    \\  <==|
    \\   \/
    ,
    \\     _
    \\  <#==-[
    \\     ~
    ,
    \\  <--
    ,
    \\  _____
    \\  <=====/ 
    \\  ~~~~~
    ,
    \\  >=<((o>
    ,
    \\              o==c
    \\             _/____\_
    \\          _.'z" || ^|| "'--.,._ 
    \\       _.-'" /o\_ ||  ||\___^ \_\
    \\    _.--'_ .  _/_\  ||. || |_J .] \_
    \\ .--'" .  (_) .] \ ]/ || .|| " . _  7~_\
    \\|L_____________T____\|+--+|[] _(._)~7__|
    \\           |_   _ ____\__   ^/ (_)^_  |__|
    \\           [_   _ ___J __}K] J (_}{_) |__|
    \\  ________|__________\     v/ (_)_ . |__|
    \\|L--- -   _ .  L   ^/\>-+-+|[] .(_) _l__l
    \\ '--,_  . (_)  ]_/ ]Y/  l^|| .__    /__/
    \\    "'-,_    .~/\\.\ .|| |_J  ]_~/ 
    \\       "'>-+-'`  /|  ||/__. . /_/
    \\             \\|~~o X|L__J|_.---'"
    \\             \\|___/ \____/
    \\              '-+--'   '--'
    ,
};

// Aliens
const alien_shapes = [_][]const u8{
    \\    .-.
    \\   (o o)
    \\  /| : |\
    \\   d b
    ,
    \\   .--.
    \\  |o  o|
    \\  |{~~}|
    \\   /  \
    ,
    \\    /\_/\
    \\   ( o.o )
    \\    > ^ <
    ,
    \\  {o,o}
    \\  /)__)
    \\  -"--"-
    ,
    \\     .-.
    \\    /_ _\
    \\    |o^o|
    \\    \ _ /
    \\   .-'-'-.
    \\  /`)  .  (`\
    \\ / /|.-'-.|\ \
    \\ \ \| (_) |/ /
    \\  \_\'-.-'/_/
    \\  /_/ \_/ \_\
    \\    |'._.'|
    \\    |  |  |
    \\     \_|_/
    \\     |-|-|
    \\     |_|_|
    \\    /_/ \_\
    ,
    \\          ___
    \\       ,-'___'-.
    \\     ,'  [(_)]  '.
    \\    |_]||[][O]o[][|
    \\  _ |_____________| _
    \\ | []   _______   [] |
    \\ | []   _______   [] |
    \\[| ||      _      || |]
    \\ |_|| =   [=]     ||_|
    \\ | || =   [|]     || |
    \\ | ||      _      || |
    \\ | ||||   (+)    (|| |
    \\ | ||_____________|| |
    \\ |_| \___________/ |_|
    \\ / \      | |      / \
    \\/___\    /___\    /___\
    ,
};

// UFOs
const ufo_shapes_right = [_][]const u8{
    \\      ___
    \\  ___|___|___
    \\  \  o o o  /
    \\   \_______/
    ,
    \\       _!_
    \\    .-'___'-.
    \\   /  o o o  \
    \\   '-..___..-'
    ,
};

const ufo_shapes_left = [_][]const u8{
    \\      ___
    \\  ___|___|___
    \\  \  o o o  /
    \\   \_______/
    ,
    \\       _!_
    \\    .-'___'-.
    \\   /  o o o  \
    \\   '-..___..-'
    ,
};

// Mothership
const mothership_right = [_][]const u8{
    \\          _..----.._
    \\       .-'  _..-'''''-.
    \\      /  ,-'       __.>
    \\     | /      _.-''
    \\     ||    ,-'    ___
    \\   __||__  |   .-' _ '-.
    \\  |      | |  / .-' '-.  \
    \\  |______| | | |       | |
    \\  |_:::__| | | |  (o)  | |
    \\  |      |_| |  \     /  |
    \\  '------'   \   '-.-'  /
    \\               '-......-'
    ,
};

const mothership_left = [_][]const u8{
    \\    _..----.._
    \\  .-''''-.._  '-.
    \\  <.__       '-,  \
    \\      ``-._      \ |
    \\     ___    '-,    ||
    \\  .-' _ '-.   |  __||__
    \\  /  .-' '-.  \ |  |      |
    \\  | |       | | |  |______|
    \\  | |  (o)  | | |  |__:::_|
    \\  |  \     /  | |_|      |
    \\   \   '-.-'  /   '------'
    \\    '-......-'
    ,
};

// Comet
const comet_right = [_][]const u8{
    \\ ~-._ *
    \\  ~~~--..__
    \\ ~---...___`--.
    \\  ~~~--..__ `-.`.
    \\ ~--..._ ``-.  `.>
    \\  `~~--..  ` . /
    \\   `~-.. `  .'>
    \\         `~-/
    ,
};

const comet_left = [_][]const u8{
    \\         * _.-~
    \\      __..--~~~
    \\  .--'___...---~
    \\ .'.-' __..--~~~
    \\ <.'  .-'' _...--~
    \\  \ . ' ..--~~'
    \\  <'.  ' ..-~'
    \\    \-~'
    ,
};

// Space station (static background)
const space_station_shape = [_][]const u8{
    \\       |
    \\      ===
    \\      |=|
    \\   ___|=|___
    \\  |  ~~|~~  |
    \\  |_________|
    \\  |[] |=| []|
    \\  |___|=|___|
    \\      |=|
    \\      ===
    \\       |
    ,
};

// Satellite
const satellite_right = [_][]const u8{
    \\  ]=-
    ,
    \\  ]=--
    ,
    \\  [|]=---
    ,
};

const satellite_left = [_][]const u8{
    \\  -=[
    ,
    \\  --=[
    ,
    \\  ---=[|]
    ,
};

// Planet (background decoration)
const planet_shape = [_][]const u8{
    \\       _.---._
    \\     .'  ___  '.
    \\    / .-'   '-. \
    \\   | /  .---.  \ |
    \\   ||  /     \  ||
    \\   | \  '---'  / |
    \\    \ '-.___..-' /
    \\     '.___7___.'
    \\    -===========- 
    ,
};

// Asteroid shapes
const asteroid_shapes = [_][]const u8{
    \\   __
    \\  (  )
    \\   ''
    ,
    \\    _.-._
    \\   /.--. \
    \\   |    | )
    \\    \__//
    ,
    \\  .-.
    \\  |o|
    \\  '-'
    ,
    \\   ,--,
    \\  ( ** )
    \\   `--'
    ,
};

// --- Main Simulation State ---

const SimState = struct {
    entities: [MAX_ENTITIES]Entity = [_]Entity{.{}} ** MAX_ENTITIES,
    width: u16 = 80,
    height: u16 = 24,
    tick: u64 = 0,
    rng: std.Random.Xoshiro256 = undefined,
    allocator: std.mem.Allocator = undefined,
    output: OutputBuffer = undefined,
    frame_buf: []u8 = undefined,
    color_buf: []Color = undefined,
    depth_buf: []u8 = undefined,
    running: bool = true,
    paused: bool = false,

    fn init(allocator: std.mem.Allocator) !*SimState {
        const self = try allocator.create(SimState);
        self.* = .{};
        self.allocator = allocator;
        self.output = OutputBuffer.init(allocator);

        const sz = try getTermSize();
        self.width = sz.w;
        self.height = sz.h;

        const buf_size = @as(usize, self.width) * @as(usize, self.height);
        self.frame_buf = try allocator.alloc(u8, buf_size);
        self.color_buf = try allocator.alloc(Color, buf_size);
        self.depth_buf = try allocator.alloc(u8, buf_size);

        // Seed RNG from clock
        var ts_seed: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_seed);
        const seed: u64 = @bitCast(@as(i64, ts_seed.nsec));
        self.rng = std.Random.Xoshiro256.init(seed);

        return self;
    }

    fn deinit(self: *SimState) void {
        self.output.deinit();
        self.allocator.free(self.frame_buf);
        self.allocator.free(self.color_buf);
        self.allocator.free(self.depth_buf);
        self.allocator.destroy(self);
    }

    fn random(self: *SimState) std.Random {
        return self.rng.random();
    }

    fn findFreeEntity(self: *SimState) ?*Entity {
        for (&self.entities) |*e| {
            if (!e.active) return e;
        }
        return null;
    }

    fn countEntitiesOfKind(self: *SimState, kind: EntityKind) u32 {
        var count: u32 = 0;
        for (&self.entities) |*e| {
            if (e.active and e.kind == kind) count += 1;
        }
        return count;
    }

    fn clearBuffers(self: *SimState) void {
        @memset(self.frame_buf, ' ');
        @memset(self.color_buf, .default);
        @memset(self.depth_buf, 255);
    }

    fn setCell(self: *SimState, x: i32, y: i32, ch: u8, color: Color, depth: u8) void {
        if (x < 0 or y < 0) return;
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, @intCast(y)) * @as(usize, self.width) + @as(usize, @intCast(x));
        if (depth < self.depth_buf[idx]) {
            self.frame_buf[idx] = ch;
            self.color_buf[idx] = color;
            self.depth_buf[idx] = depth;
        }
    }

    fn render(self: *SimState) void {
        self.output.clear();
        // Hide cursor and move to top-left
        self.output.write("\x1b[?25l\x1b[H");

        var last_color: Color = .default;
        self.output.write("\x1b[39m");

        var y: u16 = 0;
        while (y < self.height) : (y += 1) {
            var x: u16 = 0;
            while (x < self.width) : (x += 1) {
                const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
                const color = self.color_buf[idx];
                if (color != last_color) {
                    self.output.write(color.toAnsi());
                    last_color = color;
                }
                self.output.print("{c}", .{self.frame_buf[idx]});
            }
            if (y < self.height - 1) {
                self.output.write("\r\n");
            }
        }

        self.output.flush();
    }
};

// --- Entity Spawning ---

fn spawnStarField(state: *SimState) void {
    const density = @as(u32, state.width) * @as(u32, state.height) / 50;
    var i: u32 = 0;
    while (i < density) : (i += 1) {
        if (state.findFreeEntity()) |e| {
            const rng = state.random();
            e.* = .{
                .active = true,
                .kind = .star_field,
                .x = @floatFromInt(rng.intRangeAtMost(u16, 0, state.width - 1)),
                .y = @floatFromInt(rng.intRangeAtMost(u16, 0, state.height - 1)),
                .vx = 0,
                .vy = 0,
                .depth = 200 + @as(u8, @intCast(rng.intRangeAtMost(u8, 0, 50))),
                .color = switch (rng.intRangeAtMost(u8, 0, 3)) {
                    0 => .white,
                    1 => .bright_white,
                    2 => .bright_yellow,
                    else => .bright_cyan,
                },
                .die_offscreen = false,
                .lifetime = -1,
            };
        }
    }
}

fn spawnSmallShip(state: *SimState) void {
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    const going_right = rng.boolean();
    const speed = rng.float(f32) * 1.5 + 0.3;

    e.* = .{
        .active = true,
        .kind = .small_ship,
        .x = if (going_right) @as(f32, -50) else @as(f32, @floatFromInt(state.width + 5)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 1, state.height - 3)),
        .vx = if (going_right) speed else -speed,
        .vy = 0,
        .depth = 10 + rng.intRangeAtMost(u8, 0, 30),
        .color = switch (rng.intRangeAtMost(u8, 0, 6)) {
            0 => .cyan,
            1 => .bright_cyan,
            2 => .green,
            3 => .bright_green,
            4 => .yellow,
            5 => .bright_magenta,
            else => .white,
        },
        .shape_index = rng.intRangeAtMost(u16, 0, 5),
        .die_offscreen = true,
        .lifetime = -1,
        .width = 50,
        .height = 6,
    };
}

fn spawnAlien(state: *SimState) void {
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    const going_right = rng.boolean();
    const speed = rng.float(f32) * 0.8 + 0.2;

    e.* = .{
        .active = true,
        .kind = .alien,
        .x = if (going_right) @as(f32, -28) else @as(f32, @floatFromInt(state.width + 2)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 1, state.height - 18)),
        .vx = if (going_right) speed else -speed,
        .vy = @as(f32, rng.float(f32) * 0.2 - 0.1),
        .depth = 15 + rng.intRangeAtMost(u8, 0, 20),
        .color = switch (rng.intRangeAtMost(u8, 0, 4)) {
            0 => .green,
            1 => .bright_green,
            2 => .magenta,
            3 => .bright_yellow,
            else => .bright_white,
        },
        .shape_index = rng.intRangeAtMost(u16, 0, 5),
        .die_offscreen = true,
        .lifetime = -1,
        .width = 28,
        .height = 16,
    };
}

fn spawnUFO(state: *SimState) void {
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    const going_right = rng.boolean();
    const speed = rng.float(f32) * 2.0 + 1.0;

    e.* = .{
        .active = true,
        .kind = .ufo,
        .x = if (going_right) @as(f32, -20) else @as(f32, @floatFromInt(state.width + 2)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 1, state.height - 6)),
        .vx = if (going_right) speed else -speed,
        .vy = @as(f32, @sin(@as(f32, @floatFromInt(state.tick)) * 0.1)) * 0.3,
        .depth = 5 + rng.intRangeAtMost(u8, 0, 10),
        .color = .bright_yellow,
        .shape_index = rng.intRangeAtMost(u16, 0, 1),
        .frame_count = 2,
        .frame_speed = 0.3,
        .die_offscreen = true,
        .lifetime = -1,
        .width = 15,
        .height = 4,
    };
}

fn spawnMothership(state: *SimState) void {
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    const going_right = rng.boolean();
    const speed = rng.float(f32) * 0.5 + 0.3;

    e.* = .{
        .active = true,
        .kind = .mothership,
        .x = if (going_right) @as(f32, -40) else @as(f32, @floatFromInt(state.width + 2)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 1, state.height - 14)),
        .vx = if (going_right) speed else -speed,
        .vy = 0,
        .depth = 3,
        .color = .bright_white,
        .shape_index = if (going_right) @as(u16, 0) else @as(u16, 1),
        .die_offscreen = true,
        .lifetime = -1,
        .width = 35,
        .height = 12,
    };
}

fn spawnComet(state: *SimState) void {
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    const going_right = rng.boolean();
    const speed = rng.float(f32) * 3.0 + 2.0;

    e.* = .{
        .active = true,
        .kind = .comet,
        .x = if (going_right) @as(f32, -25) else @as(f32, @floatFromInt(state.width + 2)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 0, state.height - 9)),
        .vx = if (going_right) speed else -speed,
        .vy = rng.float(f32) * 0.4 - 0.2,
        .depth = 2,
        .color = .bright_yellow,
        .shape_index = if (going_right) @as(u16, 0) else @as(u16, 1),
        .die_offscreen = true,
        .lifetime = -1,
        .width = 20,
        .height = 8,
    };
}

fn spawnAsteroid(state: *SimState) void {
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    const going_right = rng.boolean();
    const speed = rng.float(f32) * 1.0 + 0.3;

    e.* = .{
        .active = true,
        .kind = .asteroid,
        .x = if (going_right) @as(f32, -8) else @as(f32, @floatFromInt(state.width + 2)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 1, state.height - 4)),
        .vx = if (going_right) speed else -speed,
        .vy = rng.float(f32) * 0.3 - 0.15,
        .depth = 20 + rng.intRangeAtMost(u8, 0, 15),
        .color = switch (rng.intRangeAtMost(u8, 0, 2)) {
            0 => .bright_black,
            1 => .white,
            else => .yellow,
        },
        .shape_index = rng.intRangeAtMost(u16, 0, 3),
        .die_offscreen = true,
        .lifetime = -1,
        .width = 8,
        .height = 4,
    };
}

fn spawnSatellite(state: *SimState) void {
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    const going_right = rng.boolean();
    const speed = rng.float(f32) * 0.6 + 0.1;

    e.* = .{
        .active = true,
        .kind = .satellite,
        .x = if (going_right) @as(f32, -12) else @as(f32, @floatFromInt(state.width + 2)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 1, state.height - 2)),
        .vx = if (going_right) speed else -speed,
        .vy = 0,
        .depth = 25 + rng.intRangeAtMost(u8, 0, 15),
        .color = .bright_blue,
        .shape_index = rng.intRangeAtMost(u16, 0, 2),
        .die_offscreen = true,
        .lifetime = -1,
        .width = 8,
        .height = 1,
    };
}

fn spawnShootingStar(state: *SimState) void {
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    e.* = .{
        .active = true,
        .kind = .shooting_star,
        .x = @floatFromInt(rng.intRangeAtMost(u16, 10, state.width - 1)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 0, state.height / 3)),
        .vx = -(rng.float(f32) * 4.0 + 3.0),
        .vy = rng.float(f32) * 2.0 + 1.0,
        .depth = 1,
        .color = .bright_white,
        .die_offscreen = true,
        .lifetime = 2.0,
        .width = 1,
        .height = 1,
    };
}

fn spawnSpaceStation(state: *SimState) void {
    if (state.countEntitiesOfKind(.space_station) > 0) return;
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    e.* = .{
        .active = true,
        .kind = .space_station,
        .x = @floatFromInt(rng.intRangeAtMost(u16, 5, state.width - 20)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 2, state.height - 14)),
        .vx = 0.05,
        .vy = 0,
        .depth = 180,
        .color = .bright_black,
        .die_offscreen = true,
        .lifetime = -1,
        .width = 15,
        .height = 11,
    };
}

fn spawnPlanet(state: *SimState) void {
    if (state.countEntitiesOfKind(.planet) > 0) return;
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    e.* = .{
        .active = true,
        .kind = .planet,
        .x = @floatFromInt(rng.intRangeAtMost(u16, 5, state.width - 20)),
        .y = @floatFromInt(rng.intRangeAtMost(u16, 2, state.height - 12)),
        .vx = 0.02,
        .vy = 0,
        .depth = 190,
        .color = switch (rng.intRangeAtMost(u8, 0, 3)) {
            0 => .red,
            1 => .blue,
            2 => .yellow,
            else => .cyan,
        },
        .die_offscreen = true,
        .lifetime = -1,
        .width = 17,
        .height = 9,
    };
}

fn spawnExhaust(state: *SimState, x: f32, y: f32, going_right: bool) void {
    const e = state.findFreeEntity() orelse return;
    const rng = state.random();

    e.* = .{
        .active = true,
        .kind = .exhaust,
        .x = x,
        .y = y,
        .vx = if (going_right) @as(f32, -0.5) else @as(f32, 0.5),
        .vy = rng.float(f32) * 0.4 - 0.2,
        .depth = 50,
        .color = switch (rng.intRangeAtMost(u8, 0, 2)) {
            0 => .bright_red,
            1 => .bright_yellow,
            else => .red,
        },
        .die_offscreen = true,
        .lifetime = 1.5 + rng.float(f32),
        .width = 1,
        .height = 1,
    };
}

// --- Drawing Shapes ---

fn drawMultilineShape(state: *SimState, shape: []const u8, x: i32, y: i32, color: Color, depth: u8) void {
    var row: i32 = 0;
    var col: i32 = 0;
    for (shape) |ch| {
        if (ch == '\n') {
            row += 1;
            col = 0;
        } else {
            if (ch != ' ') {
                state.setCell(x + col, y + row, ch, color, depth);
            }
            col += 1;
        }
    }
}

fn drawShape(state: *SimState, shape_lines: []const []const u8, x: i32, y: i32, color: Color, depth: u8) void {
    var row: i32 = 0;
    for (shape_lines) |line| {
        var col: i32 = 0;
        for (line) |ch| {
            if (ch != ' ') {
                state.setCell(x + col, y + row, ch, color, depth);
            }
            col += 1;
        }
        row += 1;
    }
}

fn drawEntity(state: *SimState, entity: *Entity) void {
    const ix: i32 = @intFromFloat(entity.x);
    const iy: i32 = @intFromFloat(entity.y);

    switch (entity.kind) {
        .star_field => {
            const rng = state.random();
            const ch_idx = rng.intRangeAtMost(u8, 0, star_chars.len - 1);
            // Stars twinkle - occasionally change character
            if (state.tick % 20 == 0 and rng.intRangeAtMost(u8, 0, 10) == 0) {
                state.setCell(ix, iy, star_chars[ch_idx], entity.color, entity.depth);
            } else {
                const stable_idx: usize = @intCast(@as(u32, @bitCast(@as(i32, @intFromFloat(entity.x * 7.0 + entity.y * 13.0)))) % star_chars.len);
                state.setCell(ix, iy, star_chars[stable_idx], entity.color, entity.depth);
            }
        },
        .small_ship => {
            const shapes = if (entity.vx > 0) &small_ships_right else &small_ships_left;
            const idx = @min(entity.shape_index, @as(u16, @intCast(shapes.len - 1)));
            drawMultilineShape(state, shapes[idx], ix, iy, entity.color, entity.depth);
        },
        .alien => {
            const idx = @min(entity.shape_index, @as(u16, @intCast(alien_shapes.len - 1)));
            drawMultilineShape(state, alien_shapes[idx], ix, iy, entity.color, entity.depth);
        },
        .ufo => {
            const shapes = if (entity.vx > 0) &ufo_shapes_right else &ufo_shapes_left;
            const idx = @min(entity.shape_index, @as(u16, @intCast(shapes.len - 1)));
            drawMultilineShape(state, shapes[idx], ix, iy, entity.color, entity.depth);
        },
        .mothership => {
            const shapes = if (entity.shape_index == 0) &mothership_right else &mothership_left;
            drawMultilineShape(state, shapes[0], ix, iy, entity.color, entity.depth);
        },
        .comet => {
            const shapes = if (entity.shape_index == 0) &comet_right else &comet_left;
            drawMultilineShape(state, shapes[0], ix, iy, entity.color, entity.depth);
        },
        .asteroid => {
            const idx = @min(entity.shape_index, @as(u16, @intCast(asteroid_shapes.len - 1)));
            drawMultilineShape(state, asteroid_shapes[idx], ix, iy, entity.color, entity.depth);
        },
        .satellite => {
            const shapes = if (entity.vx > 0) &satellite_right else &satellite_left;
            const idx = @min(entity.shape_index, @as(u16, @intCast(shapes.len - 1)));
            drawMultilineShape(state, shapes[idx], ix, iy, entity.color, entity.depth);
        },
        .shooting_star => {
            // Draw a streak
            const len: i32 = 4;
            var i: i32 = 0;
            while (i < len) : (i += 1) {
                const ch: u8 = if (i == 0) '*' else if (i == 1) '=' else '-';
                const col: Color = if (i == 0) .bright_white else if (i == 1) .bright_yellow else .yellow;
                state.setCell(ix + i, iy - @divTrunc(i, 2), ch, col, entity.depth);
            }
        },
        .space_station => {
            drawMultilineShape(state, space_station_shape[0], ix, iy, entity.color, entity.depth);
        },
        .planet => {
            drawMultilineShape(state, planet_shape[0], ix, iy, entity.color, entity.depth);
        },
        .exhaust => {
            const ch: u8 = if (entity.age < 0.5) '*' else if (entity.age < 1.0) '.' else ' ';
            state.setCell(ix, iy, ch, entity.color, entity.depth);
        },
        .nebula => {},
    }
}

// --- Update Logic ---

fn updateEntities(state: *SimState, dt: f32) void {
    for (&state.entities) |*e| {
        if (!e.active) continue;

        // Update position
        e.x += e.vx * dt * 10.0;
        e.y += e.vy * dt * 10.0;
        e.age += dt;

        // Animation frame update
        if (e.frame_count > 1) {
            e.frame_timer += dt;
            if (e.frame_timer >= e.frame_speed) {
                e.frame_timer = 0;
                e.frame = (e.frame + 1) % e.frame_count;
            }
        }

        // UFO wobble
        if (e.kind == .ufo) {
            e.vy = @sin(e.age * 3.0) * 0.3;
        }

        // Lifetime check
        if (e.lifetime > 0 and e.age >= e.lifetime) {
            e.active = false;
            continue;
        }

        // Off-screen check
        if (e.die_offscreen) {
            const w: f32 = @floatFromInt(state.width);
            const h: f32 = @floatFromInt(state.height);
            const margin: f32 = 50;
            if (e.x > w + margin or e.x < -margin or e.y > h + margin or e.y < -margin) {
                e.active = false;
            }
        }
    }
}

fn spawnEntities(state: *SimState) void {
    const rng = state.random();

    // Maintain ship population
    const ship_target = @max(3, state.width / 25);
    if (state.countEntitiesOfKind(.small_ship) < ship_target) {
        if (rng.intRangeAtMost(u16, 0, 30) == 0) {
            spawnSmallShip(state);
        }
    }

    // Occasionally spawn aliens
    if (state.countEntitiesOfKind(.alien) < 2) {
        if (rng.intRangeAtMost(u16, 0, 100) == 0) {
            spawnAlien(state);
        }
    }

    // Rarely spawn UFOs
    if (state.countEntitiesOfKind(.ufo) < 1) {
        if (rng.intRangeAtMost(u16, 0, 200) == 0) {
            spawnUFO(state);
        }
    }

    // Very rarely spawn motherships
    if (state.countEntitiesOfKind(.mothership) < 1) {
        if (rng.intRangeAtMost(u16, 0, 500) == 0) {
            spawnMothership(state);
        }
    }

    // Comets are rare
    if (state.countEntitiesOfKind(.comet) < 1) {
        if (rng.intRangeAtMost(u16, 0, 400) == 0) {
            spawnComet(state);
        }
    }

    // Asteroids
    if (state.countEntitiesOfKind(.asteroid) < 3) {
        if (rng.intRangeAtMost(u16, 0, 60) == 0) {
            spawnAsteroid(state);
        }
    }

    // Satellites
    if (state.countEntitiesOfKind(.satellite) < 2) {
        if (rng.intRangeAtMost(u16, 0, 80) == 0) {
            spawnSatellite(state);
        }
    }

    // Shooting stars
    if (rng.intRangeAtMost(u16, 0, 60) == 0) {
        spawnShootingStar(state);
    }

    // Space station (background)
    if (state.tick == 10) {
        spawnSpaceStation(state);
    }

    // Planet (background)
    if (state.tick == 20) {
        spawnPlanet(state);
    }

    // Exhaust from ships
    for (&state.entities) |*e| {
        if (!e.active) continue;
        if (e.kind == .small_ship or e.kind == .mothership) {
            if (rng.intRangeAtMost(u8, 0, 8) == 0) {
                const going_right = e.vx > 0;
                const ex = if (going_right) e.x - 1 else e.x + @as(f32, @floatFromInt(e.width));
                spawnExhaust(state, ex, e.y + @as(f32, @floatFromInt(e.height / 2)), going_right);
            }
        }
    }
}

// --- Input ---

fn readInput() ?u8 {
    var buf: [1]u8 = undefined;
    const n = std.posix.read(posix.STDIN_FILENO, &buf) catch return null;
    if (n == 0) return null;
    return buf[0];
}

// --- Main ---

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    try enableRawMode();
    defer disableRawMode();

    const state = try SimState.init(allocator);
    defer state.deinit();

    // Clear screen
    writeAll("\x1b[2J\x1b[H");

    // Spawn initial star field
    spawnStarField(state);

    const target_fps: u64 = 15;
    const frame_ns: u64 = 1_000_000_000 / target_fps;
    const dt: f32 = 1.0 / @as(f32, @floatFromInt(target_fps));

    while (state.running) {
        var ts_start: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_start);

        // Handle input
        if (readInput()) |key| {
            switch (key) {
                'q', 3 => state.running = false, // 3 = Ctrl-C
                'p' => state.paused = !state.paused,
                'r' => {
                    // Reset - kill all entities and respawn
                    for (&state.entities) |*e| {
                        e.active = false;
                    }
                    spawnStarField(state);
                },
                else => {},
            }
        }

        if (!state.paused) {
            // Spawn new entities
            spawnEntities(state);

            // Update
            updateEntities(state, dt);
        }

        // Draw
        state.clearBuffers();
        for (&state.entities) |*e| {
            if (e.active) {
                drawEntity(state, e);
            }
        }
        state.render();

        state.tick += 1;

        // Frame timing
        var ts_end: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_end);
        const elapsed_ns: i64 = (ts_end.sec - ts_start.sec) * 1_000_000_000 + (ts_end.nsec - ts_start.nsec);
        const sleep_ns = @as(i64, @intCast(frame_ns)) - elapsed_ns;
        if (sleep_ns > 0) {
            const sleep_spec = std.c.timespec{
                .sec = 0,
                .nsec = sleep_ns,
            };
            _ = std.c.nanosleep(&sleep_spec, null);
        }
    }

    // Restore terminal
    writeAll("\x1b[?25h\x1b[2J\x1b[H");
}
