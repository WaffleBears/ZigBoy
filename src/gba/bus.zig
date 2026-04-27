const std = @import("std");
const Cart = @import("cart.zig").Cart;
const Ppu = @import("ppu.zig").Ppu;
const Apu = @import("apu.zig").Apu;
const Dma = @import("dma.zig").Dma;
const Timers = @import("timer.zig").Timers;
const Irq = @import("irq.zig").Irq;

pub const Bus = struct {
    bios: [0x4000]u8 = .{0} ** 0x4000,
    ewram: [0x40000]u8 = .{0} ** 0x40000,
    iwram: [0x8000]u8 = .{0} ** 0x8000,
    cart: *Cart,
    ppu: *Ppu,
    apu: *Apu,
    dma: *Dma,
    timers: *Timers,
    irq: *Irq,
    keyinput: u16 = 0x03FF,
    keycnt: u16 = 0,
    waitcnt: u16 = 0,
    postflg: u8 = 0,
    haltcnt: u8 = 0,
    halted: bool = false,
    open_bus: u32 = 0,
    bios_open_bus: u32 = 0xE129F000,
    access_cycles: u32 = 0,
    last_access_addr: u32 = 0xFFFFFFFF,
    last_access_bytes: u32 = 0,
    cost_n: [16][2]u32 = .{.{ 1, 1 }} ** 16,
    cost_s: [16][2]u32 = .{.{ 1, 1 }} ** 16,

    pub fn init(cart: *Cart, ppu: *Ppu, apu: *Apu, dma: *Dma, timers: *Timers, irq: *Irq) Bus {
        var bus: Bus = .{
            .cart = cart,
            .ppu = ppu,
            .apu = apu,
            .dma = dma,
            .timers = timers,
            .irq = irq,
        };
        installBiosStub(&bus);
        bus.refreshAccessCosts();
        return bus;
    }

    pub fn refreshAccessCosts(self: *Bus) void {
        var region: usize = 0;
        while (region < 16) : (region += 1) {
            inline for (.{ 0, 1 }) |is_word_idx| {
                const is_word = is_word_idx != 0;
                const half_count: u32 = if (is_word) 2 else 1;
                const n_cost: u32 = switch (region) {
                    0x0, 0x3, 0x4, 0x7 => 1,
                    0x2 => if (is_word) 6 else 3,
                    0x5, 0x6 => if (is_word) 2 else 1,
                    0x8, 0x9 => blk: {
                        const n = self.waitN(0);
                        const s = self.waitS(0);
                        break :blk n + (half_count - 1) * s;
                    },
                    0xA, 0xB => blk: {
                        const n = self.waitN(1);
                        const s = self.waitS(1);
                        break :blk n + (half_count - 1) * s;
                    },
                    0xC, 0xD => blk: {
                        const n = self.waitN(2);
                        const s = self.waitS(2);
                        break :blk n + (half_count - 1) * s;
                    },
                    0xE, 0xF => self.waitSram(),
                    else => 1,
                };
                const s_cost: u32 = switch (region) {
                    0x0, 0x3, 0x4, 0x7 => 1,
                    0x2 => if (is_word) 6 else 3,
                    0x5, 0x6 => if (is_word) 2 else 1,
                    0x8, 0x9 => half_count * self.waitS(0),
                    0xA, 0xB => half_count * self.waitS(1),
                    0xC, 0xD => half_count * self.waitS(2),
                    0xE, 0xF => self.waitSram(),
                    else => 1,
                };
                self.cost_n[region][is_word_idx] = n_cost;
                self.cost_s[region][is_word_idx] = s_cost;
            }
        }
    }

    fn installBiosStub(bus: *Bus) void {
        const stub = [_]u32{
            0xe92d500f,
            0xe3a00301,
            0xe28fe000,
            0xe510f004,
            0xe8bd500f,
            0xe25ef004,
        };
        var i: usize = 0;
        while (i < stub.len) : (i += 1) {
            const off: usize = 0x18 + i * 4;
            std.mem.writeInt(u32, bus.bios[off..][0..4], stub[i], .little);
        }
        std.mem.writeInt(u32, bus.bios[0x00..][0..4], 0xea00002e, .little);
    }

    pub fn drainAccessCycles(self: *Bus) u32 {
        const c = self.access_cycles;
        self.access_cycles = 0;
        return c;
    }

    fn waitN(self: *Bus, ws: u32) u32 {
        const code: u32 = switch (ws) {
            0 => (self.waitcnt >> 2) & 0x3,
            1 => (self.waitcnt >> 5) & 0x3,
            2 => (self.waitcnt >> 8) & 0x3,
            else => 0,
        };
        return switch (code) {
            0 => 4,
            1 => 3,
            2 => 2,
            3 => 8,
            else => 4,
        };
    }

    fn waitS(self: *Bus, ws: u32) u32 {
        const bit: u32 = switch (ws) {
            0 => (self.waitcnt >> 4) & 0x1,
            1 => (self.waitcnt >> 7) & 0x1,
            2 => (self.waitcnt >> 10) & 0x1,
            else => 0,
        };
        return switch (ws) {
            0 => if (bit != 0) 1 else 2,
            1 => if (bit != 0) 1 else 4,
            2 => if (bit != 0) 1 else 8,
            else => 1,
        };
    }

    fn waitSram(self: *Bus) u32 {
        const code = self.waitcnt & 0x3;
        return switch (code) {
            0 => 4,
            1 => 3,
            2 => 2,
            3 => 8,
            else => 4,
        };
    }

    fn accessCost(self: *Bus, addr: u32, bytes: u32) u32 {
        const region = (addr >> 24) & 0x0F;
        const is_word_idx: usize = if (bytes >= 4) 1 else 0;
        const expected = self.last_access_addr +% self.last_access_bytes;
        const sequential = (addr & ~@as(u32, 3)) == (expected & ~@as(u32, 3));
        return if (sequential) self.cost_s[region][is_word_idx] else self.cost_n[region][is_word_idx];
    }

    fn note(self: *Bus, addr: u32, bytes: u32) void {
        self.access_cycles +%= self.accessCost(addr, bytes);
        self.last_access_addr = addr;
        self.last_access_bytes = bytes;
    }

    pub fn read8(self: *Bus, addr: u32) u8 {
        self.note(addr, 1);
        const region = (addr >> 24) & 0x0F;
        return switch (region) {
            0x0 => if (addr < 0x4000) self.bios[addr] else @truncate(self.bios_open_bus),
            0x2 => self.ewram[addr & 0x3FFFF],
            0x3 => self.iwram[addr & 0x7FFF],
            0x4 => self.readIo8(@intCast(addr & 0xFFFFFF)),
            0x5 => self.ppu.pram[addr & 0x3FF],
            0x6 => blk: {
                var off: u32 = addr & 0x1FFFF;
                if (off >= 0x18000) off -= 0x8000;
                break :blk self.ppu.vram[off];
            },
            0x7 => self.ppu.oam[addr & 0x3FF],
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => self.cart.romRead8(addr),
            0xE, 0xF => self.cart.sramRead8(addr),
            else => 0,
        };
    }

    pub fn read16(self: *Bus, addr: u32) u16 {
        const a = addr & ~@as(u32, 1);
        self.note(a, 2);
        const region = (a >> 24) & 0x0F;
        return switch (region) {
            0x0 => if (a < 0x4000) std.mem.readInt(u16, self.bios[a..][0..2], .little) else @truncate(self.bios_open_bus),
            0x2 => std.mem.readInt(u16, self.ewram[(a & 0x3FFFF)..][0..2], .little),
            0x3 => std.mem.readInt(u16, self.iwram[(a & 0x7FFF)..][0..2], .little),
            0x4 => self.readIo16(@intCast(a & 0xFFFFFF)),
            0x5 => std.mem.readInt(u16, self.ppu.pram[(a & 0x3FF)..][0..2], .little),
            0x6 => blk: {
                var off: u32 = a & 0x1FFFF;
                if (off >= 0x18000) off -= 0x8000;
                break :blk std.mem.readInt(u16, self.ppu.vram[off..][0..2], .little);
            },
            0x7 => std.mem.readInt(u16, self.ppu.oam[(a & 0x3FF)..][0..2], .little),
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => self.cart.romRead16(a),
            0xE, 0xF => blk: {
                const v = self.cart.sramRead8(a);
                break :blk @as(u16, v) | (@as(u16, v) << 8);
            },
            else => 0,
        };
    }

    pub fn read32(self: *Bus, addr: u32) u32 {
        const a = addr & ~@as(u32, 3);
        self.note(a, 4);
        const region = (a >> 24) & 0x0F;
        return switch (region) {
            0x0 => if (a < 0x4000) std.mem.readInt(u32, self.bios[a..][0..4], .little) else self.bios_open_bus,
            0x2 => std.mem.readInt(u32, self.ewram[(a & 0x3FFFF)..][0..4], .little),
            0x3 => std.mem.readInt(u32, self.iwram[(a & 0x7FFF)..][0..4], .little),
            0x4 => blk: {
                const lo: u32 = self.readIo16(@intCast(a & 0xFFFFFF));
                const hi: u32 = self.readIo16(@intCast((a +% 2) & 0xFFFFFF));
                break :blk lo | (hi << 16);
            },
            0x5 => std.mem.readInt(u32, self.ppu.pram[(a & 0x3FF)..][0..4], .little),
            0x6 => blk: {
                var off: u32 = a & 0x1FFFF;
                if (off >= 0x18000) off -= 0x8000;
                break :blk std.mem.readInt(u32, self.ppu.vram[off..][0..4], .little);
            },
            0x7 => std.mem.readInt(u32, self.ppu.oam[(a & 0x3FF)..][0..4], .little),
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => self.cart.romRead32(a),
            0xE, 0xF => blk: {
                const v = self.cart.sramRead8(a);
                const w: u32 = @as(u32, v) | (@as(u32, v) << 8) | (@as(u32, v) << 16) | (@as(u32, v) << 24);
                break :blk w;
            },
            else => 0,
        };
    }

    pub fn write8(self: *Bus, addr: u32, v: u8) void {
        self.note(addr, 1);
        const region = (addr >> 24) & 0x0F;
        switch (region) {
            0x2 => self.ewram[addr & 0x3FFFF] = v,
            0x3 => self.iwram[addr & 0x7FFF] = v,
            0x4 => self.writeIo8(@intCast(addr & 0xFFFFFF), v),
            0x5 => {
                const off = addr & 0x3FE;
                self.ppu.pram[off] = v;
                self.ppu.pram[off + 1] = v;
            },
            0x6 => {
                var off: u32 = addr & 0x1FFFF;
                if (off >= 0x18000) off -%= 0x8000;
                const mode: u3 = @truncate(self.ppu.dispcnt & 0x07);
                const obj_threshold: u32 = if (mode >= 3) 0x14000 else 0x10000;
                if (off >= obj_threshold) return;
                const a = off & ~@as(u32, 1);
                self.ppu.vram[a] = v;
                self.ppu.vram[a + 1] = v;
            },
            0x7 => {},
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => self.cart.romWrite8(addr, v),
            0xE, 0xF => self.cart.sramWrite8(addr, v),
            else => {},
        }
    }

    pub fn write16(self: *Bus, addr: u32, v: u16) void {
        const a = addr & ~@as(u32, 1);
        self.note(a, 2);
        const region = (a >> 24) & 0x0F;
        switch (region) {
            0x2 => std.mem.writeInt(u16, self.ewram[(a & 0x3FFFF)..][0..2], v, .little),
            0x3 => std.mem.writeInt(u16, self.iwram[(a & 0x7FFF)..][0..2], v, .little),
            0x4 => self.writeIo16(@intCast(a & 0xFFFFFF), v),
            0x5 => std.mem.writeInt(u16, self.ppu.pram[(a & 0x3FF)..][0..2], v, .little),
            0x6 => {
                var off: u32 = a & 0x1FFFF;
                if (off >= 0x18000) off -= 0x8000;
                std.mem.writeInt(u16, self.ppu.vram[off..][0..2], v, .little);
            },
            0x7 => std.mem.writeInt(u16, self.ppu.oam[(a & 0x3FF)..][0..2], v, .little),
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => self.cart.romWrite16(a, v),
            0xE, 0xF => {
                const rot: u4 = @intCast((addr & 1) * 8);
                const rotated: u8 = @truncate(std.math.rotr(u16, v, rot));
                self.cart.sramWrite8(addr, rotated);
            },
            else => {},
        }
    }

    pub fn write32(self: *Bus, addr: u32, v: u32) void {
        const a = addr & ~@as(u32, 3);
        self.note(a, 4);
        const region = (a >> 24) & 0x0F;
        switch (region) {
            0x2 => std.mem.writeInt(u32, self.ewram[(a & 0x3FFFF)..][0..4], v, .little),
            0x3 => std.mem.writeInt(u32, self.iwram[(a & 0x7FFF)..][0..4], v, .little),
            0x4 => {
                self.writeIo16(@intCast(a & 0xFFFFFF), @truncate(v));
                self.writeIo16(@intCast((a +% 2) & 0xFFFFFF), @truncate(v >> 16));
            },
            0x5 => std.mem.writeInt(u32, self.ppu.pram[(a & 0x3FF)..][0..4], v, .little),
            0x6 => {
                var off: u32 = a & 0x1FFFF;
                if (off >= 0x18000) off -= 0x8000;
                std.mem.writeInt(u32, self.ppu.vram[off..][0..4], v, .little);
            },
            0x7 => std.mem.writeInt(u32, self.ppu.oam[(a & 0x3FF)..][0..4], v, .little),
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => self.cart.romWrite32(a, v),
            0xE, 0xF => {
                const rot: u5 = @intCast((addr & 3) * 8);
                const rotated: u8 = @truncate(std.math.rotr(u32, v, rot));
                self.cart.sramWrite8(addr, rotated);
            },
            else => {},
        }
    }

    fn readIo8(self: *Bus, addr: u32) u8 {
        const v = self.readIo16(addr & ~@as(u32, 1));
        return if ((addr & 1) != 0) @truncate(v >> 8) else @truncate(v);
    }

    fn writeIo8(self: *Bus, addr: u32, val: u8) void {
        if (addr == 0x300) {
            self.postflg = val;
            return;
        }
        if (addr == 0x301) {
            self.haltcnt = val;
            self.halted = true;
            return;
        }
        const a = addr & ~@as(u32, 1);
        const cur = self.readIo16(a);
        const new: u16 = if ((addr & 1) != 0) (cur & 0x00FF) | (@as(u16, val) << 8) else (cur & 0xFF00) | val;
        self.writeIo16(a, new);
    }

    pub fn readIo16(self: *Bus, addr: u32) u16 {
        return switch (addr) {
            0x000 => self.ppu.dispcnt,
            0x002 => self.ppu.greenswap,
            0x004 => self.ppu.dispstat,
            0x006 => self.ppu.vcount,
            0x008 => self.ppu.bgcnt[0],
            0x00A => self.ppu.bgcnt[1],
            0x00C => self.ppu.bgcnt[2],
            0x00E => self.ppu.bgcnt[3],
            0x048 => self.ppu.winin,
            0x04A => self.ppu.winout,
            0x050 => self.ppu.bldcnt,
            0x052 => self.ppu.bldalpha,
            0x060...0x0AE => self.apu.read16(@intCast(addr - 0x60)),
            0x0B0 => @truncate(self.dma.ch[0].sad & 0xFFFF),
            0x0B2 => @truncate((self.dma.ch[0].sad >> 16) & 0xFFFF),
            0x0B4 => @truncate(self.dma.ch[0].dad & 0xFFFF),
            0x0B6 => @truncate((self.dma.ch[0].dad >> 16) & 0xFFFF),
            0x0B8 => 0,
            0x0BA => self.dma.ch[0].cnt_h,
            0x0BC => @truncate(self.dma.ch[1].sad & 0xFFFF),
            0x0BE => @truncate((self.dma.ch[1].sad >> 16) & 0xFFFF),
            0x0C0 => @truncate(self.dma.ch[1].dad & 0xFFFF),
            0x0C2 => @truncate((self.dma.ch[1].dad >> 16) & 0xFFFF),
            0x0C4 => 0,
            0x0C6 => self.dma.ch[1].cnt_h,
            0x0C8 => @truncate(self.dma.ch[2].sad & 0xFFFF),
            0x0CA => @truncate((self.dma.ch[2].sad >> 16) & 0xFFFF),
            0x0CC => @truncate(self.dma.ch[2].dad & 0xFFFF),
            0x0CE => @truncate((self.dma.ch[2].dad >> 16) & 0xFFFF),
            0x0D0 => 0,
            0x0D2 => self.dma.ch[2].cnt_h,
            0x0D4 => @truncate(self.dma.ch[3].sad & 0xFFFF),
            0x0D6 => @truncate((self.dma.ch[3].sad >> 16) & 0xFFFF),
            0x0D8 => @truncate(self.dma.ch[3].dad & 0xFFFF),
            0x0DA => @truncate((self.dma.ch[3].dad >> 16) & 0xFFFF),
            0x0DC => 0,
            0x0DE => self.dma.ch[3].cnt_h,
            0x100 => self.timers.read16(0),
            0x102 => self.timers.readCnt(0),
            0x104 => self.timers.read16(1),
            0x106 => self.timers.readCnt(1),
            0x108 => self.timers.read16(2),
            0x10A => self.timers.readCnt(2),
            0x10C => self.timers.read16(3),
            0x10E => self.timers.readCnt(3),
            0x130 => self.keyinput,
            0x132 => self.keycnt,
            0x200 => self.irq.ie,
            0x202 => self.irq.ifr,
            0x204 => self.waitcnt,
            0x208 => @intFromBool(self.irq.ime),
            0x300 => self.postflg,
            else => 0,
        };
    }

    pub fn writeIo16(self: *Bus, addr: u32, v: u16) void {
        switch (addr) {
            0x000 => self.ppu.dispcnt = v,
            0x002 => self.ppu.greenswap = v,
            0x004 => self.ppu.writeDispstat(v),
            0x008 => self.ppu.bgcnt[0] = v,
            0x00A => self.ppu.bgcnt[1] = v,
            0x00C => self.ppu.bgcnt[2] = v,
            0x00E => self.ppu.bgcnt[3] = v,
            0x010 => self.ppu.bghofs[0] = v & 0x1FF,
            0x012 => self.ppu.bgvofs[0] = v & 0x1FF,
            0x014 => self.ppu.bghofs[1] = v & 0x1FF,
            0x016 => self.ppu.bgvofs[1] = v & 0x1FF,
            0x018 => self.ppu.bghofs[2] = v & 0x1FF,
            0x01A => self.ppu.bgvofs[2] = v & 0x1FF,
            0x01C => self.ppu.bghofs[3] = v & 0x1FF,
            0x01E => self.ppu.bgvofs[3] = v & 0x1FF,
            0x020 => self.ppu.bgpa[0] = @bitCast(v),
            0x022 => self.ppu.bgpb[0] = @bitCast(v),
            0x024 => self.ppu.bgpc[0] = @bitCast(v),
            0x026 => self.ppu.bgpd[0] = @bitCast(v),
            0x028 => self.ppu.writeBgX(0, false, v),
            0x02A => self.ppu.writeBgX(0, true, v),
            0x02C => self.ppu.writeBgY(0, false, v),
            0x02E => self.ppu.writeBgY(0, true, v),
            0x030 => self.ppu.bgpa[1] = @bitCast(v),
            0x032 => self.ppu.bgpb[1] = @bitCast(v),
            0x034 => self.ppu.bgpc[1] = @bitCast(v),
            0x036 => self.ppu.bgpd[1] = @bitCast(v),
            0x038 => self.ppu.writeBgX(1, false, v),
            0x03A => self.ppu.writeBgX(1, true, v),
            0x03C => self.ppu.writeBgY(1, false, v),
            0x03E => self.ppu.writeBgY(1, true, v),
            0x040 => self.ppu.win_h[0] = v,
            0x042 => self.ppu.win_h[1] = v,
            0x044 => self.ppu.win_v[0] = v,
            0x046 => self.ppu.win_v[1] = v,
            0x048 => self.ppu.winin = v,
            0x04A => self.ppu.winout = v,
            0x04C => self.ppu.mosaic = v,
            0x050 => self.ppu.bldcnt = v,
            0x052 => self.ppu.bldalpha = v,
            0x054 => self.ppu.bldy = v & 0x1F,
            0x060...0x0AE => self.apu.write16(@intCast(addr - 0x60), v),
            0x0B0 => self.dma.ch[0].sad = (self.dma.ch[0].sad & 0xFFFF0000) | v,
            0x0B2 => self.dma.ch[0].sad = (self.dma.ch[0].sad & 0xFFFF) | (@as(u32, v & 0x07FF) << 16),
            0x0B4 => self.dma.ch[0].dad = (self.dma.ch[0].dad & 0xFFFF0000) | v,
            0x0B6 => self.dma.ch[0].dad = (self.dma.ch[0].dad & 0xFFFF) | (@as(u32, v & 0x07FF) << 16),
            0x0B8 => self.dma.ch[0].cnt_l = v,
            0x0BA => self.dma.pending_cycles +%= self.dma.writeCnt(0, v),
            0x0BC => self.dma.ch[1].sad = (self.dma.ch[1].sad & 0xFFFF0000) | v,
            0x0BE => self.dma.ch[1].sad = (self.dma.ch[1].sad & 0xFFFF) | (@as(u32, v & 0x0FFF) << 16),
            0x0C0 => self.dma.ch[1].dad = (self.dma.ch[1].dad & 0xFFFF0000) | v,
            0x0C2 => self.dma.ch[1].dad = (self.dma.ch[1].dad & 0xFFFF) | (@as(u32, v & 0x07FF) << 16),
            0x0C4 => self.dma.ch[1].cnt_l = v,
            0x0C6 => self.dma.pending_cycles +%= self.dma.writeCnt(1, v),
            0x0C8 => self.dma.ch[2].sad = (self.dma.ch[2].sad & 0xFFFF0000) | v,
            0x0CA => self.dma.ch[2].sad = (self.dma.ch[2].sad & 0xFFFF) | (@as(u32, v & 0x0FFF) << 16),
            0x0CC => self.dma.ch[2].dad = (self.dma.ch[2].dad & 0xFFFF0000) | v,
            0x0CE => self.dma.ch[2].dad = (self.dma.ch[2].dad & 0xFFFF) | (@as(u32, v & 0x07FF) << 16),
            0x0D0 => self.dma.ch[2].cnt_l = v,
            0x0D2 => self.dma.pending_cycles +%= self.dma.writeCnt(2, v),
            0x0D4 => self.dma.ch[3].sad = (self.dma.ch[3].sad & 0xFFFF0000) | v,
            0x0D6 => self.dma.ch[3].sad = (self.dma.ch[3].sad & 0xFFFF) | (@as(u32, v & 0x0FFF) << 16),
            0x0D8 => self.dma.ch[3].dad = (self.dma.ch[3].dad & 0xFFFF0000) | v,
            0x0DA => self.dma.ch[3].dad = (self.dma.ch[3].dad & 0xFFFF) | (@as(u32, v & 0x0FFF) << 16),
            0x0DC => self.dma.ch[3].cnt_l = v,
            0x0DE => self.dma.pending_cycles +%= self.dma.writeCnt(3, v),
            0x100 => self.timers.write16(0, v),
            0x102 => self.timers.writeCnt(0, v),
            0x104 => self.timers.write16(1, v),
            0x106 => self.timers.writeCnt(1, v),
            0x108 => self.timers.write16(2, v),
            0x10A => self.timers.writeCnt(2, v),
            0x10C => self.timers.write16(3, v),
            0x10E => self.timers.writeCnt(3, v),
            0x132 => self.keycnt = v,
            0x200 => self.irq.ie = v & 0x3FFF,
            0x202 => self.irq.ifr &= ~v,
            0x204 => {
                self.waitcnt = v;
                self.refreshAccessCosts();
            },
            0x208 => self.irq.ime = (v & 1) != 0,
            0x300 => {
                self.postflg = @truncate(v);
                self.haltcnt = @truncate(v >> 8);
                self.halted = true;
            },
            else => {},
        }
    }

    pub fn pollKeyIrq(self: *Bus) void {
        if ((self.keycnt & 0x4000) == 0) return;
        const mask = self.keycnt & 0x3FF;
        const pressed = (~self.keyinput) & 0x3FF;
        const all = (self.keycnt & 0x8000) != 0;
        const fire = if (all) (pressed & mask) == mask else (pressed & mask) != 0;
        if (fire) self.irq.request(12);
    }
};
