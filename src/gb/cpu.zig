const Mmu = @import("mmu.zig").Mmu;

pub const Cpu = struct {
    a: u8 = 0,
    f: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,
    sp: u16 = 0,
    pc: u16 = 0,

    ime: bool = false,
    ime_pending: bool = false,
    halted: bool = false,
    stopped: bool = false,
    halt_bug: bool = false,
    double_speed: bool = false,

    mmu: *Mmu,

    pub fn init(mmu: *Mmu) Cpu {
        return .{ .mmu = mmu };
    }

    pub fn resetPostBoot(self: *Cpu, cgb: bool) void {
        if (cgb) {
            self.a = 0x11;
            self.f = 0x80;
            self.b = 0x00;
            self.c = 0x00;
            self.d = 0xFF;
            self.e = 0x56;
            self.h = 0x00;
            self.l = 0x0D;
        } else {
            self.a = 0x01;
            self.f = 0xB0;
            self.b = 0x00;
            self.c = 0x13;
            self.d = 0x00;
            self.e = 0xD8;
            self.h = 0x01;
            self.l = 0x4D;
        }
        self.sp = 0xFFFE;
        self.pc = 0x0100;
        self.ime = false;
        self.ime_pending = false;
        self.halted = false;
        self.stopped = false;
        self.halt_bug = false;
        self.double_speed = false;
    }

    inline fn af(self: *const Cpu) u16 {
        return (@as(u16, self.a) << 8) | self.f;
    }
    inline fn setAf(self: *Cpu, v: u16) void {
        self.a = @intCast(v >> 8);
        self.f = @as(u8, @intCast(v & 0xFF)) & 0xF0;
    }
    inline fn bc(self: *const Cpu) u16 {
        return (@as(u16, self.b) << 8) | self.c;
    }
    inline fn setBc(self: *Cpu, v: u16) void {
        self.b = @intCast(v >> 8);
        self.c = @intCast(v & 0xFF);
    }
    inline fn de(self: *const Cpu) u16 {
        return (@as(u16, self.d) << 8) | self.e;
    }
    inline fn setDe(self: *Cpu, v: u16) void {
        self.d = @intCast(v >> 8);
        self.e = @intCast(v & 0xFF);
    }
    inline fn hl(self: *const Cpu) u16 {
        return (@as(u16, self.h) << 8) | self.l;
    }
    inline fn setHl(self: *Cpu, v: u16) void {
        self.h = @intCast(v >> 8);
        self.l = @intCast(v & 0xFF);
    }

    inline fn flagZ(self: *const Cpu) bool {
        return (self.f & 0x80) != 0;
    }
    inline fn flagN(self: *const Cpu) bool {
        return (self.f & 0x40) != 0;
    }
    inline fn flagH(self: *const Cpu) bool {
        return (self.f & 0x20) != 0;
    }
    inline fn flagC(self: *const Cpu) bool {
        return (self.f & 0x10) != 0;
    }
    inline fn setFlags(self: *Cpu, z: bool, n: bool, h: bool, c: bool) void {
        var f: u8 = 0;
        if (z) f |= 0x80;
        if (n) f |= 0x40;
        if (h) f |= 0x20;
        if (c) f |= 0x10;
        self.f = f;
    }
    inline fn setZ(self: *Cpu, v: bool) void {
        if (v) self.f |= 0x80 else self.f &= 0x7F;
    }
    inline fn setN(self: *Cpu, v: bool) void {
        if (v) self.f |= 0x40 else self.f &= 0xBF;
    }
    inline fn setH(self: *Cpu, v: bool) void {
        if (v) self.f |= 0x20 else self.f &= 0xDF;
    }
    inline fn setC(self: *Cpu, v: bool) void {
        if (v) self.f |= 0x10 else self.f &= 0xEF;
    }

    fn read8(self: *Cpu, addr: u16) u8 {
        return self.mmu.read(addr);
    }
    fn write8(self: *Cpu, addr: u16, v: u8) void {
        self.mmu.write(addr, v);
    }
    fn read16(self: *Cpu, addr: u16) u16 {
        const lo = self.read8(addr);
        const hi = self.read8(addr +% 1);
        return (@as(u16, hi) << 8) | lo;
    }
    fn write16(self: *Cpu, addr: u16, v: u16) void {
        self.write8(addr, @intCast(v & 0xFF));
        self.write8(addr +% 1, @intCast(v >> 8));
    }
    fn fetch8(self: *Cpu) u8 {
        const v = self.read8(self.pc);
        if (self.halt_bug) {
            self.halt_bug = false;
        } else {
            self.pc +%= 1;
        }
        return v;
    }
    fn fetch16(self: *Cpu) u16 {
        const lo = self.fetch8();
        const hi = self.fetch8();
        return (@as(u16, hi) << 8) | lo;
    }
    fn push16(self: *Cpu, v: u16) void {
        self.sp -%= 1;
        self.write8(self.sp, @intCast(v >> 8));
        self.sp -%= 1;
        self.write8(self.sp, @intCast(v & 0xFF));
    }
    fn pop16(self: *Cpu) u16 {
        const lo = self.read8(self.sp);
        self.sp +%= 1;
        const hi = self.read8(self.sp);
        self.sp +%= 1;
        return (@as(u16, hi) << 8) | lo;
    }

    fn add8(self: *Cpu, b: u8) void {
        const a = self.a;
        const r: u16 = @as(u16, a) + @as(u16, b);
        const h = ((a & 0x0F) + (b & 0x0F)) > 0x0F;
        self.a = @intCast(r & 0xFF);
        self.setFlags(self.a == 0, false, h, r > 0xFF);
    }
    fn adc8(self: *Cpu, b: u8) void {
        const a = self.a;
        const cy: u16 = if (self.flagC()) 1 else 0;
        const r: u16 = @as(u16, a) + @as(u16, b) + cy;
        const h = (@as(u16, a & 0x0F) + @as(u16, b & 0x0F) + cy) > 0x0F;
        self.a = @intCast(r & 0xFF);
        self.setFlags(self.a == 0, false, h, r > 0xFF);
    }
    fn sub8(self: *Cpu, b: u8) void {
        const a = self.a;
        const r: i16 = @as(i16, a) - @as(i16, b);
        const h = (@as(i16, a & 0x0F) - @as(i16, b & 0x0F)) < 0;
        self.a = @intCast(@as(u16, @bitCast(r)) & 0xFF);
        self.setFlags(self.a == 0, true, h, r < 0);
    }
    fn sbc8(self: *Cpu, b: u8) void {
        const a = self.a;
        const cy: i16 = if (self.flagC()) 1 else 0;
        const r: i16 = @as(i16, a) - @as(i16, b) - cy;
        const h = (@as(i16, a & 0x0F) - @as(i16, b & 0x0F) - cy) < 0;
        self.a = @intCast(@as(u16, @bitCast(r)) & 0xFF);
        self.setFlags(self.a == 0, true, h, r < 0);
    }
    fn and8(self: *Cpu, b: u8) void {
        self.a &= b;
        self.setFlags(self.a == 0, false, true, false);
    }
    fn xor8(self: *Cpu, b: u8) void {
        self.a ^= b;
        self.setFlags(self.a == 0, false, false, false);
    }
    fn or8(self: *Cpu, b: u8) void {
        self.a |= b;
        self.setFlags(self.a == 0, false, false, false);
    }
    fn cp8(self: *Cpu, b: u8) void {
        const a = self.a;
        const r: i16 = @as(i16, a) - @as(i16, b);
        const h = (@as(i16, a & 0x0F) - @as(i16, b & 0x0F)) < 0;
        self.setFlags(@as(u8, @intCast(@as(u16, @bitCast(r)) & 0xFF)) == 0, true, h, r < 0);
    }
    fn inc8(self: *Cpu, v: u8) u8 {
        const r = v +% 1;
        self.setZ(r == 0);
        self.setN(false);
        self.setH((v & 0x0F) + 1 > 0x0F);
        return r;
    }
    fn dec8(self: *Cpu, v: u8) u8 {
        const r = v -% 1;
        self.setZ(r == 0);
        self.setN(true);
        self.setH((v & 0x0F) == 0);
        return r;
    }
    fn addHl(self: *Cpu, v: u16) void {
        const a = self.hl();
        const r: u32 = @as(u32, a) + @as(u32, v);
        self.setN(false);
        self.setH(((a & 0x0FFF) + (v & 0x0FFF)) > 0x0FFF);
        self.setC(r > 0xFFFF);
        self.setHl(@intCast(r & 0xFFFF));
    }
    fn addSp(self: *Cpu, off: i8) u16 {
        const sp = self.sp;
        const v: u16 = @bitCast(@as(i16, off));
        const r = sp +% v;
        const b: u16 = @as(u8, @bitCast(off));
        self.setFlags(false, false, ((sp & 0x0F) + (b & 0x0F)) > 0x0F, ((sp & 0xFF) + (b & 0xFF)) > 0xFF);
        return r;
    }
    fn daa(self: *Cpu) void {
        var a: u16 = self.a;
        var adj: u16 = 0;
        var c = self.flagC();
        if (self.flagN()) {
            if (self.flagH()) adj |= 0x06;
            if (c) adj |= 0x60;
            a -%= adj;
        } else {
            if (self.flagH() or (a & 0x0F) > 0x09) adj |= 0x06;
            if (c or a > 0x99) {
                adj |= 0x60;
                c = true;
            }
            a +%= adj;
        }
        self.a = @intCast(a & 0xFF);
        self.setZ(self.a == 0);
        self.setH(false);
        self.setC(c);
    }

    fn rlc(self: *Cpu, v: u8) u8 {
        const c = (v & 0x80) != 0;
        var r: u8 = v << 1;
        if (c) r |= 1;
        self.setFlags(r == 0, false, false, c);
        return r;
    }
    fn rrc(self: *Cpu, v: u8) u8 {
        const c = (v & 0x01) != 0;
        var r: u8 = v >> 1;
        if (c) r |= 0x80;
        self.setFlags(r == 0, false, false, c);
        return r;
    }
    fn rl(self: *Cpu, v: u8) u8 {
        const oc: u8 = if (self.flagC()) 1 else 0;
        const c = (v & 0x80) != 0;
        const r = (v << 1) | oc;
        self.setFlags(r == 0, false, false, c);
        return r;
    }
    fn rr(self: *Cpu, v: u8) u8 {
        const oc: u8 = if (self.flagC()) 0x80 else 0;
        const c = (v & 0x01) != 0;
        const r = (v >> 1) | oc;
        self.setFlags(r == 0, false, false, c);
        return r;
    }
    fn sla(self: *Cpu, v: u8) u8 {
        const c = (v & 0x80) != 0;
        const r = v << 1;
        self.setFlags(r == 0, false, false, c);
        return r;
    }
    fn sra(self: *Cpu, v: u8) u8 {
        const c = (v & 0x01) != 0;
        const r = (v >> 1) | (v & 0x80);
        self.setFlags(r == 0, false, false, c);
        return r;
    }
    fn swap(self: *Cpu, v: u8) u8 {
        const r = (v >> 4) | (v << 4);
        self.setFlags(r == 0, false, false, false);
        return r;
    }
    fn srl(self: *Cpu, v: u8) u8 {
        const c = (v & 0x01) != 0;
        const r = v >> 1;
        self.setFlags(r == 0, false, false, c);
        return r;
    }
    fn bit(self: *Cpu, v: u8, n: u3) void {
        const set = (v & (@as(u8, 1) << n)) != 0;
        self.setZ(!set);
        self.setN(false);
        self.setH(true);
    }

    fn getR(self: *Cpu, idx: u3) u8 {
        return switch (idx) {
            0 => self.b,
            1 => self.c,
            2 => self.d,
            3 => self.e,
            4 => self.h,
            5 => self.l,
            6 => self.read8(self.hl()),
            7 => self.a,
        };
    }
    fn setR(self: *Cpu, idx: u3, v: u8) void {
        switch (idx) {
            0 => self.b = v,
            1 => self.c = v,
            2 => self.d = v,
            3 => self.e = v,
            4 => self.h = v,
            5 => self.l = v,
            6 => self.write8(self.hl(), v),
            7 => self.a = v,
        }
    }

    fn handleInterrupts(self: *Cpu) u32 {
        const pending = self.mmu.if_reg & self.mmu.ie & 0x1F;
        if (pending != 0) self.halted = false;
        if (!self.ime or pending == 0) return 0;
        var bit_n: u3 = 0;
        while (bit_n < 5) : (bit_n += 1) {
            const mask: u8 = @as(u8, 1) << bit_n;
            if ((pending & mask) != 0) break;
        }
        if (bit_n >= 5) return 0;
        self.ime = false;
        self.mmu.if_reg &= ~(@as(u8, 1) << bit_n);
        self.push16(self.pc);
        self.pc = switch (bit_n) {
            0 => 0x0040,
            1 => 0x0048,
            2 => 0x0050,
            3 => 0x0058,
            4 => 0x0060,
            else => 0x0040,
        };
        return 20;
    }

    pub fn step(self: *Cpu) u32 {
        if (self.stopped) {
            if (self.mmu.joypad.buttons != 0xFF) {
                self.stopped = false;
            } else {
                return 4;
            }
        }
        const apply_ime = self.ime_pending;
        const irq_cycles = self.handleInterrupts();
        if (irq_cycles != 0) {
            self.ime_pending = false;
            return irq_cycles;
        }
        if (self.halted) {
            if (apply_ime) {
                self.ime_pending = false;
                self.ime = true;
            }
            return 4;
        }
        const op = self.fetch8();
        const cycles = self.execute(op);
        if (apply_ime) {
            self.ime_pending = false;
            self.ime = true;
        }
        return cycles;
    }

    fn execute(self: *Cpu, op: u8) u32 {
        return switch (op) {
            0x00 => 4,
            0x01 => blk: {
                self.setBc(self.fetch16());
                break :blk 12;
            },
            0x02 => blk: {
                self.write8(self.bc(), self.a);
                break :blk 8;
            },
            0x03 => blk: {
                self.setBc(self.bc() +% 1);
                break :blk 8;
            },
            0x04 => blk: {
                self.b = self.inc8(self.b);
                break :blk 4;
            },
            0x05 => blk: {
                self.b = self.dec8(self.b);
                break :blk 4;
            },
            0x06 => blk: {
                self.b = self.fetch8();
                break :blk 8;
            },
            0x07 => blk: {
                self.a = self.rlc(self.a);
                self.setZ(false);
                break :blk 4;
            },
            0x08 => blk: {
                const a = self.fetch16();
                self.write16(a, self.sp);
                break :blk 20;
            },
            0x09 => blk: {
                self.addHl(self.bc());
                break :blk 8;
            },
            0x0A => blk: {
                self.a = self.read8(self.bc());
                break :blk 8;
            },
            0x0B => blk: {
                self.setBc(self.bc() -% 1);
                break :blk 8;
            },
            0x0C => blk: {
                self.c = self.inc8(self.c);
                break :blk 4;
            },
            0x0D => blk: {
                self.c = self.dec8(self.c);
                break :blk 4;
            },
            0x0E => blk: {
                self.c = self.fetch8();
                break :blk 8;
            },
            0x0F => blk: {
                self.a = self.rrc(self.a);
                self.setZ(false);
                break :blk 4;
            },
            0x10 => blk: {
                _ = self.fetch8();
                self.mmu.timer.div_counter = 0;
                if (self.mmu.cgb_mode and (self.mmu.key1 & 0x01) != 0) {
                    self.double_speed = !self.double_speed;
                    self.mmu.key1 = if (self.double_speed) 0x80 else 0x00;
                    break :blk 8200;
                } else {
                    self.stopped = true;
                    break :blk 4;
                }
            },
            0x11 => blk: {
                self.setDe(self.fetch16());
                break :blk 12;
            },
            0x12 => blk: {
                self.write8(self.de(), self.a);
                break :blk 8;
            },
            0x13 => blk: {
                self.setDe(self.de() +% 1);
                break :blk 8;
            },
            0x14 => blk: {
                self.d = self.inc8(self.d);
                break :blk 4;
            },
            0x15 => blk: {
                self.d = self.dec8(self.d);
                break :blk 4;
            },
            0x16 => blk: {
                self.d = self.fetch8();
                break :blk 8;
            },
            0x17 => blk: {
                self.a = self.rl(self.a);
                self.setZ(false);
                break :blk 4;
            },
            0x18 => blk: {
                const off: i8 = @bitCast(self.fetch8());
                self.pc = self.pc +% @as(u16, @bitCast(@as(i16, off)));
                break :blk 12;
            },
            0x19 => blk: {
                self.addHl(self.de());
                break :blk 8;
            },
            0x1A => blk: {
                self.a = self.read8(self.de());
                break :blk 8;
            },
            0x1B => blk: {
                self.setDe(self.de() -% 1);
                break :blk 8;
            },
            0x1C => blk: {
                self.e = self.inc8(self.e);
                break :blk 4;
            },
            0x1D => blk: {
                self.e = self.dec8(self.e);
                break :blk 4;
            },
            0x1E => blk: {
                self.e = self.fetch8();
                break :blk 8;
            },
            0x1F => blk: {
                self.a = self.rr(self.a);
                self.setZ(false);
                break :blk 4;
            },
            0x20 => blk: {
                const off: i8 = @bitCast(self.fetch8());
                if (!self.flagZ()) {
                    self.pc = self.pc +% @as(u16, @bitCast(@as(i16, off)));
                    break :blk 12;
                }
                break :blk 8;
            },
            0x21 => blk: {
                self.setHl(self.fetch16());
                break :blk 12;
            },
            0x22 => blk: {
                self.write8(self.hl(), self.a);
                self.setHl(self.hl() +% 1);
                break :blk 8;
            },
            0x23 => blk: {
                self.setHl(self.hl() +% 1);
                break :blk 8;
            },
            0x24 => blk: {
                self.h = self.inc8(self.h);
                break :blk 4;
            },
            0x25 => blk: {
                self.h = self.dec8(self.h);
                break :blk 4;
            },
            0x26 => blk: {
                self.h = self.fetch8();
                break :blk 8;
            },
            0x27 => blk: {
                self.daa();
                break :blk 4;
            },
            0x28 => blk: {
                const off: i8 = @bitCast(self.fetch8());
                if (self.flagZ()) {
                    self.pc = self.pc +% @as(u16, @bitCast(@as(i16, off)));
                    break :blk 12;
                }
                break :blk 8;
            },
            0x29 => blk: {
                self.addHl(self.hl());
                break :blk 8;
            },
            0x2A => blk: {
                self.a = self.read8(self.hl());
                self.setHl(self.hl() +% 1);
                break :blk 8;
            },
            0x2B => blk: {
                self.setHl(self.hl() -% 1);
                break :blk 8;
            },
            0x2C => blk: {
                self.l = self.inc8(self.l);
                break :blk 4;
            },
            0x2D => blk: {
                self.l = self.dec8(self.l);
                break :blk 4;
            },
            0x2E => blk: {
                self.l = self.fetch8();
                break :blk 8;
            },
            0x2F => blk: {
                self.a = ~self.a;
                self.setN(true);
                self.setH(true);
                break :blk 4;
            },
            0x30 => blk: {
                const off: i8 = @bitCast(self.fetch8());
                if (!self.flagC()) {
                    self.pc = self.pc +% @as(u16, @bitCast(@as(i16, off)));
                    break :blk 12;
                }
                break :blk 8;
            },
            0x31 => blk: {
                self.sp = self.fetch16();
                break :blk 12;
            },
            0x32 => blk: {
                self.write8(self.hl(), self.a);
                self.setHl(self.hl() -% 1);
                break :blk 8;
            },
            0x33 => blk: {
                self.sp +%= 1;
                break :blk 8;
            },
            0x34 => blk: {
                const v = self.read8(self.hl());
                self.write8(self.hl(), self.inc8(v));
                break :blk 12;
            },
            0x35 => blk: {
                const v = self.read8(self.hl());
                self.write8(self.hl(), self.dec8(v));
                break :blk 12;
            },
            0x36 => blk: {
                self.write8(self.hl(), self.fetch8());
                break :blk 12;
            },
            0x37 => blk: {
                self.setN(false);
                self.setH(false);
                self.setC(true);
                break :blk 4;
            },
            0x38 => blk: {
                const off: i8 = @bitCast(self.fetch8());
                if (self.flagC()) {
                    self.pc = self.pc +% @as(u16, @bitCast(@as(i16, off)));
                    break :blk 12;
                }
                break :blk 8;
            },
            0x39 => blk: {
                self.addHl(self.sp);
                break :blk 8;
            },
            0x3A => blk: {
                self.a = self.read8(self.hl());
                self.setHl(self.hl() -% 1);
                break :blk 8;
            },
            0x3B => blk: {
                self.sp -%= 1;
                break :blk 8;
            },
            0x3C => blk: {
                self.a = self.inc8(self.a);
                break :blk 4;
            },
            0x3D => blk: {
                self.a = self.dec8(self.a);
                break :blk 4;
            },
            0x3E => blk: {
                self.a = self.fetch8();
                break :blk 8;
            },
            0x3F => blk: {
                self.setN(false);
                self.setH(false);
                self.setC(!self.flagC());
                break :blk 4;
            },

            0x40...0x75, 0x77...0x7F => blk: {
                const dst: u3 = @intCast((op >> 3) & 0x07);
                const src: u3 = @intCast(op & 0x07);
                const v = self.getR(src);
                self.setR(dst, v);
                break :blk if (src == 6 or dst == 6) @as(u32, 8) else 4;
            },
            0x76 => blk: {
                if (!self.ime and (self.mmu.if_reg & self.mmu.ie & 0x1F) != 0) {
                    self.halt_bug = true;
                } else {
                    self.halted = true;
                }
                break :blk 4;
            },

            0x80...0x87 => blk: {
                self.add8(self.getR(@intCast(op & 0x07)));
                break :blk if ((op & 0x07) == 6) @as(u32, 8) else 4;
            },
            0x88...0x8F => blk: {
                self.adc8(self.getR(@intCast(op & 0x07)));
                break :blk if ((op & 0x07) == 6) @as(u32, 8) else 4;
            },
            0x90...0x97 => blk: {
                self.sub8(self.getR(@intCast(op & 0x07)));
                break :blk if ((op & 0x07) == 6) @as(u32, 8) else 4;
            },
            0x98...0x9F => blk: {
                self.sbc8(self.getR(@intCast(op & 0x07)));
                break :blk if ((op & 0x07) == 6) @as(u32, 8) else 4;
            },
            0xA0...0xA7 => blk: {
                self.and8(self.getR(@intCast(op & 0x07)));
                break :blk if ((op & 0x07) == 6) @as(u32, 8) else 4;
            },
            0xA8...0xAF => blk: {
                self.xor8(self.getR(@intCast(op & 0x07)));
                break :blk if ((op & 0x07) == 6) @as(u32, 8) else 4;
            },
            0xB0...0xB7 => blk: {
                self.or8(self.getR(@intCast(op & 0x07)));
                break :blk if ((op & 0x07) == 6) @as(u32, 8) else 4;
            },
            0xB8...0xBF => blk: {
                self.cp8(self.getR(@intCast(op & 0x07)));
                break :blk if ((op & 0x07) == 6) @as(u32, 8) else 4;
            },

            0xC0 => blk: {
                if (!self.flagZ()) {
                    self.pc = self.pop16();
                    break :blk 20;
                }
                break :blk 8;
            },
            0xC1 => blk: {
                self.setBc(self.pop16());
                break :blk 12;
            },
            0xC2 => blk: {
                const a = self.fetch16();
                if (!self.flagZ()) {
                    self.pc = a;
                    break :blk 16;
                }
                break :blk 12;
            },
            0xC3 => blk: {
                self.pc = self.fetch16();
                break :blk 16;
            },
            0xC4 => blk: {
                const a = self.fetch16();
                if (!self.flagZ()) {
                    self.push16(self.pc);
                    self.pc = a;
                    break :blk 24;
                }
                break :blk 12;
            },
            0xC5 => blk: {
                self.push16(self.bc());
                break :blk 16;
            },
            0xC6 => blk: {
                self.add8(self.fetch8());
                break :blk 8;
            },
            0xC7 => blk: {
                self.push16(self.pc);
                self.pc = 0x0000;
                break :blk 16;
            },
            0xC8 => blk: {
                if (self.flagZ()) {
                    self.pc = self.pop16();
                    break :blk 20;
                }
                break :blk 8;
            },
            0xC9 => blk: {
                self.pc = self.pop16();
                break :blk 16;
            },
            0xCA => blk: {
                const a = self.fetch16();
                if (self.flagZ()) {
                    self.pc = a;
                    break :blk 16;
                }
                break :blk 12;
            },
            0xCB => blk: {
                const sub = self.fetch8();
                break :blk self.executeCb(sub);
            },
            0xCC => blk: {
                const a = self.fetch16();
                if (self.flagZ()) {
                    self.push16(self.pc);
                    self.pc = a;
                    break :blk 24;
                }
                break :blk 12;
            },
            0xCD => blk: {
                const a = self.fetch16();
                self.push16(self.pc);
                self.pc = a;
                break :blk 24;
            },
            0xCE => blk: {
                self.adc8(self.fetch8());
                break :blk 8;
            },
            0xCF => blk: {
                self.push16(self.pc);
                self.pc = 0x0008;
                break :blk 16;
            },
            0xD0 => blk: {
                if (!self.flagC()) {
                    self.pc = self.pop16();
                    break :blk 20;
                }
                break :blk 8;
            },
            0xD1 => blk: {
                self.setDe(self.pop16());
                break :blk 12;
            },
            0xD2 => blk: {
                const a = self.fetch16();
                if (!self.flagC()) {
                    self.pc = a;
                    break :blk 16;
                }
                break :blk 12;
            },
            0xD3 => 4,
            0xD4 => blk: {
                const a = self.fetch16();
                if (!self.flagC()) {
                    self.push16(self.pc);
                    self.pc = a;
                    break :blk 24;
                }
                break :blk 12;
            },
            0xD5 => blk: {
                self.push16(self.de());
                break :blk 16;
            },
            0xD6 => blk: {
                self.sub8(self.fetch8());
                break :blk 8;
            },
            0xD7 => blk: {
                self.push16(self.pc);
                self.pc = 0x0010;
                break :blk 16;
            },
            0xD8 => blk: {
                if (self.flagC()) {
                    self.pc = self.pop16();
                    break :blk 20;
                }
                break :blk 8;
            },
            0xD9 => blk: {
                self.pc = self.pop16();
                self.ime = true;
                break :blk 16;
            },
            0xDA => blk: {
                const a = self.fetch16();
                if (self.flagC()) {
                    self.pc = a;
                    break :blk 16;
                }
                break :blk 12;
            },
            0xDB => 4,
            0xDC => blk: {
                const a = self.fetch16();
                if (self.flagC()) {
                    self.push16(self.pc);
                    self.pc = a;
                    break :blk 24;
                }
                break :blk 12;
            },
            0xDD => 4,
            0xDE => blk: {
                self.sbc8(self.fetch8());
                break :blk 8;
            },
            0xDF => blk: {
                self.push16(self.pc);
                self.pc = 0x0018;
                break :blk 16;
            },
            0xE0 => blk: {
                const off = self.fetch8();
                self.write8(0xFF00 + @as(u16, off), self.a);
                break :blk 12;
            },
            0xE1 => blk: {
                self.setHl(self.pop16());
                break :blk 12;
            },
            0xE2 => blk: {
                self.write8(0xFF00 + @as(u16, self.c), self.a);
                break :blk 8;
            },
            0xE3, 0xE4 => 4,
            0xE5 => blk: {
                self.push16(self.hl());
                break :blk 16;
            },
            0xE6 => blk: {
                self.and8(self.fetch8());
                break :blk 8;
            },
            0xE7 => blk: {
                self.push16(self.pc);
                self.pc = 0x0020;
                break :blk 16;
            },
            0xE8 => blk: {
                const off: i8 = @bitCast(self.fetch8());
                self.sp = self.addSp(off);
                break :blk 16;
            },
            0xE9 => blk: {
                self.pc = self.hl();
                break :blk 4;
            },
            0xEA => blk: {
                const a = self.fetch16();
                self.write8(a, self.a);
                break :blk 16;
            },
            0xEB, 0xEC, 0xED => 4,
            0xEE => blk: {
                self.xor8(self.fetch8());
                break :blk 8;
            },
            0xEF => blk: {
                self.push16(self.pc);
                self.pc = 0x0028;
                break :blk 16;
            },
            0xF0 => blk: {
                const off = self.fetch8();
                self.a = self.read8(0xFF00 + @as(u16, off));
                break :blk 12;
            },
            0xF1 => blk: {
                self.setAf(self.pop16());
                break :blk 12;
            },
            0xF2 => blk: {
                self.a = self.read8(0xFF00 + @as(u16, self.c));
                break :blk 8;
            },
            0xF3 => blk: {
                self.ime = false;
                self.ime_pending = false;
                break :blk 4;
            },
            0xF4 => 4,
            0xF5 => blk: {
                self.push16(self.af());
                break :blk 16;
            },
            0xF6 => blk: {
                self.or8(self.fetch8());
                break :blk 8;
            },
            0xF7 => blk: {
                self.push16(self.pc);
                self.pc = 0x0030;
                break :blk 16;
            },
            0xF8 => blk: {
                const off: i8 = @bitCast(self.fetch8());
                self.setHl(self.addSp(off));
                break :blk 12;
            },
            0xF9 => blk: {
                self.sp = self.hl();
                break :blk 8;
            },
            0xFA => blk: {
                const a = self.fetch16();
                self.a = self.read8(a);
                break :blk 16;
            },
            0xFB => blk: {
                self.ime_pending = true;
                break :blk 4;
            },
            0xFC, 0xFD => 4,
            0xFE => blk: {
                self.cp8(self.fetch8());
                break :blk 8;
            },
            0xFF => blk: {
                self.push16(self.pc);
                self.pc = 0x0038;
                break :blk 16;
            },
        };
    }

    fn executeCb(self: *Cpu, op: u8) u32 {
        const idx: u3 = @intCast(op & 0x07);
        const grp: u8 = op >> 3;
        const cycles: u32 = blk: {
            if (idx != 6) break :blk 8;
            if (grp >= 8 and grp <= 0x0F) break :blk 12;
            break :blk 16;
        };
        const v = self.getR(idx);
        if (grp < 8) {
            const r = switch (grp) {
                0 => self.rlc(v),
                1 => self.rrc(v),
                2 => self.rl(v),
                3 => self.rr(v),
                4 => self.sla(v),
                5 => self.sra(v),
                6 => self.swap(v),
                7 => self.srl(v),
                else => unreachable,
            };
            self.setR(idx, r);
        } else if (grp < 0x10) {
            self.bit(v, @intCast(grp & 0x07));
        } else if (grp < 0x18) {
            const n: u3 = @intCast(grp & 0x07);
            self.setR(idx, v & ~(@as(u8, 1) << n));
        } else {
            const n: u3 = @intCast(grp & 0x07);
            self.setR(idx, v | (@as(u8, 1) << n));
        }
        return cycles;
    }
};
