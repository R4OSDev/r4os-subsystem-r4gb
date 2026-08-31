// Copyright 2026 R4
// SPDX-License-Identifier: Apache-2.0
//
// Tiny deterministic cartridges generated from original R4OS source. They
// are test programs, not dumps of commercial software, and contain no boot
// ROM. The standard cartridge header logo is emitted solely as protocol data
// required by every real DMG cartridge and by R4GB's compatibility probe.
const std = @import("std");
const cartridge = @import("cartridge.zig");

pub const image_bytes: usize = 32 * 1024;

pub const Kind = enum {
    rom_only,
    battery_rtc,
    cgb_only,
};

pub const Metadata = struct {
    title: []const u8,
    extension: []const u8,
    battery: bool,
    rtc: bool,
    runnable_on_dmg: bool,
};

pub fn metadata(kind: Kind) Metadata {
    return switch (kind) {
        .rom_only => .{
            .title = "R4GB E2E A",
            .extension = ".gb",
            .battery = false,
            .rtc = false,
            .runnable_on_dmg = true,
        },
        .battery_rtc => .{
            .title = "R4GB E2E B",
            .extension = ".gbc",
            .battery = true,
            .rtc = true,
            .runnable_on_dmg = true,
        },
        .cgb_only => .{
            .title = "R4GB CGB ONLY",
            .extension = ".gbc",
            .battery = false,
            .rtc = false,
            .runnable_on_dmg = false,
        },
    };
}

pub fn build(out: []u8, kind: Kind) !void {
    if (out.len != image_bytes) return error.InvalidSize;
    @memset(out, 0);

    // Interrupt handlers return immediately. The timer interrupt wakes HALT
    // so the main loop samples the selected physical joypad line repeatedly.
    out[0x40] = 0xD9;
    out[0x48] = 0xD9;
    out[0x50] = 0xD9;
    out[0x58] = 0xD9;
    out[0x60] = 0xD9;

    out[0x100] = 0xC3; // JP $0150
    out[0x101] = 0x50;
    out[0x102] = 0x01;
    @memcpy(out[cartridge.logo_offset .. cartridge.logo_offset + cartridge.logo.len], cartridge.logo[0..]);

    const info = metadata(kind);
    const title_len: usize = @min(info.title.len, 15);
    @memcpy(out[0x134 .. 0x134 + title_len], info.title[0..title_len]);
    out[0x143] = switch (kind) {
        .rom_only => 0x00,
        .battery_rtc => 0x80,
        .cgb_only => 0xC0,
    };
    out[0x147] = if (kind == .battery_rtc) 0x10 else 0x00;
    out[0x148] = 0x00;
    out[0x149] = if (kind == .battery_rtc) 0x02 else 0x00;

    var cursor: usize = 0x150;
    emit(out, &cursor, &.{
        0xF3, // DI
        0x31, 0xFE, 0xFF, // LD SP,$FFFE
        0xAF, // XOR A
        0xE0, 0x26, // LDH ($FF26),A: APU off
        0x3E, 0x80,
        0xE0, 0x26, // APU on
        0x3E, 0x73,
        0xE0, 0x24, // asymmetric master volume
        0x3E, 0x11,
        0xE0, 0x25, // channel 1 to both outputs
        0x3E, 0x80,
        0xE0, 0x11, // duty
        0x3E, 0xF0,
        0xE0, 0x12, // envelope / DAC
        0x3E, 0xD6,
        0xE0, 0x13,
        0x3E, 0x86,
        0xE0, 0x14, // trigger pulse
    });

    if (kind == .battery_rtc) emit(out, &cursor, &.{
        0x3E, 0x0A,
        0xEA, 0x00, 0x00, // enable RAM/RTC
        0xAF,
        0xEA, 0x00, 0x40, // select RAM bank 0
        0x3E, 0x5A,
        0xEA, 0x00, 0xA0, // persistent SRAM witness
        0x3E, 0x08,
        0xEA, 0x00, 0x40, // select RTC seconds
        0x3E, 0x07,
        0xEA, 0x00, 0xA0, // persistent RTC witness
        0xAF,
        0xEA, 0x00, 0x60,
        0x3E, 0x01,
        0xEA, 0x00, 0x60, // latch edge
        0xAF,
        0xEA, 0x00, 0x40, // restore RAM bank 0
    });

    emit(out, &cursor, &.{
        0xAF,
        0xE0, 0x0F, // clear IF
        0x3E, 0x04,
        0xE0, 0x06, // TMA
        0xE0, 0x05, // TIMA
        0x3E, 0x05,
        0xE0, 0x07, // timer enable, 4096 Hz input
        0x3E, 0x04,
        0xEA, 0xFF, 0xFF, // IE: timer
        0xFB, // EI
    });
    const loop_address: u16 = @intCast(cursor);
    emit(out, &cursor, &.{
        0x3E, 0x20,
        0xE0, 0x00, // select directional joypad line
        0xF0, 0x00,
        0xEA, 0x00, 0xC0, // observable sample in private WRAM
        0x76, // HALT until timer or joypad interrupt
        0xC3, @truncate(loop_address), @truncate(loop_address >> 8),
    });

    finalize(out);
}

fn emit(out: []u8, cursor: *usize, bytes: []const u8) void {
    std.debug.assert(cursor.* + bytes.len <= out.len);
    @memcpy(out[cursor.* .. cursor.* + bytes.len], bytes);
    cursor.* += bytes.len;
}

fn finalize(bytes: []u8) void {
    bytes[0x14D] = cartridge.headerChecksum(bytes);
    bytes[0x14E] = 0;
    bytes[0x14F] = 0;
    const checksum = cartridge.globalChecksum(bytes);
    bytes[0x14E] = @truncate(checksum >> 8);
    bytes[0x14F] = @truncate(checksum);
}

test "open E2E fixtures are deterministic valid DMG and precise CGB rejection" {
    var first: [image_bytes]u8 = undefined;
    var second: [image_bytes]u8 = undefined;
    try build(first[0..], .rom_only);
    try build(second[0..], .rom_only);
    try std.testing.expectEqualSlices(u8, first[0..], second[0..]);
    const rom_only = try cartridge.parse(first[0..]);
    try std.testing.expectEqual(cartridge.MapperKind.rom_only, rom_only.mapper);
    try std.testing.expect(!rom_only.type_info.has_battery);

    try build(first[0..], .battery_rtc);
    const battery = try cartridge.parse(first[0..]);
    try std.testing.expectEqual(cartridge.MapperKind.mbc3, battery.mapper);
    try std.testing.expect(battery.type_info.has_battery and battery.type_info.has_timer);
    try std.testing.expectEqual(@as(usize, 8 * 1024), battery.ram_bytes);

    try build(first[0..], .cgb_only);
    try std.testing.expectError(error.CgbOnly, cartridge.parse(first[0..]));
}
