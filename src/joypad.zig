pub const Button = enum(u8) {
    right = 0,
    left = 1,
    up = 2,
    down = 3,
    a = 4,
    b = 5,
    select = 6,
    start = 7,
};

pub const Joypad = struct {
    buttons: u8 = 0xFF,
    select_dir: bool = false,
    select_btn: bool = false,
    irq_request: bool = false,

    pub fn reset(self: *Joypad) void {
        self.* = .{};
    }

    pub fn press(self: *Joypad, b: Button) void {
        const mask: u8 = @as(u8, 1) << @intCast(@intFromEnum(b));
        const was_high = (self.buttons & mask) != 0;
        self.buttons &= ~mask;
        if (was_high) self.irq_request = true;
    }

    pub fn release(self: *Joypad, b: Button) void {
        const mask: u8 = @as(u8, 1) << @intCast(@intFromEnum(b));
        self.buttons |= mask;
    }

    pub fn read(self: *const Joypad) u8 {
        var top: u8 = 0xF0;
        if (self.select_btn) top &= ~@as(u8, 0x20);
        if (self.select_dir) top &= ~@as(u8, 0x10);
        var lower: u8 = 0x0F;
        if (self.select_dir) lower &= self.buttons & 0x0F;
        if (self.select_btn) lower &= (self.buttons >> 4) & 0x0F;
        return top | lower;
    }

    pub fn write(self: *Joypad, val: u8) void {
        self.select_btn = (val & 0x20) == 0;
        self.select_dir = (val & 0x10) == 0;
    }
};
