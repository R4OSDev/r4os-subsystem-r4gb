const std = @import("std");
const core = @import("core");

const FakeStore = struct {
    owner: bool = false,
    owner_digest: [core.persistence.digest_bytes]u8 = .{0} ** core.persistence.digest_bytes,
    owner_generation: u64 = 0,
    sram: [128 * 1024]u8 = .{0} ** (128 * 1024),
    sram_len: usize = 0,
    rtc: [core.persistence.rtc_record_bytes]u8 = .{0} ** core.persistence.rtc_record_bytes,
    rtc_present: bool = false,
    fail_writes: bool = false,
    full_writes: bool = false,
    acquire_calls: u32 = 0,
    release_calls: u32 = 0,
    write_calls: u32 = 0,

    fn backend(self: *FakeStore) core.persistence.Backend {
        return .{
            .context = self,
            .acquire_fn = acquire,
            .release_fn = release,
            .read_exact_fn = readExact,
            .write_atomic_fn = writeAtomic,
        };
    }

    fn acquire(context: *anyopaque, digest: *const [core.persistence.digest_bytes]u8, generation: u64) core.persistence.BackendError!void {
        const self: *FakeStore = @ptrCast(@alignCast(context));
        self.acquire_calls += 1;
        if (self.owner) return error.Busy;
        self.owner = true;
        self.owner_digest = digest.*;
        self.owner_generation = generation;
    }

    fn release(context: *anyopaque, digest: *const [core.persistence.digest_bytes]u8, generation: u64) core.persistence.BackendError!void {
        const self: *FakeStore = @ptrCast(@alignCast(context));
        self.release_calls += 1;
        if (!self.owner) return;
        if (self.owner_generation != generation or !std.mem.eql(u8, self.owner_digest[0..], digest[0..])) return error.Io;
        self.owner = false;
        self.owner_generation = 0;
    }

    fn readExact(
        context: *anyopaque,
        _: *const [core.persistence.digest_bytes]u8,
        kind: core.persistence.FileKind,
        out: []u8,
    ) core.persistence.ReadResult {
        const self: *FakeStore = @ptrCast(@alignCast(context));
        switch (kind) {
            .sram => {
                if (self.sram_len == 0) return .missing;
                if (self.sram_len != out.len) return .wrong_size;
                @memcpy(out, self.sram[0..self.sram_len]);
            },
            .rtc => {
                if (!self.rtc_present) return .missing;
                if (out.len != self.rtc.len) return .wrong_size;
                @memcpy(out, self.rtc[0..]);
            },
        }
        return .ok;
    }

    fn writeAtomic(
        context: *anyopaque,
        digest: *const [core.persistence.digest_bytes]u8,
        kind: core.persistence.FileKind,
        bytes: []const u8,
    ) core.persistence.BackendError!void {
        const self: *FakeStore = @ptrCast(@alignCast(context));
        self.write_calls += 1;
        if (!self.owner or !std.mem.eql(u8, self.owner_digest[0..], digest[0..])) return error.Busy;
        if (self.fail_writes) return error.Io;
        if (self.full_writes) return error.Full;
        switch (kind) {
            .sram => {
                if (bytes.len > self.sram.len) return error.Full;
                @memcpy(self.sram[0..bytes.len], bytes);
                self.sram_len = bytes.len;
            },
            .rtc => {
                if (bytes.len != self.rtc.len) return error.Io;
                @memcpy(self.rtc[0..], bytes);
                self.rtc_present = true;
            },
        }
    }
};

fn makeRom(allocator: std.mem.Allocator, type_code: u8, rom_code: u8, ram_code: u8) ![]u8 {
    const size = core.cartridge.romBytes(rom_code) orelse return error.BadRomSize;
    const bytes = try allocator.alloc(u8, size);
    @memset(bytes, 0);
    var bank: usize = 0;
    while (bank * core.cartridge.rom_bank_bytes < bytes.len) : (bank += 1) {
        const base = bank * core.cartridge.rom_bank_bytes;
        bytes[base] = @truncate(bank);
        bytes[base + 1] = @truncate(bank >> 8);
    }
    writeHeader(bytes, 0, type_code, rom_code, ram_code);
    return bytes;
}

fn writeHeader(bytes: []u8, base: usize, type_code: u8, rom_code: u8, ram_code: u8) void {
    @memcpy(bytes[base + core.cartridge.logo_offset .. base + core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[base + 0x134 .. base + 0x13D], "PERSIST01");
    bytes[base + 0x143] = 0;
    bytes[base + 0x147] = type_code;
    bytes[base + 0x148] = rom_code;
    bytes[base + 0x149] = ram_code;
    var header_sum: u8 = 0;
    for (bytes[base + 0x134 .. base + 0x14D]) |value| header_sum -%= value +% 1;
    bytes[base + 0x14D] = header_sum;
    bytes[base + 0x14E] = 0;
    bytes[base + 0x14F] = 0;
    var global: u16 = 0;
    for (bytes, 0..) |value, index| {
        if (index == base + 0x14E or index == base + 0x14F) continue;
        global +%= value;
    }
    bytes[base + 0x14E] = @truncate(global >> 8);
    bytes[base + 0x14F] = @truncate(global);
}

test "full ROM SHA-256 is the only save identity" {
    const allocator = std.testing.allocator;
    const first = try makeRom(allocator, 0x03, 0x01, 0x02);
    defer allocator.free(first);
    const renamed_copy = try allocator.dupe(u8, first);
    defer allocator.free(renamed_copy);
    var left = try core.cartridge.Cartridge.init(allocator, first);
    defer left.deinit();
    var right = try core.cartridge.Cartridge.init(allocator, renamed_copy);
    defer right.deinit();
    try std.testing.expectEqualSlices(u8, left.rom_digest[0..], right.rom_digest[0..]);

    renamed_copy[0x200] ^= 1;
    writeHeader(renamed_copy, 0, 0x03, 0x01, 0x02);
    var changed = try core.cartridge.Cartridge.init(allocator, renamed_copy);
    defer changed.deinit();
    try std.testing.expect(!std.mem.eql(u8, left.rom_digest[0..], changed.rom_digest[0..]));
    var text: [core.persistence.digest_hex_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 64), core.persistence.digestHex(&left.rom_digest, &text).len);
}

test "battery SRAM is delayed, atomically retained on failure, and mandatory on close" {
    const allocator = std.testing.allocator;
    const image = try makeRom(allocator, 0x03, 0x01, 0x02);
    defer allocator.free(image);
    var store = FakeStore{};
    var cart = try core.cartridge.Cartridge.init(allocator, image);
    defer cart.deinit();
    var session = try core.persistence.Session.open(&cart, store.backend(), 7, 1_000, 10);
    cart.writeControl(0, 0x0A);
    cart.writeExternal(0xA000, 0x51);
    try std.testing.expect(cart.ram_dirty);
    try std.testing.expect(!try session.maybeFlush(&cart, core.persistence.flush_delay_t_cycles - 1, 1_001, 11));
    try std.testing.expect(try session.maybeFlush(&cart, core.persistence.flush_delay_t_cycles, 1_002, 12));
    try std.testing.expectEqual(cart.external_ram.len, store.sram_len);
    try std.testing.expectEqual(@as(u8, 0x51), store.sram[0]);

    cart.writeExternal(0xA000, 0x62);
    store.fail_writes = true;
    try std.testing.expectError(error.Io, session.close(&cart, 7, 1_003, 13));
    try std.testing.expect(!store.owner);
    try std.testing.expectEqual(@as(u8, 0x51), store.sram[0]);
    try session.close(&cart, 7, 1_003, 13);

    store.fail_writes = false;
    var reopened = try core.cartridge.Cartridge.init(allocator, image);
    defer reopened.deinit();
    var second = try core.persistence.Session.open(&reopened, store.backend(), 8, 1_004, 14);
    try std.testing.expectEqual(@as(u8, 0x51), reopened.external_ram[0]);
    try second.close(&reopened, 8, 1_004, 14);

    var full_cart = try core.cartridge.Cartridge.init(allocator, image);
    defer full_cart.deinit();
    var full_session = try core.persistence.Session.open(&full_cart, store.backend(), 9, 1_005, 15);
    full_cart.writeControl(0, 0x0A);
    full_cart.writeExternal(0xA000, 0x73);
    store.full_writes = true;
    try std.testing.expectError(error.Full, full_session.close(&full_cart, 9, 1_006, 16));
    try std.testing.expect(!store.owner);
    try std.testing.expectEqual(@as(u8, 0x51), store.sram[0]);
}

test "non-battery cartridges never acquire or persist" {
    const allocator = std.testing.allocator;
    const image = try makeRom(allocator, 0x02, 0x01, 0x02);
    defer allocator.free(image);
    var store = FakeStore{};
    var cart = try core.cartridge.Cartridge.init(allocator, image);
    defer cart.deinit();
    var session = try core.persistence.Session.open(&cart, store.backend(), 1, null, 0);
    cart.writeControl(0, 0x0A);
    cart.writeExternal(0xA000, 0xAA);
    try std.testing.expect(!cart.ram_dirty);
    try session.close(&cart, 1, null, 0);
    try std.testing.expectEqual(@as(u32, 0), store.acquire_calls);
    try std.testing.expectEqual(@as(u32, 0), store.write_calls);
}

test "one digest has one writer and stale generations cannot release it" {
    const allocator = std.testing.allocator;
    const image = try makeRom(allocator, 0x03, 0x01, 0x02);
    defer allocator.free(image);
    var store = FakeStore{};
    var first_cart = try core.cartridge.Cartridge.init(allocator, image);
    defer first_cart.deinit();
    var second_cart = try core.cartridge.Cartridge.init(allocator, image);
    defer second_cart.deinit();
    var first = try core.persistence.Session.open(&first_cart, store.backend(), 40, 100, 10);
    try std.testing.expectError(error.Busy, core.persistence.Session.open(&second_cart, store.backend(), 41, 100, 10));
    try std.testing.expectError(error.StaleGeneration, first.close(&first_cart, 39, 100, 10));
    try std.testing.expect(store.owner);
    try first.close(&first_cart, 40, 100, 10);
    try std.testing.expect(!store.owner);
    var second = try core.persistence.Session.open(&second_cart, store.backend(), 41, 100, 10);
    try second.close(&second_cart, 41, 100, 10);
}

test "versioned RTC record rejects corruption and bounds wall-clock jumps" {
    var encoded: [core.persistence.rtc_record_bytes]u8 = undefined;
    core.persistence.encodeRtc(.{
        .registers = .{ .seconds = 63, .minutes = 62, .hours = 30, .day_low = 0xAA, .day_high = 0xC1, .subsecond_t_cycles = 1234 },
        .wall_anchor_seconds = 50,
        .monotonic_anchor_ns = 99,
        .generation = 7,
    }, &encoded);
    const decoded = try core.persistence.decodeRtc(encoded[0..]);
    try std.testing.expectEqual(@as(u8, 63), decoded.registers.seconds);
    try std.testing.expectEqual(@as(u32, 1234), decoded.registers.subsecond_t_cycles);
    try std.testing.expectEqual(@as(i64, 50), decoded.wall_anchor_seconds);
    encoded[12] ^= 1;
    try std.testing.expectError(error.BadChecksum, core.persistence.decodeRtc(encoded[0..]));

    const backwards = core.persistence.offlineDelta(100, 90);
    try std.testing.expect(backwards.backwards);
    try std.testing.expectEqual(@as(u64, 0), backwards.seconds);
    const huge = core.persistence.offlineDelta(1, @as(i64, @intCast(core.persistence.max_offline_seconds)) + 10_000);
    try std.testing.expect(huge.clamped);
    try std.testing.expectEqual(core.persistence.max_offline_seconds, huge.seconds);
}

test "missing, offline and corrupt persistence inputs have deterministic open policy" {
    const allocator = std.testing.allocator;
    const image = try makeRom(allocator, 0x10, 0x01, 0x02);
    defer allocator.free(image);
    var store = FakeStore{};
    core.persistence.encodeRtc(.{
        .registers = .{ .seconds = 10, .subsecond_t_cycles = 77 },
        .wall_anchor_seconds = 100,
        .monotonic_anchor_ns = 900,
        .generation = 1,
    }, &store.rtc);
    store.rtc_present = true;

    var offline_cart = try core.cartridge.Cartridge.init(allocator, image);
    defer offline_cart.deinit();
    var offline = try core.persistence.Session.open(&offline_cart, store.backend(), 2, 105, 1_000);
    try std.testing.expectEqual(@as(u8, 15), offline_cart.mapper.rtc.seconds);
    try std.testing.expectEqual(@as(u32, 77), offline_cart.mapper.rtc.subsecond_t_cycles);
    try std.testing.expect(offline_cart.rtc_dirty);
    try offline.close(&offline_cart, 2, 105, 1_000);

    store.rtc[48] ^= 1;
    var corrupt_rtc_cart = try core.cartridge.Cartridge.init(allocator, image);
    defer corrupt_rtc_cart.deinit();
    try std.testing.expectError(error.CorruptRtc, core.persistence.Session.open(&corrupt_rtc_cart, store.backend(), 3, 106, 1_100));
    try std.testing.expect(!store.owner);

    store.rtc_present = false;
    store.sram_len = 1;
    var corrupt_save_cart = try core.cartridge.Cartridge.init(allocator, image);
    defer corrupt_save_cart.deinit();
    try std.testing.expectError(error.CorruptSave, core.persistence.Session.open(&corrupt_save_cart, store.backend(), 4, 107, 1_200));
    try std.testing.expect(!store.owner);
}

test "MBC3 RTC implements latch, halt, invalid ranges and sticky day carry" {
    var rtc = core.cartridge.RtcRegisters{};
    try std.testing.expect(!rtc.advanceTcycles(core.cartridge.dmg_t_cycles_per_second - 1));
    try std.testing.expect(rtc.advanceTcycles(1));
    try std.testing.expectEqual(@as(u8, 1), rtc.seconds);
    rtc.write(0x08, 59);
    rtc.write(0x09, 59);
    rtc.write(0x0A, 23);
    rtc.write(0x0B, 0xFF);
    rtc.write(0x0C, 1);
    _ = rtc.advanceTcycles(core.cartridge.dmg_t_cycles_per_second);
    try std.testing.expectEqual(@as(u8, 0), rtc.seconds);
    try std.testing.expectEqual(@as(u8, 0), rtc.day_low);
    try std.testing.expectEqual(@as(u8, 0x80), rtc.day_high);

    rtc.write(0x08, 59);
    rtc.write(0x09, 63);
    rtc.write(0x0A, 7);
    _ = rtc.advanceTcycles(core.cartridge.dmg_t_cycles_per_second);
    try std.testing.expectEqual(@as(u8, 0), rtc.minutes);
    try std.testing.expectEqual(@as(u8, 7), rtc.hours);

    rtc.subsecond_t_cycles = core.cartridge.dmg_t_cycles_per_second / 2;
    rtc.write(0x0C, rtc.day_high | 0x40);
    try std.testing.expect(!rtc.advanceTcycles(core.cartridge.dmg_t_cycles_per_second));
    rtc.write(0x0C, rtc.day_high & ~@as(u8, 0x40));
    try std.testing.expect(rtc.advanceTcycles(core.cartridge.dmg_t_cycles_per_second / 2));

    rtc = .{ .seconds = 17, .minutes = 23, .hours = 9, .day_low = 7, .subsecond_t_cycles = 123 };
    rtc.advanceSeconds(core.persistence.max_offline_seconds);
    try std.testing.expectEqual(@as(u8, 17), rtc.seconds);
    try std.testing.expectEqual(@as(u8, 23), rtc.minutes);
    try std.testing.expectEqual(@as(u8, 9), rtc.hours);
    try std.testing.expectEqual(@as(u8, 7), rtc.day_low);
    try std.testing.expectEqual(@as(u8, 0x80), rtc.day_high);
    try std.testing.expectEqual(@as(u32, 123), rtc.subsecond_t_cycles);
}

test "MMM01 boots from the final header and locks into its selected game" {
    const allocator = std.testing.allocator;
    const image = try makeRom(allocator, 0x00, 0x04, 0x00);
    defer allocator.free(image);
    const menu_base = image.len - 32 * 1024;
    writeHeader(image, menu_base, 0x0B, 0x04, 0x00);
    var cart = try core.cartridge.Cartridge.init(allocator, image);
    defer cart.deinit();

    try std.testing.expectEqual(menu_base, cart.header.header_offset);
    try std.testing.expectEqual(core.cartridge.MapperKind.mmm01, cart.header.mapper);
    try std.testing.expectEqual(@as(u8, 30), cart.readRom(0));
    try std.testing.expectEqual(@as(u8, 31), cart.readRom(0x4000));
    cart.writeControl(0x2000, 0x00);
    cart.writeControl(0x6000, 0x00);
    cart.writeControl(0x4000, 0x00);
    cart.writeControl(0x0000, 0x40);
    try std.testing.expect(cart.mapper.mmm_locked);
    try std.testing.expectEqual(@as(u8, 0), cart.readRom(0));
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4000));
    // Game code can still use the unmasked MBC1-compatible low bank bits,
    // while the menu-only selection fields stay locked.
    cart.writeControl(0x2000, 5);
    try std.testing.expectEqual(@as(u8, 5), cart.readRom(0x4000));
}

test "HuC1 digital banking works while unavailable IR input is deterministic" {
    const allocator = std.testing.allocator;
    const image = try makeRom(allocator, 0xFF, 0x05, 0x03);
    defer allocator.free(image);
    var cart = try core.cartridge.Cartridge.init(allocator, image);
    defer cart.deinit();
    try std.testing.expectEqual(core.cartridge.MapperKind.huc1, cart.header.mapper);
    cart.writeControl(0x2000, 17);
    try std.testing.expectEqual(@as(u8, 17), cart.readRom(0x4000));
    cart.writeControl(0x4000, 3);
    cart.writeExternal(0xA000, 0x73);
    try std.testing.expectEqual(@as(u8, 0x73), cart.readExternal(0xA000));
    cart.writeControl(0x0000, 0x0E);
    try std.testing.expectEqual(@as(u8, 0xC0), cart.readExternal(0xA000));
    cart.writeExternal(0xA000, 1);
    try std.testing.expect(cart.mapper.huc1_ir_output);
    cart.writeControl(0x0000, 0x00);
    try std.testing.expectEqual(@as(u8, 0x73), cart.readExternal(0xA000));
}
