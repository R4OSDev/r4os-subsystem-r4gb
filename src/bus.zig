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

pub const Bus = struct {
    work_ram: [0x2000]u8 = .{0} ** 0x2000,
    high_ram: [0x7F]u8 = .{0} ** 0x7F,
    open_bus: u8 = 0xFF,
};

test "all guest addresses resolve as integers into one DMG region" {
    try @import("std").testing.expectEqual(Region.cartridge_rom, classify(0x0100));
    try @import("std").testing.expectEqual(Region.echo_ram, classify(0xE123));
    try @import("std").testing.expectEqual(Region.unusable, classify(0xFEA0));
    try @import("std").testing.expectEqual(Region.interrupt_enable, classify(0xFFFF));
}
