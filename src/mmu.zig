const Cart = @import("cart.zig").Cart;
const Ppu = @import("ppu.zig").Ppu;
const Apu = @import("apu.zig").Apu;
const Timer = @import("timer.zig").Timer;
const Joypad = @import("joypad.zig").Joypad;
const Mode = @import("ppu.zig").Mode;

pub const Mmu = struct {
    cart: *Cart,
    ppu: *Ppu,
    apu: *Apu,
    timer: *Timer,
    joypad: *Joypad,

    wram: [0x8000]u8 = .{0} ** 0x8000,
    hram: [0x7F]u8 = .{0} ** 0x7F,
    ie: u8 = 0,
    if_reg: u8 = 0xE1,
    svbk: u8 = 1,
    key1: u8 = 0,
    boot_off: u8 = 1,
    cgb_mode: bool = false,

    oam_dma_active: bool = false,
    oam_dma_src: u16 = 0,
    oam_dma_pos: u8 = 0,
    oam_dma_cycles: u32 = 0,

    rp: u8 = 0x3E,
    serial_data: u8 = 0,
    serial_ctrl: u8 = 0x7E,

    last_hdma_ly: i16 = -1,

    pub fn init(cart: *Cart, ppu: *Ppu, apu: *Apu, timer: *Timer, joypad: *Joypad, cgb: bool) Mmu {
        return .{
            .cart = cart,
            .ppu = ppu,
            .apu = apu,
            .timer = timer,
            .joypad = joypad,
            .cgb_mode = cgb,
        };
    }

    pub fn reset(self: *Mmu, cgb: bool) void {
        @memset(&self.wram, 0);
        @memset(&self.hram, 0);
        self.ie = 0;
        self.if_reg = 0xE1;
        self.svbk = 1;
        self.key1 = 0;
        self.boot_off = 1;
        self.cgb_mode = cgb;
        self.oam_dma_active = false;
        self.oam_dma_pos = 0;
        self.oam_dma_cycles = 0;
        self.rp = 0x3E;
        self.serial_data = 0;
        self.serial_ctrl = 0x7E;
        self.last_hdma_ly = -1;
    }

    fn wramBank(self: *Mmu) usize {
        var b: usize = self.svbk & 0x07;
        if (b == 0) b = 1;
        return b;
    }

    pub fn read(self: *Mmu, addr: u16) u8 {
        if (addr < 0x8000) return self.cart.read(addr);
        if (addr < 0xA000) return self.ppu.readVram(addr);
        if (addr < 0xC000) return self.cart.read(addr);
        if (addr < 0xD000) return self.wram[addr - 0xC000];
        if (addr < 0xE000) return self.wram[self.wramBank() * 0x1000 + (addr - 0xD000)];
        if (addr < 0xFE00) return self.read(addr - 0x2000);
        if (addr < 0xFEA0) {
            if (self.oam_dma_active) return 0xFF;
            return self.ppu.readOam(addr);
        }
        if (addr < 0xFF00) return 0xFF;
        if (addr == 0xFFFF) return self.ie;
        if (addr >= 0xFF80) return self.hram[addr - 0xFF80];
        return self.readIo(addr);
    }

    pub fn write(self: *Mmu, addr: u16, val: u8) void {
        if (addr < 0x8000) {
            self.cart.write(addr, val);
            return;
        }
        if (addr < 0xA000) {
            self.ppu.writeVram(addr, val);
            return;
        }
        if (addr < 0xC000) {
            self.cart.write(addr, val);
            return;
        }
        if (addr < 0xD000) {
            self.wram[addr - 0xC000] = val;
            return;
        }
        if (addr < 0xE000) {
            self.wram[self.wramBank() * 0x1000 + (addr - 0xD000)] = val;
            return;
        }
        if (addr < 0xFE00) {
            self.write(addr - 0x2000, val);
            return;
        }
        if (addr < 0xFEA0) {
            if (!self.oam_dma_active) self.ppu.writeOam(addr, val);
            return;
        }
        if (addr < 0xFF00) return;
        if (addr == 0xFFFF) {
            self.ie = val;
            return;
        }
        if (addr >= 0xFF80) {
            self.hram[addr - 0xFF80] = val;
            return;
        }
        self.writeIo(addr, val);
    }

    fn readIo(self: *Mmu, addr: u16) u8 {
        return switch (addr) {
            0xFF00 => self.joypad.read(),
            0xFF01 => self.serial_data,
            0xFF02 => self.serial_ctrl | 0x7E,
            0xFF04...0xFF07 => self.timer.read(addr),
            0xFF0F => self.if_reg | 0xE0,
            0xFF10...0xFF3F => self.apu.read(addr),
            0xFF40...0xFF4B => self.ppu.readReg(addr),
            0xFF4D => if (self.cgb_mode) self.key1 | 0x7E else 0xFF,
            0xFF4F => self.ppu.readReg(addr),
            0xFF50 => self.boot_off,
            0xFF51...0xFF55 => self.ppu.readReg(addr),
            0xFF56 => if (self.cgb_mode) self.rp else 0xFF,
            0xFF68...0xFF6C => self.ppu.readReg(addr),
            0xFF70 => if (self.cgb_mode) (self.svbk | 0xF8) else 0xFF,
            else => 0xFF,
        };
    }

    fn writeIo(self: *Mmu, addr: u16, val: u8) void {
        switch (addr) {
            0xFF00 => self.joypad.write(val),
            0xFF01 => self.serial_data = val,
            0xFF02 => self.serial_ctrl = val,
            0xFF04...0xFF07 => self.timer.write(addr, val),
            0xFF0F => self.if_reg = val | 0xE0,
            0xFF10...0xFF3F => self.apu.write(addr, val),
            0xFF46 => self.startOamDma(val),
            0xFF40...0xFF45, 0xFF47...0xFF4B => self.ppu.writeReg(addr, val),
            0xFF4D => if (self.cgb_mode) {
                self.key1 = (self.key1 & 0x80) | (val & 0x01);
            },
            0xFF4F => self.ppu.writeReg(addr, val),
            0xFF50 => self.boot_off = val,
            0xFF51...0xFF54 => self.ppu.writeReg(addr, val),
            0xFF55 => {
                if (!self.cgb_mode) {
                    self.ppu.writeReg(addr, val);
                    return;
                }
                const was_active = self.ppu.hdma_active;
                if ((val & 0x80) == 0 and was_active) {
                    self.ppu.hdma_active = false;
                    self.ppu.hdma_len = (self.ppu.hdma_len & 0x7F) | 0x80;
                    return;
                }
                self.ppu.writeReg(addr, val);
                if ((val & 0x80) == 0) {
                    self.runGdma();
                } else {
                    self.last_hdma_ly = -1;
                }
            },
            0xFF56 => if (self.cgb_mode) {
                self.rp = (self.rp & 0x02) | (val & 0xFD);
            },
            0xFF68...0xFF6C => self.ppu.writeReg(addr, val),
            0xFF70 => if (self.cgb_mode) {
                self.svbk = val & 0x07;
            },
            else => {},
        }
    }

    fn startOamDma(self: *Mmu, val: u8) void {
        self.oam_dma_active = true;
        self.oam_dma_src = @as(u16, val) << 8;
        self.oam_dma_pos = 0;
        self.oam_dma_cycles = 0;
    }

    pub fn stepOamDma(self: *Mmu, cycles: u32) void {
        if (!self.oam_dma_active) return;
        self.oam_dma_cycles += cycles;
        while (self.oam_dma_cycles >= 4 and self.oam_dma_pos < 0xA0) {
            self.oam_dma_cycles -= 4;
            const src = self.oam_dma_src + self.oam_dma_pos;
            const v = self.readDmaSrc(src);
            self.ppu.oam[self.oam_dma_pos] = v;
            self.oam_dma_pos += 1;
        }
        if (self.oam_dma_pos >= 0xA0) self.oam_dma_active = false;
    }

    fn readDmaSrc(self: *Mmu, addr: u16) u8 {
        if (addr < 0x8000) return self.cart.read(addr);
        if (addr < 0xA000) return self.ppu.readVram(addr);
        if (addr < 0xC000) return self.cart.read(addr);
        if (addr < 0xD000) return self.wram[addr - 0xC000];
        if (addr < 0xE000) return self.wram[self.wramBank() * 0x1000 + (addr - 0xD000)];
        return 0xFF;
    }

    fn runGdma(self: *Mmu) void {
        const blocks: u32 = @as(u32, self.ppu.hdma_len) + 1;
        var i: u32 = 0;
        while (i < blocks * 0x10) : (i += 1) {
            const v = self.readDmaSrc(self.ppu.hdma_src +% @as(u16, @intCast(i)));
            self.ppu.writeVram(0x8000 +% self.ppu.hdma_dst +% @as(u16, @intCast(i)), v);
        }
        self.ppu.hdma_src +%= @as(u16, @intCast(blocks * 0x10));
        self.ppu.hdma_dst +%= @as(u16, @intCast(blocks * 0x10));
        self.ppu.hdma_active = false;
        self.ppu.hdma_blocks_left = 0;
        self.ppu.hdma_len = 0xFF;
    }

    pub fn requestInterrupt(self: *Mmu, bit: u3) void {
        self.if_reg |= (@as(u8, 1) << bit);
    }

    pub fn collectIrqs(self: *Mmu) void {
        if (self.ppu.irq_vblank) {
            self.requestInterrupt(0);
            self.ppu.irq_vblank = false;
        }
        if (self.ppu.irq_stat) {
            self.requestInterrupt(1);
            self.ppu.irq_stat = false;
        }
        if (self.timer.irq_request) {
            self.requestInterrupt(2);
            self.timer.irq_request = false;
        }
        if (self.joypad.irq_request) {
            self.requestInterrupt(4);
            self.joypad.irq_request = false;
        }
    }

    pub fn hdmaStep(self: *Mmu) void {
        if (self.ppu.ly == 0 and self.ppu.mode == .oam) self.last_hdma_ly = -1;
        if (!self.ppu.hdma_active) return;
        if (self.ppu.mode != .hblank) return;
        if (self.ppu.ly >= 144) return;
        if (@as(i16, self.ppu.ly) == self.last_hdma_ly) return;
        self.last_hdma_ly = self.ppu.ly;
        var i: u8 = 0;
        while (i < 0x10) : (i += 1) {
            const v = self.readDmaSrc(self.ppu.hdma_src +% i);
            self.ppu.writeVram(0x8000 +% self.ppu.hdma_dst +% i, v);
        }
        self.ppu.hdma_src +%= 0x10;
        self.ppu.hdma_dst +%= 0x10;
        if (self.ppu.hdma_blocks_left > 0) self.ppu.hdma_blocks_left -= 1;
        if (self.ppu.hdma_blocks_left == 0) {
            self.ppu.hdma_active = false;
            self.ppu.hdma_len = 0xFF;
        }
    }
};
