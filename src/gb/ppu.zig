const std = @import("std");

pub const W: usize = 160;
pub const H: usize = 144;

pub const Mode = enum(u2) { hblank = 0, vblank = 1, oam = 2, drawing = 3 };

const Sprite = struct {
    x: i32,
    y: i32,
    tile: u8,
    attr: u8,
    oam_idx: u8,
};

pub const Ppu = struct {
    vram: [0x4000]u8 = .{0} ** 0x4000,
    oam: [0xA0]u8 = .{0} ** 0xA0,

    framebuffer: [W * H]u32 = .{0} ** (W * H),

    lcdc: u8 = 0x91,
    stat: u8 = 0x85,
    scy: u8 = 0,
    scx: u8 = 0,
    ly: u8 = 0,
    lyc: u8 = 0,
    bgp: u8 = 0xFC,
    obp0: u8 = 0xFF,
    obp1: u8 = 0xFF,
    wy: u8 = 0,
    wx: u8 = 0,

    vbk: u8 = 0,
    bcps: u8 = 0,
    ocps: u8 = 0,
    bcpd: [64]u8 = .{0} ** 64,
    ocpd: [64]u8 = .{0} ** 64,
    opri: u8 = 0,

    hdma_src: u16 = 0,
    hdma_dst: u16 = 0,
    hdma_len: u8 = 0,
    hdma_active: bool = false,
    hdma_blocks_left: u8 = 0,

    cycles: u32 = 0,
    mode: Mode = .oam,
    window_line: u8 = 0,
    stat_line: bool = false,
    mode3_duration: u32 = 172,

    cgb_mode: bool = false,
    irq_vblank: bool = false,
    irq_stat: bool = false,
    new_frame: bool = false,

    bg_idx_line: [W]u8 = .{0} ** W,
    bg_attr_line: [W]u8 = .{0} ** W,
    dmg_palette: [4]u32 = .{ 0xFFE0F8D0, 0xFF88C070, 0xFF346856, 0xFF081820 },

    draw_x: u8 = 0,
    frame_sprites: [10]Sprite = undefined,
    frame_sprite_count: usize = 0,
    window_line_used_on_line: bool = false,

    pub fn reset(self: *Ppu, cgb: bool) void {
        const palette = self.dmg_palette;
        self.* = .{};
        self.dmg_palette = palette;
        self.cgb_mode = cgb;
        if (cgb) {
            for (0..64) |i| {
                self.bcpd[i] = 0xFF;
                self.ocpd[i] = 0xFF;
            }
            const grad = [_][2]u8{
                .{ 0xFF, 0x7F },
                .{ 0xB5, 0x56 },
                .{ 0x4A, 0x29 },
                .{ 0x00, 0x00 },
            };
            for (0..4) |i| {
                self.bcpd[i * 2] = grad[i][0];
                self.bcpd[i * 2 + 1] = grad[i][1];
                self.ocpd[i * 2] = grad[i][0];
                self.ocpd[i * 2 + 1] = grad[i][1];
                self.ocpd[8 + i * 2] = grad[i][0];
                self.ocpd[8 + i * 2 + 1] = grad[i][1];
            }
        }
    }

    pub fn init(cgb: bool) Ppu {
        var p: Ppu = .{};
        p.reset(cgb);
        return p;
    }

    pub fn readVram(self: *Ppu, addr: u16) u8 {
        const off = @as(usize, addr - 0x8000) + (@as(usize, self.vbk & 1) * 0x2000);
        return self.vram[off];
    }

    pub fn writeVram(self: *Ppu, addr: u16, val: u8) void {
        const off = @as(usize, addr - 0x8000) + (@as(usize, self.vbk & 1) * 0x2000);
        self.vram[off] = val;
    }

    pub fn readOam(self: *Ppu, addr: u16) u8 {
        return self.oam[addr - 0xFE00];
    }

    pub fn writeOam(self: *Ppu, addr: u16, val: u8) void {
        self.oam[addr - 0xFE00] = val;
    }

    pub fn readReg(self: *Ppu, addr: u16) u8 {
        return switch (addr) {
            0xFF40 => self.lcdc,
            0xFF41 => blk: {
                var v: u8 = (self.stat & 0xF8) | @as(u8, @intFromEnum(self.mode)) | 0x80;
                if (self.ly == self.lyc) v |= 0x04;
                break :blk v;
            },
            0xFF42 => self.scy,
            0xFF43 => self.scx,
            0xFF44 => self.ly,
            0xFF45 => self.lyc,
            0xFF47 => self.bgp,
            0xFF48 => self.obp0,
            0xFF49 => self.obp1,
            0xFF4A => self.wy,
            0xFF4B => self.wx,
            0xFF4F => self.vbk | 0xFE,
            0xFF51 => @intCast(self.hdma_src >> 8),
            0xFF52 => @intCast(self.hdma_src & 0xFF),
            0xFF53 => @intCast(self.hdma_dst >> 8),
            0xFF54 => @intCast(self.hdma_dst & 0xFF),
            0xFF55 => if (!self.hdma_active) self.hdma_len else if (self.hdma_blocks_left == 0) 0xFF else self.hdma_blocks_left - 1,
            0xFF68 => self.bcps,
            0xFF69 => self.bcpd[self.bcps & 0x3F],
            0xFF6A => self.ocps,
            0xFF6B => self.ocpd[self.ocps & 0x3F],
            0xFF6C => self.opri | 0xFE,
            else => 0xFF,
        };
    }

    pub fn writeReg(self: *Ppu, addr: u16, val: u8) void {
        switch (addr) {
            0xFF40 => {
                const was_on = (self.lcdc & 0x80) != 0;
                const becoming_on = !was_on and (val & 0x80) != 0;
                self.lcdc = val;
                if (was_on and (val & 0x80) == 0) {
                    self.ly = 0;
                    self.cycles = 0;
                    self.mode = .hblank;
                    self.window_line = 0;
                    self.stat_line = false;
                    self.draw_x = 0;
                }
                if (becoming_on) {
                    self.ly = 0;
                    self.cycles = 0;
                    self.mode = .oam;
                    self.window_line = 0;
                    self.stat_line = false;
                    self.mode3_duration = 172;
                    self.draw_x = 0;
                }
            },
            0xFF41 => self.stat = (self.stat & 0x07) | (val & 0x78),
            0xFF42 => self.scy = val,
            0xFF43 => self.scx = val,
            0xFF44 => {},
            0xFF45 => self.lyc = val,
            0xFF47 => self.bgp = val,
            0xFF48 => self.obp0 = val,
            0xFF49 => self.obp1 = val,
            0xFF4A => self.wy = val,
            0xFF4B => self.wx = val,
            0xFF4F => self.vbk = val & 1,
            0xFF51 => self.hdma_src = (self.hdma_src & 0x00FF) | (@as(u16, val) << 8),
            0xFF52 => self.hdma_src = (self.hdma_src & 0xFF00) | (val & 0xF0),
            0xFF53 => self.hdma_dst = (self.hdma_dst & 0x00FF) | ((@as(u16, val) & 0x1F) << 8),
            0xFF54 => self.hdma_dst = (self.hdma_dst & 0xFF00) | (val & 0xF0),
            0xFF55 => {
                self.hdma_len = val & 0x7F;
                self.hdma_blocks_left = self.hdma_len + 1;
                self.hdma_active = (val & 0x80) != 0;
            },
            0xFF68 => self.bcps = val,
            0xFF69 => {
                const idx = self.bcps & 0x3F;
                self.bcpd[idx] = val;
                if ((self.bcps & 0x80) != 0) self.bcps = 0x80 | ((idx + 1) & 0x3F);
            },
            0xFF6A => self.ocps = val,
            0xFF6B => {
                const idx = self.ocps & 0x3F;
                self.ocpd[idx] = val;
                if ((self.ocps & 0x80) != 0) self.ocps = 0x80 | ((idx + 1) & 0x3F);
            },
            0xFF6C => self.opri = val & 1,
            else => {},
        }
    }

    pub fn step(self: *Ppu, cycles: u32) void {
        if ((self.lcdc & 0x80) == 0) return;
        var c = cycles;
        while (c > 0) {
            const tick = @min(c, 4);
            c -= tick;
            self.cycles += tick;
            switch (self.mode) {
                .oam => if (self.cycles >= 80) {
                    self.cycles -= 80;
                    self.mode = .drawing;
                    self.mode3_duration = self.computeMode3Duration();
                    self.draw_x = 0;
                    self.window_line_used_on_line = false;
                    self.collectSprites();
                    if (self.ly < H) {
                        for (0..W) |i| {
                            self.bg_idx_line[i] = 0;
                            self.bg_attr_line[i] = 0;
                        }
                    }
                },
                .drawing => {
                    if (self.ly < H) {
                        const w32: u32 = @intCast(W);
                        const target_unclamped: u32 = if (self.mode3_duration == 0) w32 else (self.cycles * w32) / self.mode3_duration;
                        const target: u8 = @intCast(@min(target_unclamped, w32));
                        while (self.draw_x < target) : (self.draw_x += 1) {
                            self.renderBgPixel(self.draw_x, self.ly);
                            self.renderObjPixel(self.draw_x, self.ly);
                        }
                    }
                    if (self.cycles >= self.mode3_duration) {
                        self.cycles -= self.mode3_duration;
                        if (self.ly < H) {
                            while (self.draw_x < @as(u8, @intCast(W))) : (self.draw_x += 1) {
                                self.renderBgPixel(self.draw_x, self.ly);
                                self.renderObjPixel(self.draw_x, self.ly);
                            }
                        }
                        self.mode = .hblank;
                    }
                },
                .hblank => {
                    const hb_len: u32 = 376 - self.mode3_duration;
                    if (self.cycles >= hb_len) {
                        self.cycles -= hb_len;
                        self.ly += 1;
                        self.draw_x = 0;
                        if (self.window_line_used_on_line) self.window_line +%= 1;
                        if (self.ly == 144) {
                            self.mode = .vblank;
                            self.irq_vblank = true;
                            self.new_frame = true;
                        } else self.mode = .oam;
                    }
                },
                .vblank => if (self.cycles >= 456) {
                    self.cycles -= 456;
                    self.ly += 1;
                    if (self.ly > 153) {
                        self.ly = 0;
                        self.window_line = 0;
                        self.mode = .oam;
                    }
                },
            }
            self.updateStat();
        }
    }

    fn collectSprites(self: *Ppu) void {
        self.frame_sprite_count = 0;
        if ((self.lcdc & 0x02) == 0) return;
        const tall_obj = (self.lcdc & 0x04) != 0;
        const obj_h: u8 = if (tall_obj) 16 else 8;
        const y = self.ly;
        var i: usize = 0;
        while (i < 40 and self.frame_sprite_count < 10) : (i += 1) {
            const oy = @as(i32, self.oam[i * 4]) - 16;
            const ox = @as(i32, self.oam[i * 4 + 1]) - 8;
            const tile = self.oam[i * 4 + 2];
            const attr = self.oam[i * 4 + 3];
            if (@as(i32, y) >= oy and @as(i32, y) < oy + @as(i32, obj_h)) {
                self.frame_sprites[self.frame_sprite_count] = .{ .x = ox, .y = oy, .tile = tile, .attr = attr, .oam_idx = @intCast(i) };
                self.frame_sprite_count += 1;
            }
        }
        const Lt = struct {
            fn xOrder(_: void, a: Sprite, b: Sprite) bool {
                if (a.x != b.x) return a.x < b.x;
                return a.oam_idx < b.oam_idx;
            }
            fn idxOrder(_: void, a: Sprite, b: Sprite) bool {
                return a.oam_idx < b.oam_idx;
            }
        };
        if (!self.cgb_mode or self.opri == 1) {
            std.mem.sort(Sprite, self.frame_sprites[0..self.frame_sprite_count], {}, Lt.xOrder);
        } else {
            std.mem.sort(Sprite, self.frame_sprites[0..self.frame_sprite_count], {}, Lt.idxOrder);
        }
    }

    fn computeMode3Duration(self: *Ppu) u32 {
        var d: u32 = 172;
        d += @as(u32, self.scx & 7);
        if ((self.lcdc & 0x02) != 0) {
            const obj_h: u8 = if ((self.lcdc & 0x04) != 0) 16 else 8;
            const y = self.ly;
            var count: u32 = 0;
            var i: usize = 0;
            while (i < 40 and count < 10) : (i += 1) {
                const oy: i32 = @as(i32, self.oam[i * 4]) - 16;
                if (@as(i32, y) >= oy and @as(i32, y) < oy + @as(i32, obj_h)) {
                    count += 1;
                }
            }
            d += count * 6;
        }
        if ((self.lcdc & 0x20) != 0 and self.ly >= self.wy and (self.cgb_mode or (self.lcdc & 0x01) != 0)) {
            const wx_eff: i32 = @as(i32, self.wx) - 7;
            if (wx_eff >= 0 and wx_eff < @as(i32, W)) d += 6;
        }
        if (d > 289) d = 289;
        return d;
    }

    fn updateStat(self: *Ppu) void {
        var line = false;
        if ((self.stat & 0x40) != 0 and self.ly == self.lyc) line = true;
        if ((self.stat & 0x20) != 0 and self.mode == .oam) line = true;
        if ((self.stat & 0x10) != 0 and self.mode == .vblank) line = true;
        if ((self.stat & 0x08) != 0 and self.mode == .hblank) line = true;
        if (line and !self.stat_line) self.irq_stat = true;
        self.stat_line = line;
    }

    fn cgbColor(palette: *const [64]u8, pal: u8, idx: u8) u32 {
        const base: usize = @as(usize, pal) * 8 + @as(usize, idx) * 2;
        const lo = palette[base];
        const hi = palette[base + 1];
        const c: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
        const r5: u32 = c & 0x1F;
        const g5: u32 = (c >> 5) & 0x1F;
        const b5: u32 = (c >> 10) & 0x1F;
        const r: u32 = (r5 * 13 + g5 * 2 + b5) >> 1;
        const g: u32 = (g5 * 3 + b5) << 1;
        const b: u32 = (r5 * 3 + g5 * 2 + b5 * 11) >> 1;
        const r8: u32 = if (r > 255) 255 else r;
        const g8: u32 = if (g > 255) 255 else g;
        const b8: u32 = if (b > 255) 255 else b;
        return 0xFF000000 | (r8 << 16) | (g8 << 8) | b8;
    }

    fn dmgShade(self: *const Ppu, idx: u8, palette: u8) u32 {
        const shade: u8 = (palette >> @intCast(idx * 2)) & 0x03;
        return self.dmg_palette[shade & 0x03];
    }

    fn renderBgPixel(self: *Ppu, x: u8, y: u8) void {
        const bg_on = self.cgb_mode or (self.lcdc & 0x01) != 0;
        const win_on = (self.lcdc & 0x20) != 0 and (self.cgb_mode or (self.lcdc & 0x01) != 0);
        const tile_signed = (self.lcdc & 0x10) == 0;
        const wx_eff: i32 = @as(i32, self.wx) - 7;
        const win_active = win_on and y >= self.wy and (@as(i32, x) >= wx_eff) and wx_eff < @as(i32, W);

        if (win_active) {
            self.window_line_used_on_line = true;
            const win_map: u16 = if ((self.lcdc & 0x40) != 0) 0x9C00 else 0x9800;
            const win_y_use: u8 = self.window_line;
            const win_x: i32 = @as(i32, x) - wx_eff;
            const tile_row: u16 = (@as(u16, win_y_use) >> 3);
            const tile_col: u16 = @as(u16, @intCast(win_x)) >> 3;
            const map_addr = win_map + tile_row * 32 + tile_col;
            const tile_num = self.vram[map_addr - 0x8000];
            const attr: u8 = if (self.cgb_mode) self.vram[map_addr - 0x8000 + 0x2000] else 0;
            const bank: usize = if ((attr & 0x08) != 0) 0x2000 else 0;
            const flip_x = (attr & 0x20) != 0;
            const flip_y = (attr & 0x40) != 0;
            const palette = attr & 0x07;
            var fy: u8 = win_y_use & 7;
            if (flip_y) fy = 7 - fy;
            const tile_addr: usize = if (tile_signed) blk: {
                const signed: i8 = @bitCast(tile_num);
                const base: i32 = 0x9000 + @as(i32, signed) * 16;
                break :blk @as(usize, @intCast(base - 0x8000)) + bank;
            } else (@as(usize, tile_num) * 16) + bank;
            if (tile_addr + 15 >= self.vram.len) return;
            const lo = self.vram[tile_addr + fy * 2];
            const hi = self.vram[tile_addr + fy * 2 + 1];
            var fx: u8 = @as(u8, @intCast(win_x & 7));
            if (!flip_x) fx = 7 - fx;
            const bit: u3 = @intCast(fx);
            const color_idx: u8 = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
            self.bg_idx_line[x] = color_idx;
            self.bg_attr_line[x] = attr;
            const px = @as(usize, y) * W + x;
            self.framebuffer[px] = if (self.cgb_mode) cgbColor(&self.bcpd, palette, color_idx) else self.dmgShade(color_idx, self.bgp);
            return;
        }

        if (!bg_on) {
            self.framebuffer[@as(usize, y) * W + x] = if (self.cgb_mode) 0xFFFFFFFF else self.dmg_palette[0];
            self.bg_idx_line[x] = 0;
            self.bg_attr_line[x] = 0;
            return;
        }

        const bg_map: u16 = if ((self.lcdc & 0x08) != 0) 0x9C00 else 0x9800;
        const bg_y: u8 = self.scy +% y;
        const bg_x: u8 = self.scx +% x;
        const tile_row: u16 = (@as(u16, bg_y) >> 3) & 0x1F;
        const tile_col: u16 = (@as(u16, bg_x) >> 3) & 0x1F;
        const map_addr = bg_map + tile_row * 32 + tile_col;
        const tile_num = self.vram[map_addr - 0x8000];
        const attr: u8 = if (self.cgb_mode) self.vram[map_addr - 0x8000 + 0x2000] else 0;
        const bank: usize = if ((attr & 0x08) != 0) 0x2000 else 0;
        const flip_x = (attr & 0x20) != 0;
        const flip_y = (attr & 0x40) != 0;
        const palette = attr & 0x07;
        var fy: u8 = bg_y & 7;
        if (flip_y) fy = 7 - fy;
        const tile_addr: usize = if (tile_signed) blk: {
            const signed: i8 = @bitCast(tile_num);
            const base: i32 = 0x9000 + @as(i32, signed) * 16;
            break :blk @as(usize, @intCast(base - 0x8000)) + bank;
        } else (@as(usize, tile_num) * 16) + bank;
        if (tile_addr + 15 >= self.vram.len) return;
        const lo = self.vram[tile_addr + fy * 2];
        const hi = self.vram[tile_addr + fy * 2 + 1];
        var fx: u8 = bg_x & 7;
        if (!flip_x) fx = 7 - fx;
        const bit: u3 = @intCast(fx);
        const color_idx: u8 = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
        self.bg_idx_line[x] = color_idx;
        self.bg_attr_line[x] = attr;
        const px = @as(usize, y) * W + x;
        self.framebuffer[px] = if (self.cgb_mode) cgbColor(&self.bcpd, palette, color_idx) else self.dmgShade(color_idx, self.bgp);
    }

    fn renderObjPixel(self: *Ppu, x: u8, y: u8) void {
        if ((self.lcdc & 0x02) == 0) return;
        const tall_obj = (self.lcdc & 0x04) != 0;
        const obj_h: u8 = if (tall_obj) 16 else 8;
        var s: usize = 0;
        while (s < self.frame_sprite_count) : (s += 1) {
            const sp = self.frame_sprites[s];
            const sx = @as(i32, x) - sp.x;
            if (sx < 0 or sx >= 8) continue;
            var ty: u8 = @intCast(@as(i32, y) - sp.y);
            if ((sp.attr & 0x40) != 0) ty = obj_h - 1 - ty;
            var tile_num = sp.tile;
            if (tall_obj) tile_num &= 0xFE;
            if (ty >= 8) {
                tile_num |= 1;
                ty -= 8;
            }
            const bank: usize = if (self.cgb_mode and (sp.attr & 0x08) != 0) 0x2000 else 0;
            const tile_addr: usize = (@as(usize, tile_num) * 16) + bank;
            if (tile_addr + 15 >= self.vram.len) return;
            const lo = self.vram[tile_addr + ty * 2];
            const hi = self.vram[tile_addr + ty * 2 + 1];
            var bit_x: u8 = @intCast(sx);
            if ((sp.attr & 0x20) == 0) bit_x = 7 - bit_x;
            const bit: u3 = @intCast(bit_x);
            const color_idx: u8 = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
            if (color_idx == 0) return;
            const bg_attr = self.bg_attr_line[x];
            const bg_idx = self.bg_idx_line[x];
            if (self.cgb_mode) {
                const master_priority = (self.lcdc & 0x01) != 0;
                const bg_master = master_priority and (bg_attr & 0x80) != 0 and bg_idx != 0;
                const obj_behind = (sp.attr & 0x80) != 0 and bg_idx != 0 and master_priority;
                if (bg_master or obj_behind) return;
                const palette = sp.attr & 0x07;
                self.framebuffer[@as(usize, y) * W + x] = cgbColor(&self.ocpd, palette, color_idx);
            } else {
                if ((sp.attr & 0x80) != 0 and bg_idx != 0) return;
                const pal = if ((sp.attr & 0x10) != 0) self.obp1 else self.obp0;
                self.framebuffer[@as(usize, y) * W + x] = self.dmgShade(color_idx, pal);
            }
            return;
        }
    }
};
