const std = @import("std");
const clib = @cImport({
    @cInclude("time.h");
});

pub const SaveKind = enum { none, sram, flash64, flash128, eeprom4, eeprom64 };

pub const Cart = struct {
    gpa: std.mem.Allocator,
    rom: []u8,
    save: []u8,
    save_kind: SaveKind,
    has_battery: bool,
    title: [12]u8 = .{0} ** 12,
    title_len: usize = 0,

    flash_state: u8 = 0,
    flash_bank: u8 = 0,
    flash_id_mode: bool = false,
    flash_erase_mode: bool = false,
    flash_write_byte: bool = false,
    flash_id_manuf: u8 = 0x32,
    flash_id_dev: u8 = 0x1B,

    eeprom_addr: u16 = 0,
    eeprom_addr_bits: u16 = 0,
    eeprom_state: u8 = 0,
    eeprom_buf: u64 = 0,
    eeprom_buf_pos: u32 = 0,
    eeprom_size_bits: u32 = 6,
    eeprom_size_locked: bool = false,

    has_rtc: bool = false,
    gpio_readable: bool = false,
    gpio_data: u8 = 0,
    gpio_dir: u8 = 0,
    rtc_state: u8 = 0,
    rtc_cmd_buf: u8 = 0,
    rtc_cmd_bits: u8 = 0,
    rtc_data_buf: [8]u8 = .{0} ** 8,
    rtc_data_len: u8 = 0,
    rtc_data_pos: u8 = 0,
    rtc_data_bits: u8 = 0,
    rtc_status: u8 = 0x40,
    rtc_last_sck: bool = false,
    rtc_last_cs: bool = false,
    rtc_writing: bool = false,
    rtc_base_unix_secs: i64 = 0,
    rtc_emu_secs: i64 = 0,
    rtc_cycle_accum: u64 = 0,

    pub fn parse(gpa: std.mem.Allocator, data: []const u8) !*Cart {
        if (data.len < 0xC0) return error.RomTooSmall;
        const rom_buf = try gpa.dupe(u8, data);
        errdefer gpa.free(rom_buf);

        var save_kind: SaveKind = .none;
        var save_size: usize = 0;
        const haystack = data;
        if (findString(haystack, "EEPROM_V")) {
            save_kind = .eeprom64;
            save_size = 0x2000;
        } else if (findString(haystack, "FLASH1M_V")) {
            save_kind = .flash128;
            save_size = 0x20000;
        } else if (findString(haystack, "FLASH512_V") or findString(haystack, "FLASH_V")) {
            save_kind = .flash64;
            save_size = 0x10000;
        } else if (findString(haystack, "SRAM_V") or findString(haystack, "SRAM_F_V")) {
            save_kind = .sram;
            save_size = 0x8000;
        } else {
            save_kind = .sram;
            save_size = 0x8000;
        }

        const save_buf = try gpa.alloc(u8, save_size);
        errdefer gpa.free(save_buf);
        @memset(save_buf, 0xFF);

        const cart = try gpa.create(Cart);
        cart.* = .{
            .gpa = gpa,
            .rom = rom_buf,
            .save = save_buf,
            .save_kind = save_kind,
            .has_battery = save_kind != .none,
        };
        if (data.len >= 0xB0) {
            var ti: usize = 0;
            while (ti < 12 and data[0xA0 + ti] != 0) : (ti += 1) {
                const c = data[0xA0 + ti];
                cart.title[ti] = if (c >= 0x20 and c < 0x7F) c else 0x20;
            }
            cart.title_len = ti;
        }
        cart.eeprom_size_bits = if (save_kind == .eeprom64) 14 else 6;
        cart.eeprom_size_locked = false;
        switch (save_kind) {
            .flash64 => {
                cart.flash_id_manuf = 0x32;
                cart.flash_id_dev = 0x1B;
            },
            .flash128 => {
                cart.flash_id_manuf = 0x62;
                cart.flash_id_dev = 0x13;
            },
            else => {},
        }
        cart.has_rtc = detectRtc(haystack, &cart.title);
        cart.rtc_base_unix_secs = @intCast(clib.time(null));
        cart.rtc_emu_secs = 0;
        cart.rtc_cycle_accum = 0;
        return cart;
    }

    pub fn tickRtc(self: *Cart, cycles: u32) void {
        if (!self.has_rtc) return;
        self.rtc_cycle_accum +%= cycles;
        const cps: u64 = 16777216;
        while (self.rtc_cycle_accum >= cps) {
            self.rtc_cycle_accum -= cps;
            self.rtc_emu_secs +%= 1;
        }
    }

    fn detectRtc(haystack: []const u8, title: *const [12]u8) bool {
        if (findString(haystack, "SIIRTC_V")) return true;
        const t = title.*;
        const known = [_][]const u8{
            "POKEMON RUBY",
            "POKEMON SAPP",
            "POKEMON EMER",
            "BOKTAI",
            "BOKTAI 2",
            "SHIN BOKUTAI",
            "SENNENKAZOKU",
            "ROCKMAN EXE 4",
            "ROCKMANEXE4.5",
        };
        for (known) |n| {
            if (n.len > t.len) continue;
            if (std.mem.eql(u8, t[0..n.len], n)) return true;
        }
        return false;
    }

    pub fn deinit(self: *Cart) void {
        self.gpa.free(self.rom);
        self.gpa.free(self.save);
        self.gpa.destroy(self);
    }

    pub fn noteEepromDma(self: *Cart, word_count: u32) void {
        if (self.eeprom_size_locked) return;
        if (self.save_kind != .eeprom4 and self.save_kind != .eeprom64) return;
        const wc = word_count;
        if (wc == 9 or wc == 73) {
            self.eeprom_size_bits = 6;
            self.save_kind = .eeprom4;
            self.eeprom_size_locked = true;
        } else if (wc == 17 or wc == 81) {
            self.eeprom_size_bits = 14;
            self.save_kind = .eeprom64;
            self.eeprom_size_locked = true;
        }
    }

    fn findString(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    pub fn romRead8(self: *Cart, addr: u32) u8 {
        const off: u32 = addr & 0x01FFFFFF;
        if (self.save_kind == .eeprom4 or self.save_kind == .eeprom64) {
            if (((addr & 0xFF000000) >> 24) == 0x0D and self.rom.len <= 0x1000000) return 1;
            if (((addr & 0xFF000000) >> 24) == 0x0D and (addr & 0x01FFFF00) >= 0x01FFFF00) return 1;
        }
        if (self.has_rtc and self.gpio_readable) {
            switch (off) {
                0xC4 => return self.gpioReadData(),
                0xC6 => return self.gpio_dir & 0x0F,
                0xC8 => return if (self.gpio_readable) 1 else 0,
                else => {},
            }
        }
        if (off < self.rom.len) return self.rom[off];
        return @truncate((off >> 1) & 0xFF);
    }

    pub fn romRead16(self: *Cart, addr: u32) u16 {
        const off: u32 = addr & 0x01FFFFFF;
        if (self.save_kind == .eeprom4 or self.save_kind == .eeprom64) {
            const region: u32 = (addr & 0xFF000000) >> 24;
            const large_rom = self.rom.len > 0x1000000;
            const in_eeprom_range = if (large_rom)
                (region == 0x0D and (addr & 0x01FFFF00) == 0x01FFFF00)
            else
                (region == 0x0D);
            if (in_eeprom_range) return self.eepromRead();
        }
        if (self.has_rtc and self.gpio_readable) {
            switch (off) {
                0xC4 => return self.gpioReadData(),
                0xC6 => return self.gpio_dir & 0x0F,
                0xC8 => return if (self.gpio_readable) 1 else 0,
                else => {},
            }
        }
        if (off + 1 < self.rom.len) {
            return @as(u16, self.rom[off]) | (@as(u16, self.rom[off + 1]) << 8);
        }
        return @truncate(off >> 1);
    }

    pub fn romRead32(self: *Cart, addr: u32) u32 {
        const lo: u32 = self.romRead16(addr);
        const hi: u32 = self.romRead16(addr +% 2);
        return lo | (hi << 16);
    }

    pub fn romWrite8(self: *Cart, addr: u32, v: u8) void {
        if (!self.has_rtc) return;
        const off: u32 = addr & 0x01FFFFFF;
        switch (off) {
            0xC4 => self.gpioWriteData(v),
            0xC6 => self.gpio_dir = v & 0x0F,
            0xC8 => self.gpio_readable = (v & 1) != 0,
            else => {},
        }
    }

    pub fn romWrite16(self: *Cart, addr: u32, v: u16) void {
        if (self.save_kind == .eeprom4 or self.save_kind == .eeprom64) {
            const region: u32 = (addr & 0xFF000000) >> 24;
            const large_rom = self.rom.len > 0x1000000;
            const in_eeprom_range = if (large_rom)
                (region == 0x0D and (addr & 0x01FFFF00) == 0x01FFFF00)
            else
                (region == 0x0D);
            if (in_eeprom_range) {
                self.eepromWrite(v);
                return;
            }
        }
        if (self.has_rtc) {
            const off: u32 = addr & 0x01FFFFFF;
            switch (off) {
                0xC4 => self.gpioWriteData(@truncate(v)),
                0xC6 => self.gpio_dir = @as(u8, @truncate(v)) & 0x0F,
                0xC8 => self.gpio_readable = (v & 1) != 0,
                else => {},
            }
        }
    }

    pub fn romWrite32(self: *Cart, addr: u32, v: u32) void {
        self.romWrite16(addr, @truncate(v));
    }

    pub fn sramRead8(self: *Cart, addr: u32) u8 {
        switch (self.save_kind) {
            .sram => {
                const off = addr & 0x7FFF;
                if (off < self.save.len) return self.save[off];
                return 0xFF;
            },
            .flash64, .flash128 => {
                if (self.flash_id_mode) {
                    const a = addr & 0xFFFF;
                    if (a == 0) return self.flash_id_manuf;
                    if (a == 1) return self.flash_id_dev;
                }
                const bank: u32 = if (self.save_kind == .flash128) self.flash_bank else 0;
                const off: u32 = @as(u32, bank) * 0x10000 + (addr & 0xFFFF);
                if (off < self.save.len) return self.save[off];
                return 0xFF;
            },
            else => return 0xFF,
        }
    }

    pub fn sramWrite8(self: *Cart, addr: u32, v: u8) void {
        switch (self.save_kind) {
            .sram => {
                const off = addr & 0x7FFF;
                if (off < self.save.len) self.save[off] = v;
            },
            .flash64, .flash128 => self.flashWrite(addr, v),
            else => {},
        }
    }

    fn flashWrite(self: *Cart, addr: u32, v: u8) void {
        const a = addr & 0xFFFF;
        if (self.flash_write_byte) {
            self.flash_write_byte = false;
            const bank: u32 = if (self.save_kind == .flash128) self.flash_bank else 0;
            const off: u32 = @as(u32, bank) * 0x10000 + a;
            if (off < self.save.len) self.save[off] &= v;
            self.flash_state = 0;
            return;
        }
        if (self.flash_erase_mode and self.flash_state == 2 and (a & 0x0FFF) == 0 and v == 0x30) {
            const bank: u32 = if (self.save_kind == .flash128) self.flash_bank else 0;
            const start: u32 = @as(u32, bank) * 0x10000;
            const sec: u32 = a & 0xF000;
            const sec_start: u32 = start + sec;
            var i: u32 = 0;
            while (i < 0x1000 and sec_start + i < self.save.len) : (i += 1) {
                self.save[sec_start + i] = 0xFF;
            }
            self.flash_state = 0;
            self.flash_erase_mode = false;
            return;
        }
        if (a == 0x5555 and v == 0xAA and self.flash_state == 0) {
            self.flash_state = 1;
            return;
        }
        if (a == 0x2AAA and v == 0x55 and self.flash_state == 1) {
            self.flash_state = 2;
            return;
        }
        if (a == 0x5555 and self.flash_state == 2) {
            switch (v) {
                0x90 => {
                    self.flash_id_mode = true;
                    self.flash_state = 0;
                },
                0xF0 => {
                    self.flash_id_mode = false;
                    self.flash_state = 0;
                },
                0x80 => {
                    self.flash_erase_mode = true;
                    self.flash_state = 0;
                },
                0xA0 => {
                    self.flash_write_byte = true;
                    self.flash_state = 0;
                },
                0xB0 => {
                    self.flash_state = 5;
                },
                0x10 => {
                    if (self.flash_erase_mode) {
                        @memset(self.save, 0xFF);
                        self.flash_erase_mode = false;
                    }
                    self.flash_state = 0;
                },
                else => self.flash_state = 0,
            }
            return;
        }
        if (self.flash_state == 5 and a == 0x0000) {
            self.flash_bank = v & 1;
            self.flash_state = 0;
            return;
        }
        self.flash_state = 0;
    }

    fn eepromRead(self: *Cart) u16 {
        if (self.eeprom_state == 4) {
            if (self.eeprom_buf_pos < 4) {
                self.eeprom_buf_pos += 1;
                return 0;
            }
            const bit_idx: u6 = @intCast(63 - (self.eeprom_buf_pos - 4));
            const bit: u16 = @intCast((self.eeprom_buf >> bit_idx) & 1);
            self.eeprom_buf_pos += 1;
            if (self.eeprom_buf_pos >= 4 + 64) {
                self.eeprom_state = 0;
                self.eeprom_buf_pos = 0;
            }
            return bit;
        }
        return 1;
    }

    fn eepromWrite(self: *Cart, v: u16) void {
        const bit: u1 = @intCast(v & 1);
        switch (self.eeprom_state) {
            0 => {
                if (bit == 1) {
                    self.eeprom_state = 1;
                    self.eeprom_addr_bits = 0;
                    self.eeprom_buf = 0;
                    self.eeprom_buf_pos = 0;
                }
            },
            1 => {
                self.eeprom_state = if (bit == 1) 2 else 3;
            },
            2 => {
                self.eeprom_addr = (self.eeprom_addr << 1) | bit;
                self.eeprom_addr_bits += 1;
                if (self.eeprom_addr_bits >= self.eeprom_size_bits) {
                    self.eeprom_addr &= @intCast((@as(u32, 1) << @intCast(self.eeprom_size_bits)) - 1);
                    self.eeprom_state = 4;
                    self.eeprom_buf_pos = 0;
                    const off: usize = @as(usize, self.eeprom_addr) * 8;
                    if (off + 8 <= self.save.len) {
                        var b: u64 = 0;
                        var i: usize = 0;
                        while (i < 8) : (i += 1) {
                            b = (b << 8) | self.save[off + i];
                        }
                        self.eeprom_buf = b;
                    }
                }
            },
            3 => {
                self.eeprom_addr = (self.eeprom_addr << 1) | bit;
                self.eeprom_addr_bits += 1;
                if (self.eeprom_addr_bits >= self.eeprom_size_bits) {
                    self.eeprom_addr &= @intCast((@as(u32, 1) << @intCast(self.eeprom_size_bits)) - 1);
                    self.eeprom_state = 5;
                    self.eeprom_buf = 0;
                    self.eeprom_buf_pos = 0;
                }
            },
            5 => {
                self.eeprom_buf = (self.eeprom_buf << 1) | bit;
                self.eeprom_buf_pos += 1;
                if (self.eeprom_buf_pos >= 64) {
                    const off: usize = @as(usize, self.eeprom_addr) * 8;
                    if (off + 8 <= self.save.len) {
                        var i: usize = 0;
                        while (i < 8) : (i += 1) {
                            const sh: u6 = @intCast((7 - i) * 8);
                            self.save[off + i] = @truncate(self.eeprom_buf >> sh);
                        }
                    }
                    self.eeprom_state = 6;
                }
            },
            6 => {
                self.eeprom_state = 0;
            },
            else => self.eeprom_state = 0,
        }
    }

    fn gpioReadData(self: *Cart) u8 {
        var v: u8 = self.gpio_data & 0x0F;
        if (self.rtc_state == 2 and (self.gpio_dir & 0x02) == 0) {
            if (self.rtc_data_pos < self.rtc_data_len) {
                const byte = self.rtc_data_buf[self.rtc_data_pos];
                const bit_idx = self.rtc_data_bits;
                const bit = (byte >> @intCast(bit_idx)) & 1;
                if (bit != 0) v |= 0x02 else v &= ~@as(u8, 0x02);
            }
        }
        return v;
    }

    fn gpioWriteData(self: *Cart, val: u8) void {
        const new_data = val & 0x0F;
        const old_sck = self.rtc_last_sck;
        const old_cs = self.rtc_last_cs;
        const new_sck = (new_data & 0x01) != 0;
        const new_cs = (new_data & 0x04) != 0;
        const sio_in = (new_data & 0x02) != 0;

        if (!old_cs and new_cs) {
            self.rtc_state = 1;
            self.rtc_cmd_buf = 0;
            self.rtc_cmd_bits = 0;
            self.rtc_data_pos = 0;
            self.rtc_data_bits = 0;
            self.rtc_writing = false;
        } else if (old_cs and !new_cs) {
            self.rtc_state = 0;
        } else if (new_cs and !old_sck and new_sck) {
            switch (self.rtc_state) {
                1 => {
                    self.rtc_cmd_buf = (self.rtc_cmd_buf << 1);
                    if (sio_in) self.rtc_cmd_buf |= 0x01;
                    self.rtc_cmd_bits +%= 1;
                    if (self.rtc_cmd_bits >= 8) self.rtcParseCommand();
                },
                2 => {
                    if (self.rtc_data_pos < self.rtc_data_len) {
                        self.rtc_data_bits +%= 1;
                        if (self.rtc_data_bits >= 8) {
                            self.rtc_data_bits = 0;
                            self.rtc_data_pos +%= 1;
                            if (self.rtc_data_pos >= self.rtc_data_len) self.rtc_state = 0;
                        }
                    }
                },
                3 => {
                    if (self.rtc_data_pos < self.rtc_data_buf.len) {
                        const bit_idx = self.rtc_data_bits;
                        if (sio_in) self.rtc_data_buf[self.rtc_data_pos] |= (@as(u8, 1) << @intCast(bit_idx));
                        self.rtc_data_bits +%= 1;
                        if (self.rtc_data_bits >= 8) {
                            self.rtc_data_bits = 0;
                            self.rtc_data_pos +%= 1;
                            if (self.rtc_data_pos >= self.rtc_data_len) {
                                self.rtcCommitWrite();
                                self.rtc_state = 0;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        const out_mask = self.gpio_dir & 0x0F;
        self.gpio_data = (self.gpio_data & ~out_mask) | (new_data & out_mask);
        self.rtc_last_sck = new_sck;
        self.rtc_last_cs = new_cs;
    }

    fn rtcParseCommand(self: *Cart) void {
        const cmd = self.rtc_cmd_buf;
        if ((cmd & 0x0F) != 0x06) {
            self.rtc_state = 0;
            return;
        }
        const code: u8 = (cmd >> 4) & 0x07;
        const is_read = (cmd & 0x80) != 0;
        switch (code) {
            0 => {
                self.rtc_status = 0;
                self.rtc_state = 0;
            },
            1 => {
                if (is_read) {
                    self.rtc_data_buf[0] = self.rtc_status;
                    self.rtc_data_len = 1;
                    self.rtc_data_pos = 0;
                    self.rtc_data_bits = 0;
                    self.rtc_state = 2;
                } else {
                    self.rtc_data_len = 1;
                    self.rtc_data_pos = 0;
                    self.rtc_data_bits = 0;
                    @memset(&self.rtc_data_buf, 0);
                    self.rtc_state = 3;
                    self.rtc_writing = true;
                }
            },
            2 => {
                if (is_read) {
                    self.rtcFillDateTime(7);
                    self.rtc_data_len = 7;
                    self.rtc_data_pos = 0;
                    self.rtc_data_bits = 0;
                    self.rtc_state = 2;
                } else {
                    self.rtc_data_len = 7;
                    self.rtc_data_pos = 0;
                    self.rtc_data_bits = 0;
                    @memset(&self.rtc_data_buf, 0);
                    self.rtc_state = 3;
                    self.rtc_writing = true;
                }
            },
            3 => {
                if (is_read) {
                    self.rtcFillDateTime(3);
                    @memcpy(self.rtc_data_buf[0..3], self.rtc_data_buf[4..7]);
                    self.rtc_data_len = 3;
                    self.rtc_data_pos = 0;
                    self.rtc_data_bits = 0;
                    self.rtc_state = 2;
                } else {
                    self.rtc_data_len = 3;
                    self.rtc_data_pos = 0;
                    self.rtc_data_bits = 0;
                    @memset(&self.rtc_data_buf, 0);
                    self.rtc_state = 3;
                    self.rtc_writing = true;
                }
            },
            else => {
                self.rtc_state = 0;
            },
        }
    }

    fn rtcCommitWrite(self: *Cart) void {
        if (!self.rtc_writing) return;
        self.rtc_writing = false;
        if (self.rtc_data_len == 1) {
            self.rtc_status = self.rtc_data_buf[0];
        }
    }

    fn rtcFillDateTime(self: *Cart, len: u8) void {
        _ = len;
        var t: clib.time_t = @intCast(self.rtc_base_unix_secs +% self.rtc_emu_secs);
        const tm_ptr = clib.localtime(&t);
        if (tm_ptr == null) {
            @memset(self.rtc_data_buf[0..7], 0);
            self.rtc_data_buf[7] = 0;
            return;
        }
        const tm = tm_ptr.*;
        const year_full: i32 = @intCast(@as(i64, tm.tm_year) + 1900);
        const year_2dig: u8 = @intCast(@mod(year_full, 100));
        const month: u8 = @intCast(tm.tm_mon + 1);
        const day: u8 = @intCast(tm.tm_mday);
        const weekday: u8 = @intCast(tm.tm_wday & 0x07);
        const hour: u8 = @intCast(tm.tm_hour);
        const minute: u8 = @intCast(tm.tm_min);
        const second: u8 = @intCast(tm.tm_sec);
        self.rtc_data_buf[0] = toBcd(year_2dig);
        self.rtc_data_buf[1] = toBcd(month);
        self.rtc_data_buf[2] = toBcd(day);
        self.rtc_data_buf[3] = weekday;
        self.rtc_data_buf[4] = toBcd(hour);
        self.rtc_data_buf[5] = toBcd(minute);
        self.rtc_data_buf[6] = toBcd(second);
        self.rtc_data_buf[7] = 0;
    }

    fn toBcd(v: u8) u8 {
        return ((v / 10) << 4) | (v % 10);
    }
};
