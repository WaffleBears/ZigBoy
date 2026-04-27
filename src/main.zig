const std = @import("std");
const a = @import("app.zig");
const audio = @import("audio.zig");
const draw = @import("draw.zig");
const platform = @import("platform.zig");
const rl = a.rl;

fn handleMouseClick(app: *a.App, mouse: rl.Vector2) void {
    switch (app.view) {
        .config => handleConfigClick(app, mouse),
        .help => handleHelpClick(app, mouse),
        .playing => handlePlayingClick(app, mouse),
    }
    app.pressed_btn_idx = null;
}

fn handleConfigClick(app: *a.App, mouse: rl.Vector2) void {
    if (rl.CheckCollisionPointRec(mouse, app.config_close_rect)) {
        app.view = .playing;
        return;
    }
    for (app.selector_buttons) |btn| {
        if (rl.CheckCollisionPointRec(mouse, btn.rect)) {
            a.handleSelector(app, btn.action);
            return;
        }
    }
    for (app.config_rows) |row| {
        if (rl.CheckCollisionPointRec(mouse, row.rect)) {
            a.toggleConfig(app, row.toggle);
            return;
        }
    }
    if (!rl.CheckCollisionPointRec(mouse, app.config_panel_rect)) {
        app.view = .playing;
    }
}

fn handleHelpClick(app: *a.App, mouse: rl.Vector2) void {
    if (rl.CheckCollisionPointRec(mouse, app.help_close_rect)) {
        app.view = .playing;
    } else if (!rl.CheckCollisionPointRec(mouse, app.help_panel_rect)) {
        app.view = .playing;
    }
}

fn handlePlayingClick(app: *a.App, mouse: rl.Vector2) void {
    const idx = app.pressed_btn_idx orelse return;
    if (idx >= app.btn_count) return;
    const btn = &app.buttons[idx];
    const enabled = !btn.needs_rom or app.system != null;
    if (enabled and rl.CheckCollisionPointRec(mouse, btn.rect)) {
        a.handleAction(app, btn.action);
    }
}

fn capturePressedButton(app: *a.App, mouse: rl.Vector2) void {
    app.pressed_btn_idx = null;
    if (app.view != .playing) return;
    var i: usize = 0;
    while (i < app.btn_count) : (i += 1) {
        const btn = &app.buttons[i];
        const enabled = !btn.needs_rom or app.system != null;
        if (enabled and rl.CheckCollisionPointRec(mouse, btn.rect)) {
            app.pressed_btn_idx = i;
            return;
        }
    }
}

fn runEmulatorFrames(app: *a.App) void {
    if (app.paused or app.view != .playing or app.system == null) return;
    const frames: u32 = if (app.turbo) 4 else 1;
    const emu = app.system.?;
    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        if (!app.turbo and emu.audioBuffered() > a.FRAME_FRAMES * 12) break;
        emu.runFrame(app.keys);
        app.fps_frames += 1;
        if (i + 1 < frames) {
            _ = emu.drainAudio(app.audio_scratch[0..]);
        }
    }
}

fn updateFps(app: *a.App, dt: f32) void {
    app.fps_timer += dt;
    if (app.fps_timer >= 1.0) {
        app.fps_value = @as(f32, @floatFromInt(app.fps_frames)) / @as(f32, @floatCast(app.fps_timer));
        app.fps_frames = 0;
        app.fps_timer = 0;
    }
}

fn drawFrame(app: *a.App, screen_w: f32, screen_h: f32, mouse: rl.Vector2, mouse_down: bool) void {
    rl.BeginDrawing();
    rl.ClearBackground(a.C_BG);

    const game_y = a.TOOLBAR_H;
    const game_h = screen_h - a.TOOLBAR_H - a.STATUSBAR_H;
    rl.DrawRectangle(0, @intFromFloat(game_y), @intFromFloat(screen_w), @intFromFloat(game_h), a.C_BG);

    if (app.system != null) {
        const dest = draw.computeViewportRect(app, 0, game_y, screen_w, game_h);
        const src: rl.Rectangle = .{ .x = 0, .y = 0, .width = @floatFromInt(app.target_w), .height = @floatFromInt(app.target_h) };
        rl.DrawTexturePro(app.fb_texture, src, dest, .{ .x = 0, .y = 0 }, 0, rl.WHITE);
    } else {
        draw.drawPlaceholder(app, 0, game_y, screen_w, game_h);
    }

    draw.drawToolbar(app, screen_w, mouse, mouse_down);
    draw.drawStatusBar(app, screen_w, screen_h);
    if (app.view == .config) draw.drawConfigMenu(app, screen_w, screen_h, mouse, mouse_down);
    if (app.view == .help) draw.drawHelpMenu(app, screen_w, screen_h, mouse, mouse_down);
    draw.drawFlashMsg(app, screen_w, screen_h);

    rl.EndDrawing();
}

fn loadPendingRom(app: *a.App) void {
    const path = app.pending_rom orelse return;
    app.pending_rom = null;
    a.loadRom(app, path) catch |e| {
        a.setFlashMsg(app, "Failed to load: {s}", .{@errorName(e)});
    };
    app.gpa.free(path);
}

fn loadCmdLineRom(app: *a.App) void {
    const path = platform.cmdLineFirstArg(app.gpa) orelse return;
    defer app.gpa.free(path);
    a.loadRom(app, path) catch |e| {
        a.setFlashMsg(app, "Failed to open: {s}", .{@errorName(e)});
    };
}

fn cleanup(app: *a.App) void {
    if (app.system) |s| {
        if (app.sav_path) |sp| {
            if (s.batterySave()) |ram| platform.writeAllToFile(app.gpa, sp, ram) catch {};
        }
        s.deinit();
    }
    if (app.rom_path) |rp| app.gpa.free(rp);
    if (app.sav_path) |sp| app.gpa.free(sp);
    if (app.state_path) |stp| app.gpa.free(stp);
    if (app.pending_rom) |pr| app.gpa.free(pr);
    if (app.fb_buffer.len > 0) {
        rl.UnloadTexture(app.fb_texture);
        app.gpa.free(app.fb_buffer);
    }
    if (app.font_owned) rl.UnloadFont(app.font);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var app: a.App = .{ .gpa = alloc };
    a.initButtons(&app);

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT | rl.FLAG_MSAA_4X_HINT);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    const init_w: c_int = @intFromFloat(240 * a.DEFAULT_SCALE);
    const init_h: c_int = @intFromFloat(160 * a.DEFAULT_SCALE + a.TOOLBAR_H + a.STATUSBAR_H);
    rl.InitWindow(init_w, init_h, a.APP_NAME);
    defer rl.CloseWindow();
    rl.SetWindowMinSize(480, 360);
    rl.SetExitKey(0);
    rl.SetTargetFPS(60);

    rl.InitAudioDevice();
    defer rl.CloseAudioDevice();
    rl.SetAudioStreamBufferSizeDefault(@intCast(a.FRAME_FRAMES));
    app.audio_stream = rl.LoadAudioStream(a.SAMPLE_RATE, 16, 2);
    defer rl.UnloadAudioStream(app.audio_stream);
    rl.PlayAudioStream(app.audio_stream);
    var silence_buf: [a.FRAME_FRAMES * 2]i16 = .{0} ** (a.FRAME_FRAMES * 2);
    rl.UpdateAudioStream(app.audio_stream, &silence_buf, a.FRAME_FRAMES);
    rl.UpdateAudioStream(app.audio_stream, &silence_buf, a.FRAME_FRAMES);

    app.font = draw.loadAppFont();
    app.font_owned = app.font.texture.id != rl.GetFontDefault().texture.id;

    try a.ensureFramebuffer(&app, 240, 160);
    @memset(app.fb_buffer, 0xFF101010);
    rl.UpdateTexture(app.fb_texture, app.fb_buffer.ptr);

    defer cleanup(&app);

    loadCmdLineRom(&app);

    while (!rl.WindowShouldClose()) {
        const screen_w: f32 = @floatFromInt(rl.GetScreenWidth());
        const screen_h: f32 = @floatFromInt(rl.GetScreenHeight());

        a.layoutButtons(&app, screen_w);
        a.handleDroppedFiles(&app);
        loadPendingRom(&app);

        if (rl.IsKeyPressed(rl.KEY_ESCAPE) and app.view != .playing) {
            app.view = .playing;
        }

        if (app.view == .playing) {
            a.pollHotkeys(&app);
            a.pollGameKeys(&app);
        } else {
            app.keys = .{};
            app.turbo = false;
        }

        const mouse = rl.GetMousePosition();
        const mouse_down = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT);

        if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) capturePressedButton(&app, mouse);
        if (rl.IsMouseButtonReleased(rl.MOUSE_BUTTON_LEFT)) handleMouseClick(&app, mouse);

        const dt = rl.GetFrameTime();
        runEmulatorFrames(&app);
        updateFps(&app, dt);
        if (app.flash_timer > 0) app.flash_timer -= dt;

        a.updateFramebufferTexture(&app);
        audio.pump(&app);
        drawFrame(&app, screen_w, screen_h, mouse, mouse_down);
    }
}
