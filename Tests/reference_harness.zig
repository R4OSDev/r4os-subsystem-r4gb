const std = @import("std");
const core = @import("core");

const max_manifest_bytes: usize = 64 * 1024;
const max_vector_bytes: usize = 4 * 1024 * 1024;
// readFileAlloc's limited mode reserves one byte to detect overflow, so this
// harness ceiling sits above the largest legal 8 MiB Game Boy image.
const max_rom_bytes: usize = 16 * 1024 * 1024;

const SuiteKind = enum { sm83_json, rom_tree, rom_file };

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
        const validation = try core.test_vectors.validateJson(allocator, bytes);
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

fn scanRomFile(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) !Summary {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
    defer allocator.free(bytes);
    try validateRomIdentity(bytes);
    var result = Summary{ .files = 1 };
    mixDigest(&result.digest, std.fs.path.basename(path), bytes);
    return result;
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
