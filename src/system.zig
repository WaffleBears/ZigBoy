const std = @import("std");
const gb_mod = @import("gb/gb.zig");
const gba_mod = @import("gba/gba.zig");

pub const Kind = enum { gb, gba };

pub const Buttons = packed struct {
    a: bool = false,
    b: bool = false,
    select: bool = false,
    start: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    l: bool = false,
    r: bool = false,
};

pub const FrameOutput = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
};

pub const System = struct {
    kind: Kind,
    gb: ?*gb_mod.Gb = null,
    gba: ?*gba_mod.Gba = null,
    gpa: std.mem.Allocator,
    rom_path: []u8,
    sample_rate: u32,
    fb_buf: []u32,
    fb_w: u32,
    fb_h: u32,

    pub fn loadFromPath(gpa: std.mem.Allocator, path: []const u8, data: []const u8, sample_rate: u32) !*System {
        const k = detectKind(path, data) orelse return error.UnknownFormat;

        const path_copy = try gpa.dupe(u8, path);
        errdefer gpa.free(path_copy);

        var fb_w: u32 = 0;
        var fb_h: u32 = 0;
        var fb_buf: []u32 = &.{};
        errdefer if (fb_buf.len > 0) gpa.free(fb_buf);

        var gb_state: ?*gb_mod.Gb = null;
        var gba_state: ?*gba_mod.Gba = null;
        errdefer {
            if (gb_state) |g| g.deinit();
            if (gba_state) |g| g.deinit();
        }

        switch (k) {
            .gb => {
                fb_w = gb_mod.SCREEN_W;
                fb_h = gb_mod.SCREEN_H;
                fb_buf = try gpa.alloc(u32, fb_w * fb_h);
                gb_state = try gb_mod.Gb.init(gpa, data, sample_rate);
            },
            .gba => {
                fb_w = gba_mod.SCREEN_W;
                fb_h = gba_mod.SCREEN_H;
                fb_buf = try gpa.alloc(u32, fb_w * fb_h);
                gba_state = try gba_mod.Gba.init(gpa, data, sample_rate);
            },
        }

        const sys = try gpa.create(System);
        sys.* = .{
            .kind = k,
            .gb = gb_state,
            .gba = gba_state,
            .gpa = gpa,
            .rom_path = path_copy,
            .sample_rate = sample_rate,
            .fb_buf = fb_buf,
            .fb_w = fb_w,
            .fb_h = fb_h,
        };
        return sys;
    }

    pub fn deinit(self: *System) void {
        switch (self.kind) {
            .gb => if (self.gb) |g| g.deinit(),
            .gba => if (self.gba) |g| g.deinit(),
        }
        if (self.fb_buf.len > 0) self.gpa.free(self.fb_buf);
        self.gpa.free(self.rom_path);
        self.gpa.destroy(self);
    }

    pub fn frameSize(self: *const System) [2]u32 {
        return .{ self.fb_w, self.fb_h };
    }

    pub fn runFrame(self: *System, b: Buttons) void {
        switch (self.kind) {
            .gb => {
                applyGbButtons(self.gb.?, b);
                self.gb.?.stepFrame();
            },
            .gba => {
                self.gba.?.applyButtons(.{
                    .a = b.a,
                    .b = b.b,
                    .select = b.select,
                    .start = b.start,
                    .right = b.right,
                    .left = b.left,
                    .up = b.up,
                    .down = b.down,
                    .l = b.l,
                    .r = b.r,
                });
                self.gba.?.stepFrame();
            },
        }
    }

    pub fn frame(self: *System) FrameOutput {
        switch (self.kind) {
            .gb => {
                self.gb.?.writeFramebuffer(self.fb_buf);
                return .{ .pixels = self.fb_buf, .width = self.fb_w, .height = self.fb_h };
            },
            .gba => {
                self.gba.?.writeFramebuffer(self.fb_buf);
                return .{ .pixels = self.fb_buf, .width = self.fb_w, .height = self.fb_h };
            },
        }
    }

    pub fn drainAudio(self: *System, out: []f32) usize {
        return switch (self.kind) {
            .gb => self.gb.?.drainAudio(out),
            .gba => self.gba.?.drainAudio(out),
        };
    }

    pub fn audioBuffered(self: *const System) usize {
        return switch (self.kind) {
            .gb => self.gb.?.apu.buffer_len,
            .gba => self.gba.?.apu.buffer_len,
        };
    }

    pub fn audioCapacity(self: *const System) usize {
        return switch (self.kind) {
            .gb => self.gb.?.apu.buffer_cap,
            .gba => self.gba.?.apu.buffer_cap,
        };
    }

    pub fn hasBattery(self: *const System) bool {
        return switch (self.kind) {
            .gb => self.gb.?.cart.has_battery,
            .gba => self.gba.?.cart.has_battery,
        };
    }

    pub fn batterySave(self: *const System) ?[]const u8 {
        return switch (self.kind) {
            .gb => if (self.gb.?.batteryRam()) |r| r else null,
            .gba => if (self.gba.?.batteryRam()) |r| r else null,
        };
    }

    pub fn batteryLoad(self: *System, data: []const u8) void {
        switch (self.kind) {
            .gb => self.gb.?.loadBatteryBytes(data),
            .gba => self.gba.?.loadBatteryBytes(data),
        }
    }

    pub fn saveStateBytes(self: *System) ![]u8 {
        return switch (self.kind) {
            .gb => self.gb.?.saveStateBytes(),
            .gba => self.gba.?.saveStateBytes(),
        };
    }

    pub fn loadStateBytes(self: *System, data: []const u8) !void {
        switch (self.kind) {
            .gb => try self.gb.?.loadStateBytes(data),
            .gba => try self.gba.?.loadStateBytes(data),
        }
    }

    pub fn reset(self: *System) void {
        switch (self.kind) {
            .gb => self.gb.?.reset(),
            .gba => self.gba.?.reset(),
        }
    }

    pub fn label(self: *const System) []const u8 {
        return switch (self.kind) {
            .gb => if (self.gb.?.cgb_mode) "GBC" else "GB",
            .gba => "GBA",
        };
    }

    pub fn setDmgPalette(self: *System, palette: [4]u32) void {
        if (self.kind == .gb) self.gb.?.setDmgPalette(palette);
    }

    pub fn isCgb(self: *const System) bool {
        return self.kind == .gb and self.gb.?.cgb_mode;
    }

    pub fn isGba(self: *const System) bool {
        return self.kind == .gba;
    }

    pub fn romTitle(self: *const System, buf: []u8) []const u8 {
        switch (self.kind) {
            .gb => {
                const g = self.gb.?;
                var n: usize = 0;
                var i: usize = 0;
                while (i < g.cart.title_len and n < buf.len) : (i += 1) {
                    const c = g.cart.title[i];
                    if (c >= 0x20 and c < 0x7F) {
                        buf[n] = c;
                        n += 1;
                    }
                }
                return buf[0..n];
            },
            .gba => {
                const g = self.gba.?;
                const t = g.title();
                var n: usize = 0;
                var i: usize = 0;
                while (i < t.len and n < buf.len) : (i += 1) {
                    const c = t[i];
                    if (c >= 0x20 and c < 0x7F) {
                        buf[n] = c;
                        n += 1;
                    }
                }
                return buf[0..n];
            },
        }
    }
};

fn applyGbButtons(g: *gb_mod.Gb, b: Buttons) void {
    setBtn(g, .right, b.right);
    setBtn(g, .left, b.left);
    setBtn(g, .up, b.up);
    setBtn(g, .down, b.down);
    setBtn(g, .a, b.a);
    setBtn(g, .b, b.b);
    setBtn(g, .start, b.start);
    setBtn(g, .select, b.select);
}

fn setBtn(g: *gb_mod.Gb, btn: gb_mod.Button, pressed: bool) void {
    if (pressed) g.press(btn) else g.release(btn);
}

pub fn detectKind(path: []const u8, data: []const u8) ?Kind {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.') {
            const ext = path[i + 1 ..];
            if (eqIcase(ext, "gb")) return .gb;
            if (eqIcase(ext, "gbc")) return .gb;
            if (eqIcase(ext, "gba")) return .gba;
            break;
        }
        if (path[i] == '/' or path[i] == '\\') break;
    }
    if (data.len >= 0xC0) {
        const nintendo_logo: [4]u8 = .{ 0x24, 0xFF, 0xAE, 0x51 };
        if (std.mem.eql(u8, data[4..8], &nintendo_logo)) return .gba;
    }
    if (data.len >= 0x150) {
        const gb_logo: [8]u8 = .{ 0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B };
        if (std.mem.eql(u8, data[0x104..0x10C], &gb_logo)) return .gb;
    }
    return null;
}

fn eqIcase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}
