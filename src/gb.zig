const std = @import("std");
const Cart = @import("cart.zig").Cart;
const Cpu = @import("cpu.zig").Cpu;
const Mmu = @import("mmu.zig").Mmu;
const Ppu = @import("ppu.zig").Ppu;
const Apu = @import("apu.zig").Apu;
const Timer = @import("timer.zig").Timer;
const Joypad = @import("joypad.zig").Joypad;
pub const Button = @import("joypad.zig").Button;
const savestate = @import("savestate.zig");

pub const CYCLES_PER_FRAME: u32 = 70224;
pub const SCREEN_W = @import("ppu.zig").W;
pub const SCREEN_H = @import("ppu.zig").H;

pub const Gb = struct {
    cart: *Cart,
    cpu: Cpu = undefined,
    mmu: Mmu = undefined,
    ppu: Ppu = undefined,
    apu: Apu = undefined,
    timer: Timer = .{},
    joypad: Joypad = .{},
    cgb_mode: bool,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, rom_bytes: []const u8, sample_rate: u32) !*Gb {
        const cart = try alloc.create(Cart);
        errdefer alloc.destroy(cart);
        cart.* = try Cart.loadFromBytes(alloc, rom_bytes);
        errdefer cart.deinit();
        const cgb = cart.isCgb();

        var apu = try Apu.init(alloc, sample_rate);
        errdefer apu.deinit();

        const gb = try alloc.create(Gb);
        errdefer alloc.destroy(gb);

        gb.* = .{
            .cart = cart,
            .cgb_mode = cgb,
            .allocator = alloc,
            .ppu = Ppu.init(cgb),
            .apu = apu,
        };
        gb.timer = .{};
        gb.joypad = .{};
        gb.mmu = Mmu.init(gb.cart, &gb.ppu, &gb.apu, &gb.timer, &gb.joypad, cgb);
        gb.cpu = Cpu.init(&gb.mmu);
        gb.cpu.resetPostBoot(cgb);
        return gb;
    }

    pub fn deinit(self: *Gb) void {
        self.apu.deinit();
        self.cart.deinit();
        self.allocator.destroy(self.cart);
        self.allocator.destroy(self);
    }

    pub fn reset(self: *Gb) void {
        self.mmu.reset(self.cgb_mode);
        self.ppu.reset(self.cgb_mode);
        self.timer.reset();
        self.apu.reset();
        self.joypad.reset();
        self.cpu.resetPostBoot(self.cgb_mode);
    }

    pub fn stepFrame(self: *Gb) void {
        const target: u32 = if (self.cpu.double_speed) CYCLES_PER_FRAME * 2 else CYCLES_PER_FRAME;
        var cycles: u32 = 0;
        self.ppu.new_frame = false;
        while (cycles < target and !self.ppu.new_frame) {
            const c = self.cpu.step();
            self.timer.step(c);
            self.mmu.stepOamDma(c);
            const eff = if (self.cpu.double_speed) c / 2 else c;
            self.ppu.step(eff);
            self.apu.step(c, self.cpu.double_speed);
            self.mmu.hdmaStep();
            self.mmu.collectIrqs();
            cycles += c;
        }
    }

    pub fn loadStateBytesSafe(self: *Gb, data: []const u8) !void {
        const backup = try savestate.save(self.allocator, self);
        defer self.allocator.free(backup);
        savestate.load(data, self) catch |e| {
            savestate.load(backup, self) catch {};
            return e;
        };
    }

    pub fn press(self: *Gb, b: Button) void {
        self.joypad.press(b);
    }

    pub fn release(self: *Gb, b: Button) void {
        self.joypad.release(b);
    }

    pub fn writeFramebuffer(self: *Gb, dst: []u32) void {
        const n = @min(dst.len, self.ppu.framebuffer.len);
        @memcpy(dst[0..n], self.ppu.framebuffer[0..n]);
    }

    pub fn drainAudio(self: *Gb, dst: []f32) usize {
        return self.apu.drain(dst);
    }

    pub fn saveStateBytes(self: *Gb) ![]u8 {
        return savestate.save(self.allocator, self);
    }

    pub fn loadStateBytes(self: *Gb, data: []const u8) !void {
        return self.loadStateBytesSafe(data);
    }

    pub fn batteryRam(self: *Gb) ?[]u8 {
        if (!self.cart.has_battery) return null;
        return self.cart.ram;
    }

    pub fn loadBatteryBytes(self: *Gb, data: []const u8) void {
        if (!self.cart.has_battery) return;
        if (data.len != self.cart.ram.len) return;
        @memcpy(self.cart.ram, data);
    }
};
