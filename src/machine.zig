const apu = @import("apu.zig");
const bus = @import("bus.zig");
const cartridge = @import("cartridge.zig");
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
    timer: timer.Timer = .{},
    interrupts: interrupts.Interrupts = .{},
    dma: dma.Dma = .{},
    ppu: ppu.Ppu = .{},
    apu: apu.Apu = .{},
    joypad: joypad.Joypad = .{},
    serial: serial.Serial = .{},
    persistence: persistence.Persistence = .{},

    pub fn init(revision: model.Revision, cart: cartridge.Cartridge) Machine {
        const boot = model.profile(revision);
        return .{
            .revision = revision,
            .cartridge = cart,
            .io = boot.mmio,
            .cpu = cpu.Cpu.init(boot),
            .interrupts = .{ .request = boot.mmio[0x0F], .enable = boot.ie },
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

    pub fn devices(self: *Machine) bus.Devices {
        return .{
            .cartridge = &self.cartridge,
            .video_ram = &self.ppu.vram,
            .object_attribute_memory = &self.ppu.oam,
            .io = &self.io,
            .interrupt_enable = &self.interrupts.enable,
            .vram_blocked = self.ppuAccessBlocked(),
            .oam_blocked = self.oamAccessBlocked(),
            .dma_blocks_external_bus = self.dma.active,
        };
    }

    pub fn read(self: *Machine, address: u16) u8 {
        const view = self.devices();
        return self.bus.read(view, address);
    }

    pub fn write(self: *Machine, address: u16, value: u8) void {
        const view = self.devices();
        self.bus.write(view, address, value);
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
};
