const apu = @import("apu.zig");
const bus = @import("bus.zig");
const cartridge = @import("cartridge.zig");
const clock = @import("clock.zig");
const cpu = @import("cpu.zig");
const dma = @import("dma.zig");
const interrupts = @import("interrupts.zig");
const joypad = @import("joypad.zig");
const model = @import("model.zig");
const persistence = @import("persistence.zig");
const ppu = @import("ppu.zig");
const serial = @import("serial.zig");
const timer = @import("timer.zig");

pub const Machine = struct {
    revision: model.Revision,
    cartridge: cartridge.Cartridge,
    bus: bus.Bus = .{},
    io: [0x80]u8,
    cpu: cpu.Cpu,
    timer: timer.Timer,
    interrupts: interrupts.Interrupts,
    dma: dma.Dma,
    ppu: ppu.Ppu = .{},
    apu: apu.Apu = .{},
    joypad: joypad.Joypad,
    serial: serial.Serial,
    persistence: persistence.Persistence = .{},
    guest_clock: clock.Clock = .{},
    guest_t_cycles: u64 = 0,

    pub fn init(revision: model.Revision, cart: cartridge.Cartridge) Machine {
        const boot = model.profile(revision);
        return .{
            .revision = revision,
            .cartridge = cart,
            .io = boot.mmio,
            .cpu = cpu.Cpu.init(boot),
            .timer = timer.Timer.init(postBootDivider(revision), boot.mmio[0x05], boot.mmio[0x06], boot.mmio[0x07]),
            .interrupts = .{ .request = boot.mmio[0x0F] & 0x1F, .enable = boot.ie },
            .dma = .{ .source_high = boot.mmio[0x46], .active_source_high = boot.mmio[0x46] },
            .joypad = .{ .select = boot.mmio[0x00] & 0x30 },
            .serial = .{ .data = boot.mmio[0x01], .control = boot.mmio[0x02] },
            .ppu = .{
                .lcdc = boot.mmio[0x40],
                .stat = boot.mmio[0x41],
                .scy = boot.mmio[0x42],
                .scx = boot.mmio[0x43],
                .ly = boot.mmio[0x44],
                .lyc = boot.mmio[0x45],
                .bgp = boot.mmio[0x47],
                .obp0 = boot.mmio[0x48],
                .obp1 = boot.mmio[0x49],
                .wy = boot.mmio[0x4A],
                .wx = boot.mmio[0x4B],
            },
        };
    }

    pub fn deinit(self: *Machine) void {
        self.cartridge.deinit();
    }

    pub fn devices(self: *Machine) bus.Devices {
        return .{
            .cartridge = &self.cartridge,
            .video_ram = &self.ppu.vram,
            .object_attribute_memory = &self.ppu.oam,
            .io = &self.io,
            .interrupt_enable = &self.interrupts.enable,
            .vram_blocked = self.ppuAccessBlocked(),
            .oam_blocked = self.oamAccessBlocked(),
        };
    }

    /// CPU-visible access. DMA contention is evaluated here so the DMA engine
    /// can use the same owned storage without recursively blocking itself.
    pub fn read(self: *Machine, address: u16) u8 {
        if (address == 0xFF46) return self.dma.source_high;
        if (self.dma.active and address < 0xFF80) return self.bus.open_bus;
        if (address == 0xFFFF) return if (self.dma.active) self.bus.open_bus else self.interrupts.enable;
        if (address >= 0xFF00 and address <= 0xFF7F) return self.readIo(@truncate(address));
        const view = self.devices();
        return self.bus.read(view, address);
    }

    pub fn write(self: *Machine, address: u16, value: u8) void {
        if (address == 0xFF46) {
            self.writeIo(0x46, value);
            return;
        }
        if (self.dma.active and address < 0xFF80) return;
        if (address == 0xFFFF) {
            if (!self.dma.active) self.interrupts.enable = value;
            return;
        }
        if (address >= 0xFF00 and address <= 0xFF7F) {
            self.writeIo(@truncate(address), value);
            return;
        }
        const view = self.devices();
        self.bus.write(view, address, value);
    }

    pub fn cpuBus(self: *Machine) cpu.Bus {
        return .{
            .context = self,
            .read_fn = cpuRead,
            .write_fn = cpuWrite,
            .idle_fn = cpuIdle,
            .pending_interrupts_fn = cpuPendingInterrupts,
            .acknowledge_interrupt_fn = cpuAcknowledgeInterrupt,
        };
    }

    pub fn stepCpu(self: *Machine) cpu.StepResult {
        const result = self.cpu.step(self.cpuBus(), self.interrupts.pending());
        if (result.kind == .instruction and result.opcode == 0x10) {
            self.timer.writeDiv();
            if ((self.joypad.read() & 0x0F) != 0x0F) self.cpu.requestStopWake();
        }
        return result;
    }

    /// Runs complete SM83 operations until the granted budget is consumed.
    /// The only possible overshoot is the currently executing instruction.
    pub fn runTcycles(self: *Machine, budget: u32) u32 {
        const start = self.guest_t_cycles;
        while (self.guest_t_cycles - start < budget) {
            const result = self.stepCpu();
            if (result.kind == .illegal) break;
        }
        return @intCast(self.guest_t_cycles - start);
    }

    pub fn runHostSlice(self: *Machine, host_nanoseconds: u64) u32 {
        const budget = self.guest_clock.budget(host_nanoseconds);
        return if (budget == 0) 0 else self.runTcycles(budget);
    }

    pub fn setButton(self: *Machine, button: joypad.Button, down: bool, repeat: bool) void {
        if (repeat and down) return;
        if (self.joypad.set(button, down)) {
            self.interrupts.requestBit(4);
            self.cpu.requestStopWake();
        }
    }

    pub fn focusLost(self: *Machine) void {
        self.joypad.releaseAll();
    }

    pub fn tickTcycles(self: *Machine, count: u32) void {
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) self.tickOne();
    }

    fn tickOne(self: *Machine) void {
        // Stable device order: timer/system divider, DMA, serial. PPU and APU
        // join this sequence in their owner subversions without host-time input.
        const old_divider = self.timer.divider_counter;
        if (!self.cpu.stopped and self.timer.tick()) self.interrupts.requestBit(2);

        if (!self.cpu.stopped) {
            if (self.dma.tick()) |source| {
                const destination: usize = @as(u8, @truncate(source));
                if (destination < self.ppu.oam.len) self.ppu.oam[destination] = self.readDmaSource(source);
            }
        }

        if (!self.cpu.stopped and self.serial.tick(old_divider, self.timer.divider_counter)) {
            self.interrupts.requestBit(3);
        }
        self.guest_t_cycles +%= 1;
    }

    fn readDmaSource(self: *Machine, address: u16) u8 {
        return switch (address) {
            0x0000...0x7FFF => self.cartridge.readRom(address),
            0x8000...0x9FFF => self.ppu.vram[@as(usize, address) - 0x8000],
            0xA000...0xBFFF => self.cartridge.readExternal(address),
            0xC000...0xDFFF => self.bus.work_ram[@as(usize, address) - 0xC000],
            0xE000...0xFFFF => self.bus.work_ram[@as(usize, address & 0x1FFF)],
        };
    }

    fn readIo(self: *Machine, offset: u8) u8 {
        return switch (offset) {
            0x00 => self.joypad.read(),
            0x01 => self.serial.data,
            0x02 => self.serial.readControl(),
            0x04 => self.timer.readDiv(),
            0x05 => self.timer.tima,
            0x06 => self.timer.tma,
            0x07 => self.timer.readTac(),
            0x0F => self.interrupts.readRequest(),
            0x40 => self.ppu.lcdc,
            0x41 => self.ppu.stat | 0x80,
            0x42 => self.ppu.scy,
            0x43 => self.ppu.scx,
            0x44 => self.ppu.ly,
            0x45 => self.ppu.lyc,
            0x46 => self.dma.source_high,
            0x47 => self.ppu.bgp,
            0x48 => self.ppu.obp0,
            0x49 => self.ppu.obp1,
            0x4A => self.ppu.wy,
            0x4B => self.ppu.wx,
            else => self.io[offset],
        };
    }

    fn writeIo(self: *Machine, offset: u8, value: u8) void {
        switch (offset) {
            0x00 => if (self.joypad.write(value)) {
                self.interrupts.requestBit(4);
                self.cpu.requestStopWake();
            },
            0x01 => self.serial.data = value,
            0x02 => self.serial.writeControl(value),
            0x04 => self.timer.writeDiv(),
            0x05 => self.timer.writeTima(value),
            0x06 => self.timer.writeTma(value),
            0x07 => self.timer.writeTac(value),
            0x0F => self.interrupts.writeRequest(value),
            0x40 => self.ppu.lcdc = value,
            0x41 => self.ppu.stat = (self.ppu.stat & 0x07) | (value & 0x78) | 0x80,
            0x42 => self.ppu.scy = value,
            0x43 => self.ppu.scx = value,
            0x44 => {},
            0x45 => self.ppu.lyc = value,
            0x46 => self.dma.start(value),
            0x47 => self.ppu.bgp = value,
            0x48 => self.ppu.obp0 = value,
            0x49 => self.ppu.obp1 = value,
            0x4A => self.ppu.wy = value,
            0x4B => self.ppu.wx = value,
            else => self.io[offset] = value,
        }
    }

    fn ppuAccessBlocked(self: *const Machine) bool {
        return (self.ppu.lcdc & 0x80) != 0 and (self.ppu.stat & 0x03) == 3;
    }

    fn oamAccessBlocked(self: *const Machine) bool {
        if (self.dma.active) return true;
        if ((self.ppu.lcdc & 0x80) == 0) return false;
        const mode = self.ppu.stat & 0x03;
        return mode == 2 or mode == 3;
    }

    fn cpuRead(context: *anyopaque, address: u16) u8 {
        const self: *Machine = @ptrCast(@alignCast(context));
        const value = self.read(address);
        self.tickTcycles(4);
        return value;
    }

    fn cpuWrite(context: *anyopaque, address: u16, value: u8) void {
        const self: *Machine = @ptrCast(@alignCast(context));
        self.write(address, value);
        self.tickTcycles(4);
    }

    fn cpuIdle(context: *anyopaque, _: u16, _: u8) void {
        const self: *Machine = @ptrCast(@alignCast(context));
        self.tickTcycles(4);
    }

    fn cpuPendingInterrupts(context: *anyopaque) u8 {
        const self: *Machine = @ptrCast(@alignCast(context));
        return self.interrupts.pending();
    }

    fn cpuAcknowledgeInterrupt(context: *anyopaque, bit: u3) void {
        const self: *Machine = @ptrCast(@alignCast(context));
        self.interrupts.acknowledge(bit);
    }
};

fn postBootDivider(revision: model.Revision) u16 {
    // Mooneye's DMG ABC phase: six NOPs and the two LDH prefix cycles place
    // the first DIV read exactly at $AC00.
    return switch (revision) {
        .dmg_0 => 0x18CC,
        .dmg_a, .dmg_b, .dmg_c => 0xABCC,
    };
}
