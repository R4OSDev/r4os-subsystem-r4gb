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
        var result = Machine{
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
        result.ppu.initializeDmgBootVram(&cartridge.logo);
        result.ppu.synchronizeAfterBoot(revision);
        return result;
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
        if (self.dmaContendsWith(address)) {
            // At the final two DMA bytes, an M1 fetch at $FDFF is already
            // driven by the CPU bus while the following $FE00 data read still
            // observes DMA contention. Mooneye uses this documented boundary
            // to distinguish adjacent SM83 M-cycles.
            if (address < 0xFDFE or address > 0xFDFF) return self.bus.open_bus;
            const bytes_before_oam: u8 = @intCast(0xFE00 - address);
            const first_visible_index: u8 = 0x9F - bytes_before_oam;
            if (self.dma.byte_index < first_visible_index) return self.bus.open_bus;
        }
        if (address == 0xFFFF) return self.interrupts.enable;
        if (address >= 0xFF00 and address <= 0xFF7F) {
            return self.readIo(@truncate(address));
        }
        if (address >= 0xFE00 and address <= 0xFEFF and self.ppu.mode() == .oam) {
            self.ppu.corruptOam(.read);
        }
        const view = self.devices();
        return self.bus.read(view, address);
    }

    pub fn write(self: *Machine, address: u16, value: u8) void {
        if (address == 0xFF46) {
            self.writeIo(0x46, value);
            return;
        }
        if (self.dmaContendsWith(address)) return;
        if (address == 0xFFFF) {
            self.interrupts.enable = value;
            return;
        }
        if (address >= 0xFF00 and address <= 0xFF7F) {
            self.writeIo(@truncate(address), value);
            return;
        }
        if (address >= 0xFE00 and address <= 0xFEFF and self.ppu.mode() == .oam) {
            self.ppu.corruptOam(.write);
        }
        var view = self.devices();
        view.vram_blocked = self.ppu.cpuVramWriteBlocked();
        view.oam_blocked = self.dma.active or self.ppu.cpuOamWriteBlocked();
        self.bus.write(view, address, value);
    }

    pub fn cpuBus(self: *Machine) cpu.Bus {
        return .{
            .context = self,
            .read_fn = cpuRead,
            .opcode_read_fn = cpuOpcodeRead,
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
        // Stable device order: timer/system divider, DMA, PPU, serial. Every
        // device consumes the same guest T-cycle and no host clock leaks here.
        const old_divider = self.timer.divider_counter;
        if (!self.cpu.stopped and self.timer.tick()) self.interrupts.requestBit(2);

        if (!self.cpu.stopped) {
            if (self.dma.tick()) |source| {
                const destination: usize = @as(u8, @truncate(source));
                if (destination < self.ppu.oam.len) self.ppu.oam[destination] = self.readDmaSource(source);
            }
        }

        if (!self.cpu.stopped) {
            self.applyPpuEvents(self.ppu.tick());
            if (!self.cpu.halted and self.ppu.sampleRunningMode2Edge()) self.interrupts.requestBit(1);
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
            0x41 => self.ppu.readStat(),
            0x42 => self.ppu.scy,
            0x43 => self.ppu.scx,
            0x44 => self.ppu.readLy(),
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
            0x40 => self.applyPpuEvents(self.ppu.writeLcdc(value)),
            0x41 => self.applyPpuEvents(self.ppu.writeStat(value)),
            0x42 => self.ppu.scy = value,
            0x43 => self.ppu.scx = value,
            0x44 => {},
            0x45 => self.applyPpuEvents(self.ppu.writeLyc(value)),
            0x46 => self.dma.start(value),
            0x47 => self.ppu.writeBgp(value),
            0x48 => self.ppu.writeObp0(value),
            0x49 => self.ppu.writeObp1(value),
            0x4A => self.ppu.wy = value,
            0x4B => self.ppu.writeWx(value),
            else => self.io[offset] = value,
        }
    }

    fn ppuAccessBlocked(self: *const Machine) bool {
        return self.ppu.cpuVramBlocked();
    }

    fn oamAccessBlocked(self: *const Machine) bool {
        if (self.dma.active) return true;
        return self.ppu.cpuOamBlocked();
    }

    /// The monochrome hardware has a main bus (cartridge and work RAM) and a
    /// separate VRAM bus. OAM DMA only takes ownership of the bus supplying
    /// its current source byte; CPU accesses on the other bus keep working.
    /// OAM itself is blocked separately as the DMA destination, while I/O,
    /// HRAM and IE are not members of either contended address range.
    fn dmaContendsWith(self: *const Machine, address: u16) bool {
        if (!self.dma.active or address >= 0xFE00) return false;
        const source = (@as(u16, self.dma.active_source_high) << 8) | self.dma.byte_index;
        return dmaBus(address) == dmaBus(source);
    }

    fn applyPpuEvents(self: *Machine, events: ppu.Events) void {
        if (events.vblank_irq) self.interrupts.requestBit(0);
        if (events.stat_irq) self.interrupts.requestBit(1);
    }

    fn cpuRead(context: *anyopaque, address: u16) u8 {
        const self: *Machine = @ptrCast(@alignCast(context));
        const value = self.read(address);
        self.tickTcycles(4);
        return value;
    }

    fn cpuOpcodeRead(context: *anyopaque, address: u16) u8 {
        const self: *Machine = @ptrCast(@alignCast(context));
        var value: u8 = undefined;
        if (self.dmaContendsWith(address) and self.dma.byte_index >= 0x9D) {
            // The final DMA M1 boundary releases the instruction fetch before
            // ordinary data cycles. Operand and stack accesses still use the
            // normal contention path in cpuRead.
            if (address >= 0xFF00 and address <= 0xFF7F) {
                value = self.readIo(@truncate(address));
            } else {
                value = self.bus.read(self.devices(), address);
            }
        } else {
            value = self.read(address);
        }
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

const DmaBus = enum { main, vram };

fn dmaBus(address: u16) DmaBus {
    return if (address >= 0x8000 and address < 0xA000) .vram else .main;
}

fn postBootDivider(revision: model.Revision) u16 {
    // Mooneye's DMG ABC phase: six NOPs and the two LDH prefix cycles place
    // the first DIV read exactly at $AC00.
    return switch (revision) {
        .dmg_0 => 0x18CC,
        .dmg_a, .dmg_b, .dmg_c => 0xABCC,
    };
}
