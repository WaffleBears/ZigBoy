const Irq = @import("irq.zig").Irq;

pub const Timer = struct {
    counter: u16 = 0,
    reload: u16 = 0,
    cnt: u16 = 0,
    enabled: bool = false,
    cascade: bool = false,
    irq_enable: bool = false,
    prescaler: u16 = 1,
    sub_cycles: u32 = 0,
};

pub const Timers = struct {
    t: [4]Timer = [_]Timer{.{}} ** 4,
    irq: *Irq,
    apu_event_listener: ?*const fn (ctx: *anyopaque, idx: u3) void = null,
    apu_ctx: ?*anyopaque = null,

    pub fn init(irq: *Irq) Timers {
        return .{ .irq = irq };
    }

    pub fn reset(self: *Timers) void {
        var i: usize = 0;
        while (i < 4) : (i += 1) self.t[i] = .{};
    }

    pub fn read16(self: *const Timers, idx: usize) u16 {
        return self.t[idx].counter;
    }

    pub fn readCnt(self: *const Timers, idx: usize) u16 {
        return self.t[idx].cnt;
    }

    pub fn write16(self: *Timers, idx: usize, v: u16) void {
        self.t[idx].reload = v;
    }

    pub fn writeCnt(self: *Timers, idx: usize, v: u16) void {
        const old_enabled = self.t[idx].enabled;
        self.t[idx].cnt = v & 0x00C7;
        self.t[idx].cascade = (v & 0x04) != 0 and idx > 0;
        self.t[idx].irq_enable = (v & 0x40) != 0;
        const ps: u16 = switch (v & 0x03) {
            0 => 1,
            1 => 64,
            2 => 256,
            else => 1024,
        };
        self.t[idx].prescaler = ps;
        const new_enabled = (v & 0x80) != 0;
        if (new_enabled and !old_enabled) {
            self.t[idx].counter = self.t[idx].reload;
            self.t[idx].sub_cycles = 0;
        }
        self.t[idx].enabled = new_enabled;
    }

    pub fn step(self: *Timers, cycles: u32) void {
        var overflow_count: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const t = &self.t[i];
            if (!t.enabled) {
                overflow_count = 0;
                continue;
            }
            var ticks: u32 = 0;
            if (t.cascade and i > 0) {
                ticks = overflow_count;
            } else {
                t.sub_cycles += cycles;
                while (t.sub_cycles >= t.prescaler) {
                    t.sub_cycles -= t.prescaler;
                    ticks += 1;
                }
            }
            var local_overflows: u32 = 0;
            var k: u32 = 0;
            while (k < ticks) : (k += 1) {
                if (t.counter == 0xFFFF) {
                    t.counter = t.reload;
                    local_overflows += 1;
                    if (t.irq_enable) self.irq.request(@intCast(3 + i));
                    if (i < 2) {
                        if (self.apu_event_listener) |cb| {
                            if (self.apu_ctx) |ctx| cb(ctx, @intCast(i));
                        }
                    }
                } else {
                    t.counter +%= 1;
                }
            }
            overflow_count = local_overflows;
        }
    }
};
