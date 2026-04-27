const std = @import("std");
const a = @import("app.zig");
const rl = a.rl;

pub fn loadAppFont() rl.Font {
    const candidates = [_][*:0]const u8{
        "C:/Windows/Fonts/segoeui.ttf",
        "C:/Windows/Fonts/calibri.ttf",
        "C:/Windows/Fonts/arial.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    };
    for (candidates) |path| {
        const font = rl.LoadFontEx(path, 32, null, 0);
        if (font.texture.id != 0 and font.glyphCount > 0) {
            rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
            return font;
        }
    }
    return rl.GetFontDefault();
}

pub fn computeViewportRect(app: *a.App, area_x: f32, area_y: f32, area_w: f32, area_h: f32) rl.Rectangle {
    const sw: f32 = @floatFromInt(app.target_w);
    const sh: f32 = @floatFromInt(app.target_h);
    if (app.integer_scale) {
        const sx = @max(@floor(area_w / sw), 1);
        const sy = @max(@floor(area_h / sh), 1);
        const s = @min(sx, sy);
        const dw = sw * s;
        const dh = sh * s;
        return .{ .x = area_x + (area_w - dw) * 0.5, .y = area_y + (area_h - dh) * 0.5, .width = dw, .height = dh };
    }
    var dw = area_w;
    var dh = area_h;
    const aspect_src = sw / sh;
    const aspect_dst = area_w / area_h;
    if (aspect_dst > aspect_src) {
        dw = area_h * aspect_src;
    } else {
        dh = area_w / aspect_src;
    }
    return .{ .x = area_x + (area_w - dw) * 0.5, .y = area_y + (area_h - dh) * 0.5, .width = dw, .height = dh };
}

fn drawCenteredText(font: rl.Font, text: [*:0]const u8, rect: rl.Rectangle, font_size: f32, color: rl.Color) void {
    const text_size = rl.MeasureTextEx(font, text, font_size, 1);
    const px = rect.x + (rect.width - text_size.x) * 0.5;
    const py = rect.y + (rect.height - text_size.y) * 0.5;
    rl.DrawTextEx(font, text, .{ .x = px, .y = py }, font_size, 1, color);
}

pub fn drawToolbar(app: *a.App, screen_w: f32, mouse: rl.Vector2, mouse_down: bool) void {
    rl.DrawRectangle(0, 0, @intFromFloat(screen_w), @intFromFloat(a.TOOLBAR_H), a.C_PANEL);
    rl.DrawRectangle(0, @intFromFloat(a.TOOLBAR_H - 1), @intFromFloat(screen_w), 1, a.C_BORDER);

    var i: usize = 0;
    while (i < app.btn_count) : (i += 1) {
        const btn = &app.buttons[i];
        const enabled = !btn.needs_rom or app.system != null;
        const hovered = rl.CheckCollisionPointRec(mouse, btn.rect) and enabled;
        const pressed = hovered and mouse_down;
        const toggled = btn.toggleable and a.buttonToggled(app, btn.action);

        var fill = a.C_PANEL;
        if (toggled) fill = .{ .r = 0x36, .g = 0x2A, .b = 0x1E, .a = 0xFF };
        if (hovered) fill = if (pressed) a.C_ACCENT_DIM else a.C_PANEL_HI;
        if (toggled and hovered) fill = a.C_ACCENT;

        rl.DrawRectangleRounded(btn.rect, 0.30, 6, fill);
        if (toggled and !hovered) {
            const stripe: rl.Rectangle = .{ .x = btn.rect.x + 6, .y = btn.rect.y + btn.rect.height - 3, .width = btn.rect.width - 12, .height = 2 };
            rl.DrawRectangleRec(stripe, a.C_ACCENT);
        }

        const text_color = if (!enabled) a.C_TEXT_DIS else if (toggled and hovered) a.C_BG else if (toggled) a.C_ACCENT else if (hovered) a.C_TEXT else a.C_TEXT_DIM;
        var label_buf: [32:0]u8 = .{0} ** 32;
        var label_text: []const u8 = btn.label;
        if (btn.action == .pause and app.paused) label_text = "Resume";
        if (btn.action == .mute and app.muted) label_text = "Unmute";
        const len = @min(label_text.len, 31);
        @memcpy(label_buf[0..len], label_text[0..len]);
        label_buf[len] = 0;
        drawCenteredText(app.font, @ptrCast(&label_buf), btn.rect, 16, text_color);
    }
}

pub fn drawStatusBar(app: *a.App, screen_w: f32, screen_h: f32) void {
    const sb_y: f32 = screen_h - a.STATUSBAR_H;
    rl.DrawRectangle(0, @intFromFloat(sb_y), @intFromFloat(screen_w), @intFromFloat(a.STATUSBAR_H), a.C_PANEL);
    rl.DrawRectangle(0, @intFromFloat(sb_y), @intFromFloat(screen_w), 1, a.C_BORDER);

    var name_buf: [64]u8 = undefined;
    var line_buf: [192:0]u8 = .{0} ** 192;
    const left_text: []const u8 = if (app.system) |s| blk: {
        const name = s.romTitle(&name_buf);
        break :blk std.fmt.bufPrint(&line_buf, "{s}  -  {s}", .{ s.label(), if (name.len > 0) name else "(untitled)" }) catch "";
    } else blk: {
        break :blk std.fmt.bufPrint(&line_buf, "Drop a .gb / .gbc / .gba file here  -  Ctrl+O to open", .{}) catch "";
    };
    line_buf[left_text.len] = 0;

    rl.DrawTextEx(app.font, @ptrCast(&line_buf), .{ .x = 14, .y = sb_y + 7 }, 13, 1, a.C_TEXT_DIM);

    var right_buf: [192:0]u8 = .{0} ** 192;
    var pos: usize = 0;
    const sep = "   |   ";
    if (app.system != null) {
        const w = std.fmt.bufPrint(right_buf[pos..], "Slot {d}", .{app.state_slot}) catch "";
        pos += w.len;
    }
    if (app.muted) {
        const w = std.fmt.bufPrint(right_buf[pos..], "{s}MUTED", .{if (pos > 0) sep else ""}) catch "";
        pos += w.len;
    } else if (app.volume != 100) {
        const w = std.fmt.bufPrint(right_buf[pos..], "{s}{d}%", .{ if (pos > 0) sep else "", app.volume }) catch "";
        pos += w.len;
    }
    if (app.system != null and app.show_fps) {
        const w = std.fmt.bufPrint(right_buf[pos..], "{s}{d:.1} fps", .{ if (pos > 0) sep else "", app.fps_value }) catch "";
        pos += w.len;
    }
    if (app.turbo) {
        const w = std.fmt.bufPrint(right_buf[pos..], "{s}TURBO 4x", .{if (pos > 0) sep else ""}) catch "";
        pos += w.len;
    }
    right_buf[pos] = 0;

    if (pos > 0) {
        const right_text_size = rl.MeasureTextEx(app.font, @ptrCast(&right_buf), 13, 1);
        rl.DrawTextEx(app.font, @ptrCast(&right_buf), .{ .x = screen_w - right_text_size.x - 14, .y = sb_y + 7 }, 13, 1, a.C_ACCENT);
    }
}

fn drawModalPanel(rc: rl.Rectangle, title: [*:0]const u8, font: rl.Font) void {
    var dim = a.C_BG;
    dim.a = 0xC0;
    rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), dim);
    rl.DrawRectangleRounded(rc, 0.04, 8, a.C_PANEL);
    rl.DrawRectangleRoundedLinesEx(rc, 0.04, 8, 1, a.C_BORDER);
    const title_rc: rl.Rectangle = .{ .x = rc.x, .y = rc.y + 14, .width = rc.width, .height = 26 };
    drawCenteredText(font, title, title_rc, 20, a.C_ACCENT);
    rl.DrawRectangle(@intFromFloat(rc.x + 24), @intFromFloat(rc.y + 46), @intFromFloat(rc.width - 48), 1, a.C_BORDER);
}

fn drawCloseButton(font: rl.Font, rect: rl.Rectangle, mouse: rl.Vector2, mouse_down: bool) void {
    const hovered = rl.CheckCollisionPointRec(mouse, rect);
    var fill = a.C_PANEL_HI;
    if (hovered) fill = if (mouse_down) a.C_ACCENT_DIM else a.C_ACCENT;
    rl.DrawRectangleRounded(rect, 0.30, 6, fill);
    const color: rl.Color = if (hovered) a.C_BG else a.C_TEXT;
    drawCenteredText(font, "Close", rect, 14, color);
}

fn drawSelectorRow(app: *a.App, label: []const u8, value: []const u8, row_rc: rl.Rectangle, prev_idx: usize, next_idx: usize, mouse: rl.Vector2, mouse_down: bool) void {
    var label_buf: [32:0]u8 = .{0} ** 32;
    const lb = @min(label.len, 31);
    @memcpy(label_buf[0..lb], label[0..lb]);
    label_buf[lb] = 0;
    const row_h = row_rc.height;
    rl.DrawTextEx(app.font, @ptrCast(&label_buf), .{ .x = row_rc.x + 12, .y = row_rc.y + (row_h - 16) * 0.5 }, 16, 1, a.C_TEXT);

    const btn_w: f32 = 28;
    const btn_h: f32 = 26;
    const right = row_rc.x + row_rc.width - 8;
    const next_rc: rl.Rectangle = .{ .x = right - btn_w, .y = row_rc.y + (row_h - btn_h) * 0.5, .width = btn_w, .height = btn_h };
    const prev_rc: rl.Rectangle = .{ .x = next_rc.x - btn_w - 96 - 8, .y = next_rc.y, .width = btn_w, .height = btn_h };
    const value_rc: rl.Rectangle = .{ .x = prev_rc.x + btn_w + 4, .y = next_rc.y, .width = 92, .height = btn_h };

    app.selector_buttons[prev_idx].rect = prev_rc;
    app.selector_buttons[next_idx].rect = next_rc;

    drawSelectorMiniBtn(app.font, prev_rc, "<", mouse, mouse_down);
    drawSelectorMiniBtn(app.font, next_rc, ">", mouse, mouse_down);

    rl.DrawRectangleRounded(value_rc, 0.30, 6, a.C_BG);
    rl.DrawRectangleRoundedLinesEx(value_rc, 0.30, 6, 1, a.C_BORDER);
    var val_buf: [32:0]u8 = .{0} ** 32;
    const vb = @min(value.len, 31);
    @memcpy(val_buf[0..vb], value[0..vb]);
    val_buf[vb] = 0;
    drawCenteredText(app.font, @ptrCast(&val_buf), value_rc, 14, a.C_TEXT);
}

fn drawSelectorMiniBtn(font: rl.Font, rect: rl.Rectangle, txt: [*:0]const u8, mouse: rl.Vector2, mouse_down: bool) void {
    const hov = rl.CheckCollisionPointRec(mouse, rect);
    var fill = a.C_PANEL_HI;
    if (hov) fill = if (mouse_down) a.C_ACCENT_DIM else a.C_ACCENT;
    rl.DrawRectangleRounded(rect, 0.30, 6, fill);
    const col: rl.Color = if (hov) a.C_BG else a.C_TEXT;
    drawCenteredText(font, txt, rect, 14, col);
}

pub fn drawConfigMenu(app: *a.App, screen_w: f32, screen_h: f32, mouse: rl.Vector2, mouse_down: bool) void {
    const panel_w: f32 = @min(screen_w - 80, 480);
    const panel_h: f32 = @min(screen_h - 80, 470);
    const px = (screen_w - panel_w) * 0.5;
    const py = (screen_h - panel_h) * 0.5;
    const panel_rc: rl.Rectangle = .{ .x = px, .y = py, .width = panel_w, .height = panel_h };
    app.config_panel_rect = panel_rc;
    drawModalPanel(panel_rc, "Settings", app.font);

    const labels = [_][]const u8{ "Smooth scaling", "Integer scaling", "Show FPS", "Mute audio", "Pause emulation" };
    const toggles = [_]a.ConfigToggle{ .smooth, .integer, .show_fps, .mute, .pause };

    const row_h: f32 = 34;
    const row_pad_x: f32 = 28;
    var ry = py + 60;
    var i: usize = 0;
    while (i < labels.len) : (i += 1) {
        const row_rc: rl.Rectangle = .{ .x = px + row_pad_x, .y = ry, .width = panel_w - row_pad_x * 2, .height = row_h };
        app.config_rows[i] = .{ .label = labels[i], .toggle = toggles[i], .rect = row_rc };
        const hovered = rl.CheckCollisionPointRec(mouse, row_rc);
        if (hovered) rl.DrawRectangleRounded(row_rc, 0.20, 6, a.C_PANEL_HI);

        var label_buf: [32:0]u8 = .{0} ** 32;
        const len = @min(labels[i].len, 31);
        @memcpy(label_buf[0..len], labels[i][0..len]);
        label_buf[len] = 0;
        rl.DrawTextEx(app.font, @ptrCast(&label_buf), .{ .x = row_rc.x + 12, .y = row_rc.y + (row_h - 16) * 0.5 }, 16, 1, a.C_TEXT);

        const sw_w: f32 = 44;
        const sw_h: f32 = 22;
        const sw_rc: rl.Rectangle = .{ .x = row_rc.x + row_rc.width - sw_w - 8, .y = row_rc.y + (row_h - sw_h) * 0.5, .width = sw_w, .height = sw_h };
        const on = a.configToggled(app, toggles[i]);
        const track = if (on) a.C_ACCENT else a.C_BG;
        rl.DrawRectangleRounded(sw_rc, 0.5, 8, track);
        rl.DrawRectangleRoundedLinesEx(sw_rc, 0.5, 8, 1, a.C_BORDER);
        const knob_d: f32 = sw_h - 4;
        const knob_x = if (on) sw_rc.x + sw_w - knob_d - 2 else sw_rc.x + 2;
        const knob_rc: rl.Rectangle = .{ .x = knob_x, .y = sw_rc.y + 2, .width = knob_d, .height = knob_d };
        rl.DrawRectangleRounded(knob_rc, 0.5, 8, a.C_TEXT);

        ry += row_h + 2;
    }

    ry += 8;
    rl.DrawRectangle(@intFromFloat(px + row_pad_x), @intFromFloat(ry), @intFromFloat(panel_w - row_pad_x * 2), 1, a.C_BORDER);
    ry += 10;

    const sel_row1: rl.Rectangle = .{ .x = px + row_pad_x, .y = ry, .width = panel_w - row_pad_x * 2, .height = row_h };
    drawSelectorRow(app, "GB Palette", app.dmg_palette.label(), sel_row1, 0, 1, mouse, mouse_down);
    ry += row_h + 4;

    var slot_buf: [16]u8 = undefined;
    const slot_str = std.fmt.bufPrint(&slot_buf, "Slot {d}", .{app.state_slot}) catch "Slot ?";
    const sel_row2: rl.Rectangle = .{ .x = px + row_pad_x, .y = ry, .width = panel_w - row_pad_x * 2, .height = row_h };
    drawSelectorRow(app, "Save state slot", slot_str, sel_row2, 2, 3, mouse, mouse_down);
    ry += row_h + 4;

    var vol_buf: [16]u8 = undefined;
    const vol_str = std.fmt.bufPrint(&vol_buf, "{d}%", .{app.volume}) catch "?%";
    const sel_row3: rl.Rectangle = .{ .x = px + row_pad_x, .y = ry, .width = panel_w - row_pad_x * 2, .height = row_h };
    drawSelectorRow(app, "Volume", vol_str, sel_row3, 4, 5, mouse, mouse_down);
    ry += row_h + 4;

    const cw: f32 = 110;
    const ch: f32 = 32;
    app.config_close_rect = .{ .x = px + (panel_w - cw) * 0.5, .y = py + panel_h - ch - 16, .width = cw, .height = ch };
    drawCloseButton(app.font, app.config_close_rect, mouse, mouse_down);
}

pub fn drawHelpMenu(app: *a.App, screen_w: f32, screen_h: f32, mouse: rl.Vector2, mouse_down: bool) void {
    const panel_w: f32 = @min(screen_w - 80, 540);
    const panel_h: f32 = @min(screen_h - 80, 520);
    const px = (screen_w - panel_w) * 0.5;
    const py = (screen_h - panel_h) * 0.5;
    const panel_rc: rl.Rectangle = .{ .x = px, .y = py, .width = panel_w, .height = panel_h };
    app.help_panel_rect = panel_rc;
    drawModalPanel(panel_rc, "Controls", app.font);

    const rows = [_][2][:0]const u8{
        .{ "D-Pad", "Arrow Keys" },
        .{ "A / B", "Z / X" },
        .{ "L / R", "A / S" },
        .{ "Start", "Enter" },
        .{ "Select", "Right Shift / Backspace" },
        .{ "Turbo", "Tab (hold)" },
        .{ "Save State", "F1 or F5" },
        .{ "Load State", "F3 or F7" },
        .{ "Prev / Next slot", "[  /  ]" },
        .{ "Pause", "P" },
        .{ "Reset", "R" },
        .{ "Mute", "M" },
        .{ "Volume - / +", "-  /  =" },
        .{ "Fullscreen", "F11" },
        .{ "Screenshot", "F12" },
        .{ "Open ROM", "Ctrl+O" },
        .{ "Close menu", "Esc" },
    };
    const row_h: f32 = 22;
    const col_x = px + 60;
    const col_x2 = px + panel_w * 0.5;
    var ry = py + 64;
    for (rows) |row| {
        rl.DrawTextEx(app.font, row[0], .{ .x = col_x, .y = ry }, 15, 1, a.C_TEXT_DIM);
        rl.DrawTextEx(app.font, row[1], .{ .x = col_x2, .y = ry }, 15, 1, a.C_TEXT);
        ry += row_h;
    }

    const cw: f32 = 110;
    const ch: f32 = 32;
    app.help_close_rect = .{ .x = px + (panel_w - cw) * 0.5, .y = py + panel_h - ch - 16, .width = cw, .height = ch };
    drawCloseButton(app.font, app.help_close_rect, mouse, mouse_down);
}

pub fn drawPlaceholder(app: *a.App, area_x: f32, area_y: f32, area_w: f32, area_h: f32) void {
    rl.DrawRectangle(@intFromFloat(area_x), @intFromFloat(area_y), @intFromFloat(area_w), @intFromFloat(area_h), a.C_BG);

    const panel_w: f32 = @min(area_w - 80, 480);
    const panel_h: f32 = @min(area_h - 80, 220);
    if (panel_w < 200 or panel_h < 140) return;
    const px = area_x + (area_w - panel_w) * 0.5;
    const py = area_y + (area_h - panel_h) * 0.5;
    const panel_rc: rl.Rectangle = .{ .x = px, .y = py, .width = panel_w, .height = panel_h };

    rl.DrawRectangleRounded(panel_rc, 0.04, 8, a.C_PANEL);
    rl.DrawRectangleRoundedLinesEx(panel_rc, 0.04, 8, 1, a.C_BORDER);

    var t_rc: rl.Rectangle = .{ .x = px, .y = py + 30, .width = panel_w, .height = 44 };
    drawCenteredText(app.font, a.APP_NAME, t_rc, 32, a.C_TEXT);
    t_rc = .{ .x = px, .y = py + 70, .width = panel_w, .height = 18 };
    var ver_buf: [32:0]u8 = .{0} ** 32;
    const ver = std.fmt.bufPrint(&ver_buf, "v{s}", .{a.APP_VERSION}) catch "";
    ver_buf[ver.len] = 0;
    drawCenteredText(app.font, @ptrCast(&ver_buf), t_rc, 12, a.C_TEXT_DIS);
    t_rc = .{ .x = px, .y = py + 95, .width = panel_w, .height = 22 };
    drawCenteredText(app.font, "Game Boy  -  Color  -  Advance", t_rc, 15, a.C_ACCENT);

    t_rc = .{ .x = px, .y = py + 140, .width = panel_w, .height = 22 };
    drawCenteredText(app.font, "Drop a .gb / .gbc / .gba file, or press Ctrl+O", t_rc, 14, a.C_TEXT_DIM);

    t_rc = .{ .x = px, .y = py + 170, .width = panel_w, .height = 18 };
    drawCenteredText(app.font, "Click Help for the controls list.", t_rc, 13, a.C_TEXT_DIS);
}

pub fn drawFlashMsg(app: *a.App, screen_w: f32, screen_h: f32) void {
    if (app.flash_timer <= 0 or app.flash_msg_len == 0) return;
    var msg_buf: [a.FLASH_MSG_CAP:0]u8 = .{0} ** a.FLASH_MSG_CAP;
    const n = @min(app.flash_msg_len, a.FLASH_MSG_CAP);
    @memcpy(msg_buf[0..n], app.flash_msg[0..n]);
    msg_buf[n] = 0;
    const text_size = rl.MeasureTextEx(app.font, @ptrCast(&msg_buf), 14, 1);
    const pad: f32 = 14;
    const w = text_size.x + pad * 2;
    const h: f32 = 32;
    const rc: rl.Rectangle = .{ .x = (screen_w - w) * 0.5, .y = screen_h - a.STATUSBAR_H - h - 12, .width = w, .height = h };
    var alpha: f32 = 1.0;
    if (app.flash_timer < 0.5) alpha = app.flash_timer / 0.5;
    var bg_color = a.C_PANEL_HI;
    bg_color.a = @intFromFloat(alpha * 230);
    rl.DrawRectangleRounded(rc, 0.4, 8, bg_color);
    var border_color = a.C_ACCENT;
    border_color.a = @intFromFloat(alpha * 255);
    rl.DrawRectangleRoundedLinesEx(rc, 0.4, 8, 1, border_color);
    var text_color = a.C_TEXT;
    text_color.a = @intFromFloat(alpha * 255);
    rl.DrawTextEx(app.font, @ptrCast(&msg_buf), .{ .x = rc.x + pad, .y = rc.y + (h - text_size.y) * 0.5 }, 14, 1, text_color);
}
