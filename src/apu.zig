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
        self.timer = (2048 - @as(i32, self.frequency())) * 4;
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
            self.timer += (2048 - @as(i32, self.frequency())) * 4;
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
    pattern: [16]u8 = .{0} ** 16,

    fn frequency(self: *const Wave) u16 {
        return (@as(u16, self.nr34 & 0x07) << 8) | self.nr33;
    }
    fn trigger(self: *Wave) void {
        self.enabled = true;
        if (self.length == 0) self.length = 256;
        self.timer = (2048 - @as(i32, self.frequency())) * 2;
        self.pos = 0;
        if (!self.dac_enabled) self.enabled = false;
    }
    fn step(self: *Wave, cycles: u32) void {
        if (!self.enabled) return;
        self.timer -= @intCast(cycles);
        while (self.timer <= 0) {
            self.timer += (2048 - @as(i32, self.frequency())) * 2;
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
        const b = self.pattern[self.pos / 2];
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
        return @intCast(div << @intCast(shift));
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

pub const Apu = struct {
    sq1: Square = .{ .has_sweep = true },
    sq2: Square = .{},
    wave: Wave = .{},
    noise: Noise = .{},

    enabled: bool = false,
    nr50: u8 = 0,
    nr51: u8 = 0,

    frame_seq: u8 = 0,
    frame_timer: u32 = 0,

    sample_timer: f64 = 0,
    sample_rate: u32 = 48000,
    cycles_per_sample: f64 = 4194304.0 / 48000.0,

    buffer: []f32,
    buffer_len: usize = 0,
    buffer_cap: usize,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, sample_rate: u32) !Apu {
        const cap = @as(usize, sample_rate) * 4;
        const buf = try alloc.alloc(f32, cap);
        return .{
            .sample_rate = sample_rate,
            .cycles_per_sample = 4194304.0 / @as(f64, @floatFromInt(sample_rate)),
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
        self.enabled = false;
        self.nr50 = 0;
        self.nr51 = 0;
        self.frame_seq = 0;
        self.frame_timer = 0;
        self.sample_timer = 0;
        self.buffer_len = 0;
    }

    pub fn read(self: *Apu, addr: u16) u8 {
        return switch (addr) {
            0xFF10 => self.sq1.nrx0 | 0x80,
            0xFF11 => self.sq1.nrx1 | 0x3F,
            0xFF12 => self.sq1.nrx2,
            0xFF13 => 0xFF,
            0xFF14 => self.sq1.nrx4 | 0xBF,
            0xFF16 => self.sq2.nrx1 | 0x3F,
            0xFF17 => self.sq2.nrx2,
            0xFF18 => 0xFF,
            0xFF19 => self.sq2.nrx4 | 0xBF,
            0xFF1A => self.wave.nr30 | 0x7F,
            0xFF1B => 0xFF,
            0xFF1C => self.wave.nr32 | 0x9F,
            0xFF1D => 0xFF,
            0xFF1E => self.wave.nr34 | 0xBF,
            0xFF20 => 0xFF,
            0xFF21 => self.noise.nr42,
            0xFF22 => self.noise.nr43,
            0xFF23 => self.noise.nr44 | 0xBF,
            0xFF24 => self.nr50,
            0xFF25 => self.nr51,
            0xFF26 => blk: {
                var v: u8 = if (self.enabled) 0x80 else 0;
                if (self.sq1.enabled) v |= 0x01;
                if (self.sq2.enabled) v |= 0x02;
                if (self.wave.enabled) v |= 0x04;
                if (self.noise.enabled) v |= 0x08;
                break :blk v | 0x70;
            },
            0xFF30...0xFF3F => self.wave.pattern[addr - 0xFF30],
            else => 0xFF,
        };
    }

    pub fn write(self: *Apu, addr: u16, val: u8) void {
        if (!self.enabled and addr != 0xFF26 and (addr < 0xFF30 or addr > 0xFF3F) and addr != 0xFF11 and addr != 0xFF16 and addr != 0xFF1B and addr != 0xFF20) return;
        switch (addr) {
            0xFF10 => {
                self.sq1.nrx0 = val;
                self.sq1.sweep_period = (val >> 4) & 0x07;
                self.sq1.sweep_neg = (val & 0x08) != 0;
                self.sq1.sweep_shift = val & 0x07;
            },
            0xFF11 => {
                self.sq1.nrx1 = val;
                self.sq1.length = 64 - @as(u16, val & 0x3F);
            },
            0xFF12 => {
                self.sq1.nrx2 = val;
                self.sq1.dac_enabled = (val & 0xF8) != 0;
                if (!self.sq1.dac_enabled) self.sq1.enabled = false;
                self.sq1.env_period = val & 0x07;
            },
            0xFF13 => self.sq1.nrx3 = val,
            0xFF14 => {
                self.sq1.nrx4 = val;
                if ((val & 0x80) != 0) self.sq1.trigger();
            },
            0xFF16 => {
                self.sq2.nrx1 = val;
                self.sq2.length = 64 - @as(u16, val & 0x3F);
            },
            0xFF17 => {
                self.sq2.nrx2 = val;
                self.sq2.dac_enabled = (val & 0xF8) != 0;
                if (!self.sq2.dac_enabled) self.sq2.enabled = false;
                self.sq2.env_period = val & 0x07;
            },
            0xFF18 => self.sq2.nrx3 = val,
            0xFF19 => {
                self.sq2.nrx4 = val;
                if ((val & 0x80) != 0) self.sq2.trigger();
            },
            0xFF1A => {
                self.wave.nr30 = val;
                self.wave.dac_enabled = (val & 0x80) != 0;
                if (!self.wave.dac_enabled) self.wave.enabled = false;
            },
            0xFF1B => {
                self.wave.nr31 = val;
                self.wave.length = 256 - @as(u16, val);
            },
            0xFF1C => self.wave.nr32 = val,
            0xFF1D => self.wave.nr33 = val,
            0xFF1E => {
                self.wave.nr34 = val;
                if ((val & 0x80) != 0) self.wave.trigger();
            },
            0xFF20 => {
                self.noise.nr41 = val;
                self.noise.length = 64 - @as(u16, val & 0x3F);
            },
            0xFF21 => {
                self.noise.nr42 = val;
                self.noise.dac_enabled = (val & 0xF8) != 0;
                if (!self.noise.dac_enabled) self.noise.enabled = false;
                self.noise.env_period = val & 0x07;
            },
            0xFF22 => self.noise.nr43 = val,
            0xFF23 => {
                self.noise.nr44 = val;
                if ((val & 0x80) != 0) self.noise.trigger();
            },
            0xFF24 => self.nr50 = val,
            0xFF25 => self.nr51 = val,
            0xFF26 => {
                const new_on = (val & 0x80) != 0;
                if (!new_on and self.enabled) {
                    self.sq1 = .{ .has_sweep = true };
                    self.sq2 = .{};
                    self.wave.enabled = false;
                    self.noise = .{};
                    self.nr50 = 0;
                    self.nr51 = 0;
                }
                self.enabled = new_on;
            },
            0xFF30...0xFF3F => self.wave.pattern[addr - 0xFF30] = val,
            else => {},
        }
    }

    pub fn step(self: *Apu, cycles: u32, double_speed: bool) void {
        const eff = if (double_speed) cycles / 2 else cycles;
        self.frame_timer += eff;
        while (self.frame_timer >= 8192) {
            self.frame_timer -= 8192;
            self.frameStep();
        }
        self.sq1.step(eff);
        self.sq2.step(eff);
        self.wave.step(eff);
        self.noise.step(eff);

        self.sample_timer += @as(f64, @floatFromInt(eff));
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
        if (self.buffer_len + 2 > self.buffer_cap) return;
        var l: f32 = 0;
        var r: f32 = 0;
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
        l = (l / 4.0) * lvol;
        r = (r / 4.0) * rvol;
        self.buffer[self.buffer_len] = l;
        self.buffer[self.buffer_len + 1] = r;
        self.buffer_len += 2;
    }

    pub fn drain(self: *Apu, dst: []f32) usize {
        const n = @min(dst.len, self.buffer_len);
        if (n == 0) return 0;
        @memcpy(dst[0..n], self.buffer[0..n]);
        if (self.buffer_len > n) {
            std.mem.copyForwards(f32, self.buffer[0 .. self.buffer_len - n], self.buffer[n..self.buffer_len]);
        }
        self.buffer_len -= n;
        return n;
    }
};
