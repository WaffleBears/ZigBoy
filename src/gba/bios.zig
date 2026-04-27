const std = @import("std");
const Cpu = @import("arm.zig").Cpu;
const Bus = @import("bus.zig").Bus;

pub fn handleSwi(cpu: *Cpu, bus: *Bus, num: u8) bool {
    switch (num) {
        0x00 => return softReset(cpu, bus),
        0x01 => return registerRamReset(cpu, bus),
        0x02 => {
            cpu.halted = true;
            bus.halted = true;
            return true;
        },
        0x03 => {
            cpu.halted = true;
            bus.halted = true;
            return true;
        },
        0x04 => return intrWait(cpu, bus),
        0x05 => return vBlankIntrWait(cpu, bus),
        0x06 => return divFn(cpu),
        0x07 => return divArm(cpu),
        0x08 => return sqrtFn(cpu),
        0x09 => return arcTan(cpu),
        0x0A => return arcTan2(cpu),
        0x0B => return cpuSet(cpu, bus),
        0x0C => return cpuFastSet(cpu, bus),
        0x0D => return getBiosChecksum(cpu),
        0x0E => return bgAffineSet(cpu, bus),
        0x0F => return objAffineSet(cpu, bus),
        0x10 => return bitUnPack(cpu, bus),
        0x11 => return lz77UnComp(cpu, bus, false),
        0x12 => return lz77UnComp(cpu, bus, true),
        0x13 => return huffUnComp(cpu, bus),
        0x14 => return rlUnComp(cpu, bus, false),
        0x15 => return rlUnComp(cpu, bus, true),
        0x16 => return diff8bitUnFilter(cpu, bus, false),
        0x17 => return diff8bitUnFilter(cpu, bus, true),
        0x18 => return diff16bitUnFilter(cpu, bus),
        0x1F => return midiKey2Freq(cpu, bus),
        else => return true,
    }
}

fn getBiosChecksum(cpu: *Cpu) bool {
    cpu.r[0] = 0xBAAE187F;
    return true;
}

fn bitUnPack(cpu: *Cpu, bus: *Bus) bool {
    var src = cpu.r[0];
    var dst = cpu.r[1];
    const info = cpu.r[2];
    const length: u32 = bus.read16(info);
    const src_width: u8 = bus.read8(info +% 2);
    const dst_width: u8 = bus.read8(info +% 3);
    const offset_word: u32 = bus.read32(info +% 4);
    const data_offset: u32 = offset_word & 0x7FFFFFFF;
    const zero_offset = (offset_word & 0x80000000) != 0;

    if (src_width == 0 or dst_width == 0) return true;
    if (src_width != 1 and src_width != 2 and src_width != 4 and src_width != 8) return true;
    if (dst_width != 1 and dst_width != 2 and dst_width != 4 and dst_width != 8 and dst_width != 16 and dst_width != 32) return true;

    var dst_buf: u32 = 0;
    var dst_bits: u32 = 0;
    var src_byte: u32 = 0;
    var src_bits: u32 = 0;
    var remaining = length;
    while (remaining > 0) : (remaining -%= 1) {
        if (src_bits == 0) {
            src_byte = bus.read8(src);
            src +%= 1;
            src_bits = 8;
        }
        const mask: u32 = (@as(u32, 1) << @intCast(src_width)) -% 1;
        const unit = src_byte & mask;
        src_byte >>= @intCast(src_width);
        src_bits -%= src_width;

        var out: u32 = unit;
        if (out != 0 or zero_offset) out +%= data_offset;
        out &= (@as(u32, 1) << @intCast(@as(u32, dst_width) - 1) << 1) -% 1;

        dst_buf |= out << @intCast(dst_bits);
        dst_bits += dst_width;
        if (dst_bits >= 32) {
            bus.write32(dst, dst_buf);
            dst +%= 4;
            dst_buf = 0;
            dst_bits = 0;
        }
    }
    if (dst_bits > 0) {
        bus.write32(dst, dst_buf);
    }
    return true;
}

fn diff8bitUnFilter(cpu: *Cpu, bus: *Bus, vram: bool) bool {
    var src = cpu.r[0];
    var dst = cpu.r[1];
    const header = bus.read32(src);
    src +%= 4;
    const total: u32 = header >> 8;
    if (total == 0) return true;
    var prev: u8 = bus.read8(src);
    src +%= 1;
    if (vram) {
        var pair_low: u8 = prev;
        var pair_have_lo = true;
        var written: u32 = 1;
        while (written < total) : (written += 1) {
            const diff = bus.read8(src);
            src +%= 1;
            prev = prev +% diff;
            if (pair_have_lo) {
                const pair: u16 = @as(u16, pair_low) | (@as(u16, prev) << 8);
                bus.write16(dst, pair);
                dst +%= 2;
                pair_have_lo = false;
            } else {
                pair_low = prev;
                pair_have_lo = true;
            }
        }
        if (pair_have_lo) {
            bus.write16(dst, pair_low);
        }
    } else {
        bus.write8(dst, prev);
        dst +%= 1;
        var written: u32 = 1;
        while (written < total) : (written += 1) {
            const diff = bus.read8(src);
            src +%= 1;
            prev = prev +% diff;
            bus.write8(dst, prev);
            dst +%= 1;
        }
    }
    return true;
}

fn diff16bitUnFilter(cpu: *Cpu, bus: *Bus) bool {
    var src = cpu.r[0];
    var dst = cpu.r[1];
    const header = bus.read32(src);
    src +%= 4;
    const total_bytes: u32 = header >> 8;
    const total_words: u32 = total_bytes / 2;
    var prev: u16 = bus.read16(src);
    src +%= 2;
    bus.write16(dst, prev);
    dst +%= 2;
    var i: u32 = 1;
    while (i < total_words) : (i += 1) {
        const diff = bus.read16(src);
        src +%= 2;
        prev = prev +% diff;
        bus.write16(dst, prev);
        dst +%= 2;
    }
    return true;
}

fn softReset(cpu: *Cpu, bus: *Bus) bool {
    _ = bus;
    cpu.r[0] = 0;
    cpu.r[1] = 0;
    cpu.r[2] = 0;
    cpu.r[3] = 0;
    cpu.r[12] = 0;
    cpu.r_svc_sp_lr[0] = 0x03007FE0;
    cpu.r_irq_sp_lr[0] = 0x03007FA0;
    cpu.r[13] = 0x03007F00;
    cpu.r[14] = 0x08000000;
    cpu.cpsr = 0x1F;
    cpu.r[15] = 0x08000000;
    return true;
}

fn registerRamReset(cpu: *Cpu, bus: *Bus) bool {
    const flags: u32 = cpu.r[0];
    if ((flags & 0x01) != 0) @memset(&bus.ewram, 0);
    if ((flags & 0x02) != 0) {
        var i: usize = 0;
        while (i < 0x7E00) : (i += 1) bus.iwram[i] = 0;
    }
    if ((flags & 0x04) != 0) @memset(&bus.ppu.pram, 0);
    if ((flags & 0x08) != 0) @memset(&bus.ppu.vram, 0);
    if ((flags & 0x10) != 0) @memset(&bus.ppu.oam, 0);
    if ((flags & 0x20) != 0) {
        bus.ppu.dispcnt = 0x0080;
        bus.ppu.dispstat = 0;
    }
    if ((flags & 0x40) != 0) bus.apu.reset();
    return true;
}

fn intrWait(cpu: *Cpu, bus: *Bus) bool {
    const discard_old = (cpu.r[0] & 1) != 0;
    const wanted: u16 = @truncate(cpu.r[1]);
    if (discard_old) {
        bus.iwram[0x7FF8] = 0;
        bus.iwram[0x7FF9] = 0;
    }
    const flag = @as(u16, bus.iwram[0x7FF8]) | (@as(u16, bus.iwram[0x7FF9]) << 8);
    if ((flag & wanted) != 0) {
        const matched = flag & wanted;
        const cleared = flag & ~wanted;
        bus.iwram[0x7FF8] = @truncate(cleared);
        bus.iwram[0x7FF9] = @truncate(cleared >> 8);
        bus.irq.ifr &= ~matched;
        return true;
    }
    cpu.halted = true;
    bus.halted = true;
    cpu.cpsr &= ~@as(u32, 0x80);
    const back: u32 = if ((cpu.spsr_svc & 0x20) != 0) 2 else 4;
    cpu.r[14] -%= back;
    return true;
}

fn vBlankIntrWait(cpu: *Cpu, bus: *Bus) bool {
    cpu.r[0] = 1;
    cpu.r[1] = 1;
    return intrWait(cpu, bus);
}

fn divFn(cpu: *Cpu) bool {
    const num: i32 = @bitCast(cpu.r[0]);
    const den: i32 = @bitCast(cpu.r[1]);
    if (den == 0) return true;
    if (num == std.math.minInt(i32) and den == -1) {
        cpu.r[0] = @bitCast(num);
        cpu.r[1] = 0;
        cpu.r[3] = 0x80000000;
        return true;
    }
    const q = @divTrunc(num, den);
    const m = @rem(num, den);
    cpu.r[0] = @bitCast(q);
    cpu.r[1] = @bitCast(m);
    const aq: u32 = @intCast(@as(i64, @abs(q)));
    cpu.r[3] = aq;
    return true;
}

fn divArm(cpu: *Cpu) bool {
    const tmp = cpu.r[0];
    cpu.r[0] = cpu.r[1];
    cpu.r[1] = tmp;
    return divFn(cpu);
}

fn sqrtFn(cpu: *Cpu) bool {
    const v: u32 = cpu.r[0];
    if (v == 0) {
        cpu.r[0] = 0;
        return true;
    }
    var lo: u32 = 0;
    var hi: u32 = 0xFFFF;
    while (lo < hi) {
        const mid: u32 = @intCast((@as(u64, lo) + @as(u64, hi) + 1) / 2);
        const mid64: u64 = mid;
        if (mid64 *% mid64 <= v) lo = mid else hi = mid -% 1;
    }
    cpu.r[0] = lo;
    return true;
}

fn arcTan(cpu: *Cpu) bool {
    const x: i32 = @bitCast(cpu.r[0]);
    const xf: f64 = @as(f64, @floatFromInt(x)) / 16384.0;
    const r = @import("std").math.atan(xf);
    const out: i32 = @intFromFloat(r * 16384.0);
    cpu.r[0] = @bitCast(out);
    return true;
}

fn arcTan2(cpu: *Cpu) bool {
    const x: i32 = @bitCast(cpu.r[0]);
    const y: i32 = @bitCast(cpu.r[1]);
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const r = @import("std").math.atan2(yf, xf);
    var brad = r * 32768.0 / @import("std").math.pi;
    if (brad < 0) brad += 65536.0;
    const out: u32 = @intFromFloat(brad);
    cpu.r[0] = out & 0xFFFF;
    return true;
}

fn cpuSet(cpu: *Cpu, bus: *Bus) bool {
    var src: u32 = cpu.r[0];
    var dst: u32 = cpu.r[1];
    const ctl: u32 = cpu.r[2];
    const count: u32 = ctl & 0x1FFFFF;
    const fixed = (ctl & 0x01000000) != 0;
    const word = (ctl & 0x04000000) != 0;
    if (count == 0) return true;
    if (word) {
        src &= ~@as(u32, 3);
        dst &= ~@as(u32, 3);
        const v_first = bus.read32(src);
        var i: u32 = 0;
        var v = v_first;
        while (i < count) : (i += 1) {
            if (!fixed) v = bus.read32(src);
            bus.write32(dst, v);
            dst +%= 4;
            if (!fixed) src +%= 4;
        }
    } else {
        src &= ~@as(u32, 1);
        dst &= ~@as(u32, 1);
        const v_first = bus.read16(src);
        var i: u32 = 0;
        var v = v_first;
        while (i < count) : (i += 1) {
            if (!fixed) v = bus.read16(src);
            bus.write16(dst, v);
            dst +%= 2;
            if (!fixed) src +%= 2;
        }
    }
    return true;
}

fn cpuFastSet(cpu: *Cpu, bus: *Bus) bool {
    var src: u32 = cpu.r[0] & ~@as(u32, 3);
    var dst: u32 = cpu.r[1] & ~@as(u32, 3);
    const ctl: u32 = cpu.r[2];
    var count: u32 = ctl & 0x1FFFFF;
    const fixed = (ctl & 0x01000000) != 0;
    if (count == 0) return true;
    count = (count +% 7) & ~@as(u32, 7);
    var v = bus.read32(src);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (!fixed) v = bus.read32(src);
        bus.write32(dst, v);
        dst +%= 4;
        if (!fixed) src +%= 4;
    }
    return true;
}

fn bgAffineSet(cpu: *Cpu, bus: *Bus) bool {
    var src = cpu.r[0];
    var dst = cpu.r[1];
    const num = cpu.r[2];
    var i: u32 = 0;
    while (i < num) : (i += 1) {
        const cx: i32 = @bitCast(bus.read32(src));
        const cy: i32 = @bitCast(bus.read32(src +% 4));
        const dx: i16 = @bitCast(bus.read16(src +% 8));
        const dy: i16 = @bitCast(bus.read16(src +% 10));
        const sx: i16 = @bitCast(bus.read16(src +% 12));
        const sy: i16 = @bitCast(bus.read16(src +% 14));
        const theta: u16 = bus.read16(src +% 16);
        const t: f32 = @as(f32, @floatFromInt(theta)) * 2.0 * @import("std").math.pi / 65536.0;
        const cos_v = @cos(t);
        const sin_v = @sin(t);
        const sx_f: f32 = @as(f32, @floatFromInt(sx)) / 256.0;
        const sy_f: f32 = @as(f32, @floatFromInt(sy)) / 256.0;
        const pa: i16 = @intFromFloat(cos_v * sx_f * 256.0);
        const pb: i16 = @intFromFloat(-sin_v * sx_f * 256.0);
        const pc: i16 = @intFromFloat(sin_v * sy_f * 256.0);
        const pd: i16 = @intFromFloat(cos_v * sy_f * 256.0);
        const ref_x: i32 = cx -% (@as(i32, pa) *% @as(i32, dx) +% @as(i32, pb) *% @as(i32, dy));
        const ref_y: i32 = cy -% (@as(i32, pc) *% @as(i32, dx) +% @as(i32, pd) *% @as(i32, dy));
        bus.write16(dst, @bitCast(pa));
        bus.write16(dst +% 2, @bitCast(pb));
        bus.write16(dst +% 4, @bitCast(pc));
        bus.write16(dst +% 6, @bitCast(pd));
        bus.write32(dst +% 8, @bitCast(ref_x));
        bus.write32(dst +% 12, @bitCast(ref_y));
        src +%= 20;
        dst +%= 16;
    }
    return true;
}

fn objAffineSet(cpu: *Cpu, bus: *Bus) bool {
    var src = cpu.r[0];
    var dst = cpu.r[1];
    const num = cpu.r[2];
    const stride = cpu.r[3];
    var i: u32 = 0;
    while (i < num) : (i += 1) {
        const sx: i16 = @bitCast(bus.read16(src));
        const sy: i16 = @bitCast(bus.read16(src +% 2));
        const theta: u16 = bus.read16(src +% 4);
        const t: f32 = @as(f32, @floatFromInt(theta)) * 2.0 * @import("std").math.pi / 65536.0;
        const cos_v = @cos(t);
        const sin_v = @sin(t);
        const sx_f: f32 = @as(f32, @floatFromInt(sx)) / 256.0;
        const sy_f: f32 = @as(f32, @floatFromInt(sy)) / 256.0;
        const pa: i16 = @intFromFloat(cos_v * sx_f * 256.0);
        const pb: i16 = @intFromFloat(-sin_v * sx_f * 256.0);
        const pc: i16 = @intFromFloat(sin_v * sy_f * 256.0);
        const pd: i16 = @intFromFloat(cos_v * sy_f * 256.0);
        bus.write16(dst, @bitCast(pa));
        bus.write16(dst +% stride, @bitCast(pb));
        bus.write16(dst +% (stride *% 2), @bitCast(pc));
        bus.write16(dst +% (stride *% 3), @bitCast(pd));
        src +%= 8;
        dst +%= stride *% 4;
    }
    return true;
}

fn lz77UnComp(cpu: *Cpu, bus: *Bus, vram: bool) bool {
    var src: u32 = cpu.r[0];
    var dst: u32 = cpu.r[1];
    const header = bus.read32(src);
    src +%= 4;
    const total_size = header >> 8;
    var written: u32 = 0;
    while (written < total_size) {
        const flags = bus.read8(src);
        src +%= 1;
        var i: u32 = 0;
        while (i < 8 and written < total_size) : (i += 1) {
            if (((flags >> @intCast(7 - i)) & 1) != 0) {
                const b1 = bus.read8(src);
                const b2 = bus.read8(src +% 1);
                src +%= 2;
                const length: u32 = ((b1 >> 4) & 0x0F) + 3;
                const back: u32 = ((@as(u32, b1) & 0x0F) << 8) | b2;
                var k: u32 = 0;
                while (k < length and written < total_size) : (k += 1) {
                    const b = bus.read8(dst -% back -% 1);
                    if (vram) {
                        if ((written & 1) == 0) {
                            bus.write16(dst, b);
                        } else {
                            const cur = bus.read8(dst -% 1);
                            bus.write16(dst -% 1, @as(u16, cur) | (@as(u16, b) << 8));
                        }
                    } else {
                        bus.write8(dst, b);
                    }
                    dst +%= 1;
                    written += 1;
                }
            } else {
                const b = bus.read8(src);
                src +%= 1;
                if (vram) {
                    if ((written & 1) == 0) {
                        bus.write16(dst, b);
                    } else {
                        const cur = bus.read8(dst -% 1);
                        bus.write16(dst -% 1, @as(u16, cur) | (@as(u16, b) << 8));
                    }
                } else {
                    bus.write8(dst, b);
                }
                dst +%= 1;
                written += 1;
            }
        }
    }
    return true;
}

fn rlUnComp(cpu: *Cpu, bus: *Bus, vram: bool) bool {
    var src = cpu.r[0];
    var dst = cpu.r[1];
    const header = bus.read32(src);
    src +%= 4;
    const total = header >> 8;
    var written: u32 = 0;
    while (written < total) {
        const flag = bus.read8(src);
        src +%= 1;
        if ((flag & 0x80) != 0) {
            const length: u32 = (flag & 0x7F) + 3;
            const v = bus.read8(src);
            src +%= 1;
            var i: u32 = 0;
            while (i < length and written < total) : (i += 1) {
                if (vram) {
                    if ((written & 1) == 0) bus.write16(dst, v) else {
                        const cur = bus.read8(dst -% 1);
                        bus.write16(dst -% 1, @as(u16, cur) | (@as(u16, v) << 8));
                    }
                } else {
                    bus.write8(dst, v);
                }
                dst +%= 1;
                written += 1;
            }
        } else {
            const length: u32 = (flag & 0x7F) + 1;
            var i: u32 = 0;
            while (i < length and written < total) : (i += 1) {
                const v = bus.read8(src);
                src +%= 1;
                if (vram) {
                    if ((written & 1) == 0) bus.write16(dst, v) else {
                        const cur = bus.read8(dst -% 1);
                        bus.write16(dst -% 1, @as(u16, cur) | (@as(u16, v) << 8));
                    }
                } else {
                    bus.write8(dst, v);
                }
                dst +%= 1;
                written += 1;
            }
        }
    }
    return true;
}

fn huffUnComp(cpu: *Cpu, bus: *Bus) bool {
    var src = cpu.r[0];
    var dst = cpu.r[1];
    const header = bus.read32(src);
    src +%= 4;
    const data_size: u32 = (header >> 4) & 0x0F;
    const total: u32 = header >> 8;
    const tree_size: u32 = (@as(u32, bus.read8(src)) +% 1) *% 2;
    const tree_base = src;
    src +%= tree_size;

    var bitbuf: u32 = 0;
    var bits_left: u32 = 0;
    var written: u32 = 0;
    var word_buf: u32 = 0;
    var word_bits: u32 = 0;
    while (written < total) {
        var node_off: u32 = 0;
        var node = bus.read8(tree_base +% 1);
        while (true) {
            if (bits_left == 0) {
                bitbuf = bus.read32(src);
                src +%= 4;
                bits_left = 32;
            }
            const bit: u32 = (bitbuf >> 31) & 1;
            bitbuf <<= 1;
            bits_left -= 1;
            const next_off = (@as(u32, (node & 0x3F)) +% 1) *% 2;
            node_off = (node_off & ~@as(u32, 1)) +% next_off +% bit;
            const leaf_flag: u8 = if (bit == 0) 0x80 else 0x40;
            const is_leaf = (node & leaf_flag) != 0;
            node = bus.read8(tree_base +% node_off);
            if (is_leaf) {
                const sym = node;
                if (data_size == 8) {
                    bus.write8(dst, sym);
                    dst +%= 1;
                    written += 1;
                } else {
                    word_buf |= @as(u32, sym & 0x0F) << @intCast(word_bits);
                    word_bits += 4;
                    if (word_bits >= 32) {
                        bus.write32(dst, word_buf);
                        dst +%= 4;
                        word_buf = 0;
                        word_bits = 0;
                    }
                    written += 1;
                }
                break;
            }
        }
    }
    return true;
}

fn midiKey2Freq(cpu: *Cpu, bus: *Bus) bool {
    const ws = cpu.r[0];
    const mk: u8 = @truncate(cpu.r[1]);
    const fp: u8 = @truncate(cpu.r[2]);
    const freq = bus.read32(ws + 4);
    const exp_part: f32 = (@as(f32, 180) - @as(f32, @floatFromInt(mk)) - @as(f32, @floatFromInt(fp)) / 256.0) / 12.0;
    const result = @as(f32, @floatFromInt(freq)) / @import("std").math.pow(f32, 2.0, exp_part);
    cpu.r[0] = @intFromFloat(result);
    return true;
}
