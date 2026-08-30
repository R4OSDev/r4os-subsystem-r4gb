const std = @import("std");
const core = @import("core");

test "all core component declarations remain independently analyzable" {
    std.testing.refAllDecls(core);
}

test "DMG revision profiles and side-specific keyboard mapping are explicit" {
    const production = core.model.profile(core.model.production_revision);
    try std.testing.expectEqual(core.model.Revision.dmg_c, production.revision);
    try std.testing.expectEqual(@as(u16, 0x0100), production.registers.pc);
    try std.testing.expectEqual(@as(u8, 0xB0), production.registers.f);
    const dmg_zero = core.model.profile(.dmg_0);
    try std.testing.expectEqual(@as(u8, 0), dmg_zero.registers.f);
    try std.testing.expectEqual(@as(u8, 0x19), dmg_zero.mmio[0x04]);
    try std.testing.expectEqual(core.joypad.Button.select, core.host_adapter.buttonForPhysicalUsage(core.host_adapter.physical_usage_right_control).?);
    try std.testing.expect(core.host_adapter.buttonForPhysicalUsage(0xE0) == null);
    try std.testing.expectEqual(core.joypad.Button.b, core.host_adapter.buttonForPhysicalUsage(core.host_adapter.physical_usage_left_alt).?);
}

fn makeRom(allocator: std.mem.Allocator, type_code: u8, rom_code: u8, ram_code: u8, cgb_flag: u8) ![]u8 {
    const size = core.cartridge.romBytes(rom_code) orelse return error.BadFixtureRomSize;
    const bytes = try allocator.alloc(u8, size);
    @memset(bytes, 0);
    var bank: usize = 0;
    while (bank * core.cartridge.rom_bank_bytes < bytes.len) : (bank += 1) {
        const base = bank * core.cartridge.rom_bank_bytes;
        bytes[base] = @truncate(bank);
        bytes[base + 1] = @truncate(bank >> 8);
    }
    @memcpy(bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[0x134..0x13D], "SYNTHETIC");
    bytes[0x143] = cgb_flag;
    bytes[0x146] = 0;
    bytes[0x147] = type_code;
    bytes[0x148] = rom_code;
    bytes[0x149] = ram_code;
    finalize(bytes);
    return bytes;
}

fn finalize(bytes: []u8) void {
    bytes[0x14D] = core.cartridge.headerChecksum(bytes);
    bytes[0x14E] = 0;
    bytes[0x14F] = 0;
    const checksum = core.cartridge.globalChecksum(bytes);
    bytes[0x14E] = @truncate(checksum >> 8);
    bytes[0x14F] = @truncate(checksum);
}

fn addEmbeddedHeader(bytes: []u8, bank: usize) void {
    const base = bank * core.cartridge.rom_bank_bytes;
    @memcpy(bytes[base + core.cartridge.logo_offset .. base + core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[base + 0x134 .. base + 0x13D], "SUBCART01");
    bytes[base + 0x147] = 0;
    bytes[base + 0x148] = 3;
    var checksum: u8 = 0;
    for (bytes[base + 0x134 .. base + 0x14D]) |value| checksum -%= value +% 1;
    bytes[base + 0x14D] = checksum;
    finalize(bytes);
}

test "complete dual-mode image is accepted without mutation and CGB-only is rejected" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x80);
    defer allocator.free(bytes);
    const before = try allocator.dupe(u8, bytes);
    defer allocator.free(before);

    const parsed = try core.cartridge.parse(bytes);
    try std.testing.expectEqual(core.cartridge.Capability.dmg_and_cgb, parsed.capability);
    try std.testing.expectEqualSlices(u8, "SYNTHETIC", parsed.titleSlice());
    try std.testing.expectEqualSlices(u8, before, bytes);

    bytes[0x143] = 0xC0;
    finalize(bytes);
    try std.testing.expectError(error.CgbOnly, core.cartridge.parse(bytes));
}

test "image bounds, both checksums, size codes and mapper consistency are deterministic" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);

    try std.testing.expectError(error.SizeMismatch, core.cartridge.parse(bytes[0 .. bytes.len - 1]));
    bytes[0] ^= 1;
    try std.testing.expectError(error.InvalidGlobalChecksum, core.cartridge.parse(bytes));
    bytes[0] ^= 1;
    bytes[0x134] ^= 1;
    try std.testing.expectError(error.InvalidHeaderChecksum, core.cartridge.parse(bytes));
    bytes[0x134] ^= 1;
    finalize(bytes);
    bytes[core.cartridge.logo_offset] ^= 1;
    try std.testing.expectError(error.InvalidLogo, core.cartridge.parse(bytes));
    bytes[core.cartridge.logo_offset] ^= 1;

    bytes[0x148] = 0xFF;
    finalize(bytes);
    try std.testing.expectError(error.InvalidRomSizeCode, core.cartridge.parse(bytes));

    const too_large = try allocator.alloc(u8, core.cartridge.max_rom_bytes + 1);
    defer allocator.free(too_large);
    try std.testing.expectError(error.TooLarge, core.cartridge.parse(too_large));
}

test "unknown, digital-gap and accessory-dependent cartridges stay distinct" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);

    bytes[0x147] = 0x04;
    finalize(bytes);
    try std.testing.expectError(error.UnknownCartridgeType, core.cartridge.parse(bytes));
    bytes[0x147] = 0x20;
    finalize(bytes);
    try std.testing.expectError(error.UnsupportedMapper, core.cartridge.parse(bytes));
    bytes[0x147] = 0x22;
    finalize(bytes);
    try std.testing.expectError(error.UnavailableAccessory, core.cartridge.parse(bytes));
    bytes[0x147] = 0xFC;
    finalize(bytes);
    try std.testing.expectError(error.UnavailableAccessory, core.cartridge.parse(bytes));

    bytes[0x147] = 0x00;
    bytes[0x149] = 0x02;
    finalize(bytes);
    try std.testing.expectError(error.InconsistentRam, core.cartridge.parse(bytes));
}

test "cartridge owns an immutable ROM copy" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);
    const original = bytes[0];
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();
    bytes[0] ^= 0xFF;
    try std.testing.expectEqual(original, cart.rom[0]);
    try std.testing.expectEqual(original, cart.readRom(0));
}

test "MBC1 regular banking covers forbidden banks, modes and RAM mirroring" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x01, 0x06, 0x00, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    try std.testing.expectEqual(core.cartridge.MapperKind.mbc1, cart.header.mapper);
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4000));
    cart.writeControl(0x2000, 0x00);
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4000));
    cart.writeControl(0x4000, 0x01);
    try std.testing.expectEqual(@as(u8, 33), cart.readRom(0x4000));
    cart.writeControl(0x6000, 0x01);
    try std.testing.expectEqual(@as(u8, 32), cart.readRom(0x0000));

    const ram_bytes = try makeRom(allocator, 0x03, 0x04, 0x03, 0x00);
    defer allocator.free(ram_bytes);
    var ram_cart = try core.cartridge.Cartridge.init(allocator, ram_bytes);
    defer ram_cart.deinit();
    try std.testing.expectEqual(@as(u8, 0xFF), ram_cart.readExternal(0xA000));
    ram_cart.writeControl(0x0000, 0x1A);
    ram_cart.writeControl(0x6000, 1);
    ram_cart.writeControl(0x4000, 3);
    ram_cart.writeExternal(0xA000, 0x53);
    ram_cart.writeControl(0x4000, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), ram_cart.readExternal(0xA000));
    ram_cart.writeControl(0x4000, 3);
    try std.testing.expectEqual(@as(u8, 0x53), ram_cart.readExternal(0xA000));
}

test "MBC1M embedded header selects multicart wiring" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x01, 0x05, 0x00, 0x00);
    defer allocator.free(bytes);
    addEmbeddedHeader(bytes, 16);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    try std.testing.expectEqual(core.cartridge.MapperKind.mbc1_multicart, cart.header.mapper);
    cart.writeControl(0x4000, 1);
    try std.testing.expectEqual(@as(u8, 17), cart.readRom(0x4000));
    cart.writeControl(0x6000, 1);
    try std.testing.expectEqual(@as(u8, 16), cart.readRom(0x0000));
    cart.writeControl(0x2000, 0x10);
    try std.testing.expectEqual(@as(u8, 16), cart.readRom(0x4000));
}

test "MBC2 uses address bit eight and mirrored four-bit RAM" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x06, 0x03, 0x00, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    cart.writeControl(0x2100, 0x0F);
    try std.testing.expectEqual(@as(u8, 15), cart.readRom(0x4000));
    cart.writeControl(0x0100, 0x00);
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4000));
    cart.writeControl(0x0000, 0x0A);
    cart.writeExternal(0xA000, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xFB), cart.readExternal(0xA200));
    cart.writeControl(0x0000, 0x00);
    try std.testing.expectEqual(@as(u8, 0xFF), cart.readExternal(0xA000));
}

test "MBC3 and MBC30 separate RAM, RTC selection and latch state" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x10, 0x06, 0x03, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    cart.writeControl(0x0000, 0x0A);
    cart.writeControl(0x2000, 0);
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4000));
    cart.writeControl(0x4000, 2);
    cart.writeExternal(0xA000, 0x22);
    cart.writeControl(0x4000, 0x08);
    cart.writeExternal(0xA000, 42);
    cart.writeControl(0x6000, 0);
    cart.writeControl(0x6000, 1);
    try std.testing.expectEqual(@as(u8, 42), cart.readExternal(0xA111));
    cart.writeExternal(0xA000, 12);
    try std.testing.expectEqual(@as(u8, 42), cart.readExternal(0xA000));
    cart.writeControl(0x4000, 0x0D);
    try std.testing.expectEqual(@as(u8, 0xFF), cart.readExternal(0xA000));
    cart.writeControl(0x4000, 2);
    try std.testing.expectEqual(@as(u8, 0x22), cart.readExternal(0xA000));

    const mbc30_bytes = try makeRom(allocator, 0x10, 0x07, 0x05, 0x00);
    defer allocator.free(mbc30_bytes);
    var mbc30 = try core.cartridge.Cartridge.init(allocator, mbc30_bytes);
    defer mbc30.deinit();
    try std.testing.expectEqual(core.cartridge.MapperKind.mbc30, mbc30.header.mapper);
    mbc30.writeControl(0x2000, 0x80);
    try std.testing.expectEqual(@as(u8, 0x80), mbc30.readRom(0x4000));
    mbc30.writeControl(0x0000, 0x0A);
    mbc30.writeControl(0x4000, 7);
    mbc30.writeExternal(0xA000, 0x77);
    try std.testing.expectEqual(@as(u8, 0x77), mbc30.readExternal(0xA000));
}

test "MBC5 keeps ninth ROM bit and rumble separate from RAM bank" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x1E, 0x08, 0x05, 0x80);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    cart.writeControl(0x2000, 0x00);
    cart.writeControl(0x3000, 0x01);
    try std.testing.expectEqual(@as(u8, 0), cart.readRom(0x4000));
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4001));
    cart.writeControl(0x3000, 0);
    try std.testing.expectEqual(@as(u8, 0), cart.readRom(0x4001));

    cart.writeControl(0x0000, 0x0A);
    cart.writeControl(0x4000, 0x0B);
    try std.testing.expect(cart.mapper.rumble_on);
    cart.writeExternal(0xA000, 0x63);
    cart.writeControl(0x4000, 0x03);
    try std.testing.expect(!cart.mapper.rumble_on);
    try std.testing.expectEqual(@as(u8, 0x63), cart.readExternal(0xA000));
}

test "non-power-of-two ROM has electrical mirrors and unpopulated open bus" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x19, 0x52, 0x00, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    cart.writeControl(0x2000, 71);
    try std.testing.expectEqual(@as(u8, 71), cart.readRom(0x4000));
    cart.writeControl(0x2000, 72);
    try std.testing.expectEqual(@as(u8, 0xFF), cart.readRom(0x4000));
    cart.writeControl(0x2000, 128);
    try std.testing.expectEqual(@as(u8, 0), cart.readRom(0x4000));
}

test "the complete 64 KiB bus is bounded, mirrored and device-gated" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();
    var video_ram = [_]u8{0} ** 0x2000;
    var oam = [_]u8{0} ** 0xA0;
    var io = [_]u8{0xFF} ** 0x80;
    var ie: u8 = 0;
    var bus: core.bus.Bus = .{};
    var devices = core.bus.Devices{
        .cartridge = &cart,
        .video_ram = &video_ram,
        .object_attribute_memory = &oam,
        .io = &io,
        .interrupt_enable = &ie,
    };

    bus.write(devices, 0x8000, 0x80);
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(devices, 0x8000));
    bus.write(devices, 0xC123, 0xC1);
    try std.testing.expectEqual(@as(u8, 0xC1), bus.read(devices, 0xE123));
    bus.write(devices, 0xFDFF, 0xDD);
    try std.testing.expectEqual(@as(u8, 0xDD), bus.read(devices, 0xDDFF));
    bus.write(devices, 0xFE9F, 0x9F);
    try std.testing.expectEqual(@as(u8, 0x9F), bus.read(devices, 0xFE9F));
    bus.write(devices, 0xFEA0, 0xAA);
    try std.testing.expectEqual(@as(u8, 0), bus.read(devices, 0xFEA0));
    bus.write(devices, 0xFF44, 0x44);
    bus.write(devices, 0xFF80, 0x80);
    bus.write(devices, 0xFFFF, 0x1F);
    try std.testing.expectEqual(@as(u8, 0x44), bus.read(devices, 0xFF44));
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(devices, 0xFF80));
    try std.testing.expectEqual(@as(u8, 0x1F), bus.read(devices, 0xFFFF));

    devices.vram_blocked = true;
    devices.oam_blocked = true;
    bus.write(devices, 0x8000, 0x11);
    bus.write(devices, 0xFE00, 0x22);
    try std.testing.expectEqual(@as(u8, 0xFF), bus.read(devices, 0x8000));
    try std.testing.expectEqual(@as(u8, 0xFF), bus.read(devices, 0xFE00));
    try std.testing.expectEqual(@as(u8, 0xFF), bus.read(devices, 0xFEA0));
    devices.vram_blocked = false;
    devices.oam_blocked = false;
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(devices, 0x8000));
    try std.testing.expectEqual(@as(u8, 0), bus.read(devices, 0xFE00));

    devices.dma_blocks_external_bus = true;
    try std.testing.expectEqual(@as(u8, 0xFF), bus.read(devices, 0xC123));
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(devices, 0xFF80));
    bus.write(devices, 0xC123, 0x01);
    devices.dma_blocks_external_bus = false;
    try std.testing.expectEqual(@as(u8, 0xC1), bus.read(devices, 0xC123));

    var raw: u32 = 0;
    while (raw <= 0xFFFF) : (raw += 1) {
        const address: u16 = @intCast(raw);
        _ = bus.read(devices, address);
        bus.write(devices, address, @truncate(raw));
    }
}
