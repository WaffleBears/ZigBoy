const Irq = @import("irq.zig").Irq;

pub const DmaChannel = struct {
    sad: u32 = 0,
    dad: u32 = 0,
    cnt_l: u16 = 0,
    cnt_h: u16 = 0,
    sad_internal: u32 = 0,
    dad_internal: u32 = 0,
    word_count: u32 = 0,
    enabled: bool = false,
};

pub const Dma = struct {
    ch: [4]DmaChannel = [_]DmaChannel{.{}} ** 4,
    pending_cycles: u32 = 0,
    irq: *Irq,
    bus_ptr: ?*anyopaque = null,
    read32_fn: ?*const fn (ctx: *anyopaque, addr: u32) u32 = null,
    read16_fn: ?*const fn (ctx: *anyopaque, addr: u32) u16 = null,
    write32_fn: ?*const fn (ctx: *anyopaque, addr: u32, v: u32) void = null,
    write16_fn: ?*const fn (ctx: *anyopaque, addr: u32, v: u16) void = null,
    eeprom_ctx: ?*anyopaque = null,
    eeprom_notify_fn: ?*const fn (ctx: *anyopaque, word_count: u32) void = null,

    pub fn init(irq: *Irq) Dma {
        return .{ .irq = irq };
    }

    pub fn reset(self: *Dma) void {
        var i: usize = 0;
        while (i < 4) : (i += 1) self.ch[i] = .{};
        self.pending_cycles = 0;
    }

    pub fn drainPendingCycles(self: *Dma) u32 {
        const c = self.pending_cycles;
        self.pending_cycles = 0;
        return c;
    }

    pub fn writeCnt(self: *Dma, idx: usize, v: u16) u32 {
        const c = &self.ch[idx];
        const was_enabled = c.enabled;
        c.cnt_h = v;
        c.enabled = (v & 0x8000) != 0;
        if (c.enabled and !was_enabled) {
            c.sad_internal = c.sad & srcMask(idx);
            c.dad_internal = c.dad & dstMask(idx);
            c.word_count = wordCount(c, idx);
            const start_timing = (v >> 12) & 3;
            if (start_timing == 0) return self.run(idx);
        }
        return 0;
    }

    pub fn triggerVBlank(self: *Dma) u32 {
        var total: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const c = &self.ch[i];
            if (c.enabled and ((c.cnt_h >> 12) & 3) == 1) total += self.run(i);
        }
        return total;
    }

    pub fn triggerHBlank(self: *Dma) u32 {
        var total: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const c = &self.ch[i];
            if (c.enabled and ((c.cnt_h >> 12) & 3) == 2) total += self.run(i);
        }
        return total;
    }

    pub fn triggerFifoA(self: *Dma) u32 {
        var total: u32 = 0;
        if (self.ch[1].enabled and ((self.ch[1].cnt_h >> 12) & 3) == 3 and self.ch[1].dad == 0x040000A0) total += self.runFifo(1);
        if (self.ch[2].enabled and ((self.ch[2].cnt_h >> 12) & 3) == 3 and self.ch[2].dad == 0x040000A0) total += self.runFifo(2);
        return total;
    }

    pub fn triggerFifoB(self: *Dma) u32 {
        var total: u32 = 0;
        if (self.ch[1].enabled and ((self.ch[1].cnt_h >> 12) & 3) == 3 and self.ch[1].dad == 0x040000A4) total += self.runFifo(1);
        if (self.ch[2].enabled and ((self.ch[2].cnt_h >> 12) & 3) == 3 and self.ch[2].dad == 0x040000A4) total += self.runFifo(2);
        return total;
    }

    fn srcMask(idx: usize) u32 {
        return if (idx == 0) 0x07FFFFFF else 0x0FFFFFFF;
    }

    fn dstMask(idx: usize) u32 {
        return if (idx == 3) 0x0FFFFFFF else 0x07FFFFFF;
    }

    fn wordCount(c: *DmaChannel, idx: usize) u32 {
        var n: u32 = c.cnt_l;
        if (idx == 3) {
            if (n == 0) n = 0x10000;
        } else {
            n &= 0x3FFF;
            if (n == 0) n = 0x4000;
        }
        return n;
    }

    fn srcInc(c: *const DmaChannel) i32 {
        const dir: u32 = (c.cnt_h >> 7) & 3;
        const word = (c.cnt_h & 0x0400) != 0;
        const step: i32 = if (word) 4 else 2;
        return switch (dir) {
            0 => step,
            1 => -step,
            2 => 0,
            else => step,
        };
    }

    fn dstInc(c: *const DmaChannel) i32 {
        const dir: u32 = (c.cnt_h >> 5) & 3;
        const word = (c.cnt_h & 0x0400) != 0;
        const step: i32 = if (word) 4 else 2;
        return switch (dir) {
            0 => step,
            1 => -step,
            2 => 0,
            3 => step,
            else => step,
        };
    }

    pub fn run(self: *Dma, idx: usize) u32 {
        const c = &self.ch[idx];
        const word = (c.cnt_h & 0x0400) != 0;
        const irq_at_end = (c.cnt_h & 0x4000) != 0;
        const repeat = (c.cnt_h & 0x0200) != 0;
        const dst_dir: u32 = (c.cnt_h >> 5) & 3;
        const src_step = srcInc(c);
        const dst_step = dstInc(c);

        var src: u32 = c.sad_internal;
        var dst: u32 = c.dad_internal;
        var n = c.word_count;
        const total_words = n;

        if (idx == 3 and ((dst & 0xFF000000) == 0x0D000000 or (src & 0xFF000000) == 0x0D000000)) {
            if (self.eeprom_notify_fn) |notify| {
                if (self.eeprom_ctx) |ctx2| notify(ctx2, n);
            }
        }

        const r32 = self.read32_fn.?;
        const r16 = self.read16_fn.?;
        const w32 = self.write32_fn.?;
        const w16 = self.write16_fn.?;
        const ctx = self.bus_ptr.?;

        while (n > 0) : (n -= 1) {
            if (word) {
                const v = r32(ctx, src);
                w32(ctx, dst, v);
            } else {
                const v = r16(ctx, src);
                w16(ctx, dst, v);
            }
            src = @bitCast(@as(i32, @bitCast(src)) +% src_step);
            dst = @bitCast(@as(i32, @bitCast(dst)) +% dst_step);
        }
        c.sad_internal = src;
        if (dst_dir != 3) c.dad_internal = dst;

        if (irq_at_end) self.irq.request(@intCast(8 + idx));

        if (repeat and ((c.cnt_h >> 12) & 3) != 0) {
            c.word_count = wordCount(c, idx);
            if (dst_dir == 3) c.dad_internal = c.dad & dstMask(idx);
        } else {
            c.enabled = false;
            c.cnt_h &= 0x7FFF;
        }

        const per_word: u32 = if (word) 4 else 2;
        return 2 + total_words * per_word;
    }

    fn runFifo(self: *Dma, idx: usize) u32 {
        const c = &self.ch[idx];
        const irq_at_end = (c.cnt_h & 0x4000) != 0;
        const src_step = srcInc(c);

        const r32 = self.read32_fn.?;
        const w32 = self.write32_fn.?;
        const ctx = self.bus_ptr.?;

        var src: u32 = c.sad_internal;
        const dst: u32 = c.dad_internal;
        var n: u32 = 4;
        while (n > 0) : (n -= 1) {
            const v = r32(ctx, src);
            w32(ctx, dst, v);
            src = @bitCast(@as(i32, @bitCast(src)) +% src_step);
        }
        c.sad_internal = src;
        if (irq_at_end) self.irq.request(@intCast(8 + idx));
        return 2 + 4 * 4;
    }
};
