const std = @import("std");
const core = @import("core");
const r4os = @import("r4os");

const product = core.product_host;
const runtime_api = r4os.subsystem_runtime;

const FakeTime = struct {
    wall: ?i64 = 1_000,
    monotonic: u64 = 10,

    fn source(self: *FakeTime) product.TimeSource {
        return .{ .context = self, .now_fn = now };
    }

    fn now(context: *anyopaque) product.TimePoint {
        const self: *FakeTime = @ptrCast(@alignCast(context));
        return .{ .wall_seconds = self.wall, .monotonic_ns = self.monotonic };
    }
};

const FakeStore = struct {
    owner: bool = false,
    owner_digest: [core.persistence.digest_bytes]u8 = .{0} ** core.persistence.digest_bytes,
    owner_generation: u64 = 0,
    sram: [128 * 1024]u8 = .{0} ** (128 * 1024),
    sram_len: usize = 0,
    rtc: [core.persistence.rtc_record_bytes]u8 = .{0} ** core.persistence.rtc_record_bytes,
    rtc_present: bool = false,
    fail_writes: bool = false,
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
        if (generation != self.owner_generation or !std.mem.eql(u8, digest, &self.owner_digest)) return error.Io;
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
                @memcpy(out, &self.rtc);
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
        if (!self.owner or !std.mem.eql(u8, digest, &self.owner_digest)) return error.Busy;
        if (self.fail_writes) return error.Io;
        switch (kind) {
            .sram => {
                if (bytes.len > self.sram.len) return error.Full;
                @memcpy(self.sram[0..bytes.len], bytes);
                self.sram_len = bytes.len;
            },
            .rtc => {
                if (bytes.len != self.rtc.len) return error.Io;
                @memcpy(&self.rtc, bytes);
                self.rtc_present = true;
            },
        }
    }
};

const IdleHost = struct {
    presents: u32 = 0,

    fn driver(self: *IdleHost) runtime_api.HostDriver {
        return .{ .context = self, .poll_fn = poll, .present_fn = present };
    }

    fn poll(_: *anyopaque) runtime_api.HostPollResult {
        return .idle;
    }

    fn present(context: *anyopaque) i32 {
        const self: *IdleHost = @ptrCast(@alignCast(context));
        self.presents += 1;
        return runtime_api.host_present_unchanged;
    }
};

fn makeRom(allocator: std.mem.Allocator, title: []const u8, type_code: u8, ram_code: u8) ![]u8 {
    const bytes = try allocator.alloc(u8, 32 * 1024);
    @memset(bytes, 0);
    bytes[0x100] = 0x18;
    bytes[0x101] = 0xFE;
    @memcpy(bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len], &core.cartridge.logo);
    const title_len: usize = @min(title.len, 16);
    @memcpy(bytes[0x134 .. 0x134 + title_len], title[0..title_len]);
    bytes[0x143] = 0;
    bytes[0x147] = type_code;
    bytes[0x148] = 0;
    bytes[0x149] = ram_code;
    bytes[0x14D] = core.cartridge.headerChecksum(bytes);
    bytes[0x14E] = 0;
    bytes[0x14F] = 0;
    const checksum = core.cartridge.globalChecksum(bytes);
    bytes[0x14E] = @truncate(checksum >> 8);
    bytes[0x14F] = @truncate(checksum);
    return bytes;
}

fn makeRuntime() !runtime_api.Runtime {
    return runtime_api.Runtime.init(.{
        .slice_budget = product.slice_budget_t_cycles,
        .max_input_events = 8,
        .max_wait_ticks = 1,
    }, 1_000, 0, null);
}

test "parallel private guests isolate different ROMs and allow same-ROM instances" {
    const allocator = std.testing.allocator;
    var store = FakeStore{};
    var time = FakeTime{};
    var first = product.Guest.init(allocator, store.backend(), time.source(), 1);
    var second = product.Guest.init(allocator, store.backend(), time.source(), 2);
    var same_as_first = product.Guest.init(allocator, store.backend(), time.source(), 3);
    try first.openOwned(try makeRom(allocator, "ROM-A", 0x00, 0));
    try second.openOwned(try makeRom(allocator, "ROM-B", 0x00, 0));
    try same_as_first.openOwned(try makeRom(allocator, "ROM-A", 0x00, 0));
    defer _ = first.close();
    defer _ = second.close();
    defer _ = same_as_first.close();

    // Different ROMs and a byte-identical second ROM-A all own private
    // machines. Non-battery cartridges never take the save-writer lease.
    try std.testing.expectEqual(@as(u32, 0), store.acquire_calls);
    try std.testing.expect(first.machine != null and second.machine != null and same_as_first.machine != null);
    first.machine.?.bus.work_ram[0] = 0xA1;
    try std.testing.expectEqual(@as(u8, 0), second.machine.?.bus.work_ram[0]);
    try std.testing.expectEqual(@as(u8, 0), same_as_first.machine.?.bus.work_ram[0]);

    first.focusGained(1);
    try std.testing.expect(first.physicalKey(core.host_adapter.physical_usage_right, true, false, 2));
    try std.testing.expect((first.machine.?.joypad.held & 1) != 0);
    try std.testing.expectEqual(@as(u8, 0), second.machine.?.joypad.held);
    first.focusLost(3);
    try std.testing.expectEqual(@as(u8, 0), first.machine.?.joypad.held);

    var first_runtime = try makeRuntime();
    var second_runtime = try makeRuntime();
    var first_host = IdleHost{};
    var second_host = IdleHost{};
    _ = first_runtime.cycle(0, first.driver(), first_host.driver());
    _ = second_runtime.cycle(0, second.driver(), second_host.driver());
    _ = first_runtime.cycle(10, first.driver(), first_host.driver());
    _ = second_runtime.cycle(10, second.driver(), second_host.driver());
    try std.testing.expect(first.stats.slices >= 2 and second.stats.slices >= 2);
    try std.testing.expect(first.stats.maximum_slice_operations <= product.slice_budget_t_cycles + 24);
    try std.testing.expect(second.stats.maximum_slice_operations <= product.slice_budget_t_cycles + 24);
    try std.testing.expect(first.machine.?.guest_t_cycles != 0 and second.machine.?.guest_t_cycles != 0);

    first_runtime.request(.pause, 10, first.driver());
    const guest_ns_before_pause = first_runtime.clock.guest_ns;
    const cycles_before_pause = first.machine.?.guest_t_cycles;
    _ = first_runtime.cycle(1_010, first.driver(), first_host.driver());
    try std.testing.expectEqual(runtime_api.LifecycleState.paused, first_runtime.state);
    try std.testing.expectEqual(guest_ns_before_pause, first_runtime.clock.guest_ns);
    try std.testing.expectEqual(cycles_before_pause, first.machine.?.guest_t_cycles);
    first_runtime.request(.resume_running, 1_010, first.driver());
    _ = first_runtime.cycle(1_011, first.driver(), first_host.driver());
    try std.testing.expectEqual(guest_ns_before_pause + std.time.ns_per_ms, first_runtime.clock.guest_ns);

    first.machine.?.bus.work_ram[1] = 0xCC;
    first.machine.?.ppu.framebuffer[0] = 3;
    const old_generation = first.generation;
    first_runtime.request(.reset, 1_012, first.driver());
    try std.testing.expectEqual(old_generation + 1, first.generation);
    try std.testing.expectEqual(@as(u8, 0), first.machine.?.bus.work_ram[1]);
    try std.testing.expectEqual(@as(u8, 0), first.machine.?.ppu.framebuffer[0]);
    try std.testing.expectEqual(@as(usize, 0), first.machine.?.apu.queuedFrames());
    try std.testing.expectEqual(@as(u64, 1), first.stats.resets);

    first_runtime.request(.close, 1_013, first.driver());
    first_runtime.shutdown();
    try std.testing.expectEqual(@as(i32, 0), first.close());
    try std.testing.expect(!first.resourcesOpen());
    try std.testing.expect(second.resourcesOpen());
    try std.testing.expect(same_as_first.resourcesOpen());
    const second_cycles = second.machine.?.guest_t_cycles;
    _ = second_runtime.cycle(20, second.driver(), second_host.driver());
    try std.testing.expect(second.machine.?.guest_t_cycles > second_cycles);
    try std.testing.expectEqual(@as(i32, 0), first.close());
    try std.testing.expectEqual(@as(u64, 2), first.stats.machine_creates);
    try std.testing.expectEqual(@as(u64, 2), first.stats.machine_destroys);
    try std.testing.expectEqual(@as(u64, 1), first.stats.rom_releases);
    second_runtime.shutdown();
}

test "invalid CGB-only and accessory cartridges unwind owned resources" {
    const allocator = std.testing.allocator;
    var store = FakeStore{};
    var time = FakeTime{};

    var invalid = product.Guest.init(allocator, store.backend(), time.source(), 11);
    const invalid_image = try makeRom(allocator, "INVALID", 0x00, 0);
    invalid_image[0] ^= 1;
    try std.testing.expectError(error.InvalidGlobalChecksum, invalid.openOwned(invalid_image));
    try std.testing.expect(!invalid.resourcesOpen());
    try std.testing.expectEqual(@as(u64, 1), invalid.stats.rom_releases);
    try std.testing.expectEqual(@as(u32, 0), store.acquire_calls);

    var cgb = product.Guest.init(allocator, store.backend(), time.source(), 12);
    const cgb_image = try makeRom(allocator, "CGB-ONLY", 0x00, 0);
    cgb_image[0x143] = 0xC0;
    cgb_image[0x14D] = core.cartridge.headerChecksum(cgb_image);
    const cgb_checksum = core.cartridge.globalChecksum(cgb_image);
    cgb_image[0x14E] = @truncate(cgb_checksum >> 8);
    cgb_image[0x14F] = @truncate(cgb_checksum);
    try std.testing.expectError(error.CgbOnly, cgb.openOwned(cgb_image));
    try std.testing.expect(!cgb.resourcesOpen());
    try std.testing.expectEqual(@as(u64, 1), cgb.stats.rom_releases);

    var accessory = product.Guest.init(allocator, store.backend(), time.source(), 13);
    try std.testing.expectError(error.UnsupportedMbc7Accessory, accessory.openOwned(try makeRom(allocator, "MBC7", 0x22, 0)));
    try std.testing.expect(!accessory.resourcesOpen());
    try std.testing.expectEqual(@as(u64, 1), accessory.stats.rom_releases);
    try std.testing.expectEqual(@as(u32, 0), store.acquire_calls);
}

test "reset rebinds a fresh video generation and preserves flushed battery RAM" {
    const allocator = std.testing.allocator;
    var store = FakeStore{};
    var time = FakeTime{};
    var guest = product.Guest.init(allocator, store.backend(), time.source(), 7);
    try guest.openOwned(try makeRom(allocator, "RESET-SAVE", 0x03, 0x02));
    defer _ = guest.close();

    const surface = try guest.initialSurface();
    var scratch: [r4os.subsystem_host.tile_max_pixels]u32 = undefined;
    var presenter = try r4os.subsystem_host.Presenter.init(surface, scratch[0..]);
    try guest.attachVideo(&presenter);
    const original_generation = guest.video.generation;

    guest.machine.?.cartridge.writeControl(0, 0x0A);
    guest.machine.?.cartridge.writeExternal(0xA000, 0x5A);
    guest.machine.?.ppu.framebuffer[0] = 3;
    guest.machine.?.apu.beginCapture();
    guest.machine.?.apu.tick(0, 1);
    try std.testing.expectEqual(@as(i32, 0), guest.reset());
    try std.testing.expectEqual(original_generation + 1, guest.video.generation);
    try std.testing.expectEqual(@as(u8, 0x5A), guest.machine.?.cartridge.external_ram[0]);
    try std.testing.expectEqual(@as(u8, 0), guest.machine.?.ppu.framebuffer[0]);
    try std.testing.expectEqual(@as(usize, 0), guest.machine.?.apu.queuedFrames());
    try std.testing.expectEqual(@intFromPtr(&guest.machine.?.ppu.framebuffer[0]), @intFromPtr(presenter.surface.indexedPixels().?.ptr));
    try std.testing.expect(store.write_calls >= 1);
}

test "save close failure still releases every resource and remains idempotent" {
    const allocator = std.testing.allocator;
    var store = FakeStore{};
    var time = FakeTime{};
    var guest = product.Guest.init(allocator, store.backend(), time.source(), 9);
    try guest.openOwned(try makeRom(allocator, "CLOSE-FAIL", 0x03, 0x02));
    guest.machine.?.cartridge.writeControl(0, 0x0A);
    guest.machine.?.cartridge.writeExternal(0xA000, 0x77);
    store.fail_writes = true;

    try std.testing.expectEqual(product.close_error_persistence, guest.close());
    try std.testing.expect(!store.owner);
    try std.testing.expect(!guest.resourcesOpen());
    try std.testing.expectEqual(product.close_error_persistence, guest.close());
    try std.testing.expectEqual(@as(u64, 1), guest.stats.machine_destroys);
    try std.testing.expectEqual(@as(u64, 1), guest.stats.rom_releases);
    try std.testing.expectEqual(@as(u32, 1), store.release_calls);
}
