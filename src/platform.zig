const std = @import("std");
const builtin = @import("builtin");

const win = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "");
    @cDefine("UNICODE", "");
    @cDefine("_UNICODE", "");
    @cInclude("windows.h");
    @cInclude("commdlg.h");
    @cInclude("shellapi.h");
}) else struct {};

pub fn pathReplaceExt(alloc: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const last_sep = std.mem.lastIndexOfAny(u8, path, "/\\");
    const base_start: usize = if (last_sep) |s| s + 1 else 0;
    const base = path[base_start..];
    const rel_dot = std.mem.lastIndexOfScalar(u8, base, '.');
    const cut: usize = if (rel_dot) |d| base_start + d else path.len;
    return try std.fmt.allocPrint(alloc, "{s}{s}", .{ path[0..cut], new_ext });
}

pub fn statePathForSlot(alloc: std.mem.Allocator, rom_path: []const u8, slot: u8) ![]u8 {
    if (slot == 0) return pathReplaceExt(alloc, rom_path, ".state");
    var ext_buf: [16]u8 = undefined;
    const ext = try std.fmt.bufPrint(&ext_buf, ".state{d}", .{slot});
    return pathReplaceExt(alloc, rom_path, ext);
}

pub fn nextScreenshotPath(alloc: std.mem.Allocator, rom_path: ?[]const u8) ![]u8 {
    const base: []const u8 = if (rom_path) |rp| std.fs.path.basename(rp) else "screenshot";
    const dot = if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| d else base.len;
    const stem = base[0..dot];
    var n: u32 = 1;
    while (n < 99999) : (n += 1) {
        const candidate = try std.fmt.allocPrint(alloc, "{s}_{d:0>4}.png", .{ stem, n });
        if (!fileExists(alloc, candidate)) return candidate;
        alloc.free(candidate);
    }
    return error.NoFreeName;
}

fn utf8ToWideZ(alloc: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return try std.unicode.utf8ToUtf16LeAllocZ(alloc, s);
}

pub fn fileExists(alloc: std.mem.Allocator, path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    const wpath = utf8ToWideZ(alloc, path) catch return false;
    defer alloc.free(wpath);
    const attrs = win.GetFileAttributesW(wpath.ptr);
    return attrs != win.INVALID_FILE_ATTRIBUTES;
}

pub fn readAllFromFile(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (builtin.os.tag != .windows) return null;
    const wpath = try utf8ToWideZ(alloc, path);
    defer alloc.free(wpath);
    const h = win.CreateFileW(wpath.ptr, win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    if (h == win.INVALID_HANDLE_VALUE) return null;
    defer _ = win.CloseHandle(h);
    var size_high: win.DWORD = 0;
    const size_low = win.GetFileSize(h, &size_high);
    if (size_low == 0xFFFFFFFF) return error.SizeFailed;
    const total: u64 = (@as(u64, size_high) << 32) | size_low;
    if (total > 64 * 1024 * 1024) return error.TooLarge;
    const buf = try alloc.alloc(u8, @intCast(total));
    errdefer alloc.free(buf);
    var read_total: usize = 0;
    while (read_total < buf.len) {
        var got: win.DWORD = 0;
        const want: win.DWORD = @intCast(buf.len - read_total);
        if (win.ReadFile(h, buf.ptr + read_total, want, &got, null) == 0) return error.ReadFailed;
        if (got == 0) return error.ReadFailed;
        read_total += got;
    }
    return buf;
}

pub fn writeAllToFile(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    const wpath = try utf8ToWideZ(alloc, path);
    defer alloc.free(wpath);
    const wtmp = try utf8ToWideZ(alloc, tmp_path);
    defer alloc.free(wtmp);
    errdefer _ = win.DeleteFileW(wtmp.ptr);
    {
        const h = win.CreateFileW(wtmp.ptr, win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
        if (h == win.INVALID_HANDLE_VALUE) return error.OpenFailed;
        defer _ = win.CloseHandle(h);
        var total_written: usize = 0;
        while (total_written < data.len) {
            var written: win.DWORD = 0;
            const want: win.DWORD = @intCast(data.len - total_written);
            if (win.WriteFile(h, data.ptr + total_written, want, &written, null) == 0) return error.WriteFailed;
            if (written == 0) return error.WriteFailed;
            total_written += written;
        }
        if (win.FlushFileBuffers(h) == 0) return error.WriteFailed;
    }
    if (win.MoveFileExW(wtmp.ptr, wpath.ptr, win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH) == 0) return error.WriteFailed;
}

pub fn openRomDialog(alloc: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag != .windows) return null;
    var file_buf: [1024]u16 = .{0} ** 1024;
    const filter = std.unicode.utf8ToUtf16LeStringLiteral("Supported ROMs\x00*.gb;*.gbc;*.gba\x00Game Boy / GBC\x00*.gb;*.gbc\x00Game Boy Advance\x00*.gba\x00All Files\x00*.*\x00\x00");
    var ofn: win.OPENFILENAMEW = std.mem.zeroes(win.OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(win.OPENFILENAMEW);
    ofn.hwndOwner = null;
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = &file_buf;
    ofn.nMaxFile = file_buf.len;
    ofn.Flags = win.OFN_FILEMUSTEXIST | win.OFN_PATHMUSTEXIST | win.OFN_NOCHANGEDIR;
    if (win.GetOpenFileNameW(&ofn) == 0) return null;
    const len = std.mem.indexOfSentinel(u16, 0, @ptrCast(&file_buf));
    return std.unicode.utf16LeToUtf8Alloc(alloc, file_buf[0..len]) catch null;
}

pub fn cmdLineFirstArg(alloc: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag != .windows) return null;
    const cmdline = win.GetCommandLineW();
    var argc: c_int = 0;
    const argv = win.CommandLineToArgvW(cmdline, &argc);
    if (argv == null) return null;
    defer _ = win.LocalFree(@ptrCast(argv));
    if (argc < 2) return null;
    const w_arg = argv[1];
    const w_arg_len = std.mem.len(w_arg);
    return std.unicode.utf16LeToUtf8Alloc(alloc, w_arg[0..w_arg_len]) catch null;
}
