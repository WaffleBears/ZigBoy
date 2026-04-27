pub const Irq = struct {
    ie: u16 = 0,
    ifr: u16 = 0,
    ime: bool = false,

    pub fn reset(self: *Irq) void {
        self.* = .{};
    }

    pub fn request(self: *Irq, bit: u4) void {
        self.ifr |= (@as(u16, 1) << bit);
    }

    pub fn pending(self: *const Irq) bool {
        return self.ime and (self.ie & self.ifr) != 0;
    }
};
