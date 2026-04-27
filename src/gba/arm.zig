const std = @import("std");
const Bus = @import("bus.zig").Bus;

const MODE_USER: u8 = 0x10;
const MODE_FIQ: u8 = 0x11;
const MODE_IRQ: u8 = 0x12;
const MODE_SVC: u8 = 0x13;
const MODE_ABT: u8 = 0x17;
const MODE_UND: u8 = 0x1B;
const MODE_SYS: u8 = 0x1F;

const F_N: u32 = 0x80000000;
const F_Z: u32 = 0x40000000;
const F_C: u32 = 0x20000000;
const F_V: u32 = 0x10000000;
const F_I: u32 = 0x00000080;
const F_F: u32 = 0x00000040;
const F_T: u32 = 0x00000020;

pub const Cpu = struct {
    r: [16]u32 = .{0} ** 16,
    cpsr: u32 = MODE_SVC | F_I | F_F,

    r_usr: [7]u32 = .{0} ** 7,
    r_fiq: [7]u32 = .{0} ** 7,
    r_svc_sp_lr: [2]u32 = .{ 0, 0 },
    r_abt_sp_lr: [2]u32 = .{ 0, 0 },
    r_irq_sp_lr: [2]u32 = .{ 0, 0 },
    r_und_sp_lr: [2]u32 = .{ 0, 0 },
    spsr_fiq: u32 = 0,
    spsr_svc: u32 = 0,
    spsr_abt: u32 = 0,
    spsr_irq: u32 = 0,
    spsr_und: u32 = 0,

    bus: *Bus,
    halted: bool = false,
    cycles: u64 = 0,

    pub fn init(bus: *Bus) Cpu {
        return .{ .bus = bus };
    }

    pub fn reset(self: *Cpu) void {
        self.r = .{0} ** 16;
        self.cpsr = MODE_SVC | F_I | F_F;
        self.r_usr = .{0} ** 7;
        self.r_fiq = .{0} ** 7;
        self.r_svc_sp_lr = .{ 0, 0 };
        self.r_abt_sp_lr = .{ 0, 0 };
        self.r_irq_sp_lr = .{ 0, 0 };
        self.r_und_sp_lr = .{ 0, 0 };
        self.spsr_fiq = 0;
        self.spsr_svc = 0;
        self.spsr_abt = 0;
        self.spsr_irq = 0;
        self.spsr_und = 0;
        self.halted = false;
        self.cycles = 0;
    }

    pub fn skipBios(self: *Cpu) void {
        self.cpsr = MODE_SYS;
        self.r[13] = 0x03007F00;
        self.r_usr[5] = 0x03007F00;
        self.r_usr[6] = 0;
        self.r_irq_sp_lr[0] = 0x03007FA0;
        self.r_svc_sp_lr[0] = 0x03007FE0;
        self.r[15] = 0x08000000;
    }

    pub fn mode(self: *const Cpu) u8 {
        return @intCast(self.cpsr & 0x1F);
    }

    fn isThumb(self: *const Cpu) bool {
        return (self.cpsr & F_T) != 0;
    }

    pub fn switchMode(self: *Cpu, new_mode: u8) void {
        const old_mode = self.mode();
        if (old_mode == new_mode) {
            self.cpsr = (self.cpsr & ~@as(u32, 0x1F)) | new_mode;
            return;
        }
        self.saveBankedSpLr(old_mode);
        if (old_mode == MODE_FIQ and new_mode != MODE_FIQ) {
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                self.r_fiq[i] = self.r[8 + i];
                self.r[8 + i] = self.r_usr[i];
            }
        } else if (old_mode != MODE_FIQ and new_mode == MODE_FIQ) {
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                self.r_usr[i] = self.r[8 + i];
                self.r[8 + i] = self.r_fiq[i];
            }
        }
        self.loadBankedSpLr(new_mode);
        self.cpsr = (self.cpsr & ~@as(u32, 0x1F)) | new_mode;
    }

    fn saveBankedSpLr(self: *Cpu, m: u8) void {
        switch (m) {
            MODE_USER, MODE_SYS => {
                self.r_usr[5] = self.r[13];
                self.r_usr[6] = self.r[14];
            },
            MODE_FIQ => {
                self.r_fiq[5] = self.r[13];
                self.r_fiq[6] = self.r[14];
            },
            MODE_SVC => {
                self.r_svc_sp_lr[0] = self.r[13];
                self.r_svc_sp_lr[1] = self.r[14];
            },
            MODE_ABT => {
                self.r_abt_sp_lr[0] = self.r[13];
                self.r_abt_sp_lr[1] = self.r[14];
            },
            MODE_IRQ => {
                self.r_irq_sp_lr[0] = self.r[13];
                self.r_irq_sp_lr[1] = self.r[14];
            },
            MODE_UND => {
                self.r_und_sp_lr[0] = self.r[13];
                self.r_und_sp_lr[1] = self.r[14];
            },
            else => {},
        }
    }

    fn loadBankedSpLr(self: *Cpu, m: u8) void {
        switch (m) {
            MODE_USER, MODE_SYS => {
                self.r[13] = self.r_usr[5];
                self.r[14] = self.r_usr[6];
            },
            MODE_FIQ => {
                self.r[13] = self.r_fiq[5];
                self.r[14] = self.r_fiq[6];
            },
            MODE_SVC => {
                self.r[13] = self.r_svc_sp_lr[0];
                self.r[14] = self.r_svc_sp_lr[1];
            },
            MODE_ABT => {
                self.r[13] = self.r_abt_sp_lr[0];
                self.r[14] = self.r_abt_sp_lr[1];
            },
            MODE_IRQ => {
                self.r[13] = self.r_irq_sp_lr[0];
                self.r[14] = self.r_irq_sp_lr[1];
            },
            MODE_UND => {
                self.r[13] = self.r_und_sp_lr[0];
                self.r[14] = self.r_und_sp_lr[1];
            },
            else => {},
        }
    }

    fn getSpsr(self: *const Cpu) u32 {
        return switch (self.mode()) {
            MODE_FIQ => self.spsr_fiq,
            MODE_SVC => self.spsr_svc,
            MODE_ABT => self.spsr_abt,
            MODE_IRQ => self.spsr_irq,
            MODE_UND => self.spsr_und,
            else => self.cpsr,
        };
    }

    fn setSpsr(self: *Cpu, v: u32) void {
        switch (self.mode()) {
            MODE_FIQ => self.spsr_fiq = v,
            MODE_SVC => self.spsr_svc = v,
            MODE_ABT => self.spsr_abt = v,
            MODE_IRQ => self.spsr_irq = v,
            MODE_UND => self.spsr_und = v,
            else => {},
        }
    }

    pub fn checkIrq(self: *Cpu) void {
        if ((self.cpsr & F_I) != 0) return;
        if (!self.bus.irq.pending()) return;
        self.halted = false;
        const old_cpsr = self.cpsr;
        const ret_pc: u32 = self.r[15] + 4;
        self.switchMode(MODE_IRQ);
        self.spsr_irq = old_cpsr;
        self.r[14] = ret_pc;
        self.cpsr = (self.cpsr & ~F_T) | F_I;
        self.r[15] = 0x18;
        self.flushPipeline();
    }

    fn flushPipeline(self: *Cpu) void {
        if (self.isThumb()) {
            self.r[15] &= ~@as(u32, 1);
        } else {
            self.r[15] &= ~@as(u32, 3);
        }
    }

    pub fn step(self: *Cpu) u32 {
        if (self.halted) {
            if ((self.bus.irq.ie & self.bus.irq.ifr) != 0) {
                self.halted = false;
                self.bus.halted = false;
            } else {
                return 4;
            }
        }
        self.bus.access_cycles = 0;
        self.checkIrq();
        const base: u32 = if (self.isThumb()) self.stepThumb() else self.stepArm();
        return base + self.bus.drainAccessCycles();
    }

    fn condCheck(self: *const Cpu, cond: u4) bool {
        const n = (self.cpsr & F_N) != 0;
        const z = (self.cpsr & F_Z) != 0;
        const c = (self.cpsr & F_C) != 0;
        const v = (self.cpsr & F_V) != 0;
        return switch (cond) {
            0x0 => z,
            0x1 => !z,
            0x2 => c,
            0x3 => !c,
            0x4 => n,
            0x5 => !n,
            0x6 => v,
            0x7 => !v,
            0x8 => c and !z,
            0x9 => !c or z,
            0xA => n == v,
            0xB => n != v,
            0xC => !z and (n == v),
            0xD => z or (n != v),
            0xE => true,
            0xF => true,
        };
    }

    fn setNZ(self: *Cpu, v: u32) void {
        self.cpsr = (self.cpsr & ~(F_N | F_Z));
        if ((v & 0x80000000) != 0) self.cpsr |= F_N;
        if (v == 0) self.cpsr |= F_Z;
    }

    fn stepArm(self: *Cpu) u32 {
        const pc = self.r[15];
        const op = self.bus.read32(pc);
        self.r[15] +%= 4;
        const cond: u4 = @intCast(op >> 28);
        if (!self.condCheck(cond)) return 0;

        const top3: u32 = (op >> 25) & 0x07;
        switch (top3) {
            5 => return self.execB(op, (op & 0x01000000) != 0),
            7 => {
                if ((op & 0x0F000000) == 0x0F000000) return self.execSwi(op);
                return 0;
            },
            4 => return self.execBlock(op),
            2, 3 => return self.execSingleData(op),
            else => {},
        }

        if (top3 == 0) {
            if ((op & 0x0FFFFFF0) == 0x012FFF10) return self.execBx(op);
            const has_b7_b4 = (op & 0x90) == 0x90;
            if (has_b7_b4) {
                const sh: u32 = (op >> 5) & 0x03;
                if (sh == 0) {
                    if ((op & 0x0FB00FF0) == 0x01000090) return self.execSwap(op);
                    return self.execMul(op);
                }
                if ((op & 0x00400000) != 0) return self.execHalfSignedImm(op);
                return self.execHalfSignedReg(op);
            }
            if ((op & 0x0FBF0FFF) == 0x010F0000) return self.execMrs(op);
            if ((op & 0x0FB0F000) == 0x0120F000) return self.execMsr(op);
            return self.execDataProcessing(op);
        }
        if (top3 == 1) {
            if ((op & 0x0FB0F000) == 0x0320F000) return self.execMsr(op);
            return self.execDataProcessing(op);
        }
        return 0;
    }

    fn execSwi(self: *Cpu, op: u32) u32 {
        _ = op;
        const old_cpsr = self.cpsr;
        const ret_pc = self.r[15];
        self.switchMode(MODE_SVC);
        self.spsr_svc = old_cpsr;
        self.r[14] = ret_pc;
        self.cpsr = (self.cpsr & ~F_T) | F_I;
        self.r[15] = 0x08;
        return 0;
    }

    fn execB(self: *Cpu, op: u32, link: bool) u32 {
        var off: i32 = @intCast(op & 0x00FFFFFF);
        if ((off & 0x00800000) != 0) off |= @as(i32, @bitCast(@as(u32, 0xFF000000)));
        off <<= 2;
        const target: u32 = self.r[15] +% 4 +% @as(u32, @bitCast(off));
        if (link) self.r[14] = self.r[15];
        self.r[15] = target;
        self.flushPipeline();
        return 0;
    }

    fn execBx(self: *Cpu, op: u32) u32 {
        const rn: u4 = @intCast(op & 0x0F);
        const v = self.r[rn];
        if ((v & 1) != 0) {
            self.cpsr |= F_T;
            self.r[15] = v & ~@as(u32, 1);
        } else {
            self.cpsr &= ~F_T;
            self.r[15] = v & ~@as(u32, 3);
        }
        return 0;
    }

    fn execMrs(self: *Cpu, op: u32) u32 {
        const ps = (op & (1 << 22)) != 0;
        const rd: u4 = @intCast((op >> 12) & 0x0F);
        if (ps) {
            self.r[rd] = self.getSpsr();
        } else {
            self.r[rd] = self.cpsr;
        }
        return 0;
    }

    fn execMsr(self: *Cpu, op: u32) u32 {
        const imm = (op & (1 << 25)) != 0;
        const ps = (op & (1 << 22)) != 0;
        var v: u32 = 0;
        if (imm) {
            const rot: u5 = @intCast(((op >> 8) & 0x0F) * 2);
            v = std.math.rotr(u32, op & 0xFF, rot);
        } else {
            v = self.r[op & 0x0F];
        }
        var mask: u32 = 0;
        if ((op & (1 << 19)) != 0) mask |= 0xFF000000;
        if ((op & (1 << 18)) != 0) mask |= 0x00FF0000;
        if ((op & (1 << 17)) != 0) mask |= 0x0000FF00;
        if ((op & (1 << 16)) != 0) mask |= 0x000000FF;
        if (self.mode() == MODE_USER) mask &= 0xF0000000;
        if (ps) {
            const cur = self.getSpsr();
            self.setSpsr((cur & ~mask) | (v & mask));
        } else {
            const old_t = (self.cpsr & F_T) != 0;
            const new_cpsr = (self.cpsr & ~mask) | (v & mask);
            const new_mode: u8 = @intCast(new_cpsr & 0x1F);
            if ((mask & 0xFF) != 0 and self.mode() != MODE_USER) {
                self.switchMode(new_mode);
            }
            self.cpsr = (self.cpsr & ~mask) | (v & mask);
            const new_t = (self.cpsr & F_T) != 0;
            if (old_t != new_t) self.flushPipeline();
        }
        return 0;
    }

    fn shiftOp(self: *Cpu, val: u32, ty: u2, amount: u32, by_reg: bool) struct { v: u32, c: bool } {
        var c_out: bool = (self.cpsr & F_C) != 0;
        if (by_reg and amount == 0) return .{ .v = val, .c = c_out };
        switch (ty) {
            0 => {
                if (amount == 0) {
                    return .{ .v = val, .c = c_out };
                }
                if (amount >= 32) {
                    if (amount == 32) {
                        c_out = (val & 1) != 0;
                    } else {
                        c_out = false;
                    }
                    return .{ .v = 0, .c = c_out };
                }
                c_out = ((val >> @intCast(32 - amount)) & 1) != 0;
                return .{ .v = val << @intCast(amount), .c = c_out };
            },
            1 => {
                var amt = amount;
                if (!by_reg and amt == 0) amt = 32;
                if (amt >= 32) {
                    if (amt == 32) {
                        c_out = (val & 0x80000000) != 0;
                    } else {
                        c_out = false;
                    }
                    return .{ .v = 0, .c = c_out };
                }
                c_out = ((val >> @intCast(amt - 1)) & 1) != 0;
                return .{ .v = val >> @intCast(amt), .c = c_out };
            },
            2 => {
                var amt = amount;
                if (!by_reg and amt == 0) amt = 32;
                if (amt >= 32) {
                    c_out = (val & 0x80000000) != 0;
                    const result: u32 = if (c_out) 0xFFFFFFFF else 0;
                    return .{ .v = result, .c = c_out };
                }
                c_out = ((val >> @intCast(amt - 1)) & 1) != 0;
                const sv: i32 = @bitCast(val);
                return .{ .v = @bitCast(sv >> @intCast(amt)), .c = c_out };
            },
            3 => {
                if (!by_reg and amount == 0) {
                    c_out = (val & 1) != 0;
                    var r = val >> 1;
                    if ((self.cpsr & F_C) != 0) r |= 0x80000000;
                    return .{ .v = r, .c = c_out };
                }
                const amt: u5 = @intCast(amount & 0x1F);
                if (amount == 0) return .{ .v = val, .c = c_out };
                if ((amount & 0x1F) == 0) {
                    c_out = (val & 0x80000000) != 0;
                    return .{ .v = val, .c = c_out };
                }
                c_out = ((val >> (amt - 1)) & 1) != 0;
                return .{ .v = std.math.rotr(u32, val, amt), .c = c_out };
            },
        }
    }

    fn execDataProcessing(self: *Cpu, op: u32) u32 {
        const imm = (op & (1 << 25)) != 0;
        const opcode: u4 = @intCast((op >> 21) & 0x0F);
        const set_cc = (op & (1 << 20)) != 0;
        const rn: u4 = @intCast((op >> 16) & 0x0F);
        const rd: u4 = @intCast((op >> 12) & 0x0F);

        var operand2: u32 = 0;
        var shift_carry: bool = (self.cpsr & F_C) != 0;
        var rn_val = self.r[rn];
        if (rn == 15) rn_val +%= 4;
        var extra_cycles: u32 = 0;

        if (imm) {
            const rot: u5 = @intCast(((op >> 8) & 0x0F) * 2);
            operand2 = std.math.rotr(u32, op & 0xFF, rot);
            if (rot != 0) shift_carry = (operand2 & 0x80000000) != 0;
        } else {
            const rm: u4 = @intCast(op & 0x0F);
            var rm_val = self.r[rm];
            if (rm == 15) rm_val +%= 4;
            const ty: u2 = @intCast((op >> 5) & 0x03);
            const by_reg = (op & (1 << 4)) != 0;
            var amount: u32 = 0;
            if (by_reg) {
                if (rm == 15) rm_val +%= 4;
                if (rn == 15) rn_val +%= 4;
                const rs: u4 = @intCast((op >> 8) & 0x0F);
                var rs_val = self.r[rs];
                if (rs == 15) rs_val +%= 8;
                amount = rs_val & 0xFF;
                extra_cycles = 1;
            } else {
                amount = (op >> 7) & 0x1F;
            }
            const sh = self.shiftOp(rm_val, ty, amount, by_reg);
            operand2 = sh.v;
            shift_carry = sh.c;
        }

        const c_in: u32 = if ((self.cpsr & F_C) != 0) 1 else 0;
        var result: u32 = 0;
        var write_result: bool = true;
        var carry_out: bool = shift_carry;
        var overflow_set: bool = false;
        var ovf: bool = false;

        switch (opcode) {
            0x0 => result = rn_val & operand2,
            0x1 => result = rn_val ^ operand2,
            0x2 => {
                const r = @as(u64, rn_val) -% @as(u64, operand2);
                result = @truncate(r);
                carry_out = rn_val >= operand2;
                ovf = ((rn_val ^ operand2) & (rn_val ^ result) & 0x80000000) != 0;
                overflow_set = true;
            },
            0x3 => {
                const r = @as(u64, operand2) -% @as(u64, rn_val);
                result = @truncate(r);
                carry_out = operand2 >= rn_val;
                ovf = ((operand2 ^ rn_val) & (operand2 ^ result) & 0x80000000) != 0;
                overflow_set = true;
            },
            0x4 => {
                const r = @as(u64, rn_val) + @as(u64, operand2);
                result = @truncate(r);
                carry_out = (r >> 32) != 0;
                ovf = (~(rn_val ^ operand2) & (rn_val ^ result) & 0x80000000) != 0;
                overflow_set = true;
            },
            0x5 => {
                const r = @as(u64, rn_val) + @as(u64, operand2) + c_in;
                result = @truncate(r);
                carry_out = (r >> 32) != 0;
                ovf = (~(rn_val ^ operand2) & (rn_val ^ result) & 0x80000000) != 0;
                overflow_set = true;
            },
            0x6 => {
                const r = @as(i64, @as(i32, @bitCast(rn_val))) - @as(i64, @as(i32, @bitCast(operand2))) - @as(i64, 1 - @as(i32, @intCast(c_in)));
                result = @bitCast(@as(i32, @truncate(r)));
                carry_out = @as(u64, rn_val) +% (~@as(u64, operand2) & 0xFFFFFFFF) +% c_in > 0xFFFFFFFF;
                ovf = ((rn_val ^ operand2) & (rn_val ^ result) & 0x80000000) != 0;
                overflow_set = true;
            },
            0x7 => {
                const r = @as(i64, @as(i32, @bitCast(operand2))) - @as(i64, @as(i32, @bitCast(rn_val))) - @as(i64, 1 - @as(i32, @intCast(c_in)));
                result = @bitCast(@as(i32, @truncate(r)));
                carry_out = @as(u64, operand2) +% (~@as(u64, rn_val) & 0xFFFFFFFF) +% c_in > 0xFFFFFFFF;
                ovf = ((operand2 ^ rn_val) & (operand2 ^ result) & 0x80000000) != 0;
                overflow_set = true;
            },
            0x8 => {
                result = rn_val & operand2;
                write_result = false;
            },
            0x9 => {
                result = rn_val ^ operand2;
                write_result = false;
            },
            0xA => {
                const r = @as(u64, rn_val) -% @as(u64, operand2);
                result = @truncate(r);
                carry_out = rn_val >= operand2;
                ovf = ((rn_val ^ operand2) & (rn_val ^ result) & 0x80000000) != 0;
                overflow_set = true;
                write_result = false;
            },
            0xB => {
                const r = @as(u64, rn_val) + @as(u64, operand2);
                result = @truncate(r);
                carry_out = (r >> 32) != 0;
                ovf = (~(rn_val ^ operand2) & (rn_val ^ result) & 0x80000000) != 0;
                overflow_set = true;
                write_result = false;
            },
            0xC => result = rn_val | operand2,
            0xD => result = operand2,
            0xE => result = rn_val & ~operand2,
            0xF => result = ~operand2,
        }

        if (write_result) self.r[rd] = result;
        if (set_cc) {
            if (rd == 15) {
                const sp = self.getSpsr();
                const new_mode: u8 = @intCast(sp & 0x1F);
                self.switchMode(new_mode);
                self.cpsr = sp;
            } else {
                self.setNZ(result);
                self.cpsr = (self.cpsr & ~F_C);
                if (carry_out) self.cpsr |= F_C;
                if (overflow_set) {
                    self.cpsr = self.cpsr & ~F_V;
                    if (ovf) self.cpsr |= F_V;
                }
            }
        }
        if (rd == 15 and write_result) {
            self.flushPipeline();
        }
        return extra_cycles;
    }

    fn execMul(self: *Cpu, op: u32) u32 {
        const opcode: u3 = @intCast((op >> 21) & 0x07);
        const set_cc = (op & (1 << 20)) != 0;
        const rd_hi: u4 = @intCast((op >> 16) & 0x0F);
        const rd_lo: u4 = @intCast((op >> 12) & 0x0F);
        const rs: u4 = @intCast((op >> 8) & 0x0F);
        const rm: u4 = @intCast(op & 0x0F);

        switch (opcode) {
            0 => {
                const r = self.r[rm] *% self.r[rs];
                self.r[rd_hi] = r;
                if (set_cc) self.setNZ(r);
            },
            1 => {
                const r = self.r[rm] *% self.r[rs] +% self.r[rd_lo];
                self.r[rd_hi] = r;
                if (set_cc) self.setNZ(r);
            },
            4 => {
                const a: u64 = self.r[rm];
                const b: u64 = self.r[rs];
                const r = a *% b;
                self.r[rd_lo] = @truncate(r);
                self.r[rd_hi] = @truncate(r >> 32);
                if (set_cc) {
                    self.cpsr = self.cpsr & ~(F_N | F_Z);
                    if ((r & 0x8000000000000000) != 0) self.cpsr |= F_N;
                    if (r == 0) self.cpsr |= F_Z;
                }
            },
            5 => {
                const a: u64 = self.r[rm];
                const b: u64 = self.r[rs];
                const acc: u64 = (@as(u64, self.r[rd_hi]) << 32) | self.r[rd_lo];
                const r = a *% b +% acc;
                self.r[rd_lo] = @truncate(r);
                self.r[rd_hi] = @truncate(r >> 32);
                if (set_cc) {
                    self.cpsr = self.cpsr & ~(F_N | F_Z);
                    if ((r & 0x8000000000000000) != 0) self.cpsr |= F_N;
                    if (r == 0) self.cpsr |= F_Z;
                }
            },
            6 => {
                const a: i64 = @as(i32, @bitCast(self.r[rm]));
                const b: i64 = @as(i32, @bitCast(self.r[rs]));
                const r: u64 = @bitCast(a *% b);
                self.r[rd_lo] = @truncate(r);
                self.r[rd_hi] = @truncate(r >> 32);
                if (set_cc) {
                    self.cpsr = self.cpsr & ~(F_N | F_Z);
                    if ((r & 0x8000000000000000) != 0) self.cpsr |= F_N;
                    if (r == 0) self.cpsr |= F_Z;
                }
            },
            7 => {
                const a: i64 = @as(i32, @bitCast(self.r[rm]));
                const b: i64 = @as(i32, @bitCast(self.r[rs]));
                const acc: i64 = @bitCast((@as(u64, self.r[rd_hi]) << 32) | self.r[rd_lo]);
                const r: u64 = @bitCast(a *% b +% acc);
                self.r[rd_lo] = @truncate(r);
                self.r[rd_hi] = @truncate(r >> 32);
                if (set_cc) {
                    self.cpsr = self.cpsr & ~(F_N | F_Z);
                    if ((r & 0x8000000000000000) != 0) self.cpsr |= F_N;
                    if (r == 0) self.cpsr |= F_Z;
                }
            },
            else => {},
        }
        const rs_val = self.r[rs];
        var m: u32 = 4;
        if (opcode == 4 or opcode == 5) {
            if ((rs_val & 0xFFFFFF00) == 0) m = 1
            else if ((rs_val & 0xFFFF0000) == 0) m = 2
            else if ((rs_val & 0xFF000000) == 0) m = 3;
        } else {
            const top = rs_val & 0xFFFFFF00;
            if (top == 0 or top == 0xFFFFFF00) m = 1
            else {
                const top16 = rs_val & 0xFFFF0000;
                if (top16 == 0 or top16 == 0xFFFF0000) m = 2
                else {
                    const top8 = rs_val & 0xFF000000;
                    if (top8 == 0 or top8 == 0xFF000000) m = 3;
                }
            }
        }
        const extra_i: u32 = switch (opcode) {
            0 => 0,
            1 => 1,
            4, 6 => 1,
            5, 7 => 2,
            else => 0,
        };
        return m + extra_i;
    }

    fn execSwap(self: *Cpu, op: u32) u32 {
        const byte = (op & (1 << 22)) != 0;
        const rn: u4 = @intCast((op >> 16) & 0x0F);
        const rd: u4 = @intCast((op >> 12) & 0x0F);
        const rm: u4 = @intCast(op & 0x0F);
        const addr = self.r[rn];
        if (byte) {
            const v = self.bus.read8(addr);
            self.bus.write8(addr, @truncate(self.r[rm]));
            self.r[rd] = v;
        } else {
            const rot: u5 = @intCast((addr & 3) * 8);
            const raw = self.bus.read32(addr);
            self.bus.write32(addr, self.r[rm]);
            self.r[rd] = std.math.rotr(u32, raw, rot);
        }
        return 1;
    }

    fn execSingleData(self: *Cpu, op: u32) u32 {
        const reg_offset = (op & (1 << 25)) != 0;
        const pre = (op & (1 << 24)) != 0;
        const up = (op & (1 << 23)) != 0;
        const byte = (op & (1 << 22)) != 0;
        const writeback = (op & (1 << 21)) != 0;
        const load = (op & (1 << 20)) != 0;
        const rn: u4 = @intCast((op >> 16) & 0x0F);
        const rd: u4 = @intCast((op >> 12) & 0x0F);

        var offset: u32 = 0;
        if (!reg_offset) {
            offset = op & 0xFFF;
        } else {
            const rm: u4 = @intCast(op & 0x0F);
            const ty: u2 = @intCast((op >> 5) & 0x03);
            const amount: u32 = (op >> 7) & 0x1F;
            const sh = self.shiftOp(self.r[rm], ty, amount, false);
            offset = sh.v;
        }

        var addr = self.r[rn];
        if (rn == 15) addr +%= 4;
        const base_addr = addr;
        if (pre) {
            addr = if (up) addr +% offset else addr -% offset;
        }
        const access_addr = addr;

        if (load) {
            if (byte) {
                self.r[rd] = self.bus.read8(access_addr);
            } else {
                const rot: u5 = @intCast((access_addr & 3) * 8);
                const raw = self.bus.read32(access_addr & ~@as(u32, 3));
                self.r[rd] = std.math.rotr(u32, raw, rot);
            }
        } else {
            var v = self.r[rd];
            if (rd == 15) v +%= 8;
            if (byte) {
                self.bus.write8(access_addr, @truncate(v));
            } else {
                self.bus.write32(access_addr & ~@as(u32, 3), v);
            }
        }

        if (!pre) {
            addr = if (up) base_addr +% offset else base_addr -% offset;
        }
        if ((!pre or writeback) and !(load and rd == rn)) {
            self.r[rn] = addr;
        }

        if (load and rd == 15) {
            self.flushPipeline();
            return 1;
        }
        return if (load) 1 else 0;
    }

    fn execHalfSignedReg(self: *Cpu, op: u32) u32 {
        return self.execHalfSignedCommon(op, false);
    }
    fn execHalfSignedImm(self: *Cpu, op: u32) u32 {
        return self.execHalfSignedCommon(op, true);
    }

    fn execHalfSignedCommon(self: *Cpu, op: u32, imm: bool) u32 {
        const pre = (op & (1 << 24)) != 0;
        const up = (op & (1 << 23)) != 0;
        const writeback = (op & (1 << 21)) != 0;
        const load = (op & (1 << 20)) != 0;
        const rn: u4 = @intCast((op >> 16) & 0x0F);
        const rd: u4 = @intCast((op >> 12) & 0x0F);
        const sh: u2 = @intCast((op >> 5) & 0x03);

        var offset: u32 = 0;
        if (imm) {
            offset = ((op >> 4) & 0xF0) | (op & 0x0F);
        } else {
            const rm: u4 = @intCast(op & 0x0F);
            offset = self.r[rm];
        }

        var addr = self.r[rn];
        if (rn == 15) addr +%= 4;
        if (pre) addr = if (up) addr +% offset else addr -% offset;

        if (load) {
            switch (sh) {
                1 => {
                    const aligned = addr & ~@as(u32, 1);
                    var v: u32 = self.bus.read16(aligned);
                    if ((addr & 1) != 0) v = std.math.rotr(u32, v, 8);
                    self.r[rd] = v;
                },
                2 => {
                    const v: i32 = @as(i8, @bitCast(self.bus.read8(addr)));
                    self.r[rd] = @bitCast(v);
                },
                3 => {
                    if ((addr & 1) != 0) {
                        const v: i32 = @as(i8, @bitCast(self.bus.read8(addr)));
                        self.r[rd] = @bitCast(v);
                    } else {
                        const v: i32 = @as(i16, @bitCast(self.bus.read16(addr)));
                        self.r[rd] = @bitCast(v);
                    }
                },
                else => {},
            }
        } else {
            if (sh == 1) {
                var v = self.r[rd];
                if (rd == 15) v +%= 8;
                self.bus.write16(addr & ~@as(u32, 1), @truncate(v));
            }
        }

        if (!pre) addr = if (up) addr +% offset else addr -% offset;
        if ((!pre or writeback) and rn != 15 and !(load and rd == rn)) {
            self.r[rn] = addr;
        }

        if (load and rd == 15) {
            self.flushPipeline();
            return 1;
        }
        return if (load) 1 else 0;
    }

    fn execBlock(self: *Cpu, op: u32) u32 {
        const pre = (op & (1 << 24)) != 0;
        const up = (op & (1 << 23)) != 0;
        const psr = (op & (1 << 22)) != 0;
        const writeback = (op & (1 << 21)) != 0;
        const load = (op & (1 << 20)) != 0;
        const rn: u4 = @intCast((op >> 16) & 0x0F);
        var list: u16 = @truncate(op & 0xFFFF);

        const old_mode = self.mode();
        const force_user = psr and !(load and (list & 0x8000) != 0);
        if (force_user) self.switchMode(MODE_USER);

        var count: u32 = 0;
        {
            var bm = list;
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                if ((bm & 1) != 0) count += 1;
                bm >>= 1;
            }
        }

        const base = self.r[rn];
        var addr: u32 = 0;
        var write_back: u32 = 0;
        if (up) {
            addr = base;
            write_back = base +% (count * 4);
            if (pre) addr +%= 4;
        } else {
            addr = base -% (count * 4);
            write_back = addr;
            if (!pre) addr +%= 4;
        }

        if (list == 0) {
            list = 0x8000;
            count = 16;
            if (up) {
                addr = if (pre) base +% 4 else base;
                write_back = base +% 0x40;
            } else {
                addr = base -% 0x40;
                if (!pre) addr +%= 4;
                write_back = base -% 0x40;
            }
        }

        if (load) {
            var idx: u32 = 0;
            while (idx < 16) : (idx += 1) {
                if (((list >> @intCast(idx)) & 1) != 0) {
                    self.r[@as(u4, @intCast(idx))] = self.bus.read32(addr);
                    addr +%= 4;
                }
            }
            if (writeback and (list & (@as(u16, 1) << @intCast(rn))) == 0) {
                self.r[rn] = write_back;
            }
            if ((list & 0x8000) != 0) {
                if (psr) {
                    const sp = self.getSpsr();
                    const nm: u8 = @intCast(sp & 0x1F);
                    if (force_user) {} else {
                        self.switchMode(nm);
                        self.cpsr = sp;
                    }
                }
                self.flushPipeline();
            }
        } else {
            var idx: u32 = 0;
            var first = true;
            while (idx < 16) : (idx += 1) {
                if (((list >> @intCast(idx)) & 1) != 0) {
                    var v = self.r[@as(u4, @intCast(idx))];
                    if (idx == 15) v +%= 8;
                    if (idx == rn and !first) v = write_back;
                    self.bus.write32(addr, v);
                    addr +%= 4;
                    first = false;
                }
            }
            if (writeback) self.r[rn] = write_back;
        }

        if (force_user) {
            self.switchMode(old_mode);
        }
        return if (load) 1 else 0;
    }

    fn stepThumb(self: *Cpu) u32 {
        const pc = self.r[15];
        const op: u16 = @truncate(self.bus.read16(pc));
        self.r[15] +%= 2;

        const top: u8 = @intCast(op >> 8);
        const top5: u8 = top >> 3;
        if (top5 <= 0x02) return self.thMoveShifted(op);
        if (top5 == 0x03) return self.thAddSub(op);
        if (top5 >= 0x04 and top5 <= 0x07) return self.thImm(op);
        if (top == 0x40 or top == 0x41 or top == 0x42 or top == 0x43) return self.thAluReg(op);
        if (top == 0x44 or top == 0x45 or top == 0x46 or top == 0x47) return self.thHiReg(op);
        if (top5 == 0x09) return self.thLoadPc(op);
        if (top5 == 0x0A or top5 == 0x0B) return self.thLoadStoreReg(op);
        if (top5 >= 0x0C and top5 <= 0x0F) return self.thLoadStoreImm(op);
        if (top5 == 0x10 or top5 == 0x11) return self.thLoadStoreH(op);
        if (top5 == 0x12 or top5 == 0x13) return self.thLoadStoreSp(op);
        if (top5 == 0x14 or top5 == 0x15) return self.thLoadAddr(op);
        if (top == 0xB0) return self.thAdjustSp(op);
        if (top == 0xB4 or top == 0xB5 or top == 0xBC or top == 0xBD) return self.thPushPop(op);
        if (top5 == 0x18 or top5 == 0x19) return self.thMultLoadStore(op);
        if (top5 == 0x1A or top5 == 0x1B) {
            if ((op & 0x0F00) == 0x0F00) return self.thSwi(op);
            return self.thCondBranch(op);
        }
        if (top5 == 0x1C) return self.thBranch(op);
        if (top5 == 0x1E or top5 == 0x1F) return self.thLongBranch(op);
        return 0;
    }

    fn thMoveShifted(self: *Cpu, op: u16) u32 {
        const ty: u2 = @intCast((op >> 11) & 0x03);
        const offset: u32 = (op >> 6) & 0x1F;
        const rs: u4 = @intCast((op >> 3) & 0x07);
        const rd: u4 = @intCast(op & 0x07);
        const sh = self.shiftOp(self.r[rs], ty, offset, false);
        self.r[rd] = sh.v;
        self.cpsr = self.cpsr & ~F_C;
        if (sh.c) self.cpsr |= F_C;
        self.setNZ(sh.v);
        return 0;
    }

    fn thAddSub(self: *Cpu, op: u16) u32 {
        const imm = (op & 0x0400) != 0;
        const sub = (op & 0x0200) != 0;
        const rn_imm: u32 = (op >> 6) & 0x07;
        const rs: u4 = @intCast((op >> 3) & 0x07);
        const rd: u4 = @intCast(op & 0x07);
        const a = self.r[rs];
        const b: u32 = if (imm) rn_imm else self.r[@as(u4, @intCast(rn_imm))];
        if (sub) {
            const r = @as(u64, a) -% @as(u64, b);
            self.r[rd] = @truncate(r);
            self.setNZ(self.r[rd]);
            self.cpsr = self.cpsr & ~(F_C | F_V);
            if (a >= b) self.cpsr |= F_C;
            if (((a ^ b) & (a ^ self.r[rd]) & 0x80000000) != 0) self.cpsr |= F_V;
        } else {
            const r = @as(u64, a) + @as(u64, b);
            self.r[rd] = @truncate(r);
            self.setNZ(self.r[rd]);
            self.cpsr = self.cpsr & ~(F_C | F_V);
            if ((r >> 32) != 0) self.cpsr |= F_C;
            if ((~(a ^ b) & (a ^ self.r[rd]) & 0x80000000) != 0) self.cpsr |= F_V;
        }
        return 0;
    }

    fn thImm(self: *Cpu, op: u16) u32 {
        const oc: u2 = @intCast((op >> 11) & 0x03);
        const rd: u4 = @intCast((op >> 8) & 0x07);
        const imm: u32 = op & 0xFF;
        const a = self.r[rd];
        switch (oc) {
            0 => {
                self.r[rd] = imm;
                self.setNZ(imm);
            },
            1 => {
                const r = @as(u64, a) -% @as(u64, imm);
                const r32: u32 = @truncate(r);
                self.setNZ(r32);
                self.cpsr = self.cpsr & ~(F_C | F_V);
                if (a >= imm) self.cpsr |= F_C;
                if (((a ^ imm) & (a ^ r32) & 0x80000000) != 0) self.cpsr |= F_V;
            },
            2 => {
                const r = @as(u64, a) + @as(u64, imm);
                self.r[rd] = @truncate(r);
                self.setNZ(self.r[rd]);
                self.cpsr = self.cpsr & ~(F_C | F_V);
                if ((r >> 32) != 0) self.cpsr |= F_C;
                if ((~(a ^ imm) & (a ^ self.r[rd]) & 0x80000000) != 0) self.cpsr |= F_V;
            },
            3 => {
                const r = @as(u64, a) -% @as(u64, imm);
                self.r[rd] = @truncate(r);
                self.setNZ(self.r[rd]);
                self.cpsr = self.cpsr & ~(F_C | F_V);
                if (a >= imm) self.cpsr |= F_C;
                if (((a ^ imm) & (a ^ self.r[rd]) & 0x80000000) != 0) self.cpsr |= F_V;
            },
        }
        return 0;
    }

    fn thAluReg(self: *Cpu, op: u16) u32 {
        const oc: u4 = @intCast((op >> 6) & 0x0F);
        const rs: u4 = @intCast((op >> 3) & 0x07);
        const rd: u4 = @intCast(op & 0x07);
        const a = self.r[rd];
        const b = self.r[rs];
        switch (oc) {
            0x0 => {
                self.r[rd] = a & b;
                self.setNZ(self.r[rd]);
            },
            0x1 => {
                self.r[rd] = a ^ b;
                self.setNZ(self.r[rd]);
            },
            0x2 => {
                const sh = self.shiftOp(a, 0, b & 0xFF, true);
                self.r[rd] = sh.v;
                self.setNZ(sh.v);
                self.cpsr = self.cpsr & ~F_C;
                if (sh.c) self.cpsr |= F_C;
            },
            0x3 => {
                const sh = self.shiftOp(a, 1, b & 0xFF, true);
                self.r[rd] = sh.v;
                self.setNZ(sh.v);
                self.cpsr = self.cpsr & ~F_C;
                if (sh.c) self.cpsr |= F_C;
            },
            0x4 => {
                const sh = self.shiftOp(a, 2, b & 0xFF, true);
                self.r[rd] = sh.v;
                self.setNZ(sh.v);
                self.cpsr = self.cpsr & ~F_C;
                if (sh.c) self.cpsr |= F_C;
            },
            0x5 => {
                const c_in: u32 = if ((self.cpsr & F_C) != 0) 1 else 0;
                const r = @as(u64, a) + @as(u64, b) + c_in;
                self.r[rd] = @truncate(r);
                self.setNZ(self.r[rd]);
                self.cpsr = self.cpsr & ~(F_C | F_V);
                if ((r >> 32) != 0) self.cpsr |= F_C;
                if ((~(a ^ b) & (a ^ self.r[rd]) & 0x80000000) != 0) self.cpsr |= F_V;
            },
            0x6 => {
                const c_in: u32 = if ((self.cpsr & F_C) != 0) 1 else 0;
                const r: i64 = @as(i32, @bitCast(a)) - @as(i32, @bitCast(b)) - @as(i32, @intCast(1 - c_in));
                self.r[rd] = @bitCast(@as(i32, @truncate(r)));
                self.setNZ(self.r[rd]);
                self.cpsr = self.cpsr & ~(F_C | F_V);
                if (@as(u64, a) +% (~@as(u64, b) & 0xFFFFFFFF) +% c_in > 0xFFFFFFFF) self.cpsr |= F_C;
                if (((a ^ b) & (a ^ self.r[rd]) & 0x80000000) != 0) self.cpsr |= F_V;
            },
            0x7 => {
                const sh = self.shiftOp(a, 3, b & 0xFF, true);
                self.r[rd] = sh.v;
                self.setNZ(sh.v);
                self.cpsr = self.cpsr & ~F_C;
                if (sh.c) self.cpsr |= F_C;
            },
            0x8 => {
                const r = a & b;
                self.setNZ(r);
            },
            0x9 => {
                const r = @as(u64, 0) -% @as(u64, b);
                self.r[rd] = @truncate(r);
                self.setNZ(self.r[rd]);
                self.cpsr = self.cpsr & ~(F_C | F_V);
                if (b == 0) self.cpsr |= F_C;
                if ((b & self.r[rd] & 0x80000000) != 0) self.cpsr |= F_V;
            },
            0xA => {
                const r = @as(u64, a) -% @as(u64, b);
                const r32: u32 = @truncate(r);
                self.setNZ(r32);
                self.cpsr = self.cpsr & ~(F_C | F_V);
                if (a >= b) self.cpsr |= F_C;
                if (((a ^ b) & (a ^ r32) & 0x80000000) != 0) self.cpsr |= F_V;
            },
            0xB => {
                const r = @as(u64, a) + @as(u64, b);
                const r32: u32 = @truncate(r);
                self.setNZ(r32);
                self.cpsr = self.cpsr & ~(F_C | F_V);
                if ((r >> 32) != 0) self.cpsr |= F_C;
                if ((~(a ^ b) & (a ^ r32) & 0x80000000) != 0) self.cpsr |= F_V;
            },
            0xC => {
                self.r[rd] = a | b;
                self.setNZ(self.r[rd]);
            },
            0xD => {
                self.r[rd] = a *% b;
                self.setNZ(self.r[rd]);
            },
            0xE => {
                self.r[rd] = a & ~b;
                self.setNZ(self.r[rd]);
            },
            0xF => {
                self.r[rd] = ~b;
                self.setNZ(self.r[rd]);
            },
        }
        return switch (oc) {
            0x2, 0x3, 0x4, 0x7 => 1,
            0xD => blk: {
                const top = b & 0xFFFFFF00;
                if (top == 0 or top == 0xFFFFFF00) break :blk 1;
                const top16 = b & 0xFFFF0000;
                if (top16 == 0 or top16 == 0xFFFF0000) break :blk 2;
                const top8 = b & 0xFF000000;
                if (top8 == 0 or top8 == 0xFF000000) break :blk 3;
                break :blk 4;
            },
            else => 0,
        };
    }

    fn thHiReg(self: *Cpu, op: u16) u32 {
        const oc: u2 = @intCast((op >> 8) & 0x03);
        const h1 = (op & 0x0080) != 0;
        const h2 = (op & 0x0040) != 0;
        var rd: u4 = @intCast(op & 0x07);
        if (h1) rd = @intCast(@as(u8, rd) + 8);
        var rs: u4 = @intCast((op >> 3) & 0x07);
        if (h2) rs = @intCast(@as(u8, rs) + 8);
        var b = self.r[rs];
        if (rs == 15) b = (b +% 2) & ~@as(u32, 1);
        var a = self.r[rd];
        if (rd == 15) a +%= 2;
        switch (oc) {
            0 => {
                self.r[rd] = a +% b;
                if (rd == 15) self.flushPipeline();
            },
            1 => {
                const r = @as(u64, a) -% @as(u64, b);
                const r32: u32 = @truncate(r);
                self.setNZ(r32);
                self.cpsr = self.cpsr & ~(F_C | F_V);
                if (a >= b) self.cpsr |= F_C;
                if (((a ^ b) & (a ^ r32) & 0x80000000) != 0) self.cpsr |= F_V;
            },
            2 => {
                self.r[rd] = b;
                if (rd == 15) self.flushPipeline();
            },
            3 => {
                if ((b & 1) != 0) {
                    self.cpsr |= F_T;
                    self.r[15] = b & ~@as(u32, 1);
                } else {
                    self.cpsr &= ~F_T;
                    self.r[15] = b & ~@as(u32, 3);
                }
                if (h1) self.r[14] = (self.r[15] -% 2) | 1;
            },
        }
        return 0;
    }

    fn thLoadPc(self: *Cpu, op: u16) u32 {
        const rd: u4 = @intCast((op >> 8) & 0x07);
        const imm: u32 = (@as(u32, op & 0xFF)) << 2;
        const pc_base = (self.r[15] +% 2) & ~@as(u32, 3);
        self.r[rd] = self.bus.read32(pc_base +% imm);
        return 1;
    }

    fn thLoadStoreReg(self: *Cpu, op: u16) u32 {
        const oc: u2 = @intCast((op >> 10) & 0x03);
        const ro: u4 = @intCast((op >> 6) & 0x07);
        const rb: u4 = @intCast((op >> 3) & 0x07);
        const rd: u4 = @intCast(op & 0x07);
        const addr = self.r[rb] +% self.r[ro];
        const top10 = (op >> 9) & 1;
        var is_load: bool = false;
        if (top10 == 0) {
            switch (oc) {
                0 => self.bus.write32(addr & ~@as(u32, 3), self.r[rd]),
                1 => self.bus.write8(addr, @truncate(self.r[rd])),
                2 => {
                    self.r[rd] = std.math.rotr(u32, self.bus.read32(addr & ~@as(u32, 3)), @as(u5, @intCast((addr & 3) * 8)));
                    is_load = true;
                },
                3 => {
                    self.r[rd] = self.bus.read8(addr);
                    is_load = true;
                },
            }
        } else {
            is_load = oc != 0;
            switch (oc) {
                0 => self.bus.write16(addr & ~@as(u32, 1), @truncate(self.r[rd])),
                1 => {
                    const v: i32 = @as(i8, @bitCast(self.bus.read8(addr)));
                    self.r[rd] = @bitCast(v);
                },
                2 => {
                    const aligned = addr & ~@as(u32, 1);
                    var v: u32 = self.bus.read16(aligned);
                    if ((addr & 1) != 0) v = std.math.rotr(u32, v, 8);
                    self.r[rd] = v;
                },
                3 => {
                    if ((addr & 1) != 0) {
                        const v: i32 = @as(i8, @bitCast(self.bus.read8(addr)));
                        self.r[rd] = @bitCast(v);
                    } else {
                        const v: i32 = @as(i16, @bitCast(self.bus.read16(addr)));
                        self.r[rd] = @bitCast(v);
                    }
                },
            }
        }
        return if (is_load) 1 else 0;
    }

    fn thLoadStoreImm(self: *Cpu, op: u16) u32 {
        const byte = (op & 0x1000) != 0;
        const load = (op & 0x0800) != 0;
        const offset5: u32 = (op >> 6) & 0x1F;
        const rb: u4 = @intCast((op >> 3) & 0x07);
        const rd: u4 = @intCast(op & 0x07);
        if (byte) {
            const addr = self.r[rb] +% offset5;
            if (load) {
                self.r[rd] = self.bus.read8(addr);
            } else {
                self.bus.write8(addr, @truncate(self.r[rd]));
            }
        } else {
            const addr = self.r[rb] +% (offset5 << 2);
            if (load) {
                self.r[rd] = std.math.rotr(u32, self.bus.read32(addr & ~@as(u32, 3)), @as(u5, @intCast((addr & 3) * 8)));
            } else {
                self.bus.write32(addr & ~@as(u32, 3), self.r[rd]);
            }
        }
        return if (load) 1 else 0;
    }

    fn thLoadStoreH(self: *Cpu, op: u16) u32 {
        const load = (op & 0x0800) != 0;
        const offset5: u32 = (op >> 6) & 0x1F;
        const rb: u4 = @intCast((op >> 3) & 0x07);
        const rd: u4 = @intCast(op & 0x07);
        const addr = self.r[rb] +% (offset5 << 1);
        if (load) {
            const aligned = addr & ~@as(u32, 1);
            var v: u32 = self.bus.read16(aligned);
            if ((addr & 1) != 0) v = std.math.rotr(u32, v, 8);
            self.r[rd] = v;
        } else {
            self.bus.write16(addr & ~@as(u32, 1), @truncate(self.r[rd]));
        }
        return if (load) 1 else 0;
    }

    fn thLoadStoreSp(self: *Cpu, op: u16) u32 {
        const load = (op & 0x0800) != 0;
        const rd: u4 = @intCast((op >> 8) & 0x07);
        const offset: u32 = (@as(u32, op & 0xFF)) << 2;
        const addr = self.r[13] +% offset;
        if (load) {
            self.r[rd] = std.math.rotr(u32, self.bus.read32(addr & ~@as(u32, 3)), @as(u5, @intCast((addr & 3) * 8)));
        } else {
            self.bus.write32(addr & ~@as(u32, 3), self.r[rd]);
        }
        return if (load) 1 else 0;
    }

    fn thLoadAddr(self: *Cpu, op: u16) u32 {
        const sp_based = (op & 0x0800) != 0;
        const rd: u4 = @intCast((op >> 8) & 0x07);
        const offset: u32 = (@as(u32, op & 0xFF)) << 2;
        if (sp_based) {
            self.r[rd] = self.r[13] +% offset;
        } else {
            self.r[rd] = ((self.r[15] +% 2) & ~@as(u32, 3)) +% offset;
        }
        return 0;
    }

    fn thAdjustSp(self: *Cpu, op: u16) u32 {
        const sub = (op & 0x0080) != 0;
        const offset: u32 = (@as(u32, op & 0x7F)) << 2;
        if (sub) self.r[13] -%= offset else self.r[13] +%= offset;
        return 0;
    }

    fn thPushPop(self: *Cpu, op: u16) u32 {
        const load = (op & 0x0800) != 0;
        const r_bit = (op & 0x0100) != 0;
        var list: u16 = op & 0xFF;
        if (r_bit) list |= if (load) 0x8000 else 0x4000;
        var count: u32 = 0;
        {
            var t = list;
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                if ((t & 1) != 0) count += 1;
                t >>= 1;
            }
        }
        if (load) {
            var addr = self.r[13];
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                if (((list >> @intCast(i)) & 1) != 0) {
                    self.r[@as(u4, @intCast(i))] = self.bus.read32(addr);
                    addr +%= 4;
                }
            }
            self.r[13] = addr;
            if (r_bit) {
                if ((self.r[15] & 1) != 0) {
                    self.cpsr |= F_T;
                    self.r[15] &= ~@as(u32, 1);
                } else {
                    self.cpsr &= ~F_T;
                    self.r[15] &= ~@as(u32, 3);
                }
                self.flushPipeline();
            }
        } else {
            var addr = self.r[13] -% (count * 4);
            self.r[13] = addr;
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                if (((list >> @intCast(i)) & 1) != 0) {
                    self.bus.write32(addr, self.r[@as(u4, @intCast(i))]);
                    addr +%= 4;
                }
            }
        }
        return if (load) 1 else 0;
    }

    fn thMultLoadStore(self: *Cpu, op: u16) u32 {
        const load = (op & 0x0800) != 0;
        const rb: u4 = @intCast((op >> 8) & 0x07);
        const list: u16 = op & 0xFF;
        if (list == 0) {
            if (load) {
                self.r[15] = self.bus.read32(self.r[rb]);
                self.flushPipeline();
            } else {
                self.bus.write32(self.r[rb], self.r[15] +% 4);
            }
            self.r[rb] +%= 0x40;
            return if (load) 1 else 0;
        }
        var addr = self.r[rb];
        var count: u32 = 0;
        {
            var t = list;
            var i: u32 = 0;
            while (i < 8) : (i += 1) {
                if ((t & 1) != 0) count += 1;
                t >>= 1;
            }
        }
        const wb_val = addr +% (count * 4);
        if (load) {
            var i: u32 = 0;
            while (i < 8) : (i += 1) {
                if (((list >> @intCast(i)) & 1) != 0) {
                    self.r[@as(u4, @intCast(i))] = self.bus.read32(addr);
                    addr +%= 4;
                }
            }
            if ((list & (@as(u16, 1) << @intCast(rb))) == 0) self.r[rb] = wb_val;
        } else {
            var i: u32 = 0;
            var first = true;
            while (i < 8) : (i += 1) {
                if (((list >> @intCast(i)) & 1) != 0) {
                    const r_idx: u4 = @intCast(i);
                    var v = self.r[r_idx];
                    if (r_idx == rb and !first) v = wb_val;
                    self.bus.write32(addr, v);
                    addr +%= 4;
                    first = false;
                }
            }
            self.r[rb] = wb_val;
        }
        return if (load) 1 else 0;
    }

    fn thCondBranch(self: *Cpu, op: u16) u32 {
        const cond: u4 = @intCast((op >> 8) & 0x0F);
        if (!self.condCheck(cond)) return 0;
        var off: i32 = @as(i8, @bitCast(@as(u8, @truncate(op & 0xFF))));
        off <<= 1;
        self.r[15] = self.r[15] +% 2 +% @as(u32, @bitCast(off));
        self.flushPipeline();
        return 0;
    }

    fn thSwi(self: *Cpu, op: u16) u32 {
        _ = op;
        const old_cpsr = self.cpsr;
        const ret_pc = self.r[15];
        self.switchMode(MODE_SVC);
        self.spsr_svc = old_cpsr;
        self.r[14] = ret_pc;
        self.cpsr = (self.cpsr & ~F_T) | F_I;
        self.r[15] = 0x08;
        return 0;
    }

    fn thBranch(self: *Cpu, op: u16) u32 {
        var off: i32 = @intCast(op & 0x07FF);
        if ((off & 0x0400) != 0) off |= @as(i32, @bitCast(@as(u32, 0xFFFFF800)));
        off <<= 1;
        self.r[15] = self.r[15] +% 2 +% @as(u32, @bitCast(off));
        self.flushPipeline();
        return 0;
    }

    fn thLongBranch(self: *Cpu, op: u16) u32 {
        const high = (op & 0x0800) == 0;
        const off: u32 = op & 0x07FF;
        if (high) {
            var sext: u32 = off << 12;
            if ((sext & 0x00400000) != 0) sext |= 0xFF800000;
            self.r[14] = self.r[15] +% 2 +% sext;
            return 0;
        }
        const target = self.r[14] +% (off << 1);
        self.r[14] = (self.r[15]) | 1;
        self.r[15] = target & ~@as(u32, 1);
        self.flushPipeline();
        return 0;
    }
};
