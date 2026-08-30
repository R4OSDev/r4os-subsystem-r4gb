const std = @import("std");
const core = @import("core");

test "all core component declarations remain independently analyzable" {
    std.testing.refAllDecls(core);
}

test "valid dual-mode cartridge remains a DMG candidate without mutation" {
    var bytes = [_]u8{0} ** core.cartridge.header_size;
    @memcpy(bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[0x134..0x13A], "DUALGB");
    bytes[0x143] = 0x80;
    bytes[0x147] = 0x00;
    bytes[0x148] = 0x00;
    var checksum: u8 = 0;
    for (bytes[0x134..0x14D]) |value| checksum -%= value +% 1;
    bytes[0x14D] = checksum;
    const before = bytes;
    const parsed = try core.cartridge.parse(bytes[0..], 32 * 1024);
    try std.testing.expectEqual(core.cartridge.Capability.dmg_and_cgb, parsed.capability);
    try std.testing.expectEqualSlices(u8, before[0..], bytes[0..]);
}

test "damaged logo checksum size and CGB-only headers are bounded errors" {
    var bytes = [_]u8{0} ** core.cartridge.header_size;
    try std.testing.expectError(error.InvalidLogo, core.cartridge.parse(bytes[0..], 32 * 1024));
    @memcpy(bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    var checksum: u8 = 0;
    for (bytes[0x134..0x14D]) |value| checksum -%= value +% 1;
    bytes[0x14D] = checksum;
    try std.testing.expectError(error.SizeMismatch, core.cartridge.parse(bytes[0..], 64 * 1024));
    bytes[0x143] = 0xC0;
    checksum = 0;
    for (bytes[0x134..0x14D]) |value| checksum -%= value +% 1;
    bytes[0x14D] = checksum;
    try std.testing.expectError(error.CgbOnly, core.cartridge.parse(bytes[0..], 32 * 1024));
}
