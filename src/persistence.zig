const std = @import("std");
const cartridge = @import("cartridge.zig");

pub const save_root = "C:\\R4OS\\APPDATA\\SUBSYSTEMS\\r4os.gb\\SAVE\\";
pub const digest_bytes = cartridge.rom_digest_bytes;
pub const digest_hex_bytes = digest_bytes * 2;
pub const flush_delay_t_cycles: u64 = 2 * cartridge.dmg_t_cycles_per_second;
pub const max_offline_seconds: u64 = 512 * 24 * 60 * 60;
pub const rtc_record_bytes: usize = 80;
pub const rtc_record_version: u16 = 1;
const rtc_magic = "R4GBRTC1";

pub const FileKind = enum { sram, rtc };

pub const ReadResult = enum {
    ok,
    missing,
    wrong_size,
    io,
};

pub const BackendError = error{
    Busy,
    Io,
    Full,
    Unsupported,
};

/// Narrow persistence port. The product implementation is backed exclusively
/// by the public App Files facade; deterministic tests use the same contract
/// without smuggling host filesystem APIs into the emulator core.
pub const Backend = struct {
    context: *anyopaque,
    acquire_fn: *const fn (*anyopaque, *const [digest_bytes]u8, u64) BackendError!void,
    release_fn: *const fn (*anyopaque, *const [digest_bytes]u8, u64) BackendError!void,
    read_exact_fn: *const fn (*anyopaque, *const [digest_bytes]u8, FileKind, []u8) ReadResult,
    write_atomic_fn: *const fn (*anyopaque, *const [digest_bytes]u8, FileKind, []const u8) BackendError!void,

    pub fn acquire(self: Backend, digest: *const [digest_bytes]u8, generation: u64) BackendError!void {
        return self.acquire_fn(self.context, digest, generation);
    }

    pub fn release(self: Backend, digest: *const [digest_bytes]u8, generation: u64) BackendError!void {
        return self.release_fn(self.context, digest, generation);
    }

    pub fn readExact(self: Backend, digest: *const [digest_bytes]u8, kind: FileKind, out: []u8) ReadResult {
        return self.read_exact_fn(self.context, digest, kind, out);
    }

    pub fn writeAtomic(self: Backend, digest: *const [digest_bytes]u8, kind: FileKind, bytes: []const u8) BackendError!void {
        return self.write_atomic_fn(self.context, digest, kind, bytes);
    }
};

pub const OpenError = BackendError || error{
    InvalidGeneration,
    CorruptSave,
    CorruptRtc,
};

pub const FlushError = BackendError || error{
    Closed,
    StaleGeneration,
};

pub const OfflineAdjustment = struct {
    seconds: u64 = 0,
    backwards: bool = false,
    clamped: bool = false,
};

pub const RtcRecord = struct {
    registers: cartridge.RtcRegisters,
    wall_anchor_seconds: i64,
    monotonic_anchor_ns: u64,
    generation: u64,
};

pub const Session = struct {
    backend: Backend,
    digest: [digest_bytes]u8,
    generation: u64,
    enabled: bool,
    closed: bool = false,
    last_flush_guest_tick: u64 = 0,
    offline_adjustment: OfflineAdjustment = .{},

    pub fn open(
        cart: *cartridge.Cartridge,
        backend: Backend,
        generation: u64,
        wall_now_seconds: ?i64,
        monotonic_now_ns: u64,
    ) OpenError!Session {
        if (generation == 0) return error.InvalidGeneration;
        var result = Session{
            .backend = backend,
            .digest = cart.rom_digest,
            .generation = generation,
            .enabled = cart.header.type_info.has_battery,
        };
        cart.clearPersistenceDirty();
        if (!result.enabled) return result;

        try backend.acquire(&result.digest, generation);
        errdefer backend.release(&result.digest, generation) catch {};

        if (cart.external_ram.len != 0) {
            switch (backend.readExact(&result.digest, .sram, cart.external_ram)) {
                .ok, .missing => {},
                .wrong_size => return error.CorruptSave,
                .io => return error.Io,
            }
        }

        if (cart.header.type_info.has_timer) {
            var encoded: [rtc_record_bytes]u8 = undefined;
            switch (backend.readExact(&result.digest, .rtc, encoded[0..])) {
                .ok => {
                    const record = decodeRtc(encoded[0..]) catch return error.CorruptRtc;
                    cart.mapper.rtc = record.registers;
                    cart.mapper.rtc_latched = record.registers;
                    result.offline_adjustment = offlineDelta(record.wall_anchor_seconds, wall_now_seconds);
                    if (!cart.mapper.rtc.halted()) {
                        cart.advanceRtcOfflineSeconds(result.offline_adjustment.seconds);
                    }
                },
                .missing => cart.rtc_dirty = true,
                .wrong_size => return error.CorruptRtc,
                .io => return error.Io,
            }
            _ = monotonic_now_ns;
        }
        return result;
    }

    pub fn maybeFlush(
        self: *Session,
        cart: *cartridge.Cartridge,
        guest_tick: u64,
        wall_now_seconds: ?i64,
        monotonic_now_ns: u64,
    ) FlushError!bool {
        if (self.closed) return error.Closed;
        if (!self.enabled or (!cart.ram_dirty and !cart.rtc_dirty)) return false;
        if (guest_tick -| self.last_flush_guest_tick < flush_delay_t_cycles) return false;
        try self.flush(cart, wall_now_seconds, monotonic_now_ns);
        self.last_flush_guest_tick = guest_tick;
        return true;
    }

    pub fn flush(
        self: *Session,
        cart: *cartridge.Cartridge,
        wall_now_seconds: ?i64,
        monotonic_now_ns: u64,
    ) FlushError!void {
        if (self.closed) return error.Closed;
        if (!self.enabled) return;
        if (cart.ram_dirty and cart.external_ram.len != 0) {
            try self.backend.writeAtomic(&self.digest, .sram, cart.external_ram);
            cart.ram_dirty = false;
        }
        if (cart.rtc_dirty and cart.header.type_info.has_timer) {
            var encoded: [rtc_record_bytes]u8 = undefined;
            encodeRtc(.{
                .registers = cart.mapper.rtc,
                .wall_anchor_seconds = wall_now_seconds orelse 0,
                .monotonic_anchor_ns = monotonic_now_ns,
                .generation = self.generation,
            }, &encoded);
            try self.backend.writeAtomic(&self.digest, .rtc, encoded[0..]);
            cart.rtc_dirty = false;
        }
    }

    /// Close is generation checked and idempotent. Flush failure never keeps
    /// the lease alive: the old atomically published file remains authoritative
    /// and a later process can recover ownership safely.
    pub fn close(
        self: *Session,
        cart: *cartridge.Cartridge,
        generation: u64,
        wall_now_seconds: ?i64,
        monotonic_now_ns: u64,
    ) FlushError!void {
        if (self.closed) return;
        if (generation != self.generation) return error.StaleGeneration;
        self.closed = true;
        if (!self.enabled) return;
        var flush_fault: ?FlushError = null;
        // Temporarily expose the live state to the shared flush path; closed
        // remains externally visible even if either operation fails.
        self.closed = false;
        self.flush(cart, wall_now_seconds, monotonic_now_ns) catch |fault| {
            flush_fault = fault;
        };
        self.closed = true;
        var release_fault: ?BackendError = null;
        self.backend.release(&self.digest, generation) catch |fault| {
            release_fault = fault;
        };
        if (flush_fault) |fault| return fault;
        if (release_fault) |fault| return fault;
    }
};

pub fn offlineDelta(saved_wall_seconds: i64, now_wall_seconds: ?i64) OfflineAdjustment {
    const now = now_wall_seconds orelse return .{};
    if (saved_wall_seconds <= 0 or now <= 0) return .{};
    if (now < saved_wall_seconds) return .{ .backwards = true };
    const raw: u64 = @intCast(now - saved_wall_seconds);
    if (raw > max_offline_seconds) return .{ .seconds = max_offline_seconds, .clamped = true };
    return .{ .seconds = raw };
}

pub fn digestHex(digest: *const [digest_bytes]u8, out: *[digest_hex_bytes]u8) []const u8 {
    const alphabet = "0123456789ABCDEF";
    for (digest, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0F];
    }
    return out[0..];
}

pub fn encodeRtc(record: RtcRecord, out: *[rtc_record_bytes]u8) void {
    @memset(out, 0);
    @memcpy(out[0..rtc_magic.len], rtc_magic);
    writeLe(u16, out[8..10], rtc_record_version);
    writeLe(u16, out[10..12], rtc_record_bytes);
    out[12] = record.registers.seconds & 0x3F;
    out[13] = record.registers.minutes & 0x3F;
    out[14] = record.registers.hours & 0x1F;
    out[15] = record.registers.day_low;
    out[16] = record.registers.day_high & 0xC1;
    writeLe(u32, out[20..24], record.registers.subsecond_t_cycles);
    writeLe(u64, out[24..32], @bitCast(record.wall_anchor_seconds));
    writeLe(u64, out[32..40], record.monotonic_anchor_ns);
    writeLe(u64, out[40..48], record.generation);
    std.crypto.hash.sha2.Sha256.hash(out[0..48], out[48..80], .{});
}

pub fn decodeRtc(bytes: []const u8) !RtcRecord {
    if (bytes.len != rtc_record_bytes) return error.WrongSize;
    if (!std.mem.eql(u8, bytes[0..rtc_magic.len], rtc_magic)) return error.BadMagic;
    if (readLe(u16, bytes[8..10]) != rtc_record_version) return error.UnsupportedVersion;
    if (readLe(u16, bytes[10..12]) != rtc_record_bytes) return error.WrongSize;
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..48], &expected, .{});
    if (!std.mem.eql(u8, bytes[48..80], expected[0..])) return error.BadChecksum;
    if ((bytes[12] & ~@as(u8, 0x3F)) != 0 or
        (bytes[13] & ~@as(u8, 0x3F)) != 0 or
        (bytes[14] & ~@as(u8, 0x1F)) != 0 or
        (bytes[16] & ~@as(u8, 0xC1)) != 0)
        return error.InvalidRegisters;
    const subsecond = readLe(u32, bytes[20..24]);
    if (subsecond >= cartridge.dmg_t_cycles_per_second) return error.InvalidSubsecond;
    return .{
        .registers = .{
            .seconds = bytes[12],
            .minutes = bytes[13],
            .hours = bytes[14],
            .day_low = bytes[15],
            .day_high = bytes[16],
            .subsecond_t_cycles = subsecond,
        },
        .wall_anchor_seconds = @bitCast(readLe(u64, bytes[24..32])),
        .monotonic_anchor_ns = readLe(u64, bytes[32..40]),
        .generation = readLe(u64, bytes[40..48]),
    };
}

fn writeLe(comptime T: type, out: []u8, value: T) void {
    var index: usize = 0;
    while (index < @sizeOf(T)) : (index += 1) out[index] = @truncate(value >> @intCast(index * 8));
}

fn readLe(comptime T: type, bytes: []const u8) T {
    var value: T = 0;
    for (bytes, 0..) |byte, index| value |= @as(T, byte) << @intCast(index * 8);
    return value;
}
