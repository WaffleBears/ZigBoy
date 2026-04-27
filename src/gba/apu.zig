const std = @import("std");

const duty_table: [4][8]u8 = .{
    .{ 0, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 1, 1, 1 },
    .{ 0, 1, 1, 1, 1, 1, 1, 0 },
};

const Square = struct {
    enabled: bool = false,
    dac_enabled: bool = false,
    nrx0: u8 = 0,
    nrx1: u8 = 0,
    nrx2: u8 = 0,
    nrx3: u8 = 0,
    nrx4: u8 = 0,
    timer: i32 = 0,
    duty_pos: u8 = 0,
    length: u16 = 0,
    volume: u8 = 0,
    env_period: u8 = 0,
    env_timer: u8 = 0,
    env_dir: bool = false,
    sweep_period: u8 = 0,
    sweep_timer: u8 = 0,
    sweep_shift: u8 = 0,
    sweep_neg: bool = false,
    sweep_enabled: bool = false,
    sweep_freq: u16 = 0,
    has_sweep: bool = false,

    fn frequency(self: *const Square) u16 {
        return (@as(u16, self.nrx4 & 0x07) << 8) | self.nrx3;
    }
    fn setFrequency(self: *Square, f: u16) void {
        self.nrx3 = @intCast(f & 0xFF);
        self.nrx4 = (self.nrx4 & 0xF8) | @as(u8, @intCast((f >> 8) & 0x07));
    }
    fn trigger(self: *Square) void {
        self.enabled = true;
        if (self.length == 0) self.length = 64;
        self.timer = (2048 - @as(i32, self.frequency())) * 16;
        self.env_timer = if (self.env_period == 0) 8 else self.env_period;
        self.volume = (self.nrx2 >> 4) & 0x0F;
        self.env_dir = (self.nrx2 & 0x08) != 0;
        if (!self.dac_enabled) self.enabled = false;
        if (self.has_sweep) {
            self.sweep_freq = self.frequency();
            self.sweep_timer = if (self.sweep_period == 0) 8 else self.sweep_period;
            self.sweep_enabled = self.sweep_period != 0 or self.sweep_shift != 0;
            if (self.sweep_shift != 0) _ = self.calcSweep();
        }
    }
    fn calcSweep(self: *Square) u16 {
        const delta = self.sweep_freq >> @intCast(self.sweep_shift);
        const new_freq: i32 = if (self.sweep_neg) @as(i32, self.sweep_freq) - @as(i32, delta) else @as(i32, self.sweep_freq) + @as(i32, delta);
        if (new_freq > 2047 or new_freq < 0) {
            self.enabled = false;
            return self.sweep_freq;
        }
        return @intCast(new_freq);
    }
    fn step(self: *Square, cycles: u32) void {
        if (!self.enabled) return;
        self.timer -= @intCast(cycles);
        while (self.timer <= 0) {
            self.timer += (2048 - @as(i32, self.frequency())) * 16;
            self.duty_pos = (self.duty_pos + 1) & 7;
        }
    }
    fn lengthClock(self: *Square) void {
        if ((self.nrx4 & 0x40) != 0 and self.length > 0) {
            self.length -= 1;
            if (self.length == 0) self.enabled = false;
        }
    }
    fn envClock(self: *Square) void {
        if (self.env_period == 0) return;
        if (self.env_timer > 0) self.env_timer -= 1;
        if (self.env_timer == 0) {
            self.env_timer = self.env_period;
            if (self.env_dir and self.volume < 15) self.volume += 1;
            if (!self.env_dir and self.volume > 0) self.volume -= 1;
        }
    }
    fn sweepClock(self: *Square) void {
        if (!self.has_sweep) return;
        if (self.sweep_timer > 0) self.sweep_timer -= 1;
        if (self.sweep_timer == 0) {
            self.sweep_timer = if (self.sweep_period == 0) 8 else self.sweep_period;
            if (self.sweep_enabled and self.sweep_period > 0) {
                const new_freq = self.calcSweep();
                if (self.enabled and self.sweep_shift > 0) {
                    self.sweep_freq = new_freq;
                    self.setFrequency(new_freq);
                    _ = self.calcSweep();
                }
            }
        }
    }
    fn output(self: *const Square) f32 {
        if (!self.enabled or !self.dac_enabled) return 0;
        const d = (self.nrx1 >> 6) & 0x03;
        if (duty_table[d][self.duty_pos] == 0) return 0;
        return @as(f32, @floatFromInt(self.volume)) / 15.0;
    }
};

const Wave = struct {
    enabled: bool = false,
    dac_enabled: bool = false,
    nr30: u8 = 0,
    nr31: u8 = 0,
    nr32: u8 = 0,
    nr33: u8 = 0,
    nr34: u8 = 0,
    timer: i32 = 0,
    pos: u8 = 0,
    length: u16 = 0,
    pattern: [32]u8 = .{0} ** 32,
    bank: u8 = 0,

    fn frequency(self: *const Wave) u16 {
        return (@as(u16, self.nr34 & 0x07) << 8) | self.nr33;
    }
    fn trigger(self: *Wave) void {
        self.enabled = true;
        if (self.length == 0) self.length = 256;
        self.timer = (2048 - @as(i32, self.frequency())) * 8;
        self.pos = 0;
        if (!self.dac_enabled) self.enabled = false;
    }
    fn step(self: *Wave, cycles: u32) void {
        if (!self.enabled) return;
        self.timer -= @intCast(cycles);
        while (self.timer <= 0) {
            self.timer += (2048 - @as(i32, self.frequency())) * 8;
            self.pos = (self.pos + 1) & 31;
        }
    }
    fn lengthClock(self: *Wave) void {
        if ((self.nr34 & 0x40) != 0 and self.length > 0) {
            self.length -= 1;
            if (self.length == 0) self.enabled = false;
        }
    }
    fn output(self: *const Wave) f32 {
        if (!self.enabled or !self.dac_enabled) return 0;
        const idx: u8 = (self.bank * 16) + (self.pos / 2);
        const b = self.pattern[idx & 0x1F];
        const nibble: u8 = if ((self.pos & 1) == 0) (b >> 4) else (b & 0x0F);
        const shift: u8 = switch ((self.nr32 >> 5) & 0x03) {
            0 => 4,
            1 => 0,
            2 => 1,
            3 => 2,
            else => 4,
        };
        const v = nibble >> @intCast(shift);
        return @as(f32, @floatFromInt(v)) / 15.0;
    }
};

const Noise = struct {
    enabled: bool = false,
    dac_enabled: bool = false,
    nr41: u8 = 0,
    nr42: u8 = 0,
    nr43: u8 = 0,
    nr44: u8 = 0,
    timer: i32 = 0,
    lfsr: u16 = 0x7FFF,
    length: u16 = 0,
    volume: u8 = 0,
    env_period: u8 = 0,
    env_timer: u8 = 0,
    env_dir: bool = false,

    fn period(self: *const Noise) i32 {
        const div_code: u8 = self.nr43 & 0x07;
        const shift: u8 = (self.nr43 >> 4) & 0x0F;
        const div: u32 = if (div_code == 0) 8 else @as(u32, div_code) * 16;
        return @intCast((div << @intCast(shift)) * 4);
    }
    fn trigger(self: *Noise) void {
        self.enabled = true;
        if (self.length == 0) self.length = 64;
        self.timer = self.period();
        self.lfsr = 0x7FFF;
        self.env_timer = if (self.env_period == 0) 8 else self.env_period;
        self.volume = (self.nr42 >> 4) & 0x0F;
        self.env_dir = (self.nr42 & 0x08) != 0;
        if (!self.dac_enabled) self.enabled = false;
    }
    fn step(self: *Noise, cycles: u32) void {
        if (!self.enabled) return;
        self.timer -= @intCast(cycles);
        while (self.timer <= 0) {
            self.timer += self.period();
            const b = (self.lfsr & 1) ^ ((self.lfsr >> 1) & 1);
            self.lfsr = (self.lfsr >> 1) | (b << 14);
            if ((self.nr43 & 0x08) != 0) {
                self.lfsr = (self.lfsr & ~@as(u16, 0x40)) | (b << 6);
            }
        }
    }
    fn lengthClock(self: *Noise) void {
        if ((self.nr44 & 0x40) != 0 and self.length > 0) {
            self.length -= 1;
            if (self.length == 0) self.enabled = false;
        }
    }
    fn envClock(self: *Noise) void {
        if (self.env_period == 0) return;
        if (self.env_timer > 0) self.env_timer -= 1;
        if (self.env_timer == 0) {
            self.env_timer = self.env_period;
            if (self.env_dir and self.volume < 15) self.volume += 1;
            if (!self.env_dir and self.volume > 0) self.volume -= 1;
        }
    }
    fn output(self: *const Noise) f32 {
        if (!self.enabled or !self.dac_enabled) return 0;
        if ((self.lfsr & 1) != 0) return 0;
        return @as(f32, @floatFromInt(self.volume)) / 15.0;
    }
};

const FifoChan = struct {
    queue: [32]i8 = .{0} ** 32,
    head: u32 = 0,
    tail: u32 = 0,
    count: u32 = 0,
    current: i8 = 0,

    pub fn pushWord(self: *FifoChan, v: u32) void {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (self.count >= 32) break;
            const b: i8 = @bitCast(@as(u8, @truncate(v >> @intCast(i * 8))));
            self.queue[self.tail] = b;
            self.tail = (self.tail + 1) & 31;
            self.count += 1;
        }
    }

    pub fn pushHalf(self: *FifoChan, v: u16) void {
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            if (self.count >= 32) break;
            const b: i8 = @bitCast(@as(u8, @truncate(v >> @intCast(i * 8))));
            self.queue[self.tail] = b;
            self.tail = (self.tail + 1) & 31;
            self.count += 1;
        }
    }

    fn pop(self: *FifoChan) void {
        if (self.count == 0) return;
        self.current = self.queue[self.head];
        self.head = (self.head + 1) & 31;
        self.count -= 1;
    }

    fn reset(self: *FifoChan) void {
        self.* = .{};
    }
};

pub const Apu = struct {
    sq1: Square = .{ .has_sweep = true },
    sq2: Square = .{},
    wave: Wave = .{},
    noise: Noise = .{},

    fifo_a: FifoChan = .{},
    fifo_b: FifoChan = .{},

    enabled: bool = false,
    nr50: u8 = 0,
    nr51: u8 = 0,
    soundcnt_h: u16 = 0,
    soundcnt_x: u16 = 0,
    soundbias: u16 = 0x200,

    frame_seq: u8 = 0,
    frame_timer: u32 = 0,

    sample_timer: f64 = 0,
    sample_rate: u32 = 48000,
    cycles_per_sample: f64 = 16777216.0 / 48000.0,

    hpf_x_l: f32 = 0,
    hpf_y_l: f32 = 0,
    hpf_x_r: f32 = 0,
    hpf_y_r: f32 = 0,
    slew_l: f32 = 0,
    slew_r: f32 = 0,

    buffer: []f32,
    buffer_head: usize = 0,
    buffer_len: usize = 0,
    buffer_cap: usize,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, sample_rate: u32) !Apu {
        const cap = @as(usize, sample_rate) * 4;
        const buf = try alloc.alloc(f32, cap);
        return .{
            .sample_rate = sample_rate,
            .cycles_per_sample = 16777216.0 / @as(f64, @floatFromInt(sample_rate)),
            .buffer = buf,
            .buffer_cap = cap,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Apu) void {
        self.allocator.free(self.buffer);
    }

    pub fn reset(self: *Apu) void {
        self.sq1 = .{ .has_sweep = true };
        self.sq2 = .{};
        self.wave = .{};
        self.noise = .{};
        self.fifo_a = .{};
        self.fifo_b = .{};
        self.enabled = false;
        self.nr50 = 0;
        self.nr51 = 0;
        self.soundcnt_h = 0;
        self.soundcnt_x = 0;
        self.soundbias = 0x200;
        self.frame_seq = 0;
        self.frame_timer = 0;
        self.sample_timer = 0;
        self.buffer_head = 0;
        self.buffer_len = 0;
        self.hpf_x_l = 0;
        self.hpf_y_l = 0;
        self.hpf_x_r = 0;
        self.hpf_y_r = 0;
        self.slew_l = 0;
        self.slew_r = 0;
    }

    pub fn read16(self: *Apu, off: u32) u16 {
        return switch (off) {
            0x00 => @as(u16, self.sq1.nrx0),
            0x02 => @as(u16, self.sq1.nrx1 & 0xC0) | (@as(u16, self.sq1.nrx2) << 8),
            0x04 => @as(u16, self.sq1.nrx4 & 0x40) << 8,
            0x08 => @as(u16, self.sq2.nrx1 & 0xC0) | (@as(u16, self.sq2.nrx2) << 8),
            0x0C => @as(u16, self.sq2.nrx4 & 0x40) << 8,
            0x10 => @as(u16, self.wave.nr30),
            0x12 => @as(u16, self.wave.nr32) << 8,
            0x14 => @as(u16, self.wave.nr34 & 0x40) << 8,
            0x18 => @as(u16, self.noise.nr42) << 8,
            0x1C => @as(u16, self.noise.nr43) | (@as(u16, self.noise.nr44 & 0x40) << 8),
            0x20 => @as(u16, self.nr50) | (@as(u16, self.nr51) << 8),
            0x22 => self.soundcnt_h,
            0x24 => blk: {
                var v: u16 = if (self.enabled) 0x80 else 0;
                if (self.sq1.enabled) v |= 0x01;
                if (self.sq2.enabled) v |= 0x02;
                if (self.wave.enabled) v |= 0x04;
                if (self.noise.enabled) v |= 0x08;
                break :blk v;
            },
            0x28 => self.soundbias,
            0x30, 0x32, 0x34, 0x36, 0x38, 0x3A, 0x3C, 0x3E => blk: {
                const i = (off - 0x30) & 0x0F;
                const bank_off: usize = (1 - self.wave.bank) * 16;
                const lo = self.wave.pattern[bank_off + i];
                const hi = self.wave.pattern[bank_off + i + 1];
                break :blk @as(u16, lo) | (@as(u16, hi) << 8);
            },
            else => 0,
        };
    }

    pub fn write16(self: *Apu, off: u32, v: u16) void {
        switch (off) {
            0x00 => {
                self.sq1.nrx0 = @truncate(v & 0x7F);
                self.sq1.sweep_period = (self.sq1.nrx0 >> 4) & 0x07;
                self.sq1.sweep_neg = (self.sq1.nrx0 & 0x08) != 0;
                self.sq1.sweep_shift = self.sq1.nrx0 & 0x07;
            },
            0x02 => {
                self.sq1.nrx1 = @truncate(v & 0xFF);
                self.sq1.length = 64 - @as(u16, self.sq1.nrx1 & 0x3F);
                self.sq1.nrx2 = @truncate(v >> 8);
                self.sq1.dac_enabled = (self.sq1.nrx2 & 0xF8) != 0;
                if (!self.sq1.dac_enabled) self.sq1.enabled = false;
                self.sq1.env_period = self.sq1.nrx2 & 0x07;
            },
            0x04 => {
                self.sq1.nrx3 = @truncate(v & 0xFF);
                self.sq1.nrx4 = @truncate((v >> 8) & 0xC7);
                if ((v & 0x8000) != 0) self.sq1.trigger();
            },
            0x08 => {
                self.sq2.nrx1 = @truncate(v & 0xFF);
                self.sq2.length = 64 - @as(u16, self.sq2.nrx1 & 0x3F);
                self.sq2.nrx2 = @truncate(v >> 8);
                self.sq2.dac_enabled = (self.sq2.nrx2 & 0xF8) != 0;
                if (!self.sq2.dac_enabled) self.sq2.enabled = false;
                self.sq2.env_period = self.sq2.nrx2 & 0x07;
            },
            0x0C => {
                self.sq2.nrx3 = @truncate(v & 0xFF);
                self.sq2.nrx4 = @truncate((v >> 8) & 0xC7);
                if ((v & 0x8000) != 0) self.sq2.trigger();
            },
            0x10 => {
                self.wave.nr30 = @truncate(v & 0xE0);
                self.wave.dac_enabled = (self.wave.nr30 & 0x80) != 0;
                self.wave.bank = (self.wave.nr30 >> 6) & 1;
                if (!self.wave.dac_enabled) self.wave.enabled = false;
            },
            0x12 => {
                self.wave.nr31 = @truncate(v & 0xFF);
                self.wave.length = 256 - @as(u16, self.wave.nr31);
                self.wave.nr32 = @truncate((v >> 8) & 0xE0);
            },
            0x14 => {
                self.wave.nr33 = @truncate(v & 0xFF);
                self.wave.nr34 = @truncate((v >> 8) & 0xC7);
                if ((v & 0x8000) != 0) self.wave.trigger();
            },
            0x18 => {
                self.noise.nr41 = @truncate(v & 0x3F);
                self.noise.length = 64 - @as(u16, self.noise.nr41 & 0x3F);
                self.noise.nr42 = @truncate(v >> 8);
                self.noise.dac_enabled = (self.noise.nr42 & 0xF8) != 0;
                if (!self.noise.dac_enabled) self.noise.enabled = false;
                self.noise.env_period = self.noise.nr42 & 0x07;
            },
            0x1C => {
                self.noise.nr43 = @truncate(v & 0xFF);
                self.noise.nr44 = @truncate((v >> 8) & 0xC0);
                if ((v & 0x8000) != 0) self.noise.trigger();
            },
            0x20 => {
                self.nr50 = @truncate(v & 0xFF);
                self.nr51 = @truncate(v >> 8);
            },
            0x22 => {
                if ((v & 0x0800) != 0) self.fifo_a.reset();
                if ((v & 0x8000) != 0) self.fifo_b.reset();
                self.soundcnt_h = v & 0x770F;
            },
            0x24 => {
                const new_on = (v & 0x80) != 0;
                if (!new_on and self.enabled) {
                    self.sq1 = .{ .has_sweep = true };
                    self.sq2 = .{};
                    self.wave.enabled = false;
                    self.noise = .{};
                    self.nr50 = 0;
                    self.nr51 = 0;
                    self.soundcnt_h = 0;
                }
                self.enabled = new_on;
            },
            0x28 => self.soundbias = v & 0xC3FE,
            0x30, 0x32, 0x34, 0x36, 0x38, 0x3A, 0x3C, 0x3E => {
                const i = (off - 0x30) & 0x0F;
                const bank_off: usize = (1 - self.wave.bank) * 16;
                self.wave.pattern[bank_off + i] = @truncate(v & 0xFF);
                self.wave.pattern[bank_off + i + 1] = @truncate(v >> 8);
            },
            0x40, 0x42 => self.fifo_a.pushHalf(v),
            0x44, 0x46 => self.fifo_b.pushHalf(v),
            else => {},
        }
    }

    pub fn timerOverflow(self: *Apu, idx: u3) void {
        const a_timer: u3 = @intCast((self.soundcnt_h >> 10) & 1);
        const b_timer: u3 = @intCast((self.soundcnt_h >> 14) & 1);
        if (idx == a_timer) {
            self.fifo_a.pop();
        }
        if (idx == b_timer) {
            self.fifo_b.pop();
        }
    }

    pub fn step(self: *Apu, cycles: u32) void {
        self.frame_timer += cycles;
        while (self.frame_timer >= 32768) {
            self.frame_timer -= 32768;
            self.frameStep();
        }
        self.sq1.step(cycles);
        self.sq2.step(cycles);
        self.wave.step(cycles);
        self.noise.step(cycles);

        self.sample_timer += @as(f64, @floatFromInt(cycles));
        while (self.sample_timer >= self.cycles_per_sample) {
            self.sample_timer -= self.cycles_per_sample;
            self.pushSample();
        }
    }

    fn frameStep(self: *Apu) void {
        switch (self.frame_seq) {
            0 => self.lengthAll(),
            2 => {
                self.lengthAll();
                self.sq1.sweepClock();
            },
            4 => self.lengthAll(),
            6 => {
                self.lengthAll();
                self.sq1.sweepClock();
            },
            7 => {
                self.sq1.envClock();
                self.sq2.envClock();
                self.noise.envClock();
            },
            else => {},
        }
        self.frame_seq = (self.frame_seq + 1) & 7;
    }

    fn lengthAll(self: *Apu) void {
        self.sq1.lengthClock();
        self.sq2.lengthClock();
        self.wave.lengthClock();
        self.noise.lengthClock();
    }

    fn pushSample(self: *Apu) void {
        if (self.buffer_len + 2 > self.buffer_cap) {
            self.buffer_head = (self.buffer_head + 2) % self.buffer_cap;
            self.buffer_len -= 2;
        }
        var l: f32 = 0;
        var r: f32 = 0;
        const psg_vol_shift: u8 = switch (self.soundcnt_h & 0x03) {
            0 => 2,
            1 => 1,
            2 => 0,
            else => 2,
        };
        const psg_scale: f32 = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << @intCast(psg_vol_shift + 2)));
        const s1 = self.sq1.output();
        const s2 = self.sq2.output();
        const sw = self.wave.output();
        const sn = self.noise.output();
        if ((self.nr51 & 0x10) != 0) l += s1;
        if ((self.nr51 & 0x01) != 0) r += s1;
        if ((self.nr51 & 0x20) != 0) l += s2;
        if ((self.nr51 & 0x02) != 0) r += s2;
        if ((self.nr51 & 0x40) != 0) l += sw;
        if ((self.nr51 & 0x04) != 0) r += sw;
        if ((self.nr51 & 0x80) != 0) l += sn;
        if ((self.nr51 & 0x08) != 0) r += sn;
        const lvol: f32 = @as(f32, @floatFromInt(((self.nr50 >> 4) & 0x07) + 1)) / 8.0;
        const rvol: f32 = @as(f32, @floatFromInt((self.nr50 & 0x07) + 1)) / 8.0;
        l = l * lvol * psg_scale;
        r = r * rvol * psg_scale;

        const a_full = (self.soundcnt_h & 0x0004) != 0;
        const b_full = (self.soundcnt_h & 0x0040) != 0;
        const a_scale: f32 = if (a_full) 1.0 / 128.0 else 0.5 / 128.0;
        const b_scale: f32 = if (b_full) 1.0 / 128.0 else 0.5 / 128.0;
        const a_v: f32 = @as(f32, @floatFromInt(self.fifo_a.current)) * a_scale;
        const b_v: f32 = @as(f32, @floatFromInt(self.fifo_b.current)) * b_scale;
        if ((self.soundcnt_h & 0x0200) != 0) l += a_v;
        if ((self.soundcnt_h & 0x0100) != 0) r += a_v;
        if ((self.soundcnt_h & 0x2000) != 0) l += b_v;
        if ((self.soundcnt_h & 0x1000) != 0) r += b_v;

        const max_step: f32 = 0.05;
        const dl = l - self.slew_l;
        const dr = r - self.slew_r;
        if (dl > max_step) l = self.slew_l + max_step
        else if (dl < -max_step) l = self.slew_l - max_step;
        if (dr > max_step) r = self.slew_r + max_step
        else if (dr < -max_step) r = self.slew_r - max_step;
        self.slew_l = l;
        self.slew_r = r;

        const hpf_alpha: f32 = 0.985;
        const hy_l = l - self.hpf_x_l + hpf_alpha * self.hpf_y_l;
        const hy_r = r - self.hpf_x_r + hpf_alpha * self.hpf_y_r;
        self.hpf_x_l = l;
        self.hpf_x_r = r;
        self.hpf_y_l = hy_l;
        self.hpf_y_r = hy_r;
        l = hy_l;
        r = hy_r;

        if (l > 1.0) l = 1.0;
        if (l < -1.0) l = -1.0;
        if (r > 1.0) r = 1.0;
        if (r < -1.0) r = -1.0;
        const tail = (self.buffer_head + self.buffer_len) % self.buffer_cap;
        self.buffer[tail] = l;
        self.buffer[(tail + 1) % self.buffer_cap] = r;
        self.buffer_len += 2;
    }

    pub fn drain(self: *Apu, dst: []f32) usize {
        const n = @min(dst.len, self.buffer_len);
        if (n == 0) return 0;
        const head = self.buffer_head;
        const cap = self.buffer_cap;
        if (head + n <= cap) {
            @memcpy(dst[0..n], self.buffer[head .. head + n]);
        } else {
            const first = cap - head;
            @memcpy(dst[0..first], self.buffer[head..cap]);
            @memcpy(dst[first..n], self.buffer[0 .. n - first]);
        }
        self.buffer_head = (head + n) % cap;
        self.buffer_len -= n;
        return n;
    }
};
