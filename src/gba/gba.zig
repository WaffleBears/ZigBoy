const std = @import("std");
const Cart = @import("cart.zig").Cart;
const Bus = @import("bus.zig").Bus;
const Cpu = @import("arm.zig").Cpu;
const Ppu = @import("ppu.zig").Ppu;
const Apu = @import("apu.zig").Apu;
const Dma = @import("dma.zig").Dma;
const Timers = @import("timer.zig").Timers;
const Irq = @import("irq.zig").Irq;
const bios = @import("bios.zig");

pub const SCREEN_W: u32 = @import("ppu.zig").SCREEN_W;
pub const SCREEN_H: u32 = @import("ppu.zig").SCREEN_H;

pub const Buttons = struct {
    a: bool = false,
    b: bool = false,
    select: bool = false,
    start: bool = false,
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
    r: bool = false,
    l: bool = false,
};

pub const Gba = struct {
    cart: *Cart,
    cpu: Cpu = undefined,
    bus: *Bus,
    ppu: *Ppu,
    apu: Apu,
    dma: *Dma,
    timers: *Timers,
    irq: *Irq,
    allocator: std.mem.Allocator,
    cycles_in_frame: u64 = 0,
    new_frame: bool = false,
    buttons: Buttons = .{},

    pub fn init(alloc: std.mem.Allocator, rom_bytes: []const u8, sample_rate: u32) !*Gba {
        const cart = try Cart.parse(alloc, rom_bytes);
        errdefer cart.deinit();

        const ppu = try alloc.create(Ppu);
        errdefer alloc.destroy(ppu);
        ppu.* = Ppu.init();

        const irq = try alloc.create(Irq);
        errdefer alloc.destroy(irq);
        irq.* = .{};

        const dma = try alloc.create(Dma);
        errdefer alloc.destroy(dma);
        dma.* = Dma.init(irq);

        const timers = try alloc.create(Timers);
        errdefer alloc.destroy(timers);
        timers.* = Timers.init(irq);

        const apu = try Apu.init(alloc, sample_rate);
        errdefer {
            var apu_mut = apu;
            apu_mut.deinit();
        }

        const bus = try alloc.create(Bus);
        errdefer alloc.destroy(bus);
        bus.* = Bus.init(cart, ppu, undefined, dma, timers, irq);

        const gba = try alloc.create(Gba);
        errdefer alloc.destroy(gba);

        gba.* = .{
            .cart = cart,
            .bus = bus,
            .ppu = ppu,
            .apu = apu,
            .dma = dma,
            .timers = timers,
            .irq = irq,
            .allocator = alloc,
        };
        gba.bus.apu = &gba.apu;

        gba.dma.bus_ptr = @ptrCast(gba.bus);
        gba.dma.read32_fn = busRead32Adapter;
        gba.dma.read16_fn = busRead16Adapter;
        gba.dma.write32_fn = busWrite32Adapter;
        gba.dma.write16_fn = busWrite16Adapter;
        gba.dma.eeprom_ctx = @ptrCast(gba.cart);
        gba.dma.eeprom_notify_fn = eepromNotify;

        gba.timers.apu_event_listener = apuTimerListener;
        gba.timers.apu_ctx = @ptrCast(gba);

        gba.cpu = Cpu.init(gba.bus);
        gba.cpu.skipBios();
        return gba;
    }

    pub fn deinit(self: *Gba) void {
        self.apu.deinit();
        self.cart.deinit();
        self.allocator.destroy(self.bus);
        self.allocator.destroy(self.timers);
        self.allocator.destroy(self.dma);
        self.allocator.destroy(self.irq);
        self.allocator.destroy(self.ppu);
        self.allocator.destroy(self);
    }

    pub fn reset(self: *Gba) void {
        self.ppu.reset();
        self.apu.reset();
        self.dma.reset();
        self.timers.reset();
        self.irq.reset();
        self.cpu.reset();
        self.cpu.skipBios();
    }

    fn busRead32Adapter(ctx: *anyopaque, addr: u32) u32 {
        const b: *Bus = @ptrCast(@alignCast(ctx));
        return b.read32(addr);
    }
    fn busRead16Adapter(ctx: *anyopaque, addr: u32) u16 {
        const b: *Bus = @ptrCast(@alignCast(ctx));
        return b.read16(addr);
    }
    fn busWrite32Adapter(ctx: *anyopaque, addr: u32, v: u32) void {
        const b: *Bus = @ptrCast(@alignCast(ctx));
        b.write32(addr, v);
    }
    fn busWrite16Adapter(ctx: *anyopaque, addr: u32, v: u16) void {
        const b: *Bus = @ptrCast(@alignCast(ctx));
        b.write16(addr, v);
    }

    fn apuTimerListener(ctx: *anyopaque, idx: u3) void {
        const g: *Gba = @ptrCast(@alignCast(ctx));
        g.apu.timerOverflow(idx);
        if (g.apu.fifo_a.count <= 16) g.dma.pending_cycles +%= g.dma.triggerFifoA();
        if (g.apu.fifo_b.count <= 16) g.dma.pending_cycles +%= g.dma.triggerFifoB();
    }

    fn eepromNotify(ctx: *anyopaque, word_count: u32) void {
        const cart: *Cart = @ptrCast(@alignCast(ctx));
        cart.noteEepromDma(word_count);
    }

    pub fn applyButtons(self: *Gba, b: Buttons) void {
        var v: u16 = 0x03FF;
        if (b.a) v &= ~@as(u16, 0x0001);
        if (b.b) v &= ~@as(u16, 0x0002);
        if (b.select) v &= ~@as(u16, 0x0004);
        if (b.start) v &= ~@as(u16, 0x0008);
        if (b.right) v &= ~@as(u16, 0x0010);
        if (b.left) v &= ~@as(u16, 0x0020);
        if (b.up) v &= ~@as(u16, 0x0040);
        if (b.down) v &= ~@as(u16, 0x0080);
        if (b.r) v &= ~@as(u16, 0x0100);
        if (b.l) v &= ~@as(u16, 0x0200);
        self.bus.keyinput = v;
        self.bus.pollKeyIrq();
        self.buttons = b;
    }

    pub fn stepFrame(self: *Gba) void {
        const target: u64 = 280896;
        var done: u64 = 0;
        self.ppu.new_frame = false;
        while (done < target and !self.ppu.new_frame) {
            const cycles = self.cpu.step();
            self.checkSwi();
            self.timers.step(cycles);
            const ppu_res = self.ppu.step(cycles);
            self.apu.step(cycles);
            self.cart.tickRtc(cycles);
            var dma_cycles: u32 = 0;
            if (ppu_res.vblank_started) dma_cycles += self.dma.triggerVBlank();
            if (ppu_res.hblank_started) dma_cycles += self.dma.triggerHBlank();
            if (ppu_res.irqs != 0) {
                if ((ppu_res.irqs & 0x01) != 0) self.irq.request(0);
                if ((ppu_res.irqs & 0x02) != 0) self.irq.request(1);
                if ((ppu_res.irqs & 0x04) != 0) self.irq.request(2);
            }
            done += cycles;
            dma_cycles += self.dma.drainPendingCycles();
            if (dma_cycles > 0) {
                self.timers.step(dma_cycles);
                _ = self.ppu.step(dma_cycles);
                self.apu.step(dma_cycles);
                self.cart.tickRtc(dma_cycles);
                done += dma_cycles;
            }
        }
    }

    fn checkSwi(self: *Gba) void {
        if (self.cpu.r[15] != 0x08) return;
        if (self.cpu.mode() != 0x13) return;
        const ret_pc = self.cpu.r[14];
        const was_thumb = (self.cpu.spsr_svc & 0x20) != 0;
        var swi_byte: u8 = 0;
        if (was_thumb) {
            const op = self.bus.read16(ret_pc -% 2);
            swi_byte = @truncate(op);
        } else {
            const op = self.bus.read32(ret_pc -% 4);
            swi_byte = @truncate(op >> 16);
        }
        if (bios.handleSwi(&self.cpu, self.bus, swi_byte)) {
            const final_ret_pc = self.cpu.r[14];
            const saved = self.cpu.spsr_svc;
            const newm: u8 = @intCast(saved & 0x1F);
            self.cpu.switchMode(newm);
            self.cpu.cpsr = saved;
            self.cpu.r[15] = final_ret_pc;
            if ((self.cpu.cpsr & 0x20) != 0) {
                self.cpu.r[15] &= ~@as(u32, 1);
            } else {
                self.cpu.r[15] &= ~@as(u32, 3);
            }
        }
    }

    pub fn mode(self: *const Gba) u8 {
        return self.cpu.mode();
    }

    pub fn writeFramebuffer(self: *Gba, dst: []u32) void {
        const n = @min(dst.len, self.ppu.framebuffer.len);
        @memcpy(dst[0..n], self.ppu.framebuffer[0..n]);
    }

    pub fn drainAudio(self: *Gba, dst: []f32) usize {
        return self.apu.drain(dst);
    }

    pub fn batteryRam(self: *Gba) ?[]u8 {
        if (!self.cart.has_battery) return null;
        return self.cart.save;
    }

    pub fn loadBatteryBytes(self: *Gba, data: []const u8) void {
        if (!self.cart.has_battery) return;
        const n = @min(data.len, self.cart.save.len);
        @memcpy(self.cart.save[0..n], data[0..n]);
    }

    fn writeChunk(list: *std.ArrayList(u8), gpa: std.mem.Allocator, tag: [4]u8, payload: []const u8) !void {
        try list.appendSlice(gpa, &tag);
        const len: u32 = @intCast(payload.len);
        try list.appendSlice(gpa, std.mem.asBytes(&len));
        try list.appendSlice(gpa, payload);
    }

    pub fn saveStateBytes(self: *Gba) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);
        const w = struct {
            fn put(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, v: T) !void {
                try buf.appendSlice(gpa, std.mem.asBytes(&v));
            }
        };
        try list.appendSlice(self.allocator, "ZBGB\x00\x00\x00\x04");

        var sec: std.ArrayList(u8) = .empty;
        defer sec.deinit(self.allocator);

        sec.clearRetainingCapacity();
        var ri: usize = 0;
        while (ri < 16) : (ri += 1) try w.put(&sec, self.allocator, u32, self.cpu.r[ri]);
        try w.put(&sec, self.allocator, u32, self.cpu.cpsr);
        ri = 0;
        while (ri < 7) : (ri += 1) try w.put(&sec, self.allocator, u32, self.cpu.r_usr[ri]);
        ri = 0;
        while (ri < 7) : (ri += 1) try w.put(&sec, self.allocator, u32, self.cpu.r_fiq[ri]);
        try w.put(&sec, self.allocator, u32, self.cpu.r_svc_sp_lr[0]);
        try w.put(&sec, self.allocator, u32, self.cpu.r_svc_sp_lr[1]);
        try w.put(&sec, self.allocator, u32, self.cpu.r_abt_sp_lr[0]);
        try w.put(&sec, self.allocator, u32, self.cpu.r_abt_sp_lr[1]);
        try w.put(&sec, self.allocator, u32, self.cpu.r_irq_sp_lr[0]);
        try w.put(&sec, self.allocator, u32, self.cpu.r_irq_sp_lr[1]);
        try w.put(&sec, self.allocator, u32, self.cpu.r_und_sp_lr[0]);
        try w.put(&sec, self.allocator, u32, self.cpu.r_und_sp_lr[1]);
        try w.put(&sec, self.allocator, u32, self.cpu.spsr_fiq);
        try w.put(&sec, self.allocator, u32, self.cpu.spsr_svc);
        try w.put(&sec, self.allocator, u32, self.cpu.spsr_abt);
        try w.put(&sec, self.allocator, u32, self.cpu.spsr_irq);
        try w.put(&sec, self.allocator, u32, self.cpu.spsr_und);
        try w.put(&sec, self.allocator, bool, self.cpu.halted);
        try writeChunk(&list, self.allocator, "CPU0".*, sec.items);

        sec.clearRetainingCapacity();
        try sec.appendSlice(self.allocator, &self.bus.ewram);
        try sec.appendSlice(self.allocator, &self.bus.iwram);
        try w.put(&sec, self.allocator, u16, self.bus.keyinput);
        try w.put(&sec, self.allocator, u16, self.bus.keycnt);
        try w.put(&sec, self.allocator, u16, self.bus.waitcnt);
        try w.put(&sec, self.allocator, bool, self.bus.halted);
        try writeChunk(&list, self.allocator, "BUS0".*, sec.items);

        sec.clearRetainingCapacity();
        try sec.appendSlice(self.allocator, &self.ppu.pram);
        try sec.appendSlice(self.allocator, &self.ppu.vram);
        try sec.appendSlice(self.allocator, &self.ppu.oam);
        try w.put(&sec, self.allocator, u16, self.ppu.dispcnt);
        try w.put(&sec, self.allocator, u16, self.ppu.dispstat);
        try w.put(&sec, self.allocator, u16, self.ppu.vcount);
        var bi: usize = 0;
        while (bi < 4) : (bi += 1) {
            try w.put(&sec, self.allocator, u16, self.ppu.bgcnt[bi]);
            try w.put(&sec, self.allocator, u16, self.ppu.bghofs[bi]);
            try w.put(&sec, self.allocator, u16, self.ppu.bgvofs[bi]);
        }
        bi = 0;
        while (bi < 2) : (bi += 1) {
            try w.put(&sec, self.allocator, i16, self.ppu.bgpa[bi]);
            try w.put(&sec, self.allocator, i16, self.ppu.bgpb[bi]);
            try w.put(&sec, self.allocator, i16, self.ppu.bgpc[bi]);
            try w.put(&sec, self.allocator, i16, self.ppu.bgpd[bi]);
            try w.put(&sec, self.allocator, i32, self.ppu.bgx[bi]);
            try w.put(&sec, self.allocator, i32, self.ppu.bgy[bi]);
            try w.put(&sec, self.allocator, i32, self.ppu.bgx_internal[bi]);
            try w.put(&sec, self.allocator, i32, self.ppu.bgy_internal[bi]);
        }
        try w.put(&sec, self.allocator, u16, self.ppu.win_h[0]);
        try w.put(&sec, self.allocator, u16, self.ppu.win_h[1]);
        try w.put(&sec, self.allocator, u16, self.ppu.win_v[0]);
        try w.put(&sec, self.allocator, u16, self.ppu.win_v[1]);
        try w.put(&sec, self.allocator, u16, self.ppu.winin);
        try w.put(&sec, self.allocator, u16, self.ppu.winout);
        try w.put(&sec, self.allocator, u16, self.ppu.mosaic);
        try w.put(&sec, self.allocator, u16, self.ppu.bldcnt);
        try w.put(&sec, self.allocator, u16, self.ppu.bldalpha);
        try w.put(&sec, self.allocator, u16, self.ppu.bldy);
        try w.put(&sec, self.allocator, u32, self.ppu.cycles);
        try w.put(&sec, self.allocator, u32, self.ppu.dot);
        try writeChunk(&list, self.allocator, "PPU0".*, sec.items);

        sec.clearRetainingCapacity();
        var ti: usize = 0;
        while (ti < 4) : (ti += 1) {
            try w.put(&sec, self.allocator, u16, self.timers.t[ti].counter);
            try w.put(&sec, self.allocator, u16, self.timers.t[ti].reload);
            try w.put(&sec, self.allocator, u16, self.timers.t[ti].cnt);
            try w.put(&sec, self.allocator, bool, self.timers.t[ti].enabled);
            try w.put(&sec, self.allocator, bool, self.timers.t[ti].cascade);
            try w.put(&sec, self.allocator, bool, self.timers.t[ti].irq_enable);
            try w.put(&sec, self.allocator, u16, self.timers.t[ti].prescaler);
            try w.put(&sec, self.allocator, u32, self.timers.t[ti].sub_cycles);
        }
        try writeChunk(&list, self.allocator, "TIM0".*, sec.items);

        sec.clearRetainingCapacity();
        var di: usize = 0;
        while (di < 4) : (di += 1) {
            try w.put(&sec, self.allocator, u32, self.dma.ch[di].sad);
            try w.put(&sec, self.allocator, u32, self.dma.ch[di].dad);
            try w.put(&sec, self.allocator, u16, self.dma.ch[di].cnt_l);
            try w.put(&sec, self.allocator, u16, self.dma.ch[di].cnt_h);
            try w.put(&sec, self.allocator, u32, self.dma.ch[di].sad_internal);
            try w.put(&sec, self.allocator, u32, self.dma.ch[di].dad_internal);
            try w.put(&sec, self.allocator, u32, self.dma.ch[di].word_count);
            try w.put(&sec, self.allocator, bool, self.dma.ch[di].enabled);
        }
        try writeChunk(&list, self.allocator, "DMA0".*, sec.items);

        sec.clearRetainingCapacity();
        try w.put(&sec, self.allocator, u16, self.irq.ie);
        try w.put(&sec, self.allocator, u16, self.irq.ifr);
        try w.put(&sec, self.allocator, bool, self.irq.ime);
        try writeChunk(&list, self.allocator, "IRQ0".*, sec.items);

        sec.clearRetainingCapacity();
        try w.put(&sec, self.allocator, u32, @as(u32, @intCast(self.cart.save.len)));
        try sec.appendSlice(self.allocator, self.cart.save);
        try w.put(&sec, self.allocator, u8, @intFromEnum(self.cart.save_kind));
        try w.put(&sec, self.allocator, u8, self.cart.flash_state);
        try w.put(&sec, self.allocator, u8, self.cart.flash_bank);
        try w.put(&sec, self.allocator, bool, self.cart.flash_id_mode);
        try w.put(&sec, self.allocator, bool, self.cart.flash_erase_mode);
        try w.put(&sec, self.allocator, bool, self.cart.flash_write_byte);
        try w.put(&sec, self.allocator, u16, self.cart.eeprom_addr);
        try w.put(&sec, self.allocator, u16, self.cart.eeprom_addr_bits);
        try w.put(&sec, self.allocator, u8, self.cart.eeprom_state);
        try w.put(&sec, self.allocator, u64, self.cart.eeprom_buf);
        try w.put(&sec, self.allocator, u32, self.cart.eeprom_buf_pos);
        try w.put(&sec, self.allocator, u32, self.cart.eeprom_size_bits);
        try w.put(&sec, self.allocator, bool, self.cart.eeprom_size_locked);
        try w.put(&sec, self.allocator, bool, self.cart.has_rtc);
        try w.put(&sec, self.allocator, u8, self.cart.gpio_data);
        try w.put(&sec, self.allocator, u8, self.cart.gpio_dir);
        try w.put(&sec, self.allocator, bool, self.cart.gpio_readable);
        try w.put(&sec, self.allocator, u8, self.cart.rtc_state);
        try w.put(&sec, self.allocator, u8, self.cart.rtc_cmd_buf);
        try w.put(&sec, self.allocator, u8, self.cart.rtc_cmd_bits);
        try sec.appendSlice(self.allocator, &self.cart.rtc_data_buf);
        try w.put(&sec, self.allocator, u8, self.cart.rtc_data_len);
        try w.put(&sec, self.allocator, u8, self.cart.rtc_data_pos);
        try w.put(&sec, self.allocator, u8, self.cart.rtc_data_bits);
        try w.put(&sec, self.allocator, u8, self.cart.rtc_status);
        try w.put(&sec, self.allocator, bool, self.cart.rtc_last_sck);
        try w.put(&sec, self.allocator, bool, self.cart.rtc_last_cs);
        try w.put(&sec, self.allocator, bool, self.cart.rtc_writing);
        try writeChunk(&list, self.allocator, "CRT0".*, sec.items);

        try writeChunk(&list, self.allocator, "END0".*, &.{});

        return list.toOwnedSlice(self.allocator);
    }

    pub fn loadStateBytes(self: *Gba, data: []const u8) !void {
        if (data.len < 8) return error.Truncated;
        if (!std.mem.eql(u8, data[0..8], "ZBGB\x00\x00\x00\x04")) return error.BadMagic;
        var p: usize = 8;
        while (p < data.len) {
            if (p + 8 > data.len) return error.Truncated;
            const tag = data[p..][0..4].*;
            const len = std.mem.readInt(u32, data[p + 4 ..][0..4], .little);
            p += 8;
            if (p + len > data.len) return error.Truncated;
            const chunk = data[p .. p + len];
            p += len;
            if (std.mem.eql(u8, &tag, "END0")) break;
            if (std.mem.eql(u8, &tag, "CPU0")) {
                try self.loadCpuChunk(chunk);
            } else if (std.mem.eql(u8, &tag, "BUS0")) {
                try self.loadBusChunk(chunk);
            } else if (std.mem.eql(u8, &tag, "PPU0")) {
                try self.loadPpuChunk(chunk);
            } else if (std.mem.eql(u8, &tag, "TIM0")) {
                try self.loadTimChunk(chunk);
            } else if (std.mem.eql(u8, &tag, "DMA0")) {
                try self.loadDmaChunk(chunk);
            } else if (std.mem.eql(u8, &tag, "IRQ0")) {
                try self.loadIrqChunk(chunk);
            } else if (std.mem.eql(u8, &tag, "CRT0")) {
                try self.loadCartChunk(chunk);
            }
        }
    }

    const ChunkReader = struct {
        d: []const u8,
        p: usize = 0,
        fn read(self: *ChunkReader, comptime T: type, dst: *T) !void {
            const sz = @sizeOf(T);
            if (self.p + sz > self.d.len) return error.Truncated;
            @memcpy(std.mem.asBytes(dst), self.d[self.p .. self.p + sz]);
            self.p += sz;
        }
        fn readSlice(self: *ChunkReader, dst: []u8) !void {
            if (self.p + dst.len > self.d.len) return error.Truncated;
            @memcpy(dst, self.d[self.p .. self.p + dst.len]);
            self.p += dst.len;
        }
        fn skip(self: *ChunkReader, n: usize) !void {
            if (self.p + n > self.d.len) return error.Truncated;
            self.p += n;
        }
    };

    fn loadCpuChunk(self: *Gba, chunk: []const u8) !void {
        var r: ChunkReader = .{ .d = chunk };
        var ri: usize = 0;
        while (ri < 16) : (ri += 1) try r.read(u32, &self.cpu.r[ri]);
        try r.read(u32, &self.cpu.cpsr);
        ri = 0;
        while (ri < 7) : (ri += 1) try r.read(u32, &self.cpu.r_usr[ri]);
        ri = 0;
        while (ri < 7) : (ri += 1) try r.read(u32, &self.cpu.r_fiq[ri]);
        try r.read(u32, &self.cpu.r_svc_sp_lr[0]);
        try r.read(u32, &self.cpu.r_svc_sp_lr[1]);
        try r.read(u32, &self.cpu.r_abt_sp_lr[0]);
        try r.read(u32, &self.cpu.r_abt_sp_lr[1]);
        try r.read(u32, &self.cpu.r_irq_sp_lr[0]);
        try r.read(u32, &self.cpu.r_irq_sp_lr[1]);
        try r.read(u32, &self.cpu.r_und_sp_lr[0]);
        try r.read(u32, &self.cpu.r_und_sp_lr[1]);
        try r.read(u32, &self.cpu.spsr_fiq);
        try r.read(u32, &self.cpu.spsr_svc);
        try r.read(u32, &self.cpu.spsr_abt);
        try r.read(u32, &self.cpu.spsr_irq);
        try r.read(u32, &self.cpu.spsr_und);
        try r.read(bool, &self.cpu.halted);
    }

    fn loadBusChunk(self: *Gba, chunk: []const u8) !void {
        var r: ChunkReader = .{ .d = chunk };
        try r.readSlice(&self.bus.ewram);
        try r.readSlice(&self.bus.iwram);
        try r.read(u16, &self.bus.keyinput);
        try r.read(u16, &self.bus.keycnt);
        try r.read(u16, &self.bus.waitcnt);
        try r.read(bool, &self.bus.halted);
        self.bus.refreshAccessCosts();
    }

    fn loadPpuChunk(self: *Gba, chunk: []const u8) !void {
        var r: ChunkReader = .{ .d = chunk };
        try r.readSlice(&self.ppu.pram);
        try r.readSlice(&self.ppu.vram);
        try r.readSlice(&self.ppu.oam);
        try r.read(u16, &self.ppu.dispcnt);
        try r.read(u16, &self.ppu.dispstat);
        try r.read(u16, &self.ppu.vcount);
        var bi: usize = 0;
        while (bi < 4) : (bi += 1) {
            try r.read(u16, &self.ppu.bgcnt[bi]);
            try r.read(u16, &self.ppu.bghofs[bi]);
            try r.read(u16, &self.ppu.bgvofs[bi]);
        }
        bi = 0;
        while (bi < 2) : (bi += 1) {
            try r.read(i16, &self.ppu.bgpa[bi]);
            try r.read(i16, &self.ppu.bgpb[bi]);
            try r.read(i16, &self.ppu.bgpc[bi]);
            try r.read(i16, &self.ppu.bgpd[bi]);
            try r.read(i32, &self.ppu.bgx[bi]);
            try r.read(i32, &self.ppu.bgy[bi]);
            try r.read(i32, &self.ppu.bgx_internal[bi]);
            try r.read(i32, &self.ppu.bgy_internal[bi]);
        }
        try r.read(u16, &self.ppu.win_h[0]);
        try r.read(u16, &self.ppu.win_h[1]);
        try r.read(u16, &self.ppu.win_v[0]);
        try r.read(u16, &self.ppu.win_v[1]);
        try r.read(u16, &self.ppu.winin);
        try r.read(u16, &self.ppu.winout);
        try r.read(u16, &self.ppu.mosaic);
        try r.read(u16, &self.ppu.bldcnt);
        try r.read(u16, &self.ppu.bldalpha);
        try r.read(u16, &self.ppu.bldy);
        try r.read(u32, &self.ppu.cycles);
        try r.read(u32, &self.ppu.dot);
    }

    fn loadTimChunk(self: *Gba, chunk: []const u8) !void {
        var r: ChunkReader = .{ .d = chunk };
        var ti: usize = 0;
        while (ti < 4) : (ti += 1) {
            try r.read(u16, &self.timers.t[ti].counter);
            try r.read(u16, &self.timers.t[ti].reload);
            try r.read(u16, &self.timers.t[ti].cnt);
            try r.read(bool, &self.timers.t[ti].enabled);
            try r.read(bool, &self.timers.t[ti].cascade);
            try r.read(bool, &self.timers.t[ti].irq_enable);
            try r.read(u16, &self.timers.t[ti].prescaler);
            try r.read(u32, &self.timers.t[ti].sub_cycles);
        }
    }

    fn loadDmaChunk(self: *Gba, chunk: []const u8) !void {
        var r: ChunkReader = .{ .d = chunk };
        var di: usize = 0;
        while (di < 4) : (di += 1) {
            try r.read(u32, &self.dma.ch[di].sad);
            try r.read(u32, &self.dma.ch[di].dad);
            try r.read(u16, &self.dma.ch[di].cnt_l);
            try r.read(u16, &self.dma.ch[di].cnt_h);
            try r.read(u32, &self.dma.ch[di].sad_internal);
            try r.read(u32, &self.dma.ch[di].dad_internal);
            try r.read(u32, &self.dma.ch[di].word_count);
            try r.read(bool, &self.dma.ch[di].enabled);
        }
    }

    fn loadIrqChunk(self: *Gba, chunk: []const u8) !void {
        var r: ChunkReader = .{ .d = chunk };
        try r.read(u16, &self.irq.ie);
        try r.read(u16, &self.irq.ifr);
        try r.read(bool, &self.irq.ime);
    }

    fn loadCartChunk(self: *Gba, chunk: []const u8) !void {
        var r: ChunkReader = .{ .d = chunk };
        var save_len: u32 = 0;
        try r.read(u32, &save_len);
        if (save_len == self.cart.save.len) {
            try r.readSlice(self.cart.save);
        } else {
            try r.skip(save_len);
        }
        var save_kind_u: u8 = 0;
        try r.read(u8, &save_kind_u);
        if (save_kind_u > 5) return error.BadSaveKind;
        self.cart.save_kind = @enumFromInt(save_kind_u);
        try r.read(u8, &self.cart.flash_state);
        try r.read(u8, &self.cart.flash_bank);
        try r.read(bool, &self.cart.flash_id_mode);
        try r.read(bool, &self.cart.flash_erase_mode);
        try r.read(bool, &self.cart.flash_write_byte);
        try r.read(u16, &self.cart.eeprom_addr);
        try r.read(u16, &self.cart.eeprom_addr_bits);
        try r.read(u8, &self.cart.eeprom_state);
        try r.read(u64, &self.cart.eeprom_buf);
        try r.read(u32, &self.cart.eeprom_buf_pos);
        try r.read(u32, &self.cart.eeprom_size_bits);
        try r.read(bool, &self.cart.eeprom_size_locked);
        try r.read(bool, &self.cart.has_rtc);
        try r.read(u8, &self.cart.gpio_data);
        try r.read(u8, &self.cart.gpio_dir);
        try r.read(bool, &self.cart.gpio_readable);
        try r.read(u8, &self.cart.rtc_state);
        try r.read(u8, &self.cart.rtc_cmd_buf);
        try r.read(u8, &self.cart.rtc_cmd_bits);
        try r.readSlice(&self.cart.rtc_data_buf);
        try r.read(u8, &self.cart.rtc_data_len);
        try r.read(u8, &self.cart.rtc_data_pos);
        try r.read(u8, &self.cart.rtc_data_bits);
        try r.read(u8, &self.cart.rtc_status);
        try r.read(bool, &self.cart.rtc_last_sck);
        try r.read(bool, &self.cart.rtc_last_cs);
        try r.read(bool, &self.cart.rtc_writing);
    }

    pub fn title(self: *const Gba) []const u8 {
        return self.cart.title[0..self.cart.title_len];
    }
};
