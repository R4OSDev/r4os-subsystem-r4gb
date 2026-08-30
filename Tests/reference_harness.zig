const std = @import("std");
const core = @import("core");

const max_manifest_bytes: usize = 64 * 1024;
const max_vector_bytes: usize = 4 * 1024 * 1024;
// readFileAlloc's limited mode reserves one byte to detect overflow, so this
// harness ceiling sits above the largest legal 8 MiB Game Boy image.
const max_rom_bytes: usize = 16 * 1024 * 1024;

const SuiteKind = enum { sm83_json, rom_tree, rom_file, cartridge_tree, cpu_rom_file, machine_rom_manifest };

const Suite = struct {
    id: []const u8,
    path: []const u8,
    kind: SuiteKind,
    expected_files: usize,
    expected_records: usize = 0,
    categories: []const []const u8,
    selection: ?[]const u8 = null,
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
    const suite_filter: ?[]const u8 = if (args.len >= 3) args[2] else null;
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
        if (suite_filter) |filter| {
            if (!std.mem.eql(u8, filter, suite.id)) continue;
        }
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
            .machine_rom_manifest => try scanMachineRomManifest(allocator, io, cwd, suite_path, suite.selection orelse return error.MissingSelectionManifest),
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
    if (suite_filter != null and present_suites == 0) return error.ReferenceSuiteNotFound;
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

const MachineDisposition = enum { required, deferred_ppu, foreign_revision };

const MachineEntry = struct {
    path: []const u8,
    disposition: MachineDisposition,
    reason: []const u8,
};

const MachineSelection = struct {
    schema: u32,
    revision: []const u8,
    entries: []const MachineEntry,
};

fn scanMachineRomManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    root: []const u8,
    selection_path: []const u8,
) !Summary {
    const selection_bytes = try cwd.readFileAlloc(io, selection_path, allocator, .limited(max_manifest_bytes));
    defer allocator.free(selection_bytes);
    var parsed = try std.json.parseFromSlice(MachineSelection, allocator, selection_bytes, .{});
    defer parsed.deinit();
    if (parsed.value.schema != 1) return error.UnsupportedMachineSelectionSchema;
    if (!std.mem.eql(u8, parsed.value.revision, "dmg-c")) return error.UnsupportedMachineRevision;

    var result = Summary{};
    var deferred_ppu: usize = 0;
    var foreign_revision: usize = 0;
    for (parsed.value.entries) |entry| {
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
        defer allocator.free(bytes);
        try validateRomIdentity(bytes);
        switch (entry.disposition) {
            .required => {
                runMooneyeMachineRom(allocator, bytes) catch |fault| {
                    std.debug.print("R4GB machine ROM FAILED: {s} reason={s} error={s}\n", .{ entry.path, entry.reason, @errorName(fault) });
                    return fault;
                };
                result.files += 1;
                result.records += 1;
                mixDigest(&result.digest, entry.path, bytes);
            },
            .deferred_ppu => deferred_ppu += 1,
            .foreign_revision => foreign_revision += 1,
        }
    }
    std.debug.print(
        "R4GB machine selection: revision={s} required={d} deferred-ppu={d} foreign-revision={d}\n",
        .{ parsed.value.revision, result.files, deferred_ppu, foreign_revision },
    );
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

fn runMooneyeMachineRom(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var machine = core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(allocator, bytes));
    defer machine.deinit();
    // The 0.72.4 set contains no PPU-dependent required cases. Once execution
    // enters Mooneye's bank-1 reporting library, marking LY unavailable selects
    // its documented register-result path without altering post-boot MMIO tests.
    const instruction_budget: usize = 50_000_000;
    var instructions: usize = 0;
    var div_reads: [16]u16 = undefined;
    var div_read_count: usize = 0;
    var serial_edges: [8]u64 = undefined;
    var serial_edge_count: usize = 0;
    var last_program_counter: u16 = machine.cpu.registers.pc;
    while (instructions < instruction_budget) : (instructions += 1) {
        if (machine.cpu.registers.pc >= 0x4000 and
            machine.cpu.registers.b == 3 and machine.cpu.registers.c == 5 and
            machine.cpu.registers.d == 8 and machine.cpu.registers.e == 13 and
            machine.cpu.registers.h == 21 and machine.cpu.registers.l == 34)
        {
            return;
        }
        if (machine.cpu.registers.pc >= 0x4000 and
            machine.cpu.registers.b == 0x42 and machine.cpu.registers.c == 0x42 and
            machine.cpu.registers.d == 0x42 and machine.cpu.registers.e == 0x42 and
            machine.cpu.registers.h == 0x42 and machine.cpu.registers.l == 0x42)
        {
            std.debug.print(
                "R4GB Mooneye failure state: pc={x:0>4} last-main-pc={x:0>4} sp={x:0>4} a={x:0>2} f={x:0>2} cycles={d} div={x:0>4} if={x:0>2} ie={x:0>2}\n",
                .{ machine.cpu.registers.pc, last_program_counter, machine.cpu.registers.sp, machine.cpu.registers.a, machine.cpu.registers.f, machine.guest_t_cycles, machine.timer.divider_counter, machine.interrupts.readRequest(), machine.interrupts.enable },
            );
            std.debug.print(
                "R4GB Mooneye saved: f={x:0>2} a={x:0>2} c={x:0>2} b={x:0>2} e={x:0>2} d={x:0>2} l={x:0>2} h={x:0>2} flags={x:0>2}\n",
                .{ machine.bus.high_ram[0], machine.bus.high_ram[1], machine.bus.high_ram[2], machine.bus.high_ram[3], machine.bus.high_ram[4], machine.bus.high_ram[5], machine.bus.high_ram[6], machine.bus.high_ram[7], machine.bus.high_ram[8] },
            );
            std.debug.print("R4GB Mooneye DIV read phases:", .{});
            for (div_reads[0..div_read_count]) |phase| std.debug.print(" {x:0>4}", .{phase});
            std.debug.print("\n", .{});
            std.debug.print("R4GB Mooneye serial shift cycles:", .{});
            for (serial_edges[0..serial_edge_count]) |cycle| std.debug.print(" {d}", .{cycle});
            std.debug.print("\n", .{});
            return error.MooneyeMachineFailure;
        }
        const pc = machine.cpu.registers.pc;
        if (pc < 0x4000) last_program_counter = pc;
        if (pc >= 0x4000) machine.ppu.ly = 0xFF;
        const div_read = machine.cartridge.readRom(pc) == 0xF0 and machine.cartridge.readRom(pc +% 1) == 0x04;
        const old_serial_bits = machine.serial.bits_remaining;
        const execution = machine.stepCpu();
        if (div_read and div_read_count < div_reads.len) {
            div_reads[div_read_count] = machine.timer.divider_counter -% 4;
            div_read_count += 1;
        }
        if (machine.serial.bits_remaining != old_serial_bits and serial_edge_count < serial_edges.len) {
            serial_edges[serial_edge_count] = machine.guest_t_cycles;
            serial_edge_count += 1;
        }
        if (execution.kind == .illegal) return error.MooneyeMachineIllegalOpcode;
    }
    return error.MooneyeMachineTimeout;
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
