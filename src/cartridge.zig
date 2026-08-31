const std = @import("std");

pub const header_size: usize = 0x150;
pub const logo_offset: usize = 0x104;
pub const rom_bank_bytes: usize = 16 * 1024;
pub const ram_bank_bytes: usize = 8 * 1024;
pub const max_rom_bytes: usize = 8 * 1024 * 1024;
pub const dmg_t_cycles_per_second: u32 = 4_194_304;
pub const rom_digest_bytes: usize = std.crypto.hash.sha2.Sha256.digest_length;

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

pub const MapperKind = enum {
    none,
    mbc1,
    mbc1_multicart,
    mbc2,
    mbc3,
    mbc30,
    mbc5,
    mmm01,
    mbc6,
    mbc7,
    camera,
    tama5,
    huc3,
    huc1,
};

pub const Support = enum {
    supported,
    unsupported_mapper,
    unavailable_accessory,
};

pub const TypeInfo = struct {
    code: u8,
    name: []const u8,
    mapper: MapperKind,
    support: Support,
    has_ram: bool = false,
    has_battery: bool = false,
    has_timer: bool = false,
    has_rumble: bool = false,
    has_sensor: bool = false,
    has_camera: bool = false,
};

/// Canonical cartridge-type table. A known type is never silently treated as
/// another mapper: digital mapper gaps and unavailable physical accessories
/// remain distinguishable errors.
pub const cartridge_types = [_]TypeInfo{
    .{ .code = 0x00, .name = "ROM ONLY", .mapper = .none, .support = .supported },
    .{ .code = 0x01, .name = "MBC1", .mapper = .mbc1, .support = .supported },
    .{ .code = 0x02, .name = "MBC1+RAM", .mapper = .mbc1, .support = .supported, .has_ram = true },
    .{ .code = 0x03, .name = "MBC1+RAM+BATTERY", .mapper = .mbc1, .support = .supported, .has_ram = true, .has_battery = true },
    .{ .code = 0x05, .name = "MBC2", .mapper = .mbc2, .support = .supported, .has_ram = true },
    .{ .code = 0x06, .name = "MBC2+BATTERY", .mapper = .mbc2, .support = .supported, .has_ram = true, .has_battery = true },
    .{ .code = 0x08, .name = "ROM+RAM", .mapper = .none, .support = .supported, .has_ram = true },
    .{ .code = 0x09, .name = "ROM+RAM+BATTERY", .mapper = .none, .support = .supported, .has_ram = true, .has_battery = true },
    .{ .code = 0x0B, .name = "MMM01", .mapper = .mmm01, .support = .supported },
    .{ .code = 0x0C, .name = "MMM01+RAM", .mapper = .mmm01, .support = .supported, .has_ram = true },
    .{ .code = 0x0D, .name = "MMM01+RAM+BATTERY", .mapper = .mmm01, .support = .supported, .has_ram = true, .has_battery = true },
    .{ .code = 0x0F, .name = "MBC3+TIMER+BATTERY", .mapper = .mbc3, .support = .supported, .has_battery = true, .has_timer = true },
    .{ .code = 0x10, .name = "MBC3+TIMER+RAM+BATTERY", .mapper = .mbc3, .support = .supported, .has_ram = true, .has_battery = true, .has_timer = true },
    .{ .code = 0x11, .name = "MBC3", .mapper = .mbc3, .support = .supported },
    .{ .code = 0x12, .name = "MBC3+RAM", .mapper = .mbc3, .support = .supported, .has_ram = true },
    .{ .code = 0x13, .name = "MBC3+RAM+BATTERY", .mapper = .mbc3, .support = .supported, .has_ram = true, .has_battery = true },
    .{ .code = 0x19, .name = "MBC5", .mapper = .mbc5, .support = .supported },
    .{ .code = 0x1A, .name = "MBC5+RAM", .mapper = .mbc5, .support = .supported, .has_ram = true },
    .{ .code = 0x1B, .name = "MBC5+RAM+BATTERY", .mapper = .mbc5, .support = .supported, .has_ram = true, .has_battery = true },
    .{ .code = 0x1C, .name = "MBC5+RUMBLE", .mapper = .mbc5, .support = .supported, .has_rumble = true },
    .{ .code = 0x1D, .name = "MBC5+RUMBLE+RAM", .mapper = .mbc5, .support = .supported, .has_ram = true, .has_rumble = true },
    .{ .code = 0x1E, .name = "MBC5+RUMBLE+RAM+BATTERY", .mapper = .mbc5, .support = .supported, .has_ram = true, .has_battery = true, .has_rumble = true },
    .{ .code = 0x20, .name = "MBC6", .mapper = .mbc6, .support = .unsupported_mapper },
    .{ .code = 0x22, .name = "MBC7+SENSOR+RUMBLE+RAM+BATTERY", .mapper = .mbc7, .support = .unavailable_accessory, .has_ram = true, .has_battery = true, .has_rumble = true, .has_sensor = true },
    .{ .code = 0xFC, .name = "POCKET CAMERA", .mapper = .camera, .support = .unavailable_accessory, .has_camera = true },
    .{ .code = 0xFD, .name = "BANDAI TAMA5", .mapper = .tama5, .support = .unsupported_mapper },
    .{ .code = 0xFE, .name = "HuC3", .mapper = .huc3, .support = .unsupported_mapper },
    .{ .code = 0xFF, .name = "HuC1+RAM+BATTERY", .mapper = .huc1, .support = .supported, .has_ram = true, .has_battery = true },
};

pub fn typeInfo(code: u8) ?TypeInfo {
    for (cartridge_types) |entry| if (entry.code == code) return entry;
    return null;
}

pub const Header = struct {
    header_offset: usize,
    title: [16]u8 = .{0} ** 16,
    title_len: u8 = 0,
    capability: Capability,
    cgb_flag: u8,
    new_licensee: [2]u8,
    sgb_flag: u8,
    cartridge_type: u8,
    type_info: TypeInfo,
    mapper: MapperKind,
    rom_size_code: u8,
    ram_size_code: u8,
    destination_code: u8,
    old_licensee: u8,
    version: u8,
    header_checksum: u8,
    global_checksum: u16,
    expected_rom_bytes: usize,
    expected_ram_bytes: usize,
    rom_banks: usize,
    ram_banks: usize,

    pub fn titleSlice(self: *const Header) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const Error = error{
    TooSmall,
    TooLarge,
    InvalidLogo,
    InvalidHeaderChecksum,
    InvalidGlobalChecksum,
    InvalidRomSizeCode,
    InvalidRamSizeCode,
    SizeMismatch,
    CgbOnly,
    UnknownCartridgeType,
    UnsupportedMapper,
    UnavailableAccessory,
    UnsupportedMbc6,
    UnsupportedMbc7Accessory,
    UnsupportedCameraAccessory,
    UnsupportedTama5,
    UnsupportedHuc3,
    InconsistentRam,
    MapperRomTooLarge,
    MapperRamTooLarge,
};

pub fn parse(bytes: []const u8) Error!Header {
    if (bytes.len < header_size) return error.TooSmall;
    if (bytes.len > max_rom_bytes) return error.TooLarge;
    const base = detectHeaderOffset(bytes);
    if (!std.mem.eql(u8, bytes[base + logo_offset .. base + logo_offset + logo.len], logo[0..])) return error.InvalidLogo;
    if (headerChecksumAt(bytes, base) != bytes[base + 0x14D]) return error.InvalidHeaderChecksum;

    const expected_rom = romBytes(bytes[base + 0x148]) orelse return error.InvalidRomSizeCode;
    if (bytes.len != expected_rom) return error.SizeMismatch;
    const expected_global = (@as(u16, bytes[base + 0x14E]) << 8) | bytes[base + 0x14F];
    if (globalChecksumAt(bytes, base) != expected_global) return error.InvalidGlobalChecksum;

    const capability: Capability = if ((bytes[base + 0x143] & 0x80) == 0)
        .dmg
    else if ((bytes[base + 0x143] & 0x40) != 0)
        .cgb_only
    else
        .dmg_and_cgb;
    if (capability == .cgb_only) return error.CgbOnly;

    const info = typeInfo(bytes[base + 0x147]) orelse return error.UnknownCartridgeType;
    switch (info.support) {
        .supported => {},
        .unsupported_mapper => return switch (info.mapper) {
            .mbc6 => error.UnsupportedMbc6,
            .tama5 => error.UnsupportedTama5,
            .huc3 => error.UnsupportedHuc3,
            else => error.UnsupportedMapper,
        },
        .unavailable_accessory => return switch (info.mapper) {
            .mbc7 => error.UnsupportedMbc7Accessory,
            .camera => error.UnsupportedCameraAccessory,
            else => error.UnavailableAccessory,
        },
    }
    const expected_ram = ramBytes(bytes[base + 0x149]) orelse return error.InvalidRamSizeCode;

    var mapper = info.mapper;
    if (mapper == .mbc1 and detectMbc1Multicart(bytes)) mapper = .mbc1_multicart;
    if (mapper == .mbc3 and (expected_rom > 2 * 1024 * 1024 or expected_ram > 32 * 1024)) mapper = .mbc30;
    try validateConfiguration(info, mapper, expected_rom, expected_ram);

    var result = Header{
        .header_offset = base,
        .capability = capability,
        .cgb_flag = bytes[base + 0x143],
        .new_licensee = .{ bytes[base + 0x144], bytes[base + 0x145] },
        .sgb_flag = bytes[base + 0x146],
        .cartridge_type = bytes[base + 0x147],
        .type_info = info,
        .mapper = mapper,
        .rom_size_code = bytes[base + 0x148],
        .ram_size_code = bytes[base + 0x149],
        .destination_code = bytes[base + 0x14A],
        .old_licensee = bytes[base + 0x14B],
        .version = bytes[base + 0x14C],
        .header_checksum = bytes[base + 0x14D],
        .global_checksum = expected_global,
        .expected_rom_bytes = expected_rom,
        .expected_ram_bytes = expected_ram,
        .rom_banks = expected_rom / rom_bank_bytes,
        .ram_banks = if (expected_ram == 0) 0 else @max(@as(usize, 1), expected_ram / ram_bank_bytes),
    };
    const title_span: usize = if ((bytes[base + 0x143] & 0x80) != 0) 0x143 else 0x144;
    const title_end = base + title_span;
    var cursor: usize = base + 0x134;
    while (cursor < title_end and bytes[cursor] != 0 and result.title_len < result.title.len) : (cursor += 1) {
        const value = bytes[cursor];
        result.title[result.title_len] = if (value >= 0x20 and value <= 0x7E) value else '?';
        result.title_len += 1;
    }
    return result;
}

fn validateConfiguration(info: TypeInfo, mapper: MapperKind, rom_bytes: usize, ram_bytes: usize) Error!void {
    if (mapper == .mbc2) {
        if (ram_bytes != 0) return error.InconsistentRam;
    } else if (info.has_ram != (ram_bytes != 0)) {
        return error.InconsistentRam;
    }

    switch (mapper) {
        .none => {
            if (rom_bytes != 32 * 1024) return error.MapperRomTooLarge;
            if (ram_bytes > 8 * 1024) return error.MapperRamTooLarge;
        },
        .mbc1, .mbc1_multicart => {
            if (rom_bytes > 2 * 1024 * 1024) return error.MapperRomTooLarge;
            if (ram_bytes > 32 * 1024) return error.MapperRamTooLarge;
            if (rom_bytes > 512 * 1024 and ram_bytes > 8 * 1024) return error.MapperRamTooLarge;
        },
        .mbc2 => if (rom_bytes > 256 * 1024) return error.MapperRomTooLarge,
        .mbc3 => {
            if (rom_bytes > 2 * 1024 * 1024) return error.MapperRomTooLarge;
            if (ram_bytes > 32 * 1024) return error.MapperRamTooLarge;
        },
        .mbc30 => {
            if (rom_bytes > 4 * 1024 * 1024) return error.MapperRomTooLarge;
            if (ram_bytes > 64 * 1024) return error.MapperRamTooLarge;
        },
        .mbc5 => {
            if (rom_bytes > max_rom_bytes) return error.MapperRomTooLarge;
            const ram_limit: usize = if (info.has_rumble) 64 * 1024 else 128 * 1024;
            if (ram_bytes > ram_limit) return error.MapperRamTooLarge;
        },
        .mmm01 => {
            if (rom_bytes > max_rom_bytes) return error.MapperRomTooLarge;
            if (ram_bytes > 128 * 1024) return error.MapperRamTooLarge;
        },
        .huc1 => {
            if (rom_bytes > 2 * 1024 * 1024) return error.MapperRomTooLarge;
            if (ram_bytes > 128 * 1024) return error.MapperRamTooLarge;
        },
        else => unreachable,
    }
}

pub fn headerChecksum(bytes: []const u8) u8 {
    return headerChecksumAt(bytes, 0);
}

pub fn globalChecksum(bytes: []const u8) u16 {
    return globalChecksumAt(bytes, 0);
}

fn headerChecksumAt(bytes: []const u8, base: usize) u8 {
    var checksum: u8 = 0;
    for (bytes[base + 0x134 .. base + 0x14D]) |value| checksum -%= value +% 1;
    return checksum;
}

fn globalChecksumAt(bytes: []const u8, base: usize) u16 {
    var checksum: u16 = 0;
    for (bytes, 0..) |value, index| {
        if (index == base + 0x14E or index == base + 0x14F) continue;
        checksum +%= value;
    }
    return checksum;
}

fn detectHeaderOffset(bytes: []const u8) usize {
    if (bytes.len < 32 * 1024) return 0;
    const candidate = bytes.len - 32 * 1024;
    if (candidate == 0) return 0;
    if (!std.mem.eql(u8, bytes[candidate + logo_offset .. candidate + logo_offset + logo.len], logo[0..])) return 0;
    if (headerChecksumAt(bytes, candidate) != bytes[candidate + 0x14D]) return 0;
    const info = typeInfo(bytes[candidate + 0x147]) orelse return 0;
    return if (info.mapper == .mmm01) candidate else 0;
}

pub fn romBytes(code: u8) ?usize {
    return switch (code) {
        0x00...0x08 => @as(usize, 32 * 1024) << @intCast(code),
        0x52 => 72 * rom_bank_bytes,
        0x53 => 80 * rom_bank_bytes,
        0x54 => 96 * rom_bank_bytes,
        else => null,
    };
}

pub fn ramBytes(code: u8) ?usize {
    return switch (code) {
        0x00 => 0,
        0x01 => 2 * 1024,
        0x02 => 8 * 1024,
        0x03 => 32 * 1024,
        0x04 => 128 * 1024,
        0x05 => 64 * 1024,
        else => null,
    };
}

fn detectMbc1Multicart(bytes: []const u8) bool {
    // MBC1M's second sub-cartridge starts at bank $10. Checking its complete
    // embedded header avoids guessing from a title or file name.
    if (bytes.len < 17 * rom_bank_bytes) return false;
    const base = 16 * rom_bank_bytes;
    if (!std.mem.eql(u8, bytes[base + logo_offset .. base + logo_offset + logo.len], logo[0..])) return false;
    var checksum: u8 = 0;
    for (bytes[base + 0x134 .. base + 0x14D]) |value| checksum -%= value +% 1;
    return checksum == bytes[base + 0x14D];
}

pub const RtcRegisters = struct {
    seconds: u8 = 0,
    minutes: u8 = 0,
    hours: u8 = 0,
    day_low: u8 = 0,
    day_high: u8 = 0,
    subsecond_t_cycles: u32 = 0,

    pub fn halted(self: *const RtcRegisters) bool {
        return (self.day_high & 0x40) != 0;
    }

    pub fn read(self: *const RtcRegisters, selection: u8) u8 {
        return switch (selection) {
            0x08 => self.seconds,
            0x09 => self.minutes,
            0x0A => self.hours,
            0x0B => self.day_low,
            0x0C => self.day_high,
            else => 0xFF,
        };
    }

    pub fn write(self: *RtcRegisters, selection: u8, value: u8) void {
        switch (selection) {
            0x08 => {
                self.seconds = value & 0x3F;
                // The MBC3 seconds register is also the divider reset input.
                self.subsecond_t_cycles = 0;
            },
            0x09 => self.minutes = value & 0x3F,
            0x0A => self.hours = value & 0x1F,
            0x0B => self.day_low = value,
            0x0C => self.day_high = value & 0xC1,
            else => {},
        }
    }

    /// Advances the independent 32.768 kHz RTC domain expressed in DMG
    /// T-cycles. Invalid but bit-representable values follow measured MBC3
    /// behaviour: $3F/$1F roll to zero without carrying, while the normal
    /// $3B/$17 limits do carry.
    pub fn advanceTcycles(self: *RtcRegisters, count: u32) bool {
        if (self.halted() or count == 0) return false;
        const total: u64 = @as(u64, self.subsecond_t_cycles) + count;
        const elapsed: u64 = total / dmg_t_cycles_per_second;
        self.subsecond_t_cycles = @intCast(total % dmg_t_cycles_per_second);
        if (elapsed == 0) return false;
        self.advanceSeconds(elapsed);
        return true;
    }

    pub fn advanceSeconds(self: *RtcRegisters, count: u64) void {
        var remaining = count;
        // Hardware permits bit-valid but clock-invalid values. Preserve their
        // measured step-by-step rollover behaviour until the three clock
        // fields are normal again; this takes at most a few guest hours.
        while (remaining != 0 and !self.clockFieldsValid()) : (remaining -= 1) {
            self.tickSecond();
        }
        if (remaining == 0) return;

        // Persistence may need to account for months of powered-off time.
        // Once the registers are valid, advance arithmetically instead of
        // executing one host loop iteration per emulated second.
        const seconds_per_day: u128 = 24 * 60 * 60;
        const seconds_per_cycle: u128 = 512 * seconds_per_day;
        const day = (@as(u16, self.day_high & 1) << 8) | self.day_low;
        const current: u128 = @as(u128, day) * seconds_per_day +
            @as(u128, self.hours) * 60 * 60 +
            @as(u128, self.minutes) * 60 + self.seconds;
        const total = current + @as(u128, remaining);
        const within_cycle = total % seconds_per_cycle;
        const next_day: u16 = @intCast(within_cycle / seconds_per_day);
        const within_day = within_cycle % seconds_per_day;

        self.hours = @intCast(within_day / (60 * 60));
        self.minutes = @intCast((within_day / 60) % 60);
        self.seconds = @intCast(within_day % 60);
        self.day_low = @truncate(next_day);
        self.day_high = (self.day_high & 0xC0) | @as(u8, @intCast(next_day >> 8));
        if (total >= seconds_per_cycle) self.day_high |= 0x80;
    }

    fn clockFieldsValid(self: *const RtcRegisters) bool {
        return self.seconds <= 59 and self.minutes <= 59 and self.hours <= 23;
    }

    fn tickSecond(self: *RtcRegisters) void {
        if (self.seconds == 59) {
            self.seconds = 0;
            self.tickMinute();
        } else if (self.seconds == 0x3F) {
            self.seconds = 0;
        } else {
            self.seconds +%= 1;
        }
    }

    fn tickMinute(self: *RtcRegisters) void {
        if (self.minutes == 59) {
            self.minutes = 0;
            self.tickHour();
        } else if (self.minutes == 0x3F) {
            self.minutes = 0;
        } else {
            self.minutes +%= 1;
        }
    }

    fn tickHour(self: *RtcRegisters) void {
        if (self.hours == 23) {
            self.hours = 0;
            self.tickDay();
        } else if (self.hours == 0x1F) {
            self.hours = 0;
        } else {
            self.hours +%= 1;
        }
    }

    fn tickDay(self: *RtcRegisters) void {
        const day = (@as(u16, self.day_high & 1) << 8) | self.day_low;
        if (day == 0x1FF) {
            self.day_low = 0;
            self.day_high = (self.day_high & 0x40) | 0x80;
        } else {
            const next = day + 1;
            self.day_low = @truncate(next);
            self.day_high = (self.day_high & 0xC0) | @as(u8, @intCast((next >> 8) & 1));
        }
    }
};

pub const MapperState = struct {
    ram_enabled: bool = false,
    rom_bank: u16 = 1,
    bank_high: u8 = 0,
    banking_mode: bool = false,
    ram_rtc_select: u8 = 0,
    latch_write: u8 = 0xFF,
    rtc: RtcRegisters = .{},
    rtc_latched: RtcRegisters = .{},
    rumble_on: bool = false,
    mmm_locked: bool = false,
    mmm_rom_bank_mask: u8 = 0,
    mmm_rom_bank_mid: u8 = 0,
    mmm_rom_bank_high: u8 = 0,
    mmm_ram_bank_low: u8 = 0,
    mmm_ram_bank_high: u8 = 0,
    mmm_ram_bank_mask: u8 = 0,
    mmm_mode_write_disabled: bool = false,
    mmm_multiplex: bool = false,
    huc1_ir_mode: bool = false,
    huc1_ir_output: bool = false,
};

pub const Cartridge = struct {
    allocator: std.mem.Allocator,
    header: Header,
    rom: []const u8,
    rom_digest: [rom_digest_bytes]u8,
    external_ram: []u8,
    mapper: MapperState = .{},
    ram_dirty: bool = false,
    rtc_dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, image: []const u8) (Error || std.mem.Allocator.Error)!Cartridge {
        const header = try parse(image);
        const owned_rom = try allocator.dupe(u8, image);
        errdefer allocator.free(owned_rom);
        return initOwnedWithHeader(allocator, owned_rom, header);
    }

    /// Takes ownership only on success. On error, the caller still owns
    /// `owned_image`, which makes bounded host file-loading cleanup explicit.
    pub fn takeOwned(allocator: std.mem.Allocator, owned_image: []u8) (Error || std.mem.Allocator.Error)!Cartridge {
        const header = try parse(owned_image);
        return initOwnedWithHeader(allocator, owned_image, header);
    }

    fn initOwnedWithHeader(allocator: std.mem.Allocator, owned_image: []u8, header: Header) std.mem.Allocator.Error!Cartridge {
        const ram_len: usize = if (header.mapper == .mbc2) 512 else header.expected_ram_bytes;
        const external_ram = try allocator.alloc(u8, ram_len);
        @memset(external_ram, 0xFF);
        var digest: [rom_digest_bytes]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(owned_image, &digest, .{});
        return .{
            .allocator = allocator,
            .header = header,
            .rom = owned_image,
            .rom_digest = digest,
            .external_ram = external_ram,
        };
    }

    pub fn deinit(self: *Cartridge) void {
        self.allocator.free(self.external_ram);
        self.allocator.free(self.rom);
        self.* = undefined;
    }

    pub fn readRom(self: *const Cartridge, address: u16) u8 {
        if (address > 0x7FFF) return 0xFF;
        const bank: usize = if (address < 0x4000) self.lowerRomBank() else self.upperRomBank();
        const in_bank: usize = @as(usize, address) & 0x3FFF;
        const physical = self.romIndex(bank, in_bank) orelse return 0xFF;
        return self.rom[physical];
    }

    pub fn writeControl(self: *Cartridge, address: u16, value: u8) void {
        if (address > 0x7FFF) return;
        switch (self.header.mapper) {
            .none => {},
            .mbc1, .mbc1_multicart => switch (address) {
                0x0000...0x1FFF => self.mapper.ram_enabled = (value & 0x0F) == 0x0A,
                0x2000...0x3FFF => self.mapper.rom_bank = value & 0x1F,
                0x4000...0x5FFF => self.mapper.bank_high = value & 0x03,
                0x6000...0x7FFF => self.mapper.banking_mode = (value & 0x01) != 0,
                else => unreachable,
            },
            .mbc2 => {
                if (address <= 0x3FFF) {
                    if ((address & 0x0100) == 0) {
                        self.mapper.ram_enabled = (value & 0x0F) == 0x0A;
                    } else {
                        const bank = value & 0x0F;
                        self.mapper.rom_bank = if (bank == 0) 1 else bank;
                    }
                }
            },
            .mbc3, .mbc30 => switch (address) {
                0x0000...0x1FFF => self.mapper.ram_enabled = (value & 0x0F) == 0x0A,
                0x2000...0x3FFF => {
                    const mask: u8 = if (self.header.mapper == .mbc30) 0xFF else 0x7F;
                    const bank = value & mask;
                    self.mapper.rom_bank = if (bank == 0) 1 else bank;
                },
                0x4000...0x5FFF => self.mapper.ram_rtc_select = value,
                0x6000...0x7FFF => {
                    if (self.mapper.latch_write == 0 and value == 1) self.mapper.rtc_latched = self.mapper.rtc;
                    self.mapper.latch_write = value;
                },
                else => unreachable,
            },
            .mbc5 => switch (address) {
                0x0000...0x1FFF => self.mapper.ram_enabled = (value & 0x0F) == 0x0A,
                0x2000...0x2FFF => self.mapper.rom_bank = (self.mapper.rom_bank & 0x100) | value,
                0x3000...0x3FFF => self.mapper.rom_bank = (self.mapper.rom_bank & 0x0FF) | (@as(u16, value & 1) << 8),
                0x4000...0x5FFF => {
                    if (self.header.type_info.has_rumble) {
                        self.mapper.rumble_on = (value & 0x08) != 0;
                        self.mapper.ram_rtc_select = value & 0x07;
                    } else {
                        self.mapper.ram_rtc_select = value & 0x0F;
                    }
                },
                0x6000...0x7FFF => {},
                else => unreachable,
            },
            .mmm01 => switch (address) {
                0x0000...0x1FFF => {
                    self.mapper.ram_enabled = (value & 0x0F) == 0x0A;
                    if (!self.mapper.mmm_locked) {
                        self.mapper.mmm_ram_bank_mask = (value >> 4) & 0x03;
                        self.mapper.mmm_locked = (value & 0x40) != 0;
                    }
                },
                0x2000...0x3FFF => {
                    if (!self.mapper.mmm_locked) self.mapper.mmm_rom_bank_mid = (value >> 5) & 0x03;
                    const mask = self.mapper.mmm_rom_bank_mask & 0x1E;
                    self.mapper.rom_bank = (self.mapper.rom_bank & mask) | (value & ~mask & 0x1F);
                },
                0x4000...0x5FFF => {
                    const mask = self.mapper.mmm_ram_bank_mask & 0x03;
                    self.mapper.mmm_ram_bank_low = (self.mapper.mmm_ram_bank_low & mask) | (value & ~mask & 0x03);
                    if (!self.mapper.mmm_locked) {
                        self.mapper.mmm_ram_bank_high = (value >> 2) & 0x03;
                        self.mapper.mmm_rom_bank_high = (value >> 4) & 0x03;
                        self.mapper.mmm_mode_write_disabled = (value & 0x40) != 0;
                    }
                },
                0x6000...0x7FFF => {
                    if (!self.mapper.mmm_mode_write_disabled) self.mapper.banking_mode = (value & 1) != 0;
                    if (!self.mapper.mmm_locked) {
                        self.mapper.mmm_rom_bank_mask = value & 0x1E;
                        self.mapper.mmm_multiplex = (value & 0x40) != 0;
                    }
                },
                else => unreachable,
            },
            .huc1 => switch (address) {
                0x0000...0x1FFF => self.mapper.huc1_ir_mode = (value & 0x0F) == 0x0E,
                0x2000...0x3FFF => self.mapper.rom_bank = value & 0x3F,
                0x4000...0x5FFF => self.mapper.ram_rtc_select = value & 0x07,
                0x6000...0x7FFF => {},
                else => unreachable,
            },
            else => unreachable,
        }
    }

    pub fn readExternal(self: *const Cartridge, address: u16) u8 {
        if (address < 0xA000 or address > 0xBFFF) return 0xFF;
        if (self.header.mapper == .huc1 and self.mapper.huc1_ir_mode) return 0xC0;
        if (self.header.mapper == .mbc2) {
            if (!self.mapper.ram_enabled) return 0xFF;
            return 0xF0 | (self.external_ram[@as(usize, address) & 0x01FF] & 0x0F);
        }
        if (self.header.mapper != .none and self.header.mapper != .huc1 and !self.mapper.ram_enabled) return 0xFF;
        if (self.isRtcSelected()) {
            if (!self.header.type_info.has_timer) return 0xFF;
            return self.mapper.rtc_latched.read(self.mapper.ram_rtc_select);
        }
        if (self.externalSelectionDisconnected()) return 0xFF;
        const index = self.ramIndex(address) orelse return 0xFF;
        return self.external_ram[index];
    }

    pub fn writeExternal(self: *Cartridge, address: u16, value: u8) void {
        if (address < 0xA000 or address > 0xBFFF) return;
        if (self.header.mapper == .huc1 and self.mapper.huc1_ir_mode) {
            self.mapper.huc1_ir_output = (value & 1) != 0;
            return;
        }
        if (self.header.mapper == .mbc2) {
            if (self.mapper.ram_enabled) {
                const index = @as(usize, address) & 0x01FF;
                const next = value & 0x0F;
                if (self.external_ram[index] != next) {
                    self.external_ram[index] = next;
                    self.markRamDirty();
                }
            }
            return;
        }
        if (self.header.mapper != .none and self.header.mapper != .huc1 and !self.mapper.ram_enabled) return;
        if (self.isRtcSelected()) {
            if (self.header.type_info.has_timer) {
                const before = self.mapper.rtc;
                self.mapper.rtc.write(self.mapper.ram_rtc_select, value);
                if (!std.meta.eql(before, self.mapper.rtc)) self.markRtcDirty();
            }
            return;
        }
        if (self.externalSelectionDisconnected()) return;
        const index = self.ramIndex(address) orelse return;
        if (self.external_ram[index] != value) {
            self.external_ram[index] = value;
            self.markRamDirty();
        }
    }

    pub fn advanceRtcTcycles(self: *Cartridge, count: u32) void {
        if (!self.header.type_info.has_timer) return;
        if (self.mapper.rtc.advanceTcycles(count)) self.markRtcDirty();
    }

    pub fn advanceRtcOfflineSeconds(self: *Cartridge, count: u64) void {
        if (!self.header.type_info.has_timer or self.mapper.rtc.halted() or count == 0) return;
        self.mapper.rtc.advanceSeconds(count);
        self.markRtcDirty();
    }

    pub fn clearPersistenceDirty(self: *Cartridge) void {
        self.ram_dirty = false;
        self.rtc_dirty = false;
    }

    fn markRamDirty(self: *Cartridge) void {
        if (self.header.type_info.has_battery and self.external_ram.len != 0) self.ram_dirty = true;
    }

    fn markRtcDirty(self: *Cartridge) void {
        if (self.header.type_info.has_battery and self.header.type_info.has_timer) self.rtc_dirty = true;
    }

    pub fn lowerRomBank(self: *const Cartridge) usize {
        return switch (self.header.mapper) {
            .mbc1 => if (self.mapper.banking_mode) @as(usize, self.mapper.bank_high & 0x03) << 5 else 0,
            .mbc1_multicart => if (self.mapper.banking_mode) @as(usize, self.mapper.bank_high & 0x03) << 4 else 0,
            .mmm01 => self.mmm01LowerRomBank(),
            else => 0,
        };
    }

    pub fn upperRomBank(self: *const Cartridge) usize {
        return switch (self.header.mapper) {
            .none => 1,
            .mbc1 => mbc1UpperBank(self.mapper.rom_bank, self.mapper.bank_high, false),
            .mbc1_multicart => mbc1UpperBank(self.mapper.rom_bank, self.mapper.bank_high, true),
            .mbc2, .mbc3, .mbc30, .mbc5 => self.mapper.rom_bank,
            .mmm01 => self.mmm01UpperRomBank(),
            .huc1 => self.mapper.rom_bank,
            else => unreachable,
        };
    }

    fn isRtcSelected(self: *const Cartridge) bool {
        return (self.header.mapper == .mbc3 or self.header.mapper == .mbc30) and
            self.mapper.ram_rtc_select >= 0x08 and self.mapper.ram_rtc_select <= 0x0C;
    }

    fn externalSelectionDisconnected(self: *const Cartridge) bool {
        return (self.header.mapper == .mbc3 or self.header.mapper == .mbc30) and
            self.mapper.ram_rtc_select > 0x0C;
    }

    fn romIndex(self: *const Cartridge, requested_bank: usize, in_bank: usize) ?usize {
        const bank = mirrorBank(requested_bank, self.header.rom_banks) orelse return null;
        const index = bank * rom_bank_bytes + in_bank;
        return if (index < self.rom.len) index else null;
    }

    fn ramIndex(self: *const Cartridge, address: u16) ?usize {
        if (self.external_ram.len == 0) return null;
        const requested_bank: usize = switch (self.header.mapper) {
            .mbc1, .mbc1_multicart => if (self.mapper.banking_mode) self.mapper.bank_high & 0x03 else 0,
            .mbc3, .mbc30, .mbc5, .huc1 => self.mapper.ram_rtc_select,
            .mmm01 => self.mmm01RamBank(),
            else => 0,
        };
        const raw = requested_bank * ram_bank_bytes + (@as(usize, address) - 0xA000);
        // All supported physical SRAM sizes are powers of two. Missing address
        // lines therefore mirror, rather than escaping into host memory.
        return raw & (self.external_ram.len - 1);
    }

    fn mmm01LowerRomBank(self: *const Cartridge) usize {
        if (!self.mapper.mmm_locked) return self.header.rom_banks -| 2;
        const low = @as(usize, @intCast(self.mapper.rom_bank)) & self.mapper.mmm_rom_bank_mask;
        const mid = if (self.mapper.mmm_multiplex)
            (if (self.mapper.banking_mode) 0 else @as(usize, self.mapper.mmm_ram_bank_low) << 5)
        else
            @as(usize, self.mapper.mmm_rom_bank_mid) << 5;
        return low | mid | (@as(usize, self.mapper.mmm_rom_bank_high) << 7);
    }

    fn mmm01UpperRomBank(self: *const Cartridge) usize {
        if (!self.mapper.mmm_locked) return self.header.rom_banks -| 1;
        var low: usize = @as(usize, @intCast(self.mapper.rom_bank)) & 0x1F;
        const writable = low & ~@as(usize, self.mapper.mmm_rom_bank_mask);
        if (writable == 0) low |= 1;
        const mid = if (self.mapper.mmm_multiplex)
            @as(usize, self.mapper.mmm_ram_bank_low) << 5
        else
            @as(usize, self.mapper.mmm_rom_bank_mid) << 5;
        return low | mid | (@as(usize, self.mapper.mmm_rom_bank_high) << 7);
    }

    fn mmm01RamBank(self: *const Cartridge) usize {
        if (self.mapper.mmm_multiplex) {
            return self.mapper.mmm_rom_bank_mid | (@as(usize, self.mapper.mmm_ram_bank_high) << 2);
        }
        const low: usize = if (self.mapper.banking_mode)
            self.mapper.mmm_ram_bank_low
        else
            self.mapper.mmm_ram_bank_low & self.mapper.mmm_ram_bank_mask;
        return low | (@as(usize, self.mapper.mmm_ram_bank_high) << 2);
    }
};

fn mbc1UpperBank(raw_low: u16, raw_high: u8, multicart: bool) usize {
    const full_low: u8 = @intCast(raw_low & 0x1F);
    const translated: u8 = if (full_low == 0) 1 else full_low;
    const low_mask: u8 = if (multicart) 0x0F else 0x1F;
    const high_shift: u4 = if (multicart) 4 else 5;
    return (@as(usize, raw_high & 0x03) << high_shift) | (translated & low_mask);
}

fn mirrorBank(requested: usize, count: usize) ?usize {
    if (count == 0) return null;
    var wired_count: usize = 1;
    while (wired_count < count) wired_count <<= 1;
    const bank = requested & (wired_count - 1);
    return if (bank < count) bank else null;
}

test "known cartridge table distinguishes mapper and accessory gaps" {
    try std.testing.expectEqual(Support.supported, typeInfo(0x1E).?.support);
    try std.testing.expectEqual(Support.unsupported_mapper, typeInfo(0x20).?.support);
    try std.testing.expectEqual(Support.unavailable_accessory, typeInfo(0x22).?.support);
    try std.testing.expectEqual(Support.unavailable_accessory, typeInfo(0xFC).?.support);
    try std.testing.expect(typeInfo(0x04) == null);
}
