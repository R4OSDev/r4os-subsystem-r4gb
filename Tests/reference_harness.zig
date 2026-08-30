const std = @import("std");
const core = @import("core");

const max_manifest_bytes: usize = 64 * 1024;
const max_vector_bytes: usize = 4 * 1024 * 1024;
// readFileAlloc's limited mode reserves one byte to detect overflow, so this
// harness ceiling sits above the largest legal 8 MiB Game Boy image.
const max_rom_bytes: usize = 16 * 1024 * 1024;

const SuiteKind = enum { sm83_json, rom_tree, rom_file, cartridge_tree, cpu_rom_file };

const Suite = struct {
    id: []const u8,
    path: []const u8,
    kind: SuiteKind,
    expected_files: usize,
    expected_records: usize = 0,
    categories: []const []const u8,
};

const Manifest = struct {
    schema: u32,
    suites: []const Suite,
};

const Summary = struct {
    files: usize = 0,
    records: usize = 0,
    digest: [32]u8 = .{0} ** 32,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4GB reference harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const root = if (args.len >= 2) args[1] else "../../../ExFiles/Reference/GameBoy";
    cwd.access(io, root, .{}) catch {
        std.debug.print("R4GB reference harness SKIP: optional root missing: {s}\n", .{root});
        return;
    };

    const manifest_bytes = try cwd.readFileAlloc(io, "Tests/reference_manifest.json", allocator, .limited(max_manifest_bytes));
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{});
    defer parsed.deinit();
    if (parsed.value.schema != 1) return error.UnsupportedManifestSchema;

    var total_files: usize = 0;
    var total_records: usize = 0;
    var present_suites: usize = 0;
    for (parsed.value.suites) |suite| {
        const suite_path = try std.fs.path.join(allocator, &.{ root, suite.path });
        defer allocator.free(suite_path);
        cwd.access(io, suite_path, .{}) catch {
            std.debug.print("R4GB reference suite SKIP: {s} path={s}\n", .{ suite.id, suite.path });
            continue;
        };
        const summary = switch (suite.kind) {
            .sm83_json => try scanVectorTree(allocator, io, cwd, suite_path),
            .rom_tree => try scanRomTree(allocator, io, cwd, suite_path),
            .rom_file => try scanRomFile(allocator, io, cwd, suite_path),
            .cartridge_tree => try scanCartridgeTree(allocator, io, cwd, suite_path),
            .cpu_rom_file => try scanCpuRomFile(allocator, io, cwd, suite_path),
        };
        if (summary.files != suite.expected_files or summary.records != suite.expected_records) {
            std.debug.print(
                "R4GB reference suite mismatch: {s} files={d}/{d} records={d}/{d}\n",
                .{ suite.id, summary.files, suite.expected_files, summary.records, suite.expected_records },
            );
            return error.ReferenceCountMismatch;
        }
        present_suites += 1;
        total_files += summary.files;
        total_records += summary.records;
        var digest_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(digest_hex[0..], "{x}", .{summary.digest}) catch unreachable;
        std.debug.print("R4GB reference suite OK: {s} files={d} records={d} categories=", .{ suite.id, summary.files, summary.records });
        for (suite.categories, 0..) |category, index| std.debug.print("{s}{s}", .{ if (index == 0) "" else ",", category });
        std.debug.print(" digest={s}\n", .{digest_hex[0..]});
    }
    std.debug.print("R4GB reference harness OK: suites={d} files={d} vectors={d}\n", .{ present_suites, total_files, total_records });
}

fn scanVectorTree(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root: []const u8) !Summary {
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result = Summary{};
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.path, ".json")) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_vector_bytes));
        defer allocator.free(bytes);
        const validation = try core.test_vectors.executeJson(allocator, bytes);
        result.files += 1;
        result.records += validation.vectors;
        mixDigest(&result.digest, entry.path, bytes);
    }
    return result;
}

fn scanRomTree(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root: []const u8) !Summary {
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result = Summary{};
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.path, ".gb")) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
        defer allocator.free(bytes);
        try validateRomIdentity(bytes);
        result.files += 1;
        mixDigest(&result.digest, entry.path, bytes);
    }
    return result;
}

fn scanCartridgeTree(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root: []const u8) !Summary {
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result = Summary{};
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.path, ".gb")) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
        defer allocator.free(bytes);
        _ = try core.cartridge.parse(bytes);
        result.files += 1;
        result.records += 1;
        mixDigest(&result.digest, entry.path, bytes);
    }
    return result;
}

fn scanRomFile(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) !Summary {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
    defer allocator.free(bytes);
    try validateRomIdentity(bytes);
    var result = Summary{ .files = 1 };
    mixDigest(&result.digest, std.fs.path.basename(path), bytes);
    return result;
}

fn scanCpuRomFile(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) !Summary {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
    defer allocator.free(bytes);
    try runMooneyeCpuRom(allocator, bytes);
    var result = Summary{ .files = 1, .records = 1 };
    mixDigest(&result.digest, std.fs.path.basename(path), bytes);
    return result;
}

const CpuRomBus = struct {
    cartridge: *core.cartridge.Cartridge,
    guest_bus: core.bus.Bus = .{},
    video_ram: [0x2000]u8 = .{0} ** 0x2000,
    object_attribute_memory: [0xA0]u8 = .{0} ** 0xA0,
    io: [0x80]u8,
    interrupt_enable: u8,

    fn devices(self: *CpuRomBus) core.bus.Devices {
        return .{
            .cartridge = self.cartridge,
            .video_ram = &self.video_ram,
            .object_attribute_memory = &self.object_attribute_memory,
            .io = &self.io,
            .interrupt_enable = &self.interrupt_enable,
        };
    }

    fn read(context: *anyopaque, address: u16) u8 {
        const self: *CpuRomBus = @ptrCast(@alignCast(context));
        const view = self.devices();
        return self.guest_bus.read(view, address);
    }

    fn write(context: *anyopaque, address: u16, value: u8) void {
        const self: *CpuRomBus = @ptrCast(@alignCast(context));
        const view = self.devices();
        self.guest_bus.write(view, address, value);
    }

    fn idle(_: *anyopaque, _: u16, _: u8) void {}

    fn cpuBus(self: *CpuRomBus) core.cpu.Bus {
        return .{ .context = self, .read_fn = read, .write_fn = write, .idle_fn = idle };
    }
};

fn runMooneyeCpuRom(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var cartridge = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cartridge.deinit();
    const profile = core.model.profile(.dmg_c);
    var memory = CpuRomBus{
        .cartridge = &cartridge,
        .io = profile.mmio,
        .interrupt_enable = profile.ie,
    };
    // The selected CPU-only probes deliberately take Mooneye's documented
    // no-PPU fast path; no PPU result is inferred in this subversion.
    memory.io[0x44] = 0xFF;
    var processor = core.cpu.Cpu.init(profile);
    const instruction_budget: usize = 20_000_000;
    var instructions: usize = 0;
    while (instructions < instruction_budget) : (instructions += 1) {
        if (processor.registers.b == 3 and processor.registers.c == 5 and
            processor.registers.d == 8 and processor.registers.e == 13 and
            processor.registers.h == 21 and processor.registers.l == 34)
        {
            return;
        }
        if (processor.registers.b == 0x42 and processor.registers.c == 0x42 and
            processor.registers.d == 0x42 and processor.registers.e == 0x42 and
            processor.registers.h == 0x42 and processor.registers.l == 0x42)
        {
            return error.MooneyeCpuFailure;
        }
        const execution = processor.step(memory.cpuBus(), 0);
        if (execution.kind == .illegal or execution.kind == .halted or execution.kind == .stopped) {
            return error.MooneyeCpuUnexpectedState;
        }
    }
    return error.MooneyeCpuTimeout;
}

fn validateRomIdentity(bytes: []const u8) !void {
    if (bytes.len < core.cartridge.header_size) return error.ReferenceRomTooSmall;
    if (!std.mem.eql(
        u8,
        bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len],
        core.cartridge.logo[0..],
    )) return error.ReferenceRomLogoMismatch;
}

fn mixDigest(aggregate: *[32]u8, name: []const u8, bytes: []const u8) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(name);
    hash.update(&.{0});
    hash.update(bytes);
    var value: [32]u8 = undefined;
    hash.final(&value);
    for (aggregate, value) |*destination, source| destination.* ^= source;
}
