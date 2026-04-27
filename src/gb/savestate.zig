const std = @import("std");

const MAGIC: u32 = 0x47424353;
const VERSION: u32 = 4;

const TAG_META = "META".*;
const TAG_CPU = "CPU0".*;
const TAG_MMU = "MMU0".*;
const TAG_PPU = "PPU0".*;
const TAG_TIM = "TIM0".*;
const TAG_APU = "APU0".*;
const TAG_JOY = "JOY0".*;
const TAG_CART = "CRT0".*;
const TAG_END = "END0".*;

pub const Writer = struct {
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn u8v(self: *Writer, v: u8) !void {
        try self.list.append(self.alloc, v);
    }
    pub fn u16v(self: *Writer, v: u16) !void {
        try self.u8v(@truncate(v));
        try self.u8v(@truncate(v >> 8));
    }
    pub fn u32v(self: *Writer, v: u32) !void {
        try self.u16v(@truncate(v));
        try self.u16v(@truncate(v >> 16));
    }
    pub fn bytes(self: *Writer, b: []const u8) !void {
        try self.list.appendSlice(self.alloc, b);
    }
    pub fn boolv(self: *Writer, v: bool) !void {
        try self.u8v(if (v) 1 else 0);
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    end: usize = 0,

    pub fn u8v(self: *Reader) !u8 {
        if (self.pos >= self.end) return error.Truncated;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }
    pub fn u16v(self: *Reader) !u16 {
        const lo = try self.u8v();
        const hi = try self.u8v();
        return (@as(u16, hi) << 8) | lo;
    }
    pub fn u32v(self: *Reader) !u32 {
        const lo = try self.u16v();
        const hi = try self.u16v();
        return (@as(u32, hi) << 16) | lo;
    }
    pub fn bytes(self: *Reader, dst: []u8) !void {
        if (self.pos + dst.len > self.end) return error.Truncated;
        @memcpy(dst, self.buf[self.pos .. self.pos + dst.len]);
        self.pos += dst.len;
    }
    pub fn boolv(self: *Reader) !bool {
        return (try self.u8v()) != 0;
    }
    pub fn skip(self: *Reader, n: usize) !void {
        if (self.pos + n > self.end) return error.Truncated;
        self.pos += n;
    }
    pub fn opt_u8(self: *Reader) ?u8 {
        if (self.pos >= self.end) return null;
        return self.u8v() catch null;
    }
    pub fn opt_u16(self: *Reader) ?u16 {
        if (self.pos + 2 > self.end) return null;
        return self.u16v() catch null;
    }
    pub fn opt_u32(self: *Reader) ?u32 {
        if (self.pos + 4 > self.end) return null;
        return self.u32v() catch null;
    }
    pub fn opt_bool(self: *Reader) ?bool {
        if (self.pos >= self.end) return null;
        return self.boolv() catch null;
    }
};

fn writeChunk(w: *Writer, tag: [4]u8, payload: []const u8) !void {
    try w.bytes(&tag);
    try w.u32v(@intCast(payload.len));
    try w.bytes(payload);
}

pub fn save(alloc: std.mem.Allocator, gb: anytype) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var w: Writer = .{ .list = &list, .alloc = alloc };

    try w.u32v(MAGIC);
    try w.u32v(VERSION);

    var section: std.ArrayList(u8) = .empty;
    defer section.deinit(alloc);
    var sw: Writer = .{ .list = &section, .alloc = alloc };

    section.clearRetainingCapacity();
    try sw.u32v(std.hash.Crc32.hash(gb.cart.rom));
    try sw.boolv(gb.cgb_mode);
    try writeChunk(&w, TAG_META, section.items);

    const cpu = &gb.cpu;
    section.clearRetainingCapacity();
    try sw.u8v(cpu.a);
    try sw.u8v(cpu.f);
    try sw.u8v(cpu.b);
    try sw.u8v(cpu.c);
    try sw.u8v(cpu.d);
    try sw.u8v(cpu.e);
    try sw.u8v(cpu.h);
    try sw.u8v(cpu.l);
    try sw.u16v(cpu.sp);
    try sw.u16v(cpu.pc);
    try sw.boolv(cpu.ime);
    try sw.boolv(cpu.ime_pending);
    try sw.boolv(cpu.halted);
    try sw.boolv(cpu.halt_bug);
    try sw.boolv(cpu.stopped);
    try sw.boolv(cpu.double_speed);
    try writeChunk(&w, TAG_CPU, section.items);

    const mmu = &gb.mmu;
    section.clearRetainingCapacity();
    try sw.bytes(&mmu.wram);
    try sw.bytes(&mmu.hram);
    try sw.u8v(mmu.ie);
    try sw.u8v(mmu.if_reg);
    try sw.u8v(mmu.svbk);
    try sw.u8v(mmu.key1);
    try sw.boolv(mmu.oam_dma_active);
    try sw.u16v(mmu.oam_dma_src);
    try sw.u8v(mmu.oam_dma_pos);
    try sw.u32v(mmu.oam_dma_cycles);
    try sw.u8v(mmu.boot_off);
    try sw.u8v(mmu.serial_data);
    try sw.u8v(mmu.serial_ctrl);
    try sw.u32v(mmu.serial_cycles);
    try sw.u8v(mmu.rp);
    try sw.u32v(mmu.gdma_pending_cycles);
    try sw.u16v(@bitCast(mmu.last_hdma_ly));
    try writeChunk(&w, TAG_MMU, section.items);

    section.clearRetainingCapacity();
    try sw.u8v(gb.joypad.buttons);
    try sw.boolv(gb.joypad.select_dir);
    try sw.boolv(gb.joypad.select_btn);
    try sw.boolv(gb.joypad.irq_request);
    try writeChunk(&w, TAG_JOY, section.items);

    const ppu = &gb.ppu;
    section.clearRetainingCapacity();
    try sw.bytes(&ppu.vram);
    try sw.bytes(&ppu.oam);
    try sw.u8v(ppu.lcdc);
    try sw.u8v(ppu.stat);
    try sw.u8v(ppu.scy);
    try sw.u8v(ppu.scx);
    try sw.u8v(ppu.ly);
    try sw.u8v(ppu.lyc);
    try sw.u8v(ppu.bgp);
    try sw.u8v(ppu.obp0);
    try sw.u8v(ppu.obp1);
    try sw.u8v(ppu.wy);
    try sw.u8v(ppu.wx);
    try sw.u8v(ppu.vbk);
    try sw.u8v(ppu.bcps);
    try sw.u8v(ppu.ocps);
    try sw.bytes(&ppu.bcpd);
    try sw.bytes(&ppu.ocpd);
    try sw.u8v(ppu.opri);
    try sw.u16v(ppu.hdma_src);
    try sw.u16v(ppu.hdma_dst);
    try sw.u8v(ppu.hdma_len);
    try sw.boolv(ppu.hdma_active);
    try sw.u8v(ppu.hdma_blocks_left);
    try sw.u32v(ppu.cycles);
    try sw.u8v(@intFromEnum(ppu.mode));
    try sw.u8v(ppu.window_line);
    try sw.u32v(ppu.mode3_duration);
    try sw.boolv(ppu.irq_vblank);
    try sw.boolv(ppu.irq_stat);
    try sw.boolv(ppu.stat_line);
    try writeChunk(&w, TAG_PPU, section.items);

    const tm = &gb.timer;
    section.clearRetainingCapacity();
    try sw.u16v(tm.div_counter);
    try sw.u8v(tm.tima);
    try sw.u8v(tm.tma);
    try sw.u8v(tm.tac);
    try sw.boolv(tm.overflow_pending);
    try sw.u8v(tm.overflow_delay);
    try sw.u8v(@intCast(tm.last_and));
    try sw.boolv(tm.irq_request);
    try writeChunk(&w, TAG_TIM, section.items);

    section.clearRetainingCapacity();
    try writeApu(&sw, &gb.apu);
    try writeChunk(&w, TAG_APU, section.items);

    const cart = gb.cart;
    section.clearRetainingCapacity();
    try sw.u16v(cart.rom_bank);
    try sw.u8v(cart.ram_bank);
    try sw.boolv(cart.ram_enabled);
    try sw.u8v(cart.banking_mode);
    try sw.bytes(&cart.rtc_regs);
    try sw.bytes(&cart.rtc_latched);
    try sw.u8v(cart.rtc_select);
    try sw.u8v(cart.rtc_latch_prev);
    try sw.u32v(cart.rtc_cycle_accum);
    try sw.u32v(@intCast(cart.ram.len));
    try sw.bytes(cart.ram);
    try writeChunk(&w, TAG_CART, section.items);

    try writeChunk(&w, TAG_END, &.{});

    return try list.toOwnedSlice(alloc);
}

fn writeSquare(w: *Writer, sq: anytype) !void {
    try w.boolv(sq.enabled);
    try w.boolv(sq.dac_enabled);
    try w.u8v(sq.nrx0);
    try w.u8v(sq.nrx1);
    try w.u8v(sq.nrx2);
    try w.u8v(sq.nrx3);
    try w.u8v(sq.nrx4);
    try w.u32v(@bitCast(sq.timer));
    try w.u8v(sq.duty_pos);
    try w.u16v(sq.length);
    try w.u8v(sq.volume);
    try w.u8v(sq.env_period);
    try w.u8v(sq.env_timer);
    try w.boolv(sq.env_dir);
    try w.u8v(sq.sweep_period);
    try w.u8v(sq.sweep_timer);
    try w.u8v(sq.sweep_shift);
    try w.boolv(sq.sweep_neg);
    try w.boolv(sq.sweep_enabled);
    try w.u16v(sq.sweep_freq);
}

fn readSquare(r: *Reader, sq: anytype) !void {
    sq.enabled = try r.boolv();
    sq.dac_enabled = try r.boolv();
    sq.nrx0 = try r.u8v();
    sq.nrx1 = try r.u8v();
    sq.nrx2 = try r.u8v();
    sq.nrx3 = try r.u8v();
    sq.nrx4 = try r.u8v();
    sq.timer = @bitCast(try r.u32v());
    sq.duty_pos = try r.u8v();
    sq.length = try r.u16v();
    sq.volume = try r.u8v();
    sq.env_period = try r.u8v();
    sq.env_timer = try r.u8v();
    sq.env_dir = try r.boolv();
    sq.sweep_period = try r.u8v();
    sq.sweep_timer = try r.u8v();
    sq.sweep_shift = try r.u8v();
    sq.sweep_neg = try r.boolv();
    sq.sweep_enabled = try r.boolv();
    sq.sweep_freq = try r.u16v();
}

fn writeApu(w: *Writer, apu: anytype) !void {
    try w.boolv(apu.enabled);
    try w.u8v(apu.nr50);
    try w.u8v(apu.nr51);
    try w.u8v(apu.frame_seq);
    try w.u32v(apu.frame_timer);
    try writeSquare(w, &apu.sq1);
    try writeSquare(w, &apu.sq2);
    try w.boolv(apu.wave.enabled);
    try w.boolv(apu.wave.dac_enabled);
    try w.u8v(apu.wave.nr30);
    try w.u8v(apu.wave.nr31);
    try w.u8v(apu.wave.nr32);
    try w.u8v(apu.wave.nr33);
    try w.u8v(apu.wave.nr34);
    try w.u32v(@bitCast(apu.wave.timer));
    try w.u8v(apu.wave.pos);
    try w.u16v(apu.wave.length);
    try w.bytes(&apu.wave.pattern);
    try w.boolv(apu.noise.enabled);
    try w.boolv(apu.noise.dac_enabled);
    try w.u8v(apu.noise.nr41);
    try w.u8v(apu.noise.nr42);
    try w.u8v(apu.noise.nr43);
    try w.u8v(apu.noise.nr44);
    try w.u32v(@bitCast(apu.noise.timer));
    try w.u16v(apu.noise.lfsr);
    try w.u16v(apu.noise.length);
    try w.u8v(apu.noise.volume);
    try w.u8v(apu.noise.env_period);
    try w.u8v(apu.noise.env_timer);
    try w.boolv(apu.noise.env_dir);
}

fn readApu(r: *Reader, apu: anytype) !void {
    apu.enabled = try r.boolv();
    apu.nr50 = try r.u8v();
    apu.nr51 = try r.u8v();
    apu.frame_seq = try r.u8v();
    apu.frame_timer = try r.u32v();
    try readSquare(r, &apu.sq1);
    try readSquare(r, &apu.sq2);
    apu.wave.enabled = try r.boolv();
    apu.wave.dac_enabled = try r.boolv();
    apu.wave.nr30 = try r.u8v();
    apu.wave.nr31 = try r.u8v();
    apu.wave.nr32 = try r.u8v();
    apu.wave.nr33 = try r.u8v();
    apu.wave.nr34 = try r.u8v();
    apu.wave.timer = @bitCast(try r.u32v());
    apu.wave.pos = try r.u8v();
    apu.wave.length = try r.u16v();
    try r.bytes(&apu.wave.pattern);
    apu.noise.enabled = try r.boolv();
    apu.noise.dac_enabled = try r.boolv();
    apu.noise.nr41 = try r.u8v();
    apu.noise.nr42 = try r.u8v();
    apu.noise.nr43 = try r.u8v();
    apu.noise.nr44 = try r.u8v();
    apu.noise.timer = @bitCast(try r.u32v());
    apu.noise.lfsr = try r.u16v();
    apu.noise.length = try r.u16v();
    apu.noise.volume = try r.u8v();
    apu.noise.env_period = try r.u8v();
    apu.noise.env_timer = try r.u8v();
    apu.noise.env_dir = try r.boolv();
    apu.buffer_head = 0;
    apu.buffer_len = 0;
    apu.sample_timer = 0;
}

fn loadMeta(r: *Reader, gb: anytype) !void {
    const hash = try r.u32v();
    if (hash != std.hash.Crc32.hash(gb.cart.rom)) return error.WrongRom;
    _ = r.opt_bool();
}

fn loadCpu(r: *Reader, gb: anytype) !void {
    const cpu = &gb.cpu;
    cpu.a = try r.u8v();
    cpu.f = try r.u8v();
    cpu.b = try r.u8v();
    cpu.c = try r.u8v();
    cpu.d = try r.u8v();
    cpu.e = try r.u8v();
    cpu.h = try r.u8v();
    cpu.l = try r.u8v();
    cpu.sp = try r.u16v();
    cpu.pc = try r.u16v();
    cpu.ime = try r.boolv();
    cpu.ime_pending = try r.boolv();
    cpu.halted = try r.boolv();
    cpu.halt_bug = try r.boolv();
    cpu.stopped = try r.boolv();
    cpu.double_speed = try r.boolv();
}

fn loadMmu(r: *Reader, gb: anytype) !void {
    const mmu = &gb.mmu;
    try r.bytes(&mmu.wram);
    try r.bytes(&mmu.hram);
    mmu.ie = try r.u8v();
    mmu.if_reg = try r.u8v();
    mmu.svbk = try r.u8v();
    mmu.key1 = try r.u8v();
    mmu.oam_dma_active = try r.boolv();
    mmu.oam_dma_src = try r.u16v();
    mmu.oam_dma_pos = try r.u8v();
    mmu.oam_dma_cycles = try r.u32v();
    mmu.boot_off = try r.u8v();
    mmu.serial_data = try r.u8v();
    mmu.serial_ctrl = try r.u8v();
    mmu.serial_cycles = try r.u32v();
    mmu.rp = try r.u8v();
    mmu.gdma_pending_cycles = try r.u32v();
    if (r.opt_u16()) |v| mmu.last_hdma_ly = @bitCast(v);
}

fn loadJoy(r: *Reader, gb: anytype) !void {
    gb.joypad.buttons = try r.u8v();
    gb.joypad.select_dir = try r.boolv();
    gb.joypad.select_btn = try r.boolv();
    gb.joypad.irq_request = try r.boolv();
}

fn loadPpu(r: *Reader, gb: anytype) !void {
    const ppu = &gb.ppu;
    try r.bytes(&ppu.vram);
    try r.bytes(&ppu.oam);
    ppu.lcdc = try r.u8v();
    ppu.stat = try r.u8v();
    ppu.scy = try r.u8v();
    ppu.scx = try r.u8v();
    ppu.ly = try r.u8v();
    ppu.lyc = try r.u8v();
    ppu.bgp = try r.u8v();
    ppu.obp0 = try r.u8v();
    ppu.obp1 = try r.u8v();
    ppu.wy = try r.u8v();
    ppu.wx = try r.u8v();
    ppu.vbk = try r.u8v();
    ppu.bcps = try r.u8v();
    ppu.ocps = try r.u8v();
    try r.bytes(&ppu.bcpd);
    try r.bytes(&ppu.ocpd);
    ppu.opri = try r.u8v();
    ppu.hdma_src = try r.u16v();
    ppu.hdma_dst = try r.u16v();
    ppu.hdma_len = try r.u8v();
    ppu.hdma_active = try r.boolv();
    ppu.hdma_blocks_left = try r.u8v();
    ppu.cycles = try r.u32v();
    const mode_v = try r.u8v();
    ppu.mode = @enumFromInt(mode_v & 0x03);
    ppu.window_line = try r.u8v();
    ppu.mode3_duration = try r.u32v();
    ppu.irq_vblank = try r.boolv();
    ppu.irq_stat = try r.boolv();
    if (r.opt_bool()) |v| ppu.stat_line = v;
    ppu.draw_x = 0;
    ppu.frame_sprite_count = 0;
    ppu.window_line_used_on_line = false;
}

fn loadTim(r: *Reader, gb: anytype) !void {
    const tm = &gb.timer;
    tm.div_counter = try r.u16v();
    tm.tima = try r.u8v();
    tm.tma = try r.u8v();
    tm.tac = try r.u8v();
    tm.overflow_pending = try r.boolv();
    tm.overflow_delay = try r.u8v();
    tm.last_and = @intCast((try r.u8v()) & 1);
    if (r.opt_bool()) |v| tm.irq_request = v;
}

fn loadCart(r: *Reader, gb: anytype) !void {
    const cart = gb.cart;
    cart.rom_bank = try r.u16v();
    cart.ram_bank = try r.u8v();
    cart.ram_enabled = try r.boolv();
    cart.banking_mode = try r.u8v();
    try r.bytes(&cart.rtc_regs);
    try r.bytes(&cart.rtc_latched);
    cart.rtc_select = try r.u8v();
    cart.rtc_latch_prev = try r.u8v();
    cart.rtc_cycle_accum = try r.u32v();
    const ram_len = try r.u32v();
    if (ram_len == cart.ram.len) {
        try r.bytes(cart.ram);
    } else {
        try r.skip(ram_len);
    }
}

pub fn load(data: []const u8, gb: anytype) !void {
    if (data.len < 8) return error.Truncated;
    var head: Reader = .{ .buf = data, .end = data.len };

    if ((try head.u32v()) != MAGIC) return error.BadMagic;
    const version = try head.u32v();
    if (version != VERSION) return error.WrongVersion;

    while (head.pos < head.end) {
        if (head.pos + 8 > head.end) return error.Truncated;
        var tag: [4]u8 = undefined;
        try head.bytes(&tag);
        const len = try head.u32v();
        if (head.pos + len > head.end) return error.Truncated;
        const chunk_end = head.pos + len;
        var r: Reader = .{ .buf = data, .pos = head.pos, .end = chunk_end };

        if (std.mem.eql(u8, &tag, &TAG_END)) {
            head.pos = chunk_end;
            break;
        } else if (std.mem.eql(u8, &tag, &TAG_META)) {
            try loadMeta(&r, gb);
        } else if (std.mem.eql(u8, &tag, &TAG_CPU)) {
            try loadCpu(&r, gb);
        } else if (std.mem.eql(u8, &tag, &TAG_MMU)) {
            try loadMmu(&r, gb);
        } else if (std.mem.eql(u8, &tag, &TAG_JOY)) {
            try loadJoy(&r, gb);
        } else if (std.mem.eql(u8, &tag, &TAG_PPU)) {
            try loadPpu(&r, gb);
        } else if (std.mem.eql(u8, &tag, &TAG_TIM)) {
            try loadTim(&r, gb);
        } else if (std.mem.eql(u8, &tag, &TAG_APU)) {
            try readApu(&r, &gb.apu);
        } else if (std.mem.eql(u8, &tag, &TAG_CART)) {
            try loadCart(&r, gb);
        }
        head.pos = chunk_end;
    }
}
