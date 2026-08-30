const std = @import("std");
const core = @import("core");

const max_manifest_bytes: usize = 64 * 1024;
const max_vector_bytes: usize = 4 * 1024 * 1024;
// readFileAlloc's limited mode reserves one byte to detect overflow, so this
// harness ceiling sits above the largest legal 8 MiB Game Boy image.
const max_rom_bytes: usize = 16 * 1024 * 1024;

const SuiteKind = enum { sm83_json, rom_tree, rom_file, cartridge_tree, cpu_rom_file, machine_rom_manifest, ppu_screenshot_manifest };

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
    const suite_filter: ?[]const u8 = if (args.len >= 3 and args[2].len != 0) args[2] else null;
    const case_filter: ?[]const u8 = if (args.len >= 4) args[3] else null;
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
            .machine_rom_manifest => try scanMachineRomManifest(allocator, io, cwd, suite_path, suite.selection orelse return error.MissingSelectionManifest, case_filter),
            .ppu_screenshot_manifest => try scanPpuScreenshotManifest(allocator, io, cwd, suite_path, suite.selection orelse return error.MissingSelectionManifest, case_filter),
        };
        const expected_files = if (case_filter == null) suite.expected_files else 1;
        const expected_records = if (case_filter == null) suite.expected_records else 1;
        if (summary.files != expected_files or summary.records != expected_records) {
            std.debug.print(
                "R4GB reference suite mismatch: {s} files={d}/{d} records={d}/{d}\n",
                .{ suite.id, summary.files, expected_files, summary.records, expected_records },
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
    case_filter: ?[]const u8,
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
        if (case_filter) |filter| {
            if (!std.mem.eql(u8, filter, entry.path)) continue;
        }
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
    if (case_filter != null and result.files == 0) return error.ReferenceCaseNotFound;
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
    // A live PPU now carries Mooneye's reporting library through its two
    // VBlanks; result registers are observed at the suite's LD B,B breakpoint.
    const instruction_budget: usize = 5_000_000;
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
                "R4GB Mooneye failure state: pc={x:0>4} last-main-pc={x:0>4} sp={x:0>4} a={x:0>2} f={x:0>2} cycles={d} div={x:0>4} if={x:0>2} ie={x:0>2} ppu-line={d} ppu-ly={d} ppu-dot={d} ppu-mode={s}\n",
                .{ machine.cpu.registers.pc, last_program_counter, machine.cpu.registers.sp, machine.cpu.registers.a, machine.cpu.registers.f, machine.guest_t_cycles, machine.timer.divider_counter, machine.interrupts.readRequest(), machine.interrupts.enable, machine.ppu.line, machine.ppu.ly, machine.ppu.dot, @tagName(machine.ppu.mode()) },
            );
            std.debug.print(
                "R4GB Mooneye saved: f={x:0>2} a={x:0>2} c={x:0>2} b={x:0>2} e={x:0>2} d={x:0>2} l={x:0>2} h={x:0>2} flags={x:0>2}\n",
                .{ machine.bus.high_ram[0], machine.bus.high_ram[1], machine.bus.high_ram[2], machine.bus.high_ram[3], machine.bus.high_ram[4], machine.bus.high_ram[5], machine.bus.high_ram[6], machine.bus.high_ram[7], machine.bus.high_ram[8] },
            );
            std.debug.print("R4GB Mooneye HRAM[00..1f]:", .{});
            for (machine.bus.high_ram[0..32]) |value| std.debug.print(" {x:0>2}", .{value});
            std.debug.print("\n", .{});
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
    std.debug.print(
        "R4GB Mooneye timeout state: pc={x:0>4} sp={x:0>4} a={x:0>2} f={x:0>2} bc={x:0>2}{x:0>2} de={x:0>2}{x:0>2} hl={x:0>2}{x:0>2} cycles={d} if={x:0>2} ie={x:0>2} ppu-line={d} ppu-ly={d} ppu-dot={d} ppu-mode={s}\n",
        .{ machine.cpu.registers.pc, machine.cpu.registers.sp, machine.cpu.registers.a, machine.cpu.registers.f, machine.cpu.registers.b, machine.cpu.registers.c, machine.cpu.registers.d, machine.cpu.registers.e, machine.cpu.registers.h, machine.cpu.registers.l, machine.guest_t_cycles, machine.interrupts.readRequest(), machine.interrupts.enable, machine.ppu.line, machine.ppu.ly, machine.ppu.dot, @tagName(machine.ppu.mode()) },
    );
    return error.MooneyeMachineTimeout;
}

const ScreenshotEntry = struct {
    rom: []const u8,
    reference: []const u8,
    minimum_frames: u16,
};

const ScreenshotSelection = struct {
    schema: u32,
    revision: []const u8,
    entries: []const ScreenshotEntry,
};

fn scanPpuScreenshotManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    root: []const u8,
    selection_path: []const u8,
    case_filter: ?[]const u8,
) !Summary {
    const selection_bytes = try cwd.readFileAlloc(io, selection_path, allocator, .limited(max_manifest_bytes));
    defer allocator.free(selection_bytes);
    var parsed = try std.json.parseFromSlice(ScreenshotSelection, allocator, selection_bytes, .{});
    defer parsed.deinit();
    if (parsed.value.schema != 1) return error.UnsupportedScreenshotSelectionSchema;
    if (!std.mem.eql(u8, parsed.value.revision, "dmg-c")) return error.UnsupportedScreenshotRevision;

    var result = Summary{};
    for (parsed.value.entries) |entry| {
        if (case_filter) |filter| {
            if (!std.mem.eql(u8, filter, entry.rom)) continue;
        }
        const rom_path = try std.fs.path.join(allocator, &.{ root, entry.rom });
        defer allocator.free(rom_path);
        const reference_path = try std.fs.path.join(allocator, &.{ root, entry.reference });
        defer allocator.free(reference_path);
        const rom_bytes = try cwd.readFileAlloc(io, rom_path, allocator, .limited(max_rom_bytes));
        defer allocator.free(rom_bytes);
        const png_bytes = try cwd.readFileAlloc(io, reference_path, allocator, .limited(max_vector_bytes));
        defer allocator.free(png_bytes);
        try validateRomIdentity(rom_bytes);
        const expected = try decodeDmgPng(png_bytes);
        runPpuScreenshotRom(allocator, rom_bytes, &expected, entry.minimum_frames, entry.rom) catch |fault| {
            std.debug.print("R4GB PPU screenshot FAILED: rom={s} reference={s} error={s}\n", .{ entry.rom, entry.reference, @errorName(fault) });
            return fault;
        };
        result.files += 1;
        result.records += 1;
        mixDigest(&result.digest, entry.rom, rom_bytes);
        mixDigest(&result.digest, entry.reference, png_bytes);
    }
    if (case_filter != null and result.files == 0) return error.ReferenceCaseNotFound;
    return result;
}

fn runPpuScreenshotRom(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: *const [core.ppu.frame_pixels]u8,
    minimum_frames: u16,
    name: []const u8,
) !void {
    var machine = core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(allocator, bytes));
    defer machine.deinit();
    const instruction_budget: usize = 5_000_000;
    var instructions: usize = 0;
    while (instructions < instruction_budget) : (instructions += 1) {
        const pc = machine.cpu.registers.pc;
        if (machine.ppu.frames_completed >= minimum_frames and pc < 0x8000 and machine.cartridge.readRom(pc) == 0x40) {
            var differences: usize = 0;
            var first_difference: ?usize = null;
            for (machine.ppu.framebuffer, expected.*, 0..) |actual, wanted, index| {
                if (actual == wanted) continue;
                differences += 1;
                if (first_difference == null) first_difference = index;
            }
            if (first_difference) |index| {
                std.debug.print(
                    "R4GB pixel mismatch: rom={s} frame={d} different={d}/{d} first=({d},{d}) actual={d} expected={d}\n",
                    .{ name, machine.ppu.frames_completed, differences, core.ppu.frame_pixels, index % core.ppu.width, index / core.ppu.width, machine.ppu.framebuffer[index], expected[index] },
                );
                var reported: usize = 0;
                for (machine.ppu.framebuffer, expected.*, 0..) |actual, wanted, mismatch_index| {
                    if (actual == wanted) continue;
                    std.debug.print(" ({d},{d}:{d}>{d})", .{ mismatch_index % core.ppu.width, mismatch_index / core.ppu.width, actual, wanted });
                    reported += 1;
                    if (reported == 16) break;
                }
                std.debug.print("\n", .{});
                const first_y = index / core.ppu.width;
                printPixelRuns("actual", first_y, machine.ppu.framebuffer[first_y * core.ppu.width ..][0..core.ppu.width]);
                printPixelRuns("expected", first_y, expected[first_y * core.ppu.width ..][0..core.ppu.width]);
                printDifferenceRows(&machine.ppu.framebuffer, expected);
                return error.PpuScreenshotMismatch;
            }
            return;
        }
        const execution = machine.stepCpu();
        if (execution.kind == .illegal) return error.PpuScreenshotIllegalOpcode;
    }
    std.debug.print(
        "R4GB screenshot timeout: rom={s} pc={x:0>4} frame={d} line={d} dot={d}\n",
        .{ name, machine.cpu.registers.pc, machine.ppu.frames_completed, machine.ppu.line, machine.ppu.dot },
    );
    return error.PpuScreenshotTimeout;
}

fn printDifferenceRows(actual: *const [core.ppu.frame_pixels]u8, expected: *const [core.ppu.frame_pixels]u8) void {
    var reported: usize = 0;
    for (0..core.ppu.height) |y| {
        var count: usize = 0;
        var first: usize = core.ppu.width;
        var last: usize = 0;
        for (0..core.ppu.width) |x| {
            const index = y * core.ppu.width + x;
            if (actual[index] == expected[index]) continue;
            count += 1;
            first = @min(first, x);
            last = x;
        }
        if (count == 0) continue;
        if (reported < 16) std.debug.print("R4GB row difference: y={d} count={d} span={d}..{d}\n", .{ y, count, first, last });
        reported += 1;
    }
}

fn printPixelRuns(label: []const u8, y: usize, pixels: []const u8) void {
    std.debug.print("R4GB row {d:0>3} {s}:", .{ y, label });
    var start: usize = 0;
    while (start < pixels.len) {
        var end = start + 1;
        while (end < pixels.len and pixels[end] == pixels[start]) end += 1;
        std.debug.print(" {d}x{d}", .{ pixels[start], end - start });
        start = end;
    }
    std.debug.print("\n", .{});
}

fn decodeDmgPng(bytes: []const u8) ![core.ppu.frame_pixels]u8 {
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature)) return error.InvalidPngSignature;

    var bit_depth: u8 = 0;
    var idat: ?[]const u8 = null;
    var cursor: usize = signature.len;
    while (cursor + 12 <= bytes.len) {
        const length = std.mem.readInt(u32, bytes[cursor..][0..4], .big);
        const payload_start = cursor + 8;
        const payload_end = payload_start + @as(usize, length);
        if (payload_end + 4 > bytes.len) return error.TruncatedPngChunk;
        const chunk_type = bytes[cursor + 4 .. cursor + 8];
        const payload = bytes[payload_start..payload_end];
        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (payload.len != 13 or std.mem.readInt(u32, payload[0..4], .big) != core.ppu.width or
                std.mem.readInt(u32, payload[4..8], .big) != core.ppu.height)
            {
                return error.UnsupportedPngDimensions;
            }
            bit_depth = payload[8];
            if ((bit_depth != 1 and bit_depth != 2 and bit_depth != 8) or payload[9] != 0 or
                payload[10] != 0 or payload[11] != 0 or payload[12] != 0)
            {
                return error.UnsupportedPngFormat;
            }
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (idat != null) return error.MultiplePngDataChunks;
            idat = payload;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
        cursor = payload_end + 4;
    }
    if (bit_depth == 0) return error.MissingPngHeader;
    const compressed = idat orelse return error.MissingPngData;
    const row_bytes = (core.ppu.width * @as(usize, bit_depth) + 7) / 8;
    const raw_len = (row_bytes + 1) * core.ppu.height;
    var raw: [core.ppu.height * (core.ppu.width + 1)]u8 = undefined;
    var compressed_reader: std.Io.Reader = .fixed(compressed);
    var decompressor: std.compress.flate.Decompress = .init(&compressed_reader, .zlib, &.{});
    var raw_writer: std.Io.Writer = .fixed(raw[0..raw_len]);
    const written = try decompressor.reader.streamRemaining(&raw_writer);
    if (written != raw_len) return error.InvalidPngDataLength;

    var expected: [core.ppu.frame_pixels]u8 = undefined;
    var previous: [core.ppu.width]u8 = .{0} ** core.ppu.width;
    var current: [core.ppu.width]u8 = undefined;
    var raw_offset: usize = 0;
    var y: usize = 0;
    while (y < core.ppu.height) : (y += 1) {
        const filter = raw[raw_offset];
        raw_offset += 1;
        var byte_index: usize = 0;
        while (byte_index < row_bytes) : (byte_index += 1) {
            const encoded = raw[raw_offset + byte_index];
            const left: u8 = if (byte_index == 0) 0 else current[byte_index - 1];
            const above = previous[byte_index];
            const upper_left: u8 = if (byte_index == 0) 0 else previous[byte_index - 1];
            current[byte_index] = switch (filter) {
                0 => encoded,
                1 => encoded +% left,
                2 => encoded +% above,
                3 => encoded +% @as(u8, @intCast((@as(u16, left) + above) / 2)),
                4 => encoded +% paeth(left, above, upper_left),
                else => return error.UnsupportedPngFilter,
            };
        }
        raw_offset += row_bytes;
        var x: usize = 0;
        while (x < core.ppu.width) : (x += 1) {
            const bit_offset = x * bit_depth;
            const shift: u3 = @intCast(8 - bit_depth - bit_offset % 8);
            const mask: u8 = if (bit_depth == 8) 0xFF else (@as(u8, 1) << @intCast(bit_depth)) - 1;
            const sample = (current[bit_offset / 8] >> shift) & mask;
            const grayscale: u16 = @as(u16, sample) * 255 / mask;
            if (grayscale % 85 != 0) return error.NonDmgGrayscaleLevel;
            expected[y * core.ppu.width + x] = @intCast((255 - grayscale) / 85);
        }
        previous = current;
    }
    return expected;
}

fn paeth(left: u8, above: u8, upper_left: u8) u8 {
    const a: i16 = left;
    const b: i16 = above;
    const c: i16 = upper_left;
    const prediction = a + b - c;
    const distance_a = @abs(prediction - a);
    const distance_b = @abs(prediction - b);
    const distance_c = @abs(prediction - c);
    return if (distance_a <= distance_b and distance_a <= distance_c)
        left
    else if (distance_b <= distance_c)
        above
    else
        upper_left;
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
