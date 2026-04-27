const std = @import("std");
const sys = @import("system.zig");
const platform = @import("platform.zig");

pub const rl = @cImport({
    @cInclude("raylib.h");
});

pub const APP_NAME: [*:0]const u8 = "ZigBoy";
pub const APP_VERSION: [*:0]const u8 = "1.1";

pub const SAMPLE_RATE: u32 = 48000;
pub const FRAME_FRAMES: usize = 800;

pub const DEFAULT_SCALE: f32 = 4.0;
pub const TOOLBAR_H: f32 = 48;
pub const STATUSBAR_H: f32 = 28;

pub const FLASH_MSG_CAP: usize = 256;
pub const STATE_SLOTS: u8 = 10;

pub const C_BG = rl.Color{ .r = 0x14, .g = 0x14, .b = 0x18, .a = 0xFF };
pub const C_PANEL = rl.Color{ .r = 0x20, .g = 0x22, .b = 0x28, .a = 0xFF };
pub const C_PANEL_HI = rl.Color{ .r = 0x2A, .g = 0x2D, .b = 0x35, .a = 0xFF };
pub const C_BORDER = rl.Color{ .r = 0x33, .g = 0x36, .b = 0x40, .a = 0xFF };
pub const C_ACCENT = rl.Color{ .r = 0xE6, .g = 0x86, .b = 0x3A, .a = 0xFF };
pub const C_ACCENT_DIM = rl.Color{ .r = 0xA6, .g = 0x5C, .b = 0x22, .a = 0xFF };
pub const C_TEXT = rl.Color{ .r = 0xEC, .g = 0xEC, .b = 0xEE, .a = 0xFF };
pub const C_TEXT_DIM = rl.Color{ .r = 0x9A, .g = 0x9D, .b = 0xA8, .a = 0xFF };
pub const C_TEXT_DIS = rl.Color{ .r = 0x55, .g = 0x58, .b = 0x60, .a = 0xFF };

pub const DmgPalette = enum(u8) {
    classic_green = 0,
    grayscale = 1,
    autumn = 2,
    blue = 3,
    pocket = 4,

    pub fn label(self: DmgPalette) []const u8 {
        return switch (self) {
            .classic_green => "Classic Green",
            .grayscale => "Grayscale",
            .autumn => "Autumn",
            .blue => "Ocean Blue",
            .pocket => "Pocket",
        };
    }

    pub fn colors(self: DmgPalette) [4]u32 {
        return switch (self) {
            .classic_green => .{ 0xFFD0F8E0, 0xFF70C088, 0xFF566834, 0xFF201808 },
            .grayscale => .{ 0xFFFFFFFF, 0xFFAAAAAA, 0xFF555555, 0xFF000000 },
            .autumn => .{ 0xFFFFE7C7, 0xFFE5A26B, 0xFF8B5535, 0xFF2A1810 },
            .blue => .{ 0xFFE6F2FF, 0xFF6BA8E0, 0xFF2C4F8C, 0xFF0A1530 },
            .pocket => .{ 0xFFE0E0D0, 0xFFA0A088, 0xFF606040, 0xFF202010 },
        };
    }
};

pub const ButtonAction = enum {
    open,
    pause,
    reset,
    save_state,
    load_state,
    mute,
    config,
    help,
};

pub const View = enum { playing, config, help };

pub const ConfigToggle = enum { smooth, integer, show_fps, mute, pause };

pub const ConfigRow = struct {
    label: []const u8,
    toggle: ConfigToggle,
    rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

pub const SelectorAction = enum { palette_prev, palette_next, slot_prev, slot_next, vol_dec, vol_inc };

pub const SelectorButton = struct {
    action: SelectorAction,
    rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

pub const Button = struct {
    label: []const u8,
    action: ButtonAction,
    rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    toggleable: bool = false,
    needs_rom: bool = false,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    system: ?*sys.System = null,
    rom_path: ?[]u8 = null,
    sav_path: ?[]u8 = null,
    state_path: ?[]u8 = null,

    paused: bool = false,
    turbo: bool = false,
    muted: bool = false,
    smooth: bool = true,
    integer_scale: bool = false,
    show_fps: bool = true,
    view: View = .playing,
    dmg_palette: DmgPalette = .classic_green,
    state_slot: u8 = 0,
    volume: u8 = 100,
    pressed_btn_idx: ?usize = null,
    audio_underrun_streak: u32 = 0,

    keys: sys.Buttons = .{},
    fps_value: f32 = 0,
    fps_frames: u32 = 0,
    fps_timer: f64 = 0,

    target_w: u32 = 240,
    target_h: u32 = 160,

    fb_image: rl.Image = undefined,
    fb_texture: rl.Texture2D = undefined,
    fb_buffer: []u32 = &.{},

    audio_stream: rl.AudioStream = undefined,
    audio_scratch: [FRAME_FRAMES * 2]f32 = undefined,
    audio_i16: [FRAME_FRAMES * 2]i16 = undefined,
    audio_pending_len: usize = 0,
    audio_smooth_gain: f32 = 0,
    audio_silence_samples: u32 = 0,
    audio_was_playing: bool = false,

    font: rl.Font = undefined,
    font_owned: bool = false,

    buttons: [8]Button = undefined,
    btn_count: usize = 0,

    config_rows: [5]ConfigRow = undefined,
    config_close_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    config_panel_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    help_close_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    help_panel_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    selector_buttons: [6]SelectorButton = .{
        .{ .action = .palette_prev },
        .{ .action = .palette_next },
        .{ .action = .slot_prev },
        .{ .action = .slot_next },
        .{ .action = .vol_dec },
        .{ .action = .vol_inc },
    },

    pending_rom: ?[]u8 = null,
    flash_msg: [FLASH_MSG_CAP]u8 = .{0} ** FLASH_MSG_CAP,
    flash_msg_len: usize = 0,
    flash_timer: f32 = 0,
};

pub fn setFlashMsg(app: *App, comptime fmt: []const u8, args: anytype) void {
    const slice = std.fmt.bufPrint(&app.flash_msg, fmt, args) catch blk: {
        const trunc = "(message too long)";
        const n = @min(trunc.len, app.flash_msg.len);
        @memcpy(app.flash_msg[0..n], trunc[0..n]);
        break :blk app.flash_msg[0..n];
    };
    app.flash_msg_len = slice.len;
    app.flash_timer = 2.5;
}

pub fn initButtons(app: *App) void {
    app.buttons[0] = .{ .label = "Open", .action = .open };
    app.buttons[1] = .{ .label = "Pause", .action = .pause, .toggleable = true, .needs_rom = true };
    app.buttons[2] = .{ .label = "Reset", .action = .reset, .needs_rom = true };
    app.buttons[3] = .{ .label = "Save", .action = .save_state, .needs_rom = true };
    app.buttons[4] = .{ .label = "Load", .action = .load_state, .needs_rom = true };
    app.buttons[5] = .{ .label = "Mute", .action = .mute, .toggleable = true };
    app.buttons[6] = .{ .label = "Config", .action = .config, .toggleable = true };
    app.buttons[7] = .{ .label = "Help", .action = .help, .toggleable = true };
    app.btn_count = 8;
}

pub fn buttonToggled(app: *App, action: ButtonAction) bool {
    return switch (action) {
        .pause => app.paused,
        .mute => app.muted,
        .config => app.view == .config,
        .help => app.view == .help,
        else => false,
    };
}

pub fn layoutButtons(app: *App, screen_w: f32) void {
    const pad: f32 = 10;
    const gap: f32 = 6;
    const btn_w: f32 = 80;
    const small_w: f32 = 70;
    const btn_h: f32 = TOOLBAR_H - 16;
    var x: f32 = pad;
    var i: usize = 0;
    while (i < app.btn_count) : (i += 1) {
        const btn = &app.buttons[i];
        const w: f32 = if (btn.action == .config or btn.action == .help) small_w else btn_w;
        if (btn.action == .help) {
            btn.rect = .{ .x = screen_w - w - pad, .y = 8, .width = w, .height = btn_h };
        } else if (btn.action == .config) {
            btn.rect = .{ .x = screen_w - w * 2 - pad - gap, .y = 8, .width = w, .height = btn_h };
        } else {
            btn.rect = .{ .x = x, .y = 8, .width = w, .height = btn_h };
            x += w + gap;
        }
    }
}

pub fn ensureFramebuffer(app: *App, w: u32, h: u32) !void {
    if (app.target_w == w and app.target_h == h and app.fb_buffer.len == w * h) return;
    if (app.fb_buffer.len > 0) {
        rl.UnloadTexture(app.fb_texture);
        app.gpa.free(app.fb_buffer);
    }
    app.target_w = w;
    app.target_h = h;
    app.fb_buffer = try app.gpa.alloc(u32, w * h);
    @memset(app.fb_buffer, 0xFF101010);
    app.fb_image = .{
        .data = app.fb_buffer.ptr,
        .width = @intCast(w),
        .height = @intCast(h),
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
    app.fb_texture = rl.LoadTextureFromImage(app.fb_image);
    rl.SetTextureFilter(app.fb_texture, if (app.smooth) rl.TEXTURE_FILTER_BILINEAR else rl.TEXTURE_FILTER_POINT);
}

pub fn loadRom(app: *App, path: []const u8) !void {
    const data_opt = try platform.readAllFromFile(app.gpa, path);
    if (data_opt == null) return error.FileNotFound;
    const data = data_opt.?;
    defer app.gpa.free(data);
    if (data.len > 64 * 1024 * 1024 or data.len < 0x150) return error.BadRomSize;

    const new_rom_path = try app.gpa.dupe(u8, path);
    errdefer app.gpa.free(new_rom_path);
    const new_sav_path = try platform.pathReplaceExt(app.gpa, path, ".sav");
    errdefer app.gpa.free(new_sav_path);
    const new_state_path = try platform.statePathForSlot(app.gpa, path, app.state_slot);
    errdefer app.gpa.free(new_state_path);

    const system = try sys.System.loadFromPath(app.gpa, path, data, SAMPLE_RATE);
    errdefer system.deinit();

    if (platform.readAllFromFile(app.gpa, new_sav_path) catch null) |save| {
        defer app.gpa.free(save);
        system.batteryLoad(save);
    }

    if (app.system) |old| {
        if (app.sav_path) |sp| {
            if (old.batterySave()) |ram| platform.writeAllToFile(app.gpa, sp, ram) catch |e| {
                setFlashMsg(app, "Battery save failed: {s}", .{@errorName(e)});
            };
        }
        old.deinit();
    }
    if (app.rom_path) |rp| app.gpa.free(rp);
    if (app.sav_path) |sp| app.gpa.free(sp);
    if (app.state_path) |stp| app.gpa.free(stp);

    app.system = system;
    app.rom_path = new_rom_path;
    app.sav_path = new_sav_path;
    app.state_path = new_state_path;
    app.keys = .{};

    if (!system.isCgb()) system.setDmgPalette(app.dmg_palette.colors());

    const fs = system.frameSize();
    try ensureFramebuffer(app, fs[0], fs[1]);

    var prime: u32 = 0;
    while (prime < 8) : (prime += 1) {
        system.runFrame(.{});
    }
    app.audio_pending_len = 0;
    app.audio_underrun_streak = 0;
    app.audio_smooth_gain = 0;
    app.audio_silence_samples = SAMPLE_RATE / 5;

    var name_buf: [64]u8 = undefined;
    const name = system.romTitle(&name_buf);
    setFlashMsg(app, "Loaded: {s}", .{if (name.len > 0) name else std.fs.path.basename(path)});
}

pub fn updateStatePathForSlot(app: *App) void {
    if (app.rom_path) |rp| {
        const new_path = platform.statePathForSlot(app.gpa, rp, app.state_slot) catch return;
        if (app.state_path) |old| app.gpa.free(old);
        app.state_path = new_path;
    }
}

pub fn doSaveState(app: *App) void {
    if (app.system == null or app.state_path == null) {
        setFlashMsg(app, "No ROM loaded", .{});
        return;
    }
    const data = app.system.?.saveStateBytes() catch |e| {
        setFlashMsg(app, "Save state failed: {s}", .{@errorName(e)});
        return;
    };
    defer app.gpa.free(data);
    platform.writeAllToFile(app.gpa, app.state_path.?, data) catch |e| {
        setFlashMsg(app, "Write state failed: {s}", .{@errorName(e)});
        return;
    };
    setFlashMsg(app, "State saved (slot {d})", .{app.state_slot});
}

pub fn doLoadState(app: *App) void {
    if (app.system == null or app.state_path == null) {
        setFlashMsg(app, "No ROM loaded", .{});
        return;
    }
    const data_opt = platform.readAllFromFile(app.gpa, app.state_path.?) catch |e| {
        setFlashMsg(app, "Read state failed: {s}", .{@errorName(e)});
        return;
    };
    if (data_opt == null) {
        setFlashMsg(app, "No save state in slot {d}", .{app.state_slot});
        return;
    }
    defer app.gpa.free(data_opt.?);
    app.system.?.loadStateBytes(data_opt.?) catch |e| {
        setFlashMsg(app, "Load state failed: {s}", .{@errorName(e)});
        return;
    };
    setFlashMsg(app, "State loaded", .{});
}

pub fn doReset(app: *App) void {
    if (app.system) |s| {
        s.reset();
        if (!s.isCgb()) s.setDmgPalette(app.dmg_palette.colors());
        setFlashMsg(app, "Reset", .{});
    }
}

pub fn doScreenshot(app: *App) void {
    if (app.system == null or app.fb_buffer.len == 0) {
        setFlashMsg(app, "No frame to capture", .{});
        return;
    }
    const path = platform.nextScreenshotPath(app.gpa, app.rom_path) catch {
        setFlashMsg(app, "Screenshot path failed", .{});
        return;
    };
    defer app.gpa.free(path);
    const path_z = app.gpa.dupeZ(u8, path) catch {
        setFlashMsg(app, "Screenshot alloc failed", .{});
        return;
    };
    defer app.gpa.free(path_z);
    const src: rl.Image = .{
        .data = app.fb_buffer.ptr,
        .width = @intCast(app.target_w),
        .height = @intCast(app.target_h),
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
    if (rl.ExportImage(src, path_z.ptr)) {
        setFlashMsg(app, "Saved {s}", .{path});
    } else {
        setFlashMsg(app, "Screenshot failed", .{});
    }
}

pub fn doToggleFullscreen(app: *App) void {
    rl.ToggleFullscreen();
    if (rl.IsWindowFullscreen()) {
        setFlashMsg(app, "Fullscreen", .{});
    } else {
        setFlashMsg(app, "Windowed", .{});
    }
}

pub fn cyclePalette(app: *App, dir: i32) void {
    const cur: i32 = @intCast(@intFromEnum(app.dmg_palette));
    const total: i32 = @intCast(@typeInfo(DmgPalette).@"enum".fields.len);
    var n = @mod(cur + dir, total);
    if (n < 0) n += total;
    app.dmg_palette = @enumFromInt(@as(u8, @intCast(n)));
    if (app.system) |s| {
        if (!s.isCgb()) s.setDmgPalette(app.dmg_palette.colors());
    }
    setFlashMsg(app, "Palette: {s}", .{app.dmg_palette.label()});
}

pub fn cycleSlot(app: *App, dir: i32) void {
    const cur: i32 = @intCast(app.state_slot);
    const total: i32 = @intCast(STATE_SLOTS);
    var n = @mod(cur + dir, total);
    if (n < 0) n += total;
    app.state_slot = @intCast(n);
    updateStatePathForSlot(app);
    setFlashMsg(app, "State slot: {d}", .{app.state_slot});
}

pub fn adjustVolume(app: *App, delta: i32) void {
    const cur: i32 = @intCast(app.volume);
    var n = cur + delta;
    if (n < 0) n = 0;
    if (n > 100) n = 100;
    app.volume = @intCast(n);
    setFlashMsg(app, "Volume: {d}%", .{app.volume});
}

pub fn handleSelector(app: *App, a: SelectorAction) void {
    switch (a) {
        .palette_prev => cyclePalette(app, -1),
        .palette_next => cyclePalette(app, 1),
        .slot_prev => cycleSlot(app, -1),
        .slot_next => cycleSlot(app, 1),
        .vol_dec => adjustVolume(app, -10),
        .vol_inc => adjustVolume(app, 10),
    }
}

pub fn requestOpenDialog(app: *App) void {
    if (platform.openRomDialog(app.gpa)) |path| {
        if (app.pending_rom) |old| app.gpa.free(old);
        app.pending_rom = path;
    }
}

pub fn handleAction(app: *App, action: ButtonAction) void {
    switch (action) {
        .open => requestOpenDialog(app),
        .pause => {
            app.paused = !app.paused;
            if (app.paused) setFlashMsg(app, "Paused", .{}) else setFlashMsg(app, "Resumed", .{});
        },
        .reset => doReset(app),
        .save_state => doSaveState(app),
        .load_state => doLoadState(app),
        .mute => {
            app.muted = !app.muted;
            if (app.muted) setFlashMsg(app, "Muted", .{}) else setFlashMsg(app, "Unmuted", .{});
        },
        .config => app.view = if (app.view == .config) .playing else .config,
        .help => app.view = if (app.view == .help) .playing else .help,
    }
}

pub fn toggleConfig(app: *App, t: ConfigToggle) void {
    switch (t) {
        .smooth => {
            app.smooth = !app.smooth;
            if (app.fb_buffer.len > 0) {
                rl.SetTextureFilter(app.fb_texture, if (app.smooth) rl.TEXTURE_FILTER_BILINEAR else rl.TEXTURE_FILTER_POINT);
            }
        },
        .integer => app.integer_scale = !app.integer_scale,
        .show_fps => app.show_fps = !app.show_fps,
        .mute => app.muted = !app.muted,
        .pause => app.paused = !app.paused,
    }
}

pub fn configToggled(app: *const App, t: ConfigToggle) bool {
    return switch (t) {
        .smooth => app.smooth,
        .integer => app.integer_scale,
        .show_fps => app.show_fps,
        .mute => app.muted,
        .pause => app.paused,
    };
}

pub fn pollHotkeys(app: *App) void {
    const ctrl = rl.IsKeyDown(rl.KEY_LEFT_CONTROL) or rl.IsKeyDown(rl.KEY_RIGHT_CONTROL);
    if (rl.IsKeyPressed(rl.KEY_F1)) doSaveState(app);
    if (rl.IsKeyPressed(rl.KEY_F3)) doLoadState(app);
    if (rl.IsKeyPressed(rl.KEY_F5)) doSaveState(app);
    if (rl.IsKeyPressed(rl.KEY_F7)) doLoadState(app);
    if (rl.IsKeyPressed(rl.KEY_F11)) doToggleFullscreen(app);
    if (rl.IsKeyPressed(rl.KEY_F12)) doScreenshot(app);
    if (rl.IsKeyPressed(rl.KEY_LEFT_BRACKET)) cycleSlot(app, -1);
    if (rl.IsKeyPressed(rl.KEY_RIGHT_BRACKET)) cycleSlot(app, 1);
    if (rl.IsKeyPressed(rl.KEY_P)) handleAction(app, .pause);
    if (rl.IsKeyPressed(rl.KEY_R) and !ctrl) doReset(app);
    if (rl.IsKeyPressed(rl.KEY_M)) handleAction(app, .mute);
    if (rl.IsKeyPressed(rl.KEY_O) and ctrl) requestOpenDialog(app);
    if (rl.IsKeyPressed(rl.KEY_MINUS)) adjustVolume(app, -10);
    if (rl.IsKeyPressed(rl.KEY_EQUAL)) adjustVolume(app, 10);
}

pub fn pollGameKeys(app: *App) void {
    app.keys = .{
        .right = rl.IsKeyDown(rl.KEY_RIGHT),
        .left = rl.IsKeyDown(rl.KEY_LEFT),
        .up = rl.IsKeyDown(rl.KEY_UP),
        .down = rl.IsKeyDown(rl.KEY_DOWN),
        .a = rl.IsKeyDown(rl.KEY_Z),
        .b = rl.IsKeyDown(rl.KEY_X),
        .l = rl.IsKeyDown(rl.KEY_A),
        .r = rl.IsKeyDown(rl.KEY_S),
        .start = rl.IsKeyDown(rl.KEY_ENTER),
        .select = rl.IsKeyDown(rl.KEY_RIGHT_SHIFT) or rl.IsKeyDown(rl.KEY_BACKSPACE),
    };
    app.turbo = rl.IsKeyDown(rl.KEY_TAB);
}

pub fn handleDroppedFiles(app: *App) void {
    if (!rl.IsFileDropped()) return;
    const list = rl.LoadDroppedFiles();
    defer rl.UnloadDroppedFiles(list);
    if (list.count == 0) return;
    const c_path = list.paths[0];
    const path_len = std.mem.len(c_path);
    if (app.pending_rom) |old| app.gpa.free(old);
    app.pending_rom = app.gpa.dupe(u8, c_path[0..path_len]) catch null;
    if (list.count > 1) {
        setFlashMsg(app, "Loaded first of {d} dropped files", .{list.count});
    }
}

pub fn updateFramebufferTexture(app: *App) void {
    if (app.system == null) return;
    const f = app.system.?.frame();
    const n = @min(app.fb_buffer.len, f.pixels.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const argb = f.pixels[i];
        const a: u32 = (argb & 0xFF000000);
        const r: u32 = (argb >> 16) & 0xFF;
        const g: u32 = (argb >> 8) & 0xFF;
        const b: u32 = argb & 0xFF;
        app.fb_buffer[i] = a | (b << 16) | (g << 8) | r;
    }
    rl.UpdateTexture(app.fb_texture, app.fb_buffer.ptr);
}
