pub const Timer = struct {
    div_counter: u16 = 0,
    tima: u8 = 0,
    tma: u8 = 0,
    tac: u8 = 0,
    overflow_pending: bool = false,
    overflow_delay: u8 = 0,
    last_and: u1 = 0,
    irq_request: bool = false,

    pub fn reset(self: *Timer) void {
        self.* = .{};
    }

    pub fn read(self: *Timer, addr: u16) u8 {
        return switch (addr) {
            0xFF04 => @intCast(self.div_counter >> 8),
            0xFF05 => self.tima,
            0xFF06 => self.tma,
            0xFF07 => self.tac | 0xF8,
            else => 0xFF,
        };
    }

    pub fn write(self: *Timer, addr: u16, val: u8) void {
        switch (addr) {
            0xFF04 => {
                self.div_counter = 0;
                self.checkEdge();
            },
            0xFF05 => {
                self.tima = val;
                self.overflow_pending = false;
                self.overflow_delay = 0;
            },
            0xFF06 => {
                self.tma = val;
                if (self.overflow_delay > 0) self.tima = val;
            },
            0xFF07 => {
                self.tac = val & 0x07;
                self.checkEdge();
            },
            else => {},
        }
    }

    fn timerBit(self: *const Timer) u4 {
        return switch (self.tac & 0x03) {
            0 => 9,
            1 => 3,
            2 => 5,
            3 => 7,
            else => unreachable,
        };
    }

    fn currentAnd(self: *const Timer) u1 {
        if ((self.tac & 0x04) == 0) return 0;
        const bit = self.timerBit();
        return @intCast((self.div_counter >> bit) & 1);
    }

    fn checkEdge(self: *Timer) void {
        const new_and = self.currentAnd();
        if (self.last_and == 1 and new_and == 0) self.tickTima();
        self.last_and = new_and;
    }

    fn tickTima(self: *Timer) void {
        if (self.tima == 0xFF) {
            self.tima = 0;
            self.overflow_pending = true;
            self.overflow_delay = 4;
        } else {
            self.tima +%= 1;
        }
    }

    pub fn step(self: *Timer, cycles: u32) void {
        var c: u32 = 0;
        while (c < cycles) {
            const tick: u32 = @min(@as(u32, 4), cycles - c);
            c += tick;
            if (self.overflow_pending) {
                const dec: u8 = @intCast(@min(@as(u32, self.overflow_delay), tick));
                self.overflow_delay -= dec;
                if (self.overflow_delay == 0) {
                    self.tima = self.tma;
                    self.irq_request = true;
                    self.overflow_pending = false;
                }
            }
            self.div_counter +%= @intCast(tick);
            self.checkEdge();
        }
    }
};
