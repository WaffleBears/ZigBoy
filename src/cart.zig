const std = @import("std");

pub const MbcKind = enum(u8) {
    rom_only,
    mbc1,
    mbc2,
    mbc3,
    mbc5,
};

pub const Cart = struct {
    rom: []u8,
    ram: []u8,
    kind: MbcKind,
    has_battery: bool,
    has_rtc: bool,
    cgb_flag: u8,
    title: [16]u8,
    title_len: usize,

    rom_bank: u16 = 1,
    ram_bank: u8 = 0,
    ram_enabled: bool = false,
    banking_mode: u8 = 0,
    rtc_regs: [5]u8 = .{0} ** 5,
    rtc_latched: [5]u8 = .{0} ** 5,
    rtc_select: u8 = 0,
    rtc_latch_prev: u8 = 0xFF,

    allocator: std.mem.Allocator,

    pub fn loadFromBytes(alloc: std.mem.Allocator, data: []const u8) !Cart {
        if (data.len < 0x150) return error.InvalidRom;
        const cart_type = data[0x147];
        const ram_size_code = data[0x149];

        var ram_size: usize = switch (ram_size_code) {
            0 => 0,
            1 => 2 * 1024,
            2 => 8 * 1024,
            3 => 32 * 1024,
            4 => 128 * 1024,
            5 => 64 * 1024,
            else => 0,
        };

        const kind: MbcKind = switch (cart_type) {
            0x00, 0x08, 0x09 => .rom_only,
            0x01, 0x02, 0x03 => .mbc1,
            0x05, 0x06 => blk: {
                ram_size = 512;
                break :blk .mbc2;
            },
            0x0F, 0x10, 0x11, 0x12, 0x13 => .mbc3,
            0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E => .mbc5,
            else => .rom_only,
        };

        const has_battery = switch (cart_type) {
            0x03, 0x06, 0x09, 0x0F, 0x10, 0x13, 0x1B, 0x1E => true,
            else => false,
        };
        const has_rtc = cart_type == 0x0F or cart_type == 0x10;

        const real_ram = if (ram_size == 0) @as(usize, 1) else ram_size;

        const rom_copy = try alloc.alloc(u8, data.len);
        errdefer alloc.free(rom_copy);
        @memcpy(rom_copy, data);
        const ram = try alloc.alloc(u8, real_ram);
        @memset(ram, 0);

        var title: [16]u8 = undefined;
        @memcpy(&title, data[0x134..0x144]);
        var tl: usize = 0;
        while (tl < 16 and title[tl] != 0) : (tl += 1) {}

        return .{
            .rom = rom_copy,
            .ram = ram,
            .kind = kind,
            .has_battery = has_battery,
            .has_rtc = has_rtc,
            .cgb_flag = data[0x143],
            .title = title,
            .title_len = tl,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Cart) void {
        self.allocator.free(self.rom);
        self.allocator.free(self.ram);
    }

    pub fn isCgb(self: *const Cart) bool {
        return (self.cgb_flag & 0x80) != 0;
    }

    pub fn read(self: *Cart, addr: u16) u8 {
        return switch (self.kind) {
            .rom_only => self.readRomOnly(addr),
            .mbc1 => self.readMbc1(addr),
            .mbc2 => self.readMbc2(addr),
            .mbc3 => self.readMbc3(addr),
            .mbc5 => self.readMbc5(addr),
        };
    }

    pub fn write(self: *Cart, addr: u16, val: u8) void {
        switch (self.kind) {
            .rom_only => self.writeRomOnly(addr, val),
            .mbc1 => self.writeMbc1(addr, val),
            .mbc2 => self.writeMbc2(addr, val),
            .mbc3 => self.writeMbc3(addr, val),
            .mbc5 => self.writeMbc5(addr, val),
        }
    }

    fn readRomOnly(self: *Cart, addr: u16) u8 {
        if (addr < 0x8000) {
            if (addr < self.rom.len) return self.rom[addr];
            return 0xFF;
        }
        if (addr >= 0xA000 and addr < 0xC000 and self.ram.len > 1) {
            const off = addr - 0xA000;
            if (off < self.ram.len) return self.ram[off];
        }
        return 0xFF;
    }

    fn writeRomOnly(self: *Cart, addr: u16, val: u8) void {
        if (addr >= 0xA000 and addr < 0xC000 and self.ram.len > 1) {
            const off = addr - 0xA000;
            if (off < self.ram.len) self.ram[off] = val;
        }
    }

    fn readMbc1(self: *Cart, addr: u16) u8 {
        if (addr < 0x4000) {
            const bank: u32 = if (self.banking_mode == 1) (@as(u32, self.ram_bank) << 5) else 0;
            const off = bank * 0x4000 + addr;
            if (off < self.rom.len) return self.rom[off];
            return 0xFF;
        } else if (addr < 0x8000) {
            var bank: u32 = self.rom_bank & 0x1F;
            if (bank == 0) bank = 1;
            bank |= (@as(u32, self.ram_bank) & 0x03) << 5;
            const off = bank * 0x4000 + (addr - 0x4000);
            if (off < self.rom.len) return self.rom[off];
            return 0xFF;
        } else if (addr >= 0xA000 and addr < 0xC000) {
            if (!self.ram_enabled or self.ram.len <= 1) return 0xFF;
            const bank: u32 = if (self.banking_mode == 1) self.ram_bank & 0x03 else 0;
            const off = bank * 0x2000 + (addr - 0xA000);
            if (off < self.ram.len) return self.ram[off];
            return 0xFF;
        }
        return 0xFF;
    }

    fn writeMbc1(self: *Cart, addr: u16, val: u8) void {
        if (addr < 0x2000) {
            self.ram_enabled = (val & 0x0F) == 0x0A;
        } else if (addr < 0x4000) {
            self.rom_bank = (self.rom_bank & 0x60) | (val & 0x1F);
        } else if (addr < 0x6000) {
            self.ram_bank = val & 0x03;
        } else if (addr < 0x8000) {
            self.banking_mode = val & 0x01;
        } else if (addr >= 0xA000 and addr < 0xC000) {
            if (!self.ram_enabled or self.ram.len <= 1) return;
            const bank: u32 = if (self.banking_mode == 1) self.ram_bank & 0x03 else 0;
            const off = bank * 0x2000 + (addr - 0xA000);
            if (off < self.ram.len) self.ram[off] = val;
        }
    }

    fn readMbc2(self: *Cart, addr: u16) u8 {
        if (addr < 0x4000) {
            if (addr < self.rom.len) return self.rom[addr];
            return 0xFF;
        } else if (addr < 0x8000) {
            var bank: u32 = self.rom_bank & 0x0F;
            if (bank == 0) bank = 1;
            const off = bank * 0x4000 + (addr - 0x4000);
            if (off < self.rom.len) return self.rom[off];
            return 0xFF;
        } else if (addr >= 0xA000 and addr < 0xC000) {
            if (!self.ram_enabled) return 0xFF;
            const off = @as(usize, addr - 0xA000) & 0x1FF;
            return self.ram[off] | 0xF0;
        }
        return 0xFF;
    }

    fn writeMbc2(self: *Cart, addr: u16, val: u8) void {
        if (addr < 0x4000) {
            if ((addr & 0x100) == 0) {
                self.ram_enabled = (val & 0x0F) == 0x0A;
            } else {
                var b: u16 = val & 0x0F;
                if (b == 0) b = 1;
                self.rom_bank = b;
            }
            return;
        }
        if (addr >= 0xA000 and addr < 0xC000) {
            if (!self.ram_enabled) return;
            const off = @as(usize, addr - 0xA000) & 0x1FF;
            self.ram[off] = val & 0x0F;
        }
    }

    fn readMbc3(self: *Cart, addr: u16) u8 {
        if (addr < 0x4000) {
            if (addr < self.rom.len) return self.rom[addr];
            return 0xFF;
        } else if (addr < 0x8000) {
            var bank: u32 = self.rom_bank;
            if (bank == 0) bank = 1;
            const off = bank * 0x4000 + (addr - 0x4000);
            if (off < self.rom.len) return self.rom[off];
            return 0xFF;
        } else if (addr >= 0xA000 and addr < 0xC000) {
            if (!self.ram_enabled) return 0xFF;
            if (self.rtc_select >= 0x08 and self.rtc_select <= 0x0C) {
                return self.rtc_latched[self.rtc_select - 0x08];
            }
            const bank: u32 = self.ram_bank;
            const off = bank * 0x2000 + (addr - 0xA000);
            if (off < self.ram.len) return self.ram[off];
            return 0xFF;
        }
        return 0xFF;
    }

    fn writeMbc3(self: *Cart, addr: u16, val: u8) void {
        if (addr < 0x2000) {
            self.ram_enabled = (val & 0x0F) == 0x0A;
        } else if (addr < 0x4000) {
            self.rom_bank = val & 0x7F;
        } else if (addr < 0x6000) {
            if (val <= 0x07) {
                self.ram_bank = val;
                self.rtc_select = 0;
            } else if (val >= 0x08 and val <= 0x0C) {
                self.rtc_select = val;
            }
        } else if (addr < 0x8000) {
            if (self.rtc_latch_prev == 0x00 and val == 0x01) {
                @memcpy(&self.rtc_latched, &self.rtc_regs);
            }
            self.rtc_latch_prev = val;
        } else if (addr >= 0xA000 and addr < 0xC000) {
            if (!self.ram_enabled) return;
            if (self.rtc_select >= 0x08 and self.rtc_select <= 0x0C) {
                self.rtc_regs[self.rtc_select - 0x08] = val;
                return;
            }
            const bank: u32 = self.ram_bank;
            const off = bank * 0x2000 + (addr - 0xA000);
            if (off < self.ram.len) self.ram[off] = val;
        }
    }

    fn readMbc5(self: *Cart, addr: u16) u8 {
        if (addr < 0x4000) {
            if (addr < self.rom.len) return self.rom[addr];
            return 0xFF;
        } else if (addr < 0x8000) {
            const bank: u32 = self.rom_bank;
            const off = bank * 0x4000 + (addr - 0x4000);
            if (off < self.rom.len) return self.rom[off];
            return 0xFF;
        } else if (addr >= 0xA000 and addr < 0xC000) {
            if (!self.ram_enabled or self.ram.len <= 1) return 0xFF;
            const bank: u32 = self.ram_bank & 0x0F;
            const off = bank * 0x2000 + (addr - 0xA000);
            if (off < self.ram.len) return self.ram[off];
            return 0xFF;
        }
        return 0xFF;
    }

    fn writeMbc5(self: *Cart, addr: u16, val: u8) void {
        if (addr < 0x2000) {
            self.ram_enabled = (val & 0x0F) == 0x0A;
        } else if (addr < 0x3000) {
            self.rom_bank = (self.rom_bank & 0x100) | val;
        } else if (addr < 0x4000) {
            self.rom_bank = (self.rom_bank & 0x0FF) | (@as(u16, val & 0x01) << 8);
        } else if (addr < 0x6000) {
            self.ram_bank = val & 0x0F;
        } else if (addr >= 0xA000 and addr < 0xC000) {
            if (!self.ram_enabled or self.ram.len <= 1) return;
            const bank: u32 = self.ram_bank & 0x0F;
            const off = bank * 0x2000 + (addr - 0xA000);
            if (off < self.ram.len) self.ram[off] = val;
        }
    }
};
