const std = @import("std");
const Gb = @import("gb.zig").Gb;
const Button = @import("gb.zig").Button;

const w = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "");
    @cDefine("UNICODE", "");
    @cDefine("_UNICODE", "");
    @cInclude("windows.h");
    @cInclude("mmsystem.h");
    @cInclude("commdlg.h");
    @cInclude("shellapi.h");
    @cInclude("dwmapi.h");
});

const DWMWA_USE_IMMERSIVE_DARK_MODE_OLD: c_uint = 19;
const DWMWA_USE_IMMERSIVE_DARK_MODE: c_uint = 20;

const SAMPLE_RATE: u32 = 48000;
const FRAME_FRAMES: usize = 800;
const N_AUDIO_BUFFERS: usize = 6;

const SCALE: c_int = 4;
const SRC_W: c_int = 160;
const SRC_H: c_int = 144;

const ID_FILE_LOAD: u16 = 100;
const ID_FILE_SAVESTATE: u16 = 101;
const ID_FILE_LOADSTATE: u16 = 102;
const ID_FILE_PAUSE: u16 = 103;
const ID_FILE_RESET: u16 = 104;
const ID_FILE_MUTE: u16 = 105;
const ID_FILE_EXIT: u16 = 106;
const ID_FILE_SAVESTATE_AS: u16 = 107;
const ID_FILE_LOADSTATE_AS: u16 = 108;
const ID_HELP_KEYS: u16 = 200;

const App = struct {
    hwnd: w.HWND = undefined,
    h_menu: w.HMENU = undefined,
    gpa: std.mem.Allocator,
    gb: ?*Gb = null,
    rom_path: ?[]u8 = null,
    sav_path: ?[]u8 = null,
    state_path: ?[]u8 = null,

    framebuffer: [SRC_W * SRC_H]u32 = .{0} ** (SRC_W * SRC_H),

    h_wave_out: w.HWAVEOUT = null,
    audio_bufs: [N_AUDIO_BUFFERS][FRAME_FRAMES * 2]i16 = undefined,
    audio_hdrs: [N_AUDIO_BUFFERS]w.WAVEHDR = undefined,

    paused: bool = false,
    turbo: bool = false,
    muted: bool = false,
    minimized: bool = false,
    quit: bool = false,
    new_rom: ?[]u8 = null,

    last_qpc: w.LARGE_INTEGER = undefined,
    qpc_freq: w.LARGE_INTEGER = undefined,
    accum_us: i64 = 0,
};

var g_app: *App = undefined;

fn dbg(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n\x00", args) catch return;
    w.OutputDebugStringA(@ptrCast(s.ptr));
}

fn utf8ToWide(alloc: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return try std.unicode.utf8ToUtf16LeAllocZ(alloc, s);
}

fn wideToUtf8(alloc: std.mem.Allocator, ws: [*:0]const u16) ![]u8 {
    const len = std.mem.indexOfSentinel(u16, 0, ws);
    return try std.unicode.utf16LeToUtf8Alloc(alloc, ws[0..len]);
}

fn pathReplaceExt(alloc: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    return try std.fmt.allocPrint(alloc, "{s}{s}", .{ path[0..dot], new_ext });
}

fn writeAllToFile(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const wpath = try utf8ToWide(alloc, path);
    defer alloc.free(wpath);
    const h = w.CreateFileW(wpath.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer _ = w.CloseHandle(h);
    var total_written: usize = 0;
    while (total_written < data.len) {
        var written: w.DWORD = 0;
        const want: w.DWORD = @intCast(data.len - total_written);
        if (w.WriteFile(h, data.ptr + total_written, want, &written, null) == 0) return error.WriteFailed;
        if (written == 0) return error.WriteFailed;
        total_written += written;
    }
}

fn readAllFromFile(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    const wpath = try utf8ToWide(alloc, path);
    defer alloc.free(wpath);
    const h = w.CreateFileW(wpath.ptr, w.GENERIC_READ, w.FILE_SHARE_READ, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return null;
    defer _ = w.CloseHandle(h);
    var size_high: w.DWORD = 0;
    const size_low = w.GetFileSize(h, &size_high);
    if (size_low == 0xFFFFFFFF) return error.SizeFailed;
    const total: u64 = (@as(u64, size_high) << 32) | size_low;
    if (total > 64 * 1024 * 1024) return error.TooLarge;
    var buf = try alloc.alloc(u8, @intCast(total));
    errdefer alloc.free(buf);
    var read_total: usize = 0;
    while (read_total < buf.len) {
        var got: w.DWORD = 0;
        const want: w.DWORD = @intCast(buf.len - read_total);
        if (w.ReadFile(h, buf.ptr + read_total, want, &got, null) == 0) return error.ReadFailed;
        if (got == 0) break;
        read_total += got;
    }
    if (read_total != buf.len) {
        buf = try alloc.realloc(buf, read_total);
    }
    return buf;
}

fn keyToButton(vk: w.WPARAM) ?Button {
    return switch (vk) {
        w.VK_RIGHT => .right,
        w.VK_LEFT => .left,
        w.VK_UP => .up,
        w.VK_DOWN => .down,
        'Z', 'X' => .a,
        'A' => .b,
        w.VK_RETURN => .start,
        w.VK_RSHIFT, w.VK_BACK => .select,
        else => null,
    };
}

fn showError(app: *App, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "error";
    if (utf8ToWide(app.gpa, msg)) |wide| {
        defer app.gpa.free(wide);
        _ = w.MessageBoxW(app.hwnd, wide.ptr, std.unicode.utf8ToUtf16LeStringLiteral("ZigBoy"), w.MB_OK | w.MB_ICONERROR);
    } else |_| {}
}

fn loadRomFromPath(app: *App, path: []const u8) !void {
    const data_opt = try readAllFromFile(app.gpa, path);
    if (data_opt == null) return error.OpenFailed;
    const data = data_opt.?;
    defer app.gpa.free(data);
    if (data.len > 16 * 1024 * 1024 or data.len < 0x150) return error.BadRomSize;

    const new_rom_path = try app.gpa.dupe(u8, path);
    errdefer app.gpa.free(new_rom_path);
    const new_sav_path = try pathReplaceExt(app.gpa, path, ".sav");
    errdefer app.gpa.free(new_sav_path);
    const new_state_path = try pathReplaceExt(app.gpa, path, ".state");
    errdefer app.gpa.free(new_state_path);

    const gb = try Gb.init(app.gpa, data, SAMPLE_RATE);
    errdefer gb.deinit();

    if (readAllFromFile(app.gpa, new_sav_path) catch null) |sav| {
        defer app.gpa.free(sav);
        gb.loadBatteryBytes(sav);
    }

    if (app.gb) |old| {
        if (app.sav_path) |sp| {
            if (old.batteryRam()) |ram| writeAllToFile(app.gpa, sp, ram) catch {};
        }
        old.deinit();
    }
    if (app.rom_path) |rp| app.gpa.free(rp);
    if (app.sav_path) |sp| app.gpa.free(sp);
    if (app.state_path) |stp| app.gpa.free(stp);

    app.gb = gb;
    app.rom_path = new_rom_path;
    app.sav_path = new_sav_path;
    app.state_path = new_state_path;

    if (app.h_wave_out != null) {
        _ = w.waveOutReset(app.h_wave_out);
        for (0..N_AUDIO_BUFFERS) |i| {
            app.audio_hdrs[i].dwFlags |= w.WHDR_DONE;
        }
    }

    var title_buf: [128]u8 = undefined;
    var sane: [16]u8 = undefined;
    var sane_len: usize = 0;
    for (0..gb.cart.title_len) |i| {
        const c = gb.cart.title[i];
        if (c >= 0x20 and c < 0x7F) {
            sane[sane_len] = c;
            sane_len += 1;
        }
    }
    const title_text = if (sane_len > 0)
        (std.fmt.bufPrint(&title_buf, "ZigBoy - {s}", .{sane[0..sane_len]}) catch "ZigBoy")
    else
        "ZigBoy";
    if (utf8ToWide(app.gpa, title_text)) |wide| {
        defer app.gpa.free(wide);
        _ = w.SetWindowTextW(app.hwnd, wide.ptr);
    } else |_| {}
    updateMenuEnabled(app);
    dbg("loaded {s} ({} bytes, cgb={})", .{ path, data.len, gb.cgb_mode });
}

fn loadRomTryShowError(app: *App, path: []const u8) void {
    loadRomFromPath(app, path) catch |e| {
        showError(app, "Failed to load ROM:\n{s}\n\nError: {}", .{ path, e });
    };
}

fn openRomDialog(app: *App) void {
    var file_buf: [1024]u16 = .{0} ** 1024;
    const filter_w = std.unicode.utf8ToUtf16LeStringLiteral("Game Boy ROMs\x00*.gb;*.gbc\x00All\x00*.*\x00\x00");
    var ofn: w.OPENFILENAMEW = std.mem.zeroes(w.OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(w.OPENFILENAMEW);
    ofn.hwndOwner = app.hwnd;
    ofn.lpstrFilter = filter_w;
    ofn.lpstrFile = &file_buf;
    ofn.nMaxFile = file_buf.len;
    ofn.Flags = w.OFN_FILEMUSTEXIST | w.OFN_PATHMUSTEXIST | w.OFN_NOCHANGEDIR;
    if (w.GetOpenFileNameW(&ofn) == 0) return;
    const path = wideToUtf8(app.gpa, @ptrCast(&file_buf)) catch return;
    if (app.new_rom) |old| app.gpa.free(old);
    app.new_rom = path;
}

fn renderFrame(app: *App, hdc: w.HDC) void {
    if (app.gb) |gb| gb.writeFramebuffer(&app.framebuffer);

    var rc: w.RECT = undefined;
    _ = w.GetClientRect(app.hwnd, &rc);
    const cw = rc.right - rc.left;
    const ch = rc.bottom - rc.top;
    if (cw <= 0 or ch <= 0) return;

    const mem_dc = w.CreateCompatibleDC(hdc);
    if (mem_dc == null) return;
    defer _ = w.DeleteDC(mem_dc);
    const mem_bmp = w.CreateCompatibleBitmap(hdc, cw, ch);
    if (mem_bmp == null) return;
    defer _ = w.DeleteObject(mem_bmp);
    const old_bmp = w.SelectObject(mem_dc, mem_bmp);
    defer _ = w.SelectObject(mem_dc, old_bmp);

    var bmi: w.BITMAPINFO = std.mem.zeroes(w.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = SRC_W;
    bmi.bmiHeader.biHeight = -SRC_H;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = w.BI_RGB;

    const sx_n = cw * SRC_H;
    const sy_n = ch * SRC_W;
    var dst_w: c_int = cw;
    var dst_h: c_int = ch;
    if (sx_n > sy_n) {
        dst_w = @divTrunc(ch * SRC_W, SRC_H);
    } else {
        dst_h = @divTrunc(cw * SRC_H, SRC_W);
    }
    const dst_x = @divTrunc(cw - dst_w, 2);
    const dst_y = @divTrunc(ch - dst_h, 2);

    _ = w.PatBlt(mem_dc, 0, 0, cw, ch, w.BLACKNESS);
    _ = w.SetStretchBltMode(mem_dc, w.COLORONCOLOR);
    _ = w.StretchDIBits(
        mem_dc,
        dst_x,
        dst_y,
        dst_w,
        dst_h,
        0,
        0,
        SRC_W,
        SRC_H,
        &app.framebuffer,
        &bmi,
        w.DIB_RGB_COLORS,
        w.SRCCOPY,
    );
    _ = w.BitBlt(hdc, 0, 0, cw, ch, mem_dc, 0, 0, w.SRCCOPY);
}

fn audioInit(app: *App) !void {
    var fmt: w.WAVEFORMATEX = std.mem.zeroes(w.WAVEFORMATEX);
    fmt.wFormatTag = w.WAVE_FORMAT_PCM;
    fmt.nChannels = 2;
    fmt.nSamplesPerSec = SAMPLE_RATE;
    fmt.wBitsPerSample = 16;
    fmt.nBlockAlign = 4;
    fmt.nAvgBytesPerSec = SAMPLE_RATE * 4;
    const r = w.waveOutOpen(&app.h_wave_out, w.WAVE_MAPPER, &fmt, 0, 0, w.CALLBACK_NULL);
    if (r != w.MMSYSERR_NOERROR) return error.WaveOutOpen;
    for (0..N_AUDIO_BUFFERS) |i| {
        @memset(&app.audio_bufs[i], 0);
        app.audio_hdrs[i] = std.mem.zeroes(w.WAVEHDR);
        app.audio_hdrs[i].lpData = @ptrCast(&app.audio_bufs[i]);
        app.audio_hdrs[i].dwBufferLength = FRAME_FRAMES * 2 * @sizeOf(i16);
        app.audio_hdrs[i].dwFlags = 0;
        _ = w.waveOutPrepareHeader(app.h_wave_out, &app.audio_hdrs[i], @sizeOf(w.WAVEHDR));
        app.audio_hdrs[i].dwFlags |= w.WHDR_DONE;
    }
}

fn audioDeinit(app: *App) void {
    if (app.h_wave_out == null) return;
    _ = w.waveOutReset(app.h_wave_out);
    for (0..N_AUDIO_BUFFERS) |i| {
        _ = w.waveOutUnprepareHeader(app.h_wave_out, &app.audio_hdrs[i], @sizeOf(w.WAVEHDR));
    }
    _ = w.waveOutClose(app.h_wave_out);
    app.h_wave_out = null;
}

fn audioPump(app: *App) void {
    if (app.h_wave_out == null) return;
    if (app.gb == null) return;
    const gb = app.gb.?;
    var f32_buf: [FRAME_FRAMES * 2]f32 = undefined;
    for (0..N_AUDIO_BUFFERS) |i| {
        const hdr = &app.audio_hdrs[i];
        if ((hdr.dwFlags & w.WHDR_DONE) == 0) continue;
        const got = gb.drainAudio(&f32_buf);
        if (got == 0) break;
        const dst = &app.audio_bufs[i];
        for (0..got) |j| {
            var v = f32_buf[j];
            if (app.muted) v = 0;
            if (v > 1.0) v = 1.0;
            if (v < -1.0) v = -1.0;
            dst[j] = @intFromFloat(v * 32767.0);
        }
        for (got..FRAME_FRAMES * 2) |j| dst[j] = 0;
        hdr.dwFlags &= ~@as(w.DWORD, w.WHDR_DONE);
        _ = w.waveOutWrite(app.h_wave_out, hdr, @sizeOf(w.WAVEHDR));
    }
}

fn updateMenuChecks(app: *App) void {
    const pause_flags: c_uint = @intCast(if (app.paused) (w.MF_BYCOMMAND | w.MF_CHECKED) else (w.MF_BYCOMMAND | w.MF_UNCHECKED));
    const mute_flags: c_uint = @intCast(if (app.muted) (w.MF_BYCOMMAND | w.MF_CHECKED) else (w.MF_BYCOMMAND | w.MF_UNCHECKED));
    _ = w.CheckMenuItem(app.h_menu, ID_FILE_PAUSE, pause_flags);
    _ = w.CheckMenuItem(app.h_menu, ID_FILE_MUTE, mute_flags);
}

fn updateMenuEnabled(app: *App) void {
    const has_game: c_uint = @intCast(if (app.gb != null) (w.MF_BYCOMMAND | w.MF_ENABLED) else (w.MF_BYCOMMAND | w.MF_GRAYED));
    _ = w.EnableMenuItem(app.h_menu, ID_FILE_SAVESTATE, has_game);
    _ = w.EnableMenuItem(app.h_menu, ID_FILE_LOADSTATE, has_game);
    _ = w.EnableMenuItem(app.h_menu, ID_FILE_SAVESTATE_AS, has_game);
    _ = w.EnableMenuItem(app.h_menu, ID_FILE_LOADSTATE_AS, has_game);
    _ = w.EnableMenuItem(app.h_menu, ID_FILE_PAUSE, has_game);
    _ = w.EnableMenuItem(app.h_menu, ID_FILE_RESET, has_game);
}

fn doSaveState(app: *App) void {
    if (app.gb == null or app.state_path == null) return;
    const data = app.gb.?.saveStateBytes() catch |e| {
        showError(app, "Save state failed: {}", .{e});
        return;
    };
    defer app.gpa.free(data);
    writeAllToFile(app.gpa, app.state_path.?, data) catch |e| {
        showError(app, "Write state failed: {}", .{e});
        return;
    };
    dbg("state saved", .{});
}

fn doLoadState(app: *App) void {
    if (app.gb == null or app.state_path == null) return;
    const data = readAllFromFile(app.gpa, app.state_path.?) catch |e| {
        showError(app, "Read state failed: {}", .{e});
        return;
    };
    if (data == null) {
        showError(app, "No save state found.", .{});
        return;
    }
    defer app.gpa.free(data.?);
    app.gb.?.loadStateBytes(data.?) catch |e| {
        showError(app, "Load state failed: {}", .{e});
        return;
    };
    dbg("state loaded", .{});
}

fn doSaveStateAs(app: *App) void {
    if (app.gb == null) return;
    var file_buf: [1024]u16 = .{0} ** 1024;
    const filter_w = std.unicode.utf8ToUtf16LeStringLiteral("Save States\x00*.state\x00All\x00*.*\x00\x00");
    const default_ext = std.unicode.utf8ToUtf16LeStringLiteral("state");
    var ofn: w.OPENFILENAMEW = std.mem.zeroes(w.OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(w.OPENFILENAMEW);
    ofn.hwndOwner = app.hwnd;
    ofn.lpstrFilter = filter_w;
    ofn.lpstrFile = &file_buf;
    ofn.nMaxFile = file_buf.len;
    ofn.lpstrDefExt = default_ext;
    ofn.Flags = w.OFN_OVERWRITEPROMPT | w.OFN_PATHMUSTEXIST | w.OFN_NOCHANGEDIR;
    if (w.GetSaveFileNameW(&ofn) == 0) return;
    const path = wideToUtf8(app.gpa, @ptrCast(&file_buf)) catch return;
    defer app.gpa.free(path);
    const data = app.gb.?.saveStateBytes() catch |e| {
        showError(app, "Save state failed: {}", .{e});
        return;
    };
    defer app.gpa.free(data);
    writeAllToFile(app.gpa, path, data) catch |e| {
        showError(app, "Write failed: {}", .{e});
        return;
    };
    dbg("state saved to {s}", .{path});
}

fn doLoadStateAs(app: *App) void {
    if (app.gb == null) return;
    var file_buf: [1024]u16 = .{0} ** 1024;
    const filter_w = std.unicode.utf8ToUtf16LeStringLiteral("Save States\x00*.state\x00All\x00*.*\x00\x00");
    var ofn: w.OPENFILENAMEW = std.mem.zeroes(w.OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(w.OPENFILENAMEW);
    ofn.hwndOwner = app.hwnd;
    ofn.lpstrFilter = filter_w;
    ofn.lpstrFile = &file_buf;
    ofn.nMaxFile = file_buf.len;
    ofn.Flags = w.OFN_FILEMUSTEXIST | w.OFN_PATHMUSTEXIST | w.OFN_NOCHANGEDIR;
    if (w.GetOpenFileNameW(&ofn) == 0) return;
    const path = wideToUtf8(app.gpa, @ptrCast(&file_buf)) catch return;
    defer app.gpa.free(path);
    const data = readAllFromFile(app.gpa, path) catch |e| {
        showError(app, "Read failed: {}", .{e});
        return;
    };
    if (data == null) {
        showError(app, "File not found.", .{});
        return;
    }
    defer app.gpa.free(data.?);
    app.gb.?.loadStateBytes(data.?) catch |e| {
        showError(app, "Load state failed: {}", .{e});
        return;
    };
    dbg("state loaded from {s}", .{path});
}

fn togglePause(app: *App) void {
    app.paused = !app.paused;
    updateMenuChecks(app);
}

fn toggleMute(app: *App) void {
    app.muted = !app.muted;
    updateMenuChecks(app);
}

fn doReset(app: *App) void {
    if (app.gb) |gb| {
        gb.reset();
        if (app.h_wave_out != null) {
            _ = w.waveOutReset(app.h_wave_out);
            for (0..N_AUDIO_BUFFERS) |i| app.audio_hdrs[i].dwFlags |= w.WHDR_DONE;
        }
    }
}

fn showControls(app: *App) void {
    const text = std.unicode.utf8ToUtf16LeStringLiteral(
        "Game keys:\n\n" ++
        "Arrows - D-pad\n" ++
        "Z / X - A button\n" ++
        "A - B button\n" ++
        "Enter - Start\n" ++
        "Right Shift / Backspace - Select\n\n" ++
        "Hotkeys:\n" ++
        "F1 - Save State\n" ++
        "F3 - Load State\n" ++
        "P - Pause\n" ++
        "R - Reset\n" ++
        "M - Mute\n" ++
        "O / Ctrl+O - Load ROM\n" ++
        "Tab - Turbo (hold)\n" ++
        "Esc - Exit\n\n" ++
        "You can also drag a .gb/.gbc file onto the window.");
    _ = w.MessageBoxW(app.hwnd, text, std.unicode.utf8ToUtf16LeStringLiteral("ZigBoy - Controls"), w.MB_OK | w.MB_ICONINFORMATION);
}

fn handleHotkey(app: *App, vk: w.WPARAM) bool {
    switch (vk) {
        w.VK_ESCAPE => {
            app.quit = true;
            return true;
        },
        w.VK_F1 => {
            doSaveState(app);
            return true;
        },
        w.VK_F3 => {
            doLoadState(app);
            return true;
        },
        'P' => {
            togglePause(app);
            return true;
        },
        'R' => {
            doReset(app);
            return true;
        },
        'M' => {
            toggleMute(app);
            return true;
        },
        'O' => {
            openRomDialog(app);
            return true;
        },
        else => return false,
    }
}

fn wndProc(hwnd: w.HWND, msg: c_uint, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.c) w.LRESULT {
    const app = g_app;
    switch (msg) {
        w.WM_CLOSE, w.WM_DESTROY => {
            app.quit = true;
            w.PostQuitMessage(0);
            return 0;
        },
        w.WM_PAINT => {
            var ps: w.PAINTSTRUCT = undefined;
            const hdc = w.BeginPaint(hwnd, &ps);
            renderFrame(app, hdc);
            _ = w.EndPaint(hwnd, &ps);
            return 0;
        },
        w.WM_ERASEBKGND => return 1,
        w.WM_SIZE => {
            const t = wparam;
            app.minimized = (t == w.SIZE_MINIMIZED);
            _ = w.InvalidateRect(hwnd, null, w.FALSE);
            return 0;
        },
        w.WM_COMMAND => {
            const id: u16 = @intCast(wparam & 0xFFFF);
            switch (id) {
                ID_FILE_LOAD => openRomDialog(app),
                ID_FILE_SAVESTATE => doSaveState(app),
                ID_FILE_LOADSTATE => doLoadState(app),
                ID_FILE_SAVESTATE_AS => doSaveStateAs(app),
                ID_FILE_LOADSTATE_AS => doLoadStateAs(app),
                ID_FILE_PAUSE => togglePause(app),
                ID_FILE_RESET => doReset(app),
                ID_FILE_MUTE => toggleMute(app),
                ID_FILE_EXIT => app.quit = true,
                ID_HELP_KEYS => showControls(app),
                else => {},
            }
            return 0;
        },
        w.WM_DROPFILES => {
            const hdrop: w.HDROP = @ptrFromInt(wparam);
            var path_buf: [1024]u16 = .{0} ** 1024;
            const len = w.DragQueryFileW(hdrop, 0, &path_buf, path_buf.len);
            if (len > 0 and len < path_buf.len) {
                if (wideToUtf8(app.gpa, @ptrCast(&path_buf))) |path| {
                    if (app.new_rom) |old| app.gpa.free(old);
                    app.new_rom = path;
                } else |_| {}
            }
            w.DragFinish(hdrop);
            return 0;
        },
        w.WM_KEYDOWN, w.WM_SYSKEYDOWN => {
            const repeat = (lparam & (@as(w.LPARAM, 1) << 30)) != 0;
            if (wparam == w.VK_TAB) {
                app.turbo = true;
                return 0;
            }
            if (!repeat and handleHotkey(app, wparam)) return 0;
            if (keyToButton(wparam)) |b| if (app.gb) |gb| gb.press(b);
            return 0;
        },
        w.WM_KEYUP, w.WM_SYSKEYUP => {
            if (wparam == w.VK_TAB) {
                app.turbo = false;
                return 0;
            }
            if (keyToButton(wparam)) |b| if (app.gb) |gb| gb.release(b);
            return 0;
        },
        w.WM_KILLFOCUS => {
            app.turbo = false;
            return 0;
        },
        w.WM_SETCURSOR => {
            const hit_test: u16 = @intCast(lparam & 0xFFFF);
            if (hit_test == w.HTCLIENT) {
                _ = w.SetCursor(null);
                return 1;
            }
            return w.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn buildMenu() w.HMENU {
    const menu = w.CreateMenu();
    const file = w.CreatePopupMenu();
    const game = w.CreatePopupMenu();
    const help = w.CreatePopupMenu();
    _ = w.AppendMenuW(file, w.MF_STRING, ID_FILE_LOAD, std.unicode.utf8ToUtf16LeStringLiteral("&Load ROM...\tCtrl+O"));
    _ = w.AppendMenuW(file, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(file, w.MF_STRING, ID_FILE_EXIT, std.unicode.utf8ToUtf16LeStringLiteral("E&xit\tEsc"));
    _ = w.AppendMenuW(game, w.MF_STRING, ID_FILE_PAUSE, std.unicode.utf8ToUtf16LeStringLiteral("&Pause\tP"));
    _ = w.AppendMenuW(game, w.MF_STRING, ID_FILE_RESET, std.unicode.utf8ToUtf16LeStringLiteral("&Reset\tR"));
    _ = w.AppendMenuW(game, w.MF_STRING, ID_FILE_MUTE, std.unicode.utf8ToUtf16LeStringLiteral("&Mute\tM"));
    _ = w.AppendMenuW(game, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(game, w.MF_STRING, ID_FILE_SAVESTATE, std.unicode.utf8ToUtf16LeStringLiteral("Quick &Save\tF1"));
    _ = w.AppendMenuW(game, w.MF_STRING, ID_FILE_LOADSTATE, std.unicode.utf8ToUtf16LeStringLiteral("Quick L&oad\tF3"));
    _ = w.AppendMenuW(game, w.MF_STRING, ID_FILE_SAVESTATE_AS, std.unicode.utf8ToUtf16LeStringLiteral("Save State &As..."));
    _ = w.AppendMenuW(game, w.MF_STRING, ID_FILE_LOADSTATE_AS, std.unicode.utf8ToUtf16LeStringLiteral("Loa&d State From..."));
    _ = w.AppendMenuW(help, w.MF_STRING, ID_HELP_KEYS, std.unicode.utf8ToUtf16LeStringLiteral("&Controls"));
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(file), std.unicode.utf8ToUtf16LeStringLiteral("&File"));
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(game), std.unicode.utf8ToUtf16LeStringLiteral("&Game"));
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(help), std.unicode.utf8ToUtf16LeStringLiteral("&Help"));
    return menu;
}

fn applyDarkTitleBar(hwnd: w.HWND) void {
    var dark: w.BOOL = w.TRUE;
    _ = w.DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(w.BOOL));
    _ = w.DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, &dark, @sizeOf(w.BOOL));
}


fn buildAccelerators() w.HACCEL {
    const accels = [_]w.ACCEL{
        .{ .fVirt = w.FCONTROL | w.FVIRTKEY, .key = 'O', .cmd = ID_FILE_LOAD },
        .{ .fVirt = w.FVIRTKEY, .key = w.VK_F1, .cmd = ID_FILE_SAVESTATE },
        .{ .fVirt = w.FVIRTKEY, .key = w.VK_F3, .cmd = ID_FILE_LOADSTATE },
    };
    return w.CreateAcceleratorTableW(@constCast(@ptrCast(&accels)), accels.len);
}

fn createMainWindow(app: *App, instance: w.HINSTANCE) !void {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZIGBOY_WND");
    var wc: w.WNDCLASSEXW = std.mem.zeroes(w.WNDCLASSEXW);
    wc.cbSize = @sizeOf(w.WNDCLASSEXW);
    wc.style = w.CS_HREDRAW | w.CS_VREDRAW;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = instance;
    wc.hCursor = w.LoadCursorW(null, @ptrFromInt(32512));
    wc.hbrBackground = null;
    wc.lpszClassName = class_name;
    if (w.RegisterClassExW(&wc) == 0) return error.RegisterClass;

    var rc: w.RECT = .{ .left = 0, .top = 0, .right = SRC_W * SCALE, .bottom = SRC_H * SCALE };
    _ = w.AdjustWindowRectEx(&rc, w.WS_OVERLAPPEDWINDOW, w.TRUE, 0);
    const wnd_w = rc.right - rc.left;
    const wnd_h = rc.bottom - rc.top;

    app.h_menu = buildMenu();
    const title = std.unicode.utf8ToUtf16LeStringLiteral("ZigBoy");
    const hwnd = w.CreateWindowExW(
        0,
        class_name,
        title,
        w.WS_OVERLAPPEDWINDOW | w.WS_VISIBLE,
        w.CW_USEDEFAULT,
        w.CW_USEDEFAULT,
        wnd_w,
        wnd_h,
        null,
        app.h_menu,
        instance,
        null,
    );
    if (hwnd == null) return error.CreateWindow;
    app.hwnd = hwnd.?;
    applyDarkTitleBar(app.hwnd);
    w.DragAcceptFiles(app.hwnd, w.TRUE);
    updateMenuChecks(app);
    updateMenuEnabled(app);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var app: App = .{ .gpa = alloc };
    g_app = &app;
    defer {
        if (app.gb) |gb| {
            if (app.sav_path) |sp| {
                if (gb.batteryRam()) |ram| writeAllToFile(alloc, sp, ram) catch {};
            }
            gb.deinit();
        }
        if (app.rom_path) |rp| alloc.free(rp);
        if (app.sav_path) |sp| alloc.free(sp);
        if (app.state_path) |stp| alloc.free(stp);
        if (app.new_rom) |nr| alloc.free(nr);
        audioDeinit(&app);
    }

    var arg_iter = try std.process.Args.Iterator.initAllocator(init.args, alloc);
    defer arg_iter.deinit();
    _ = arg_iter.next();
    var initial_rom: ?[]u8 = null;
    defer if (initial_rom) |ir| alloc.free(ir);
    if (arg_iter.next()) |a| initial_rom = try alloc.dupe(u8, a);

    const instance: w.HINSTANCE = @ptrCast(w.GetModuleHandleW(null).?);
    try createMainWindow(&app, instance);
    try audioInit(&app);

    const accel = buildAccelerators();
    defer {
        if (accel != null) _ = w.DestroyAcceleratorTable(accel);
    }

    if (initial_rom) |p| {
        loadRomTryShowError(&app, p);
    } else {
        openRomDialog(&app);
    }

    var msg: w.MSG = undefined;
    _ = w.QueryPerformanceFrequency(&app.qpc_freq);
    _ = w.QueryPerformanceCounter(&app.last_qpc);

    while (!app.quit) {
        while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
            if (msg.message == w.WM_QUIT) {
                app.quit = true;
                break;
            }
            if (accel == null or w.TranslateAcceleratorW(app.hwnd, accel, &msg) == 0) {
                _ = w.TranslateMessage(&msg);
                _ = w.DispatchMessageW(&msg);
            }
        }
        if (app.quit) break;

        if (app.new_rom) |p| {
            const owned = p;
            app.new_rom = null;
            loadRomTryShowError(&app, owned);
            alloc.free(owned);
        }

        const did_work = !app.paused and !app.minimized and app.gb != null;
        if (did_work) {
            const frames: u32 = if (app.turbo) 4 else 1;
            var i: u32 = 0;
            while (i < frames) : (i += 1) {
                app.gb.?.stepFrame();
            }
            audioPump(&app);
            _ = w.InvalidateRect(app.hwnd, null, w.FALSE);
        }

        if (did_work and app.turbo) {
            _ = w.QueryPerformanceCounter(&app.last_qpc);
            app.accum_us = 0;
        } else {
            var now: w.LARGE_INTEGER = undefined;
            _ = w.QueryPerformanceCounter(&now);
            const elapsed_us: i64 = @divTrunc((now.QuadPart - app.last_qpc.QuadPart) * 1_000_000, app.qpc_freq.QuadPart);
            app.last_qpc = now;
            const target_us: i64 = if (did_work) 16667 else 5000;
            app.accum_us += target_us - elapsed_us;
            if (app.accum_us > 0 and app.accum_us < 100_000) {
                w.Sleep(@intCast(@divTrunc(app.accum_us, 1000)));
                app.accum_us = 0;
            } else if (app.accum_us < -50_000) {
                app.accum_us = 0;
            }
        }
    }
}
