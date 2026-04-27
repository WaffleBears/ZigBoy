const std = @import("std");

pub const SCREEN_W: u32 = 240;
pub const SCREEN_H: u32 = 160;

pub const Ppu = struct {
    pram: [0x400]u8 = .{0} ** 0x400,
    vram: [0x18000]u8 = .{0} ** 0x18000,
    oam: [0x400]u8 = .{0} ** 0x400,
    framebuffer: [SCREEN_W * SCREEN_H]u32 = .{0} ** (SCREEN_W * SCREEN_H),

    dispcnt: u16 = 0x0080,
    greenswap: u16 = 0,
    dispstat: u16 = 0,
    vcount: u16 = 0,
    bgcnt: [4]u16 = .{0} ** 4,
    bghofs: [4]u16 = .{0} ** 4,
    bgvofs: [4]u16 = .{0} ** 4,
    bgpa: [2]i16 = .{ 0x100, 0x100 },
    bgpb: [2]i16 = .{ 0, 0 },
    bgpc: [2]i16 = .{ 0, 0 },
    bgpd: [2]i16 = .{ 0x100, 0x100 },
    bgx: [2]i32 = .{ 0, 0 },
    bgy: [2]i32 = .{ 0, 0 },
    bgx_internal: [2]i32 = .{ 0, 0 },
    bgy_internal: [2]i32 = .{ 0, 0 },
    win_h: [2]u16 = .{ 0, 0 },
    win_v: [2]u16 = .{ 0, 0 },
    winin: u16 = 0,
    winout: u16 = 0,
    mosaic: u16 = 0,
    bldcnt: u16 = 0,
    bldalpha: u16 = 0,
    bldy: u16 = 0,

    cycles: u32 = 0,
    dot: u32 = 0,
    irq_request_mask: u8 = 0,
    new_frame: bool = false,

    bg_lines: [4][SCREEN_W]u32 = .{.{0} ** SCREEN_W} ** 4,
    bg_active: [4]bool = .{false} ** 4,
    obj_line: [SCREEN_W]u32 = .{0} ** SCREEN_W,
    obj_pri: [SCREEN_W]u8 = .{4} ** SCREEN_W,
    obj_window: [SCREEN_W]bool = .{false} ** SCREEN_W,
    obj_alpha: [SCREEN_W]bool = .{false} ** SCREEN_W,

    pub fn init() Ppu {
        return .{};
    }

    pub fn reset(self: *Ppu) void {
        const fb = self.framebuffer;
        self.* = .{};
        self.framebuffer = fb;
        @memset(&self.framebuffer, 0xFF000000);
    }

    pub fn writeDispstat(self: *Ppu, v: u16) void {
        self.dispstat = (v & 0xFF38) | (self.dispstat & 0x0007);
    }

    pub fn writeBgX(self: *Ppu, idx: usize, hi: bool, v: u16) void {
        if (hi) {
            self.bgx[idx] = (self.bgx[idx] & 0x0000FFFF) | (@as(i32, @as(i16, @bitCast(v & 0x0FFF))) << 16);
        } else {
            self.bgx[idx] = (self.bgx[idx] & ~@as(i32, 0xFFFF)) | @as(i32, v);
        }
        self.bgx_internal[idx] = signExtend28(self.bgx[idx]);
    }

    pub fn writeBgY(self: *Ppu, idx: usize, hi: bool, v: u16) void {
        if (hi) {
            self.bgy[idx] = (self.bgy[idx] & 0x0000FFFF) | (@as(i32, @as(i16, @bitCast(v & 0x0FFF))) << 16);
        } else {
            self.bgy[idx] = (self.bgy[idx] & ~@as(i32, 0xFFFF)) | @as(i32, v);
        }
        self.bgy_internal[idx] = signExtend28(self.bgy[idx]);
    }

    fn signExtend28(v: i32) i32 {
        const u: u32 = @bitCast(v);
        const masked: u32 = u & 0x0FFFFFFF;
        if ((masked & 0x08000000) != 0) {
            return @bitCast(masked | 0xF0000000);
        }
        return @bitCast(masked);
    }

    pub const StepResult = struct { hblank_started: bool = false, vblank_started: bool = false, irqs: u8 = 0 };

    pub fn step(self: *Ppu, cycles: u32) StepResult {
        var res: StepResult = .{};
        self.cycles += cycles;
        while (self.cycles >= 4) {
            self.cycles -= 4;
            self.dot += 1;
            if (self.dot == 240) {
                self.dispstat |= 0x0002;
                if ((self.dispstat & 0x0010) != 0) res.irqs |= 0x02;
                res.hblank_started = true;
                if (self.vcount < 160) self.renderScanline();
            }
            if (self.dot >= 308) {
                self.dot = 0;
                self.dispstat &= ~@as(u16, 0x0002);
                self.vcount += 1;
                if (self.vcount == 160) {
                    self.dispstat |= 0x0001;
                    if ((self.dispstat & 0x0008) != 0) res.irqs |= 0x01;
                    res.vblank_started = true;
                    self.bgx_internal[0] = signExtend28(self.bgx[0]);
                    self.bgy_internal[0] = signExtend28(self.bgy[0]);
                    self.bgx_internal[1] = signExtend28(self.bgx[1]);
                    self.bgy_internal[1] = signExtend28(self.bgy[1]);
                    self.new_frame = true;
                } else if (self.vcount == 227) {
                    self.dispstat &= ~@as(u16, 0x0001);
                } else if (self.vcount >= 228) {
                    self.vcount = 0;
                }
                const lyc: u16 = (self.dispstat >> 8) & 0xFF;
                if (self.vcount == lyc) {
                    self.dispstat |= 0x0004;
                    if ((self.dispstat & 0x0020) != 0) res.irqs |= 0x04;
                } else {
                    self.dispstat &= ~@as(u16, 0x0004);
                }
                if (self.vcount < 160) {
                    self.bgx_internal[0] = @bitCast(@as(u32, @bitCast(self.bgx_internal[0])) +% @as(u32, @bitCast(@as(i32, self.bgpb[0]))));
                    self.bgy_internal[0] = @bitCast(@as(u32, @bitCast(self.bgy_internal[0])) +% @as(u32, @bitCast(@as(i32, self.bgpd[0]))));
                    self.bgx_internal[1] = @bitCast(@as(u32, @bitCast(self.bgx_internal[1])) +% @as(u32, @bitCast(@as(i32, self.bgpb[1]))));
                    self.bgy_internal[1] = @bitCast(@as(u32, @bitCast(self.bgy_internal[1])) +% @as(u32, @bitCast(@as(i32, self.bgpd[1]))));
                }
            }
        }
        return res;
    }

    fn pram15(self: *const Ppu, idx: u32) u32 {
        const i = idx & 0x1FF;
        const lo = self.pram[i * 2];
        const hi = self.pram[i * 2 + 1];
        const c: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
        return rgb15(c);
    }

    fn rgb15(c: u16) u32 {
        const r: u32 = @as(u32, c & 0x1F);
        const g: u32 = @as(u32, (c >> 5) & 0x1F);
        const b: u32 = @as(u32, (c >> 10) & 0x1F);
        const r8 = (r << 3) | (r >> 2);
        const g8 = (g << 3) | (g >> 2);
        const b8 = (b << 3) | (b >> 2);
        return 0xFF000000 | (r8 << 16) | (g8 << 8) | b8;
    }

    fn renderScanline(self: *Ppu) void {
        const y: u32 = self.vcount;
        const off: u32 = y * SCREEN_W;
        const mode: u3 = @truncate(self.dispcnt & 0x07);

        if ((self.dispcnt & 0x80) != 0) {
            var x: u32 = 0;
            while (x < SCREEN_W) : (x += 1) self.framebuffer[off + x] = 0xFFFFFFFF;
            return;
        }

        var i: usize = 0;
        while (i < 4) : (i += 1) {
            self.bg_active[i] = false;
            @memset(&self.bg_lines[i], 0);
        }
        @memset(&self.obj_line, 0);
        @memset(&self.obj_pri, 4);
        @memset(&self.obj_window, false);
        @memset(&self.obj_alpha, false);

        switch (mode) {
            0 => {
                if ((self.dispcnt & 0x100) != 0) self.renderTextBg(0, y);
                if ((self.dispcnt & 0x200) != 0) self.renderTextBg(1, y);
                if ((self.dispcnt & 0x400) != 0) self.renderTextBg(2, y);
                if ((self.dispcnt & 0x800) != 0) self.renderTextBg(3, y);
            },
            1 => {
                if ((self.dispcnt & 0x100) != 0) self.renderTextBg(0, y);
                if ((self.dispcnt & 0x200) != 0) self.renderTextBg(1, y);
                if ((self.dispcnt & 0x400) != 0) self.renderAffineBg(2, y);
            },
            2 => {
                if ((self.dispcnt & 0x400) != 0) self.renderAffineBg(2, y);
                if ((self.dispcnt & 0x800) != 0) self.renderAffineBg(3, y);
            },
            3 => {
                if ((self.dispcnt & 0x400) != 0) self.renderBitmap16(y);
            },
            4 => {
                if ((self.dispcnt & 0x400) != 0) self.renderBitmap8(y);
            },
            5 => {
                if ((self.dispcnt & 0x400) != 0) self.renderBitmap16Small(y);
            },
            else => {},
        }

        if ((self.dispcnt & 0x1000) != 0) self.renderSprites(y);

        self.compose(y);
    }

    fn renderTextBg(self: *Ppu, bg: usize, y: u32) void {
        self.bg_active[bg] = true;
        const cnt = self.bgcnt[bg];
        const tile_base: u32 = (@as(u32, cnt) >> 2 & 0x3) * 0x4000;
        const map_base: u32 = (@as(u32, cnt) >> 8 & 0x1F) * 0x800;
        const size: u32 = (cnt >> 14) & 0x03;
        const bpp8 = (cnt & 0x80) != 0;
        const mosaic = (cnt & 0x40) != 0;
        const mos_x: u32 = if (mosaic) ((self.mosaic & 0x000F) + 1) else 1;
        const mos_y: u32 = if (mosaic) (((self.mosaic >> 4) & 0x000F) + 1) else 1;
        const ey: u32 = (y / mos_y) * mos_y;

        const map_w: u32 = if ((size & 1) != 0) 512 else 256;
        const map_h: u32 = if ((size & 2) != 0) 512 else 256;

        const hofs = self.bghofs[bg];
        const vofs = self.bgvofs[bg];
        const sy: u32 = (ey + vofs) & (map_h - 1);

        var x: u32 = 0;
        while (x < SCREEN_W) : (x += 1) {
            const ex: u32 = (x / mos_x) * mos_x;
            const sx: u32 = (ex + hofs) & (map_w - 1);
            const tx_in_screen: u32 = (sx & 0xFF) >> 3;
            const ty_in_screen: u32 = (sy & 0xFF) >> 3;
            var screen_idx: u32 = 0;
            if (size == 1) {
                screen_idx = if ((sx & 0x100) != 0) 1 else 0;
            } else if (size == 2) {
                screen_idx = if ((sy & 0x100) != 0) 1 else 0;
            } else if (size == 3) {
                const sx_high: u32 = if ((sx & 0x100) != 0) 1 else 0;
                const sy_high: u32 = if ((sy & 0x100) != 0) 1 else 0;
                screen_idx = sx_high + sy_high * 2;
            }
            const map_addr = map_base + screen_idx * 0x800 + ty_in_screen * 32 * 2 + tx_in_screen * 2;
            if (map_addr + 1 >= self.vram.len) continue;
            const tile_lo = self.vram[map_addr];
            const tile_hi = self.vram[map_addr + 1];
            const tile_data: u16 = @as(u16, tile_lo) | (@as(u16, tile_hi) << 8);
            const tile_num: u32 = tile_data & 0x3FF;
            const flip_h = (tile_data & 0x400) != 0;
            const flip_v = (tile_data & 0x800) != 0;
            const palette: u32 = (tile_data >> 12) & 0x0F;
            var fx: u32 = sx & 7;
            var fy: u32 = sy & 7;
            if (flip_h) fx = 7 - fx;
            if (flip_v) fy = 7 - fy;

            var color_idx: u32 = 0;
            if (bpp8) {
                const ta = tile_base + tile_num * 64 + fy * 8 + fx;
                if (ta >= self.vram.len) continue;
                color_idx = self.vram[ta];
            } else {
                const ta = tile_base + tile_num * 32 + fy * 4 + (fx >> 1);
                if (ta >= self.vram.len) continue;
                const b = self.vram[ta];
                const ci: u32 = if ((fx & 1) == 0) (b & 0x0F) else (b >> 4);
                if (ci != 0) color_idx = palette * 16 + ci;
            }
            if (color_idx != 0) {
                self.bg_lines[bg][x] = self.pram15(color_idx) | 0x40000000;
            }
        }
    }

    fn renderAffineBg(self: *Ppu, bg: usize, y: u32) void {
        _ = y;
        const idx: usize = bg - 2;
        self.bg_active[bg] = true;
        const cnt = self.bgcnt[bg];
        const tile_base: u32 = (@as(u32, cnt) >> 2 & 0x3) * 0x4000;
        const map_base: u32 = (@as(u32, cnt) >> 8 & 0x1F) * 0x800;
        const size_idx: u32 = (cnt >> 14) & 0x03;
        const wrap = (cnt & 0x2000) != 0;
        const mosaic = (cnt & 0x40) != 0;
        const mos_x: u32 = if (mosaic) ((self.mosaic & 0x000F) + 1) else 1;
        const map_size: i32 = switch (size_idx) {
            0 => 128,
            1 => 256,
            2 => 512,
            else => 1024,
        };
        const tiles_per_row: u32 = @intCast(@divTrunc(map_size, 8));
        const pa: i32 = self.bgpa[idx];
        const pc: i32 = self.bgpc[idx];
        const ref_x_base: i32 = self.bgx_internal[idx];
        const ref_y_base: i32 = self.bgy_internal[idx];

        var x: u32 = 0;
        var last_color: u32 = 0;
        var last_ex: u32 = 0xFFFFFFFF;
        while (x < SCREEN_W) : (x += 1) {
            const ex: u32 = (x / mos_x) * mos_x;
            if (mosaic and ex == last_ex) {
                if (last_color != 0) self.bg_lines[bg][x] = last_color;
                continue;
            }
            const ref_x: i32 = ref_x_base +% (pa *% @as(i32, @intCast(ex)));
            const ref_y: i32 = ref_y_base +% (pc *% @as(i32, @intCast(ex)));
            const sx_full = ref_x >> 8;
            const sy_full = ref_y >> 8;
            var sx = sx_full;
            var sy = sy_full;
            if (wrap) {
                sx &= map_size - 1;
                sy &= map_size - 1;
            } else if (sx < 0 or sx >= map_size or sy < 0 or sy >= map_size) {
                last_color = 0;
                last_ex = ex;
                continue;
            }
            const ux: u32 = @intCast(sx);
            const uy: u32 = @intCast(sy);
            const tx = ux >> 3;
            const ty = uy >> 3;
            const fx = ux & 7;
            const fy = uy & 7;
            const map_addr = map_base + ty * tiles_per_row + tx;
            if (map_addr >= self.vram.len) {
                last_color = 0;
                last_ex = ex;
                continue;
            }
            const tile_num: u32 = self.vram[map_addr];
            const ta = tile_base + tile_num * 64 + fy * 8 + fx;
            if (ta >= self.vram.len) {
                last_color = 0;
                last_ex = ex;
                continue;
            }
            const color_idx: u32 = self.vram[ta];
            if (color_idx != 0) {
                const c = self.pram15(color_idx) | 0x40000000;
                self.bg_lines[bg][x] = c;
                last_color = c;
            } else {
                last_color = 0;
            }
            last_ex = ex;
        }
    }

    fn renderBitmap16(self: *Ppu, y: u32) void {
        self.bg_active[2] = true;
        const idx: usize = 0;
        const pa: i32 = self.bgpa[idx];
        const pc: i32 = self.bgpc[idx];
        var ref_x: i32 = self.bgx_internal[idx];
        var ref_y: i32 = self.bgy_internal[idx];
        _ = y;
        var x: u32 = 0;
        while (x < SCREEN_W) : (x += 1) {
            const sx = ref_x >> 8;
            const sy = ref_y >> 8;
            ref_x +%= pa;
            ref_y +%= pc;
            if (sx < 0 or sx >= 240 or sy < 0 or sy >= 160) continue;
            const off: usize = (@as(usize, @intCast(sy)) * 240 + @as(usize, @intCast(sx))) * 2;
            const lo = self.vram[off];
            const hi = self.vram[off + 1];
            const c: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            self.bg_lines[2][x] = rgb15(c) | 0x40000000;
        }
    }

    fn renderBitmap8(self: *Ppu, y: u32) void {
        self.bg_active[2] = true;
        const idx: usize = 0;
        const pa: i32 = self.bgpa[idx];
        const pc: i32 = self.bgpc[idx];
        var ref_x: i32 = self.bgx_internal[idx];
        var ref_y: i32 = self.bgy_internal[idx];
        const frame: usize = if ((self.dispcnt & 0x10) != 0) 0xA000 else 0;
        _ = y;
        var x: u32 = 0;
        while (x < SCREEN_W) : (x += 1) {
            const sx = ref_x >> 8;
            const sy = ref_y >> 8;
            ref_x +%= pa;
            ref_y +%= pc;
            if (sx < 0 or sx >= 240 or sy < 0 or sy >= 160) continue;
            const off: usize = frame + @as(usize, @intCast(sy)) * 240 + @as(usize, @intCast(sx));
            const ci = self.vram[off];
            if (ci != 0) self.bg_lines[2][x] = self.pram15(ci) | 0x40000000;
        }
    }

    fn renderBitmap16Small(self: *Ppu, y: u32) void {
        self.bg_active[2] = true;
        const idx: usize = 0;
        const pa: i32 = self.bgpa[idx];
        const pc: i32 = self.bgpc[idx];
        var ref_x: i32 = self.bgx_internal[idx];
        var ref_y: i32 = self.bgy_internal[idx];
        const frame: usize = if ((self.dispcnt & 0x10) != 0) 0xA000 else 0;
        _ = y;
        var x: u32 = 0;
        while (x < SCREEN_W) : (x += 1) {
            const sx = ref_x >> 8;
            const sy = ref_y >> 8;
            ref_x +%= pa;
            ref_y +%= pc;
            if (sx < 0 or sx >= 160 or sy < 0 or sy >= 128) continue;
            const off: usize = frame + (@as(usize, @intCast(sy)) * 160 + @as(usize, @intCast(sx))) * 2;
            const lo = self.vram[off];
            const hi = self.vram[off + 1];
            const c: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            self.bg_lines[2][x] = rgb15(c) | 0x40000000;
        }
    }

    const SpriteSizes: [3][4][2]u8 = .{
        .{ .{ 8, 8 }, .{ 16, 16 }, .{ 32, 32 }, .{ 64, 64 } },
        .{ .{ 16, 8 }, .{ 32, 8 }, .{ 32, 16 }, .{ 64, 32 } },
        .{ .{ 8, 16 }, .{ 8, 32 }, .{ 16, 32 }, .{ 32, 64 } },
    };

    fn renderSprites(self: *Ppu, y: u32) void {
        const mode: u3 = @truncate(self.dispcnt & 0x07);
        const obj_1d = (self.dispcnt & 0x40) != 0;
        const tile_base: u32 = 0x10000;
        const yi: i32 = @intCast(y);

        var n: usize = 0;
        while (n < 128) : (n += 1) {
            const oam_off = n * 8;
            const a0: u16 = @as(u16, self.oam[oam_off]) | (@as(u16, self.oam[oam_off + 1]) << 8);
            const a1: u16 = @as(u16, self.oam[oam_off + 2]) | (@as(u16, self.oam[oam_off + 3]) << 8);
            const a2: u16 = @as(u16, self.oam[oam_off + 4]) | (@as(u16, self.oam[oam_off + 5]) << 8);
            const sy_raw: i32 = a0 & 0xFF;
            const affine = (a0 & 0x100) != 0;
            const double_size = (a0 & 0x200) != 0;
            const disabled = !affine and double_size;
            if (disabled) continue;
            const obj_mode: u32 = (a0 & 0x0C00) >> 10;
            const mosaic = (a0 & 0x1000) != 0;
            const bpp8 = (a0 & 0x2000) != 0;
            const shape: u32 = (a0 & 0xC000) >> 14;
            const size: u32 = (a1 & 0xC000) >> 14;
            if (shape > 2) continue;
            const w: u32 = SpriteSizes[shape][size][0];
            const h: u32 = SpriteSizes[shape][size][1];
            const draw_w: i32 = if (affine and double_size) @intCast(w * 2) else @intCast(w);
            const draw_h: i32 = if (affine and double_size) @intCast(h * 2) else @intCast(h);

            var sy: i32 = sy_raw;
            if (sy >= 160) sy -= 256;
            if (yi < sy or yi >= sy + draw_h) continue;

            const sx_raw: i32 = @intCast(a1 & 0x1FF);
            const sx: i32 = if ((a1 & 0x100) != 0 and sx_raw >= 256) sx_raw - 512 else sx_raw;
            const tile_num: u32 = a2 & 0x3FF;
            const priority: u8 = @intCast((a2 >> 10) & 0x03);
            const palette: u32 = (a2 >> 12) & 0x0F;

            const flip_h = !affine and (a1 & 0x1000) != 0;
            const flip_v = !affine and (a1 & 0x2000) != 0;

            var pa: i32 = 0x100;
            var pb: i32 = 0;
            var pc: i32 = 0;
            var pd: i32 = 0x100;
            if (affine) {
                const grp: u32 = (a1 >> 9) & 0x1F;
                const aoff: u32 = grp * 32;
                pa = readOamS16(self, aoff + 6);
                pb = readOamS16(self, aoff + 14);
                pc = readOamS16(self, aoff + 22);
                pd = readOamS16(self, aoff + 30);
            }

            const mos_x: u32 = if (mosaic) (((self.mosaic >> 8) & 0x000F) + 1) else 1;
            const mos_y: u32 = if (mosaic) (((self.mosaic >> 12) & 0x000F) + 1) else 1;
            const row_in_sprite_full: i32 = yi - sy;
            const row_eff: i32 = @as(i32, @intCast(@as(u32, @intCast(row_in_sprite_full)) / mos_y * mos_y));

            var x_off: i32 = 0;
            while (x_off < draw_w) : (x_off += 1) {
                const out_x = sx + x_off;
                if (out_x < 0 or out_x >= SCREEN_W) continue;
                const out_x_u: u32 = @intCast(out_x);
                if (obj_mode != 2 and self.obj_pri[out_x_u] != 4 and self.obj_pri[out_x_u] <= priority) continue;
                const col_eff: i32 = @as(i32, @intCast(@as(u32, @intCast(x_off)) / mos_x * mos_x));
                var tx: i32 = col_eff;
                var ty: i32 = row_eff;
                if (affine) {
                    const cx: i32 = @divTrunc(draw_w, 2);
                    const cy: i32 = @divTrunc(draw_h, 2);
                    const dx: i32 = col_eff - cx;
                    const dy: i32 = row_eff - cy;
                    const half_w: i32 = @intCast(w / 2);
                    const half_h: i32 = @intCast(h / 2);
                    tx = ((pa * dx + pb * dy) >> 8) + half_w;
                    ty = ((pc * dx + pd * dy) >> 8) + half_h;
                    if (tx < 0 or tx >= @as(i32, @intCast(w))) continue;
                    if (ty < 0 or ty >= @as(i32, @intCast(h))) continue;
                } else {
                    if (flip_h) tx = @as(i32, @intCast(w)) - 1 - tx;
                    if (flip_v) ty = @as(i32, @intCast(h)) - 1 - ty;
                }
                const tile_x: u32 = @intCast(@divTrunc(tx, 8));
                const tile_y: u32 = @intCast(@divTrunc(ty, 8));
                const fx: u32 = @intCast(@mod(tx, 8));
                const fy: u32 = @intCast(@mod(ty, 8));
                var tile_idx: u32 = tile_num;
                if (obj_1d) {
                    const tw: u32 = w / 8;
                    if (bpp8) {
                        tile_idx +%= (tile_y * tw + tile_x) * 2;
                    } else {
                        tile_idx +%= tile_y * tw + tile_x;
                    }
                } else {
                    if (bpp8) {
                        tile_idx +%= (tile_y * 32) + tile_x * 2;
                    } else {
                        tile_idx +%= tile_y * 32 + tile_x;
                    }
                }
                tile_idx &= 0x3FF;
                if (mode >= 3 and mode <= 5 and tile_idx < 512) continue;
                var color_idx: u32 = 0;
                if (bpp8) {
                    const ta = tile_base + tile_idx * 32 + fy * 8 + fx;
                    if (ta >= self.vram.len) continue;
                    color_idx = self.vram[ta];
                } else {
                    const ta = tile_base + tile_idx * 32 + fy * 4 + (fx >> 1);
                    if (ta >= self.vram.len) continue;
                    const b = self.vram[ta];
                    const ci: u32 = if ((fx & 1) == 0) (b & 0x0F) else (b >> 4);
                    if (ci != 0) color_idx = palette * 16 + ci;
                }
                if (color_idx == 0) continue;
                if (obj_mode == 2) {
                    self.obj_window[out_x_u] = true;
                    continue;
                }
                if (self.obj_pri[out_x_u] == 4 or priority < self.obj_pri[out_x_u]) {
                    const c = self.pram15(0x100 + color_idx);
                    self.obj_line[out_x_u] = c | 0x40000000;
                    self.obj_pri[out_x_u] = priority;
                    self.obj_alpha[out_x_u] = obj_mode == 1;
                }
            }
        }
    }

    fn readOamS16(self: *const Ppu, off: u32) i32 {
        const lo = self.oam[off];
        const hi = self.oam[off + 1];
        const v: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
        return v;
    }

    fn compose(self: *Ppu, y: u32) void {
        const off: u32 = y * SCREEN_W;
        const win0_on = (self.dispcnt & 0x2000) != 0;
        const win1_on = (self.dispcnt & 0x4000) != 0;
        const winobj_on = (self.dispcnt & 0x8000) != 0;
        const any_window = win0_on or win1_on or winobj_on;

        const win0_top: u32 = (self.win_v[0] >> 8) & 0xFF;
        const win0_bot: u32 = self.win_v[0] & 0xFF;
        const win0_left: u32 = (self.win_h[0] >> 8) & 0xFF;
        const win0_right: u32 = self.win_h[0] & 0xFF;
        const win1_top: u32 = (self.win_v[1] >> 8) & 0xFF;
        const win1_bot: u32 = self.win_v[1] & 0xFF;
        const win1_left: u32 = (self.win_h[1] >> 8) & 0xFF;
        const win1_right: u32 = self.win_h[1] & 0xFF;

        const win0_inrow = win0_on and inWinRow(y, win0_top, win0_bot);
        const win1_inrow = win1_on and inWinRow(y, win1_top, win1_bot);

        const bldcnt = self.bldcnt;
        const bld_mode: u8 = @intCast((bldcnt >> 6) & 0x03);
        const eva: u32 = @min(@as(u32, self.bldalpha & 0x1F), 16);
        const evb: u32 = @min(@as(u32, (self.bldalpha >> 8) & 0x1F), 16);
        const evy: u32 = @min(@as(u32, self.bldy & 0x1F), 16);

        const backdrop_color = self.pram15(0);

        var x: u32 = 0;
        while (x < SCREEN_W) : (x += 1) {
            var enable_mask: u8 = 0x3F;
            if (any_window) {
                if (win0_inrow and inWinCol(x, win0_left, win0_right)) {
                    enable_mask = @intCast(self.winin & 0x3F);
                } else if (win1_inrow and inWinCol(x, win1_left, win1_right)) {
                    enable_mask = @intCast((self.winin >> 8) & 0x3F);
                } else if (winobj_on and self.obj_window[x]) {
                    enable_mask = @intCast((self.winout >> 8) & 0x3F);
                } else {
                    enable_mask = @intCast(self.winout & 0x3F);
                }
            }

            var top_color: u32 = backdrop_color;
            var top_layer: u8 = 5;
            var second_color: u32 = backdrop_color;
            var second_layer: u8 = 5;

            const obj_visible = (enable_mask & 0x10) != 0 and self.obj_pri[x] != 4 and self.obj_line[x] != 0;
            const obj_color = self.obj_line[x] & 0x00FFFFFF;
            const obj_pri = self.obj_pri[x];
            const obj_force_blend = self.obj_alpha[x];

            var pri: u8 = 0;
            while (pri < 4) : (pri += 1) {
                if (obj_visible and obj_pri == pri) {
                    if (top_layer == 5) {
                        top_color = obj_color;
                        top_layer = 4;
                    } else if (second_layer == 5) {
                        second_color = obj_color;
                        second_layer = 4;
                    }
                }
                var b: usize = 0;
                while (b < 4) : (b += 1) {
                    if (!self.bg_active[b]) continue;
                    const bm: u8 = @as(u8, 1) << @intCast(b);
                    if ((enable_mask & bm) == 0) continue;
                    const bgp: u8 = @intCast(self.bgcnt[b] & 0x03);
                    if (bgp != pri) continue;
                    if (self.bg_lines[b][x] == 0) continue;
                    const c = self.bg_lines[b][x] & 0x00FFFFFF;
                    if (top_layer == 5) {
                        top_color = c;
                        top_layer = @intCast(b);
                    } else if (second_layer == 5) {
                        second_color = c;
                        second_layer = @intCast(b);
                    }
                }
            }

            const cm_enabled = (enable_mask & 0x20) != 0;
            var final_color: u32 = top_color;
            if (cm_enabled) {
                const top_first = isFirst(bldcnt, top_layer);
                const second_target = isSecond(bldcnt, second_layer);
                const force = obj_force_blend and top_layer == 4 and second_target;
                if ((bld_mode == 1 and top_first and second_target) or force) {
                    final_color = blendAlpha(top_color, second_color, eva, evb);
                } else if (bld_mode == 2 and top_first) {
                    final_color = blendBrighter(top_color, evy);
                } else if (bld_mode == 3 and top_first) {
                    final_color = blendDarker(top_color, evy);
                }
            } else if (obj_force_blend and top_layer == 4) {
                const second_target = isSecond(bldcnt, second_layer);
                if (second_target) final_color = blendAlpha(top_color, second_color, eva, evb);
            }
            self.framebuffer[off + x] = 0xFF000000 | final_color;
        }

        if ((self.greenswap & 1) != 0) {
            var gx: u32 = 0;
            while (gx + 1 < SCREEN_W) : (gx += 2) {
                const a = self.framebuffer[off + gx];
                const b = self.framebuffer[off + gx + 1];
                const ag = a & 0x0000FF00;
                const bg = b & 0x0000FF00;
                self.framebuffer[off + gx] = (a & 0xFFFF00FF) | bg;
                self.framebuffer[off + gx + 1] = (b & 0xFFFF00FF) | ag;
            }
        }
    }

    fn inWinRow(y: u32, top: u32, bot: u32) bool {
        if (top <= bot) return y >= top and y < bot;
        return y >= top or y < bot;
    }

    fn inWinCol(x: u32, left: u32, right: u32) bool {
        if (left <= right) return x >= left and x < right;
        return x >= left or x < right;
    }

    fn isFirst(bldcnt: u16, layer: u8) bool {
        if (layer == 5) return (bldcnt & 0x0020) != 0;
        if (layer == 4) return (bldcnt & 0x0010) != 0;
        return (bldcnt & (@as(u16, 1) << @intCast(layer))) != 0;
    }

    fn isSecond(bldcnt: u16, layer: u8) bool {
        if (layer == 5) return (bldcnt & 0x2000) != 0;
        if (layer == 4) return (bldcnt & 0x1000) != 0;
        return (bldcnt & (@as(u16, 0x100) << @intCast(layer))) != 0;
    }

    fn blendAlpha(a: u32, b: u32, eva: u32, evb: u32) u32 {
        const ar: u32 = (a >> 16) & 0xFF;
        const ag: u32 = (a >> 8) & 0xFF;
        const ab: u32 = a & 0xFF;
        const br: u32 = (b >> 16) & 0xFF;
        const bg: u32 = (b >> 8) & 0xFF;
        const bb: u32 = b & 0xFF;
        const r: u32 = @min((ar * eva + br * evb) >> 4, 255);
        const g: u32 = @min((ag * eva + bg * evb) >> 4, 255);
        const bo: u32 = @min((ab * eva + bb * evb) >> 4, 255);
        return (r << 16) | (g << 8) | bo;
    }

    fn blendBrighter(a: u32, evy: u32) u32 {
        const ar: u32 = (a >> 16) & 0xFF;
        const ag: u32 = (a >> 8) & 0xFF;
        const ab: u32 = a & 0xFF;
        const r: u32 = ar + (((255 - ar) * evy) >> 4);
        const g: u32 = ag + (((255 - ag) * evy) >> 4);
        const b: u32 = ab + (((255 - ab) * evy) >> 4);
        return (r << 16) | (g << 8) | b;
    }

    fn blendDarker(a: u32, evy: u32) u32 {
        const ar: u32 = (a >> 16) & 0xFF;
        const ag: u32 = (a >> 8) & 0xFF;
        const ab: u32 = a & 0xFF;
        const r: u32 = ar - ((ar * evy) >> 4);
        const g: u32 = ag - ((ag * evy) >> 4);
        const b: u32 = ab - ((ab * evy) >> 4);
        return (r << 16) | (g << 8) | b;
    }
};
