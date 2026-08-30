const std = @import("std");

pub const header_size: usize = 0x150;
pub const logo_offset: usize = 0x104;
pub const logo = [_]u8{
    0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B,
    0x03, 0x73, 0x00, 0x83, 0x00, 0x0C, 0x00, 0x0D,
    0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
    0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99,
    0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC,
    0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
};

pub const Capability = enum {
    dmg,
    dmg_and_cgb,
    cgb_only,
};

pub const Header = struct {
    title: [16]u8 = .{0} ** 16,
    title_len: u8 = 0,
    capability: Capability,
    cartridge_type: u8,
    rom_size_code: u8,
    ram_size_code: u8,
    destination_code: u8,
    version: u8,
    expected_rom_bytes: usize,

    pub fn titleSlice(self: *const Header) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const Error = error{
    TooSmall,
    InvalidLogo,
    InvalidHeaderChecksum,
    InvalidRomSizeCode,
    SizeMismatch,
    CgbOnly,
};

pub fn parse(bytes: []const u8, actual_size: usize) Error!Header {
    if (bytes.len < header_size or actual_size < header_size) return error.TooSmall;
    if (!std.mem.eql(u8, bytes[logo_offset .. logo_offset + logo.len], logo[0..])) return error.InvalidLogo;
    var checksum: u8 = 0;
    for (bytes[0x134..0x14D]) |value| checksum -%= value +% 1;
    if (checksum != bytes[0x14D]) return error.InvalidHeaderChecksum;
    const expected = romBytes(bytes[0x148]) orelse return error.InvalidRomSizeCode;
    if (actual_size != expected) return error.SizeMismatch;
    const capability: Capability = switch (bytes[0x143]) {
        0xC0 => .cgb_only,
        0x80 => .dmg_and_cgb,
        else => .dmg,
    };
    if (capability == .cgb_only) return error.CgbOnly;
    var result = Header{
        .capability = capability,
        .cartridge_type = bytes[0x147],
        .rom_size_code = bytes[0x148],
        .ram_size_code = bytes[0x149],
        .destination_code = bytes[0x14A],
        .version = bytes[0x14C],
        .expected_rom_bytes = expected,
    };
    const title_end: usize = if (bytes[0x143] == 0x80 or bytes[0x143] == 0xC0) 0x143 else 0x144;
    var cursor: usize = 0x134;
    while (cursor < title_end and bytes[cursor] != 0 and result.title_len < result.title.len) : (cursor += 1) {
        const value = bytes[cursor];
        result.title[result.title_len] = if (value >= 0x20 and value <= 0x7E) value else '?';
        result.title_len += 1;
    }
    return result;
}

pub fn romBytes(code: u8) ?usize {
    return switch (code) {
        0x00...0x08 => @as(usize, 32 * 1024) << @intCast(code),
        0x52 => 72 * 16 * 1024,
        0x53 => 80 * 16 * 1024,
        0x54 => 96 * 16 * 1024,
        else => null,
    };
}

pub const Cartridge = struct {
    header: Header,
    rom: []const u8,
    external_ram: []u8,
};
