const cartridge = @import("cartridge.zig");

pub const Region = enum {
    cartridge_rom,
    video_ram,
    cartridge_ram,
    work_ram,
    echo_ram,
    object_attribute_memory,
    unusable,
    io,
    high_ram,
    interrupt_enable,
};

pub fn classify(address: u16) Region {
    return switch (address) {
        0x0000...0x7FFF => .cartridge_rom,
        0x8000...0x9FFF => .video_ram,
        0xA000...0xBFFF => .cartridge_ram,
        0xC000...0xDFFF => .work_ram,
        0xE000...0xFDFF => .echo_ram,
        0xFE00...0xFE9F => .object_attribute_memory,
        0xFEA0...0xFEFF => .unusable,
        0xFF00...0xFF7F => .io,
        0xFF80...0xFFFE => .high_ram,
        0xFFFF => .interrupt_enable,
    };
}

/// Addressable storage owned by the corresponding guest devices. The bus
/// receives these references only for the duration of one access; it never
/// stores or exposes host pointers to the emulated CPU.
pub const Devices = struct {
    cartridge: *cartridge.Cartridge,
    video_ram: *[0x2000]u8,
    object_attribute_memory: *[0xA0]u8,
    io: *[0x80]u8,
    interrupt_enable: *u8,
    vram_blocked: bool = false,
    oam_blocked: bool = false,
    dma_blocks_external_bus: bool = false,
};

pub const Bus = struct {
    work_ram: [0x2000]u8 = .{0} ** 0x2000,
    high_ram: [0x7F]u8 = .{0} ** 0x7F,
    open_bus: u8 = 0xFF,

    pub fn read(self: *Bus, devices: Devices, address: u16) u8 {
        if (devices.dma_blocks_external_bus and address < 0xFF80) return self.open_bus;
        return switch (classify(address)) {
            .cartridge_rom => devices.cartridge.readRom(address),
            .video_ram => if (devices.vram_blocked) self.open_bus else devices.video_ram[@as(usize, address) - 0x8000],
            .cartridge_ram => devices.cartridge.readExternal(address),
            .work_ram => self.work_ram[@as(usize, address) - 0xC000],
            .echo_ram => self.work_ram[@as(usize, address) - 0xE000],
            .object_attribute_memory => if (devices.oam_blocked) self.open_bus else devices.object_attribute_memory[@as(usize, address) - 0xFE00],
            .unusable => if (devices.oam_blocked) self.open_bus else 0x00,
            .io => devices.io[@as(usize, address) - 0xFF00],
            .high_ram => self.high_ram[@as(usize, address) - 0xFF80],
            .interrupt_enable => devices.interrupt_enable.*,
        };
    }

    pub fn write(self: *Bus, devices: Devices, address: u16, value: u8) void {
        if (devices.dma_blocks_external_bus and address < 0xFF80) return;
        switch (classify(address)) {
            .cartridge_rom => devices.cartridge.writeControl(address, value),
            .video_ram => if (!devices.vram_blocked) {
                devices.video_ram[@as(usize, address) - 0x8000] = value;
            },
            .cartridge_ram => devices.cartridge.writeExternal(address, value),
            .work_ram => self.work_ram[@as(usize, address) - 0xC000] = value,
            .echo_ram => self.work_ram[@as(usize, address) - 0xE000] = value,
            .object_attribute_memory => if (!devices.oam_blocked) {
                devices.object_attribute_memory[@as(usize, address) - 0xFE00] = value;
            },
            .unusable => {},
            .io => devices.io[@as(usize, address) - 0xFF00] = value,
            .high_ram => self.high_ram[@as(usize, address) - 0xFF80] = value,
            .interrupt_enable => devices.interrupt_enable.* = value,
        }
    }
};

test "all guest addresses resolve as integers into one DMG region" {
    try @import("std").testing.expectEqual(Region.cartridge_rom, classify(0x0100));
    try @import("std").testing.expectEqual(Region.echo_ram, classify(0xE123));
    try @import("std").testing.expectEqual(Region.unusable, classify(0xFEA0));
    try @import("std").testing.expectEqual(Region.interrupt_enable, classify(0xFFFF));
}
