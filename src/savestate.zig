const std = @import("std");

const MAGIC: u32 = 0x47424353;
const VERSION: u32 = 2;

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

    pub fn u8v(self: *Reader) !u8 {
        if (self.pos >= self.buf.len) return error.Truncated;
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
        if (self.pos + dst.len > self.buf.len) return error.Truncated;
        @memcpy(dst, self.buf[self.pos .. self.pos + dst.len]);
        self.pos += dst.len;
    }
    pub fn boolv(self: *Reader) !bool {
        return (try self.u8v()) != 0;
    }
    pub fn skip(self: *Reader, n: usize) !void {
        if (self.pos + n > self.buf.len) return error.Truncated;
        self.pos += n;
    }
};

pub fn save(alloc: std.mem.Allocator, gb: anytype) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var w: Writer = .{ .list = &list, .alloc = alloc };

    try w.u32v(MAGIC);
    try w.u32v(VERSION);
    try w.u32v(std.hash.Crc32.hash(gb.cart.rom));
    try w.boolv(gb.cgb_mode);

    const cpu = &gb.cpu;
    try w.u8v(cpu.a);
    try w.u8v(cpu.f);
    try w.u8v(cpu.b);
    try w.u8v(cpu.c);
    try w.u8v(cpu.d);
    try w.u8v(cpu.e);
    try w.u8v(cpu.h);
    try w.u8v(cpu.l);
    try w.u16v(cpu.sp);
    try w.u16v(cpu.pc);
    try w.boolv(cpu.ime);
    try w.boolv(cpu.ime_pending);
    try w.boolv(cpu.halted);
    try w.boolv(cpu.double_speed);

    const mmu = &gb.mmu;
    try w.bytes(&mmu.wram);
    try w.bytes(&mmu.hram);
    try w.u8v(mmu.ie);
    try w.u8v(mmu.if_reg);
    try w.u8v(mmu.svbk);
    try w.u8v(mmu.key1);
    try w.boolv(mmu.oam_dma_active);
    try w.u16v(mmu.oam_dma_src);
    try w.u8v(mmu.oam_dma_pos);
    try w.u32v(mmu.oam_dma_cycles);

    const ppu = &gb.ppu;
    try w.bytes(&ppu.vram);
    try w.bytes(&ppu.oam);
    try w.u8v(ppu.lcdc);
    try w.u8v(ppu.stat);
    try w.u8v(ppu.scy);
    try w.u8v(ppu.scx);
    try w.u8v(ppu.ly);
    try w.u8v(ppu.lyc);
    try w.u8v(ppu.bgp);
    try w.u8v(ppu.obp0);
    try w.u8v(ppu.obp1);
    try w.u8v(ppu.wy);
    try w.u8v(ppu.wx);
    try w.u8v(ppu.vbk);
    try w.u8v(ppu.bcps);
    try w.u8v(ppu.ocps);
    try w.bytes(&ppu.bcpd);
    try w.bytes(&ppu.ocpd);
    try w.u8v(ppu.opri);
    try w.u16v(ppu.hdma_src);
    try w.u16v(ppu.hdma_dst);
    try w.u8v(ppu.hdma_len);
    try w.boolv(ppu.hdma_active);
    try w.u8v(ppu.hdma_blocks_left);
    try w.u32v(ppu.cycles);
    try w.u8v(@intFromEnum(ppu.mode));
    try w.u8v(ppu.window_line);

    const tm = &gb.timer;
    try w.u16v(tm.div_counter);
    try w.u8v(tm.tima);
    try w.u8v(tm.tma);
    try w.u8v(tm.tac);
    try w.boolv(tm.overflow_pending);
    try w.u8v(tm.overflow_delay);
    try w.u8v(@intCast(tm.last_and));

    try writeApu(&w, &gb.apu);

    try w.boolv(ppu.stat_line);
    try w.u16v(@bitCast(gb.mmu.last_hdma_ly));

    const cart = gb.cart;
    try w.u16v(cart.rom_bank);
    try w.u8v(cart.ram_bank);
    try w.boolv(cart.ram_enabled);
    try w.u8v(cart.banking_mode);
    try w.bytes(&cart.rtc_regs);
    try w.bytes(&cart.rtc_latched);
    try w.u8v(cart.rtc_select);
    try w.u8v(cart.rtc_latch_prev);
    try w.u32v(@intCast(cart.ram.len));
    try w.bytes(cart.ram);

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
    apu.buffer_len = 0;
    apu.sample_timer = 0;
}

pub fn load(data: []const u8, gb: anytype) !void {
    var r: Reader = .{ .buf = data };

    if ((try r.u32v()) != MAGIC) return error.BadMagic;
    if ((try r.u32v()) != VERSION) return error.WrongVersion;
    if ((try r.u32v()) != std.hash.Crc32.hash(gb.cart.rom)) return error.WrongRom;
    _ = try r.boolv();

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
    cpu.double_speed = try r.boolv();

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

    const tm = &gb.timer;
    tm.div_counter = try r.u16v();
    tm.tima = try r.u8v();
    tm.tma = try r.u8v();
    tm.tac = try r.u8v();
    tm.overflow_pending = try r.boolv();
    tm.overflow_delay = try r.u8v();
    tm.last_and = @intCast((try r.u8v()) & 1);

    try readApu(&r, &gb.apu);

    ppu.stat_line = try r.boolv();
    gb.mmu.last_hdma_ly = @bitCast(try r.u16v());

    const cart = gb.cart;
    cart.rom_bank = try r.u16v();
    cart.ram_bank = try r.u8v();
    cart.ram_enabled = try r.boolv();
    cart.banking_mode = try r.u8v();
    try r.bytes(&cart.rtc_regs);
    try r.bytes(&cart.rtc_latched);
    cart.rtc_select = try r.u8v();
    cart.rtc_latch_prev = try r.u8v();
    const ram_len = try r.u32v();
    if (ram_len == cart.ram.len) {
        try r.bytes(cart.ram);
    } else {
        try r.skip(ram_len);
    }
}
