const std = @import("std");
const r4os = @import("r4os");
const persistence = @import("persistence.zig");

const PathRole = enum { sram, rtc, lock, atomic_lock, sram_stage, rtc_stage, sram_backup, rtc_backup };

pub const Store = struct {
    files: r4os.app_storage.Files,
    lock_writer: ?r4os.app_storage.OwnedStageWriter = null,
    lock_generation: u64 = 0,
    lock_digest: [persistence.digest_bytes]u8 = .{0} ** persistence.digest_bytes,

    pub fn init(files: r4os.app_storage.Files) Store {
        return .{ .files = files };
    }

    pub fn backend(self: *Store) persistence.Backend {
        return .{
            .context = self,
            .acquire_fn = acquire,
            .release_fn = release,
            .read_exact_fn = readExact,
            .write_atomic_fn = writeAtomic,
        };
    }

    pub fn removeTestFiles(self: *Store, digest: *const [persistence.digest_bytes]u8) void {
        // The self-test may start from an image where APPDATA does not exist
        // yet. Avoid issuing delete operations through a missing parent chain;
        // production Session.open creates the same hierarchy before acquiring
        // its lease.
        ensureSaveRoot(&self.files) catch return;
        for ([_]PathRole{
            PathRole.sram,
            PathRole.rtc,
            PathRole.lock,
            PathRole.atomic_lock,
            PathRole.sram_stage,
            PathRole.rtc_stage,
            PathRole.sram_backup,
            PathRole.rtc_backup,
        }) |role| {
            const path = makePath(digest, role) catch continue;
            _ = self.files.delete(path.asZ());
        }
    }

    fn acquire(context: *anyopaque, digest: *const [persistence.digest_bytes]u8, generation: u64) persistence.BackendError!void {
        const self: *Store = @ptrCast(@alignCast(context));
        if (self.lock_writer != null) return error.Busy;
        try ensureSaveRoot(&self.files);
        const path = makePath(digest, .lock) catch return error.Io;
        var writer = switch (self.files.ownedCreateWriter(path.asZ())) {
            .writer => |value| value,
            .failure => |fault| return mapOpenFault(fault),
        };
        var keep = false;
        defer if (!keep) {
            _ = writer.abort();
        };
        var body: [96]u8 = undefined;
        const lock_body = std.fmt.bufPrint(body[0..], "R4GB_SAVE_LOCK=1\nGENERATION={d}\n", .{generation}) catch return error.Io;
        switch (writer.write(lock_body)) {
            .ok => {},
            else => return error.Io,
        }
        switch (writer.finishKeepOwnership()) {
            .ok => {},
            else => return error.Io,
        }
        keep = true;
        self.lock_writer = writer;
        self.lock_generation = generation;
        self.lock_digest = digest.*;
    }

    fn release(context: *anyopaque, digest: *const [persistence.digest_bytes]u8, generation: u64) persistence.BackendError!void {
        const self: *Store = @ptrCast(@alignCast(context));
        if (self.lock_writer == null) return;
        if (self.lock_generation != generation or !std.mem.eql(u8, self.lock_digest[0..], digest[0..])) return error.Io;
        var writer = self.lock_writer.?;
        self.lock_writer = null;
        self.lock_generation = 0;
        switch (writer.abort()) {
            .ok => {},
            .failure => |fault| if (fault != r4os.abi.file_stream_error_not_found) return error.Io,
            .missing => {},
        }
    }

    fn readExact(
        context: *anyopaque,
        digest: *const [persistence.digest_bytes]u8,
        kind: persistence.FileKind,
        out: []u8,
    ) persistence.ReadResult {
        const self: *Store = @ptrCast(@alignCast(context));
        const path = makePath(digest, if (kind == .sram) .sram else .rtc) catch return .io;
        const info = switch (self.files.info(path.asZ())) {
            .value => |value| value,
            .missing => return .missing,
            .failure => return .io,
        };
        if (info.is_dir != 0 or info.size != out.len) return .wrong_size;
        var offset: usize = 0;
        while (offset < out.len) {
            const transferred = switch (self.files.readAt(path.asZ(), @intCast(offset), out[offset..])) {
                .bytes => |count| count,
                .end, .failure => return .io,
            };
            if (transferred == 0 or transferred > out.len - offset) return .io;
            offset += transferred;
        }
        return .ok;
    }

    fn writeAtomic(
        context: *anyopaque,
        digest: *const [persistence.digest_bytes]u8,
        kind: persistence.FileKind,
        bytes: []const u8,
    ) persistence.BackendError!void {
        const self: *Store = @ptrCast(@alignCast(context));
        if (self.lock_writer == null or !std.mem.eql(u8, self.lock_digest[0..], digest[0..])) return error.Busy;
        const transaction = makePath(digest, .atomic_lock) catch return error.Io;
        const target = makePath(digest, if (kind == .sram) .sram else .rtc) catch return error.Io;
        const stage = makePath(digest, if (kind == .sram) .sram_stage else .rtc_stage) catch return error.Io;
        const backup = makePath(digest, if (kind == .sram) .sram_backup else .rtc_backup) catch return error.Io;
        var transaction_writer = switch (self.files.ownedCreateWriter(transaction.asZ())) {
            .writer => |value| value,
            .failure => |fault| return mapOpenFault(fault),
        };
        defer _ = transaction_writer.abort();
        switch (transaction_writer.finishKeepOwnership()) {
            .ok => {},
            .failure => |fault| return mapOpenFault(fault),
            .missing => return error.Io,
        }
        var writer = switch (self.files.streamWriter(stage.asZ(), r4os.abi.file_stream_open_replace)) {
            .writer => |value| value,
            .failure => |fault| return mapOpenFault(fault),
        };
        var finished = false;
        defer if (!finished) {
            _ = writer.abort();
        };
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + 16 * 1024, bytes.len);
            switch (writer.write(bytes[offset..end])) {
                .ok => {},
                .failure => |fault| return mapOpenFault(fault),
                .missing => return error.Io,
            }
            offset = end;
        }
        switch (writer.finish()) {
            .ok => finished = true,
            .failure => |fault| return mapOpenFault(fault),
            .missing => return error.Io,
        }
        switch (self.files.replaceAtomic(target.asZ(), stage.asZ(), backup.asZ(), .{})) {
            .ok => {},
            .unsupported => return error.Unsupported,
            else => return error.Io,
        }
    }
};

fn ensureSaveRoot(files: *const r4os.app_storage.Files) persistence.BackendError!void {
    const directories = [_][]const u8{
        "C:\\R4OS\\APPDATA",
        "C:\\R4OS\\APPDATA\\SUBSYSTEMS",
        "C:\\R4OS\\APPDATA\\SUBSYSTEMS\\r4os.gb",
        "C:\\R4OS\\APPDATA\\SUBSYSTEMS\\r4os.gb\\SAVE",
    };
    for (directories) |raw| {
        const path = r4os.AbsoluteFilePath.parse(raw) catch return error.Io;
        switch (files.createDirectory(path.asZ())) {
            .ok, .missing => {},
            .failure => return error.Io,
        }
    }
}

fn makePath(digest: *const [persistence.digest_bytes]u8, role: PathRole) !r4os.AbsoluteFilePath {
    if (role == .atomic_lock or role == .sram_stage or role == .rtc_stage or role == .sram_backup or role == .rtc_backup) {
        var token: [10]u8 = undefined;
        makeAtomicToken(digest, &token);
        const discriminator: u8 = switch (role) {
            .atomic_lock => 'L',
            .sram_stage => 'N',
            .sram_backup => 'B',
            .rtc_stage => 'T',
            .rtc_backup => 'R',
            else => unreachable,
        };
        var short_raw: [160]u8 = undefined;
        const rendered = try std.fmt.bufPrint(short_raw[0..], "{s}{s}.{c}{s}", .{
            persistence.save_root,
            token[0..8],
            discriminator,
            token[8..10],
        });
        return r4os.AbsoluteFilePath.parse(rendered);
    }

    var digest_text: [persistence.digest_hex_bytes]u8 = undefined;
    const hash = persistence.digestHex(digest, &digest_text);
    const suffix = switch (role) {
        .sram => ".SAV",
        .rtc => ".RTC",
        .lock => ".LCK",
        .atomic_lock => unreachable,
        .sram_stage => ".SAV.NEW",
        .rtc_stage => ".RTC.NEW",
        .sram_backup => ".SAV.BAK",
        .rtc_backup => ".RTC.BAK",
    };
    var raw: [192]u8 = undefined;
    const rendered = try std.fmt.bufPrint(raw[0..], "{s}{s}{s}", .{ persistence.save_root, hash, suffix });
    return r4os.AbsoluteFilePath.parse(rendered);
}

/// R4SYS's no-fallback atomic primitive deliberately requires private stage
/// and backup basenames to fit 8.3. Ten Base32 digits retain 50 digest bits;
/// the role discriminator makes transaction names distinct. A retained
/// create-only `.Lxx` lease serializes the compressed namespace, so even a
/// rare 50-bit collision fails closed before either stage can be touched.
fn makeAtomicToken(digest: *const [persistence.digest_bytes]u8, out: *[10]u8) void {
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUV";
    var accumulator: u64 = 0;
    for (digest[0..7]) |byte| accumulator = (accumulator << 8) | byte;
    accumulator >>= 6;
    for (0..out.len) |index| {
        const shift: u6 = @intCast((out.len - index - 1) * 5);
        out[index] = alphabet[@as(usize, @intCast((accumulator >> shift) & 0x1F))];
    }
}

fn mapOpenFault(fault: i32) persistence.BackendError {
    return switch (fault) {
        r4os.abi.file_stream_error_exists => error.Busy,
        r4os.abi.file_stream_error_unsupported => error.Unsupported,
        r4os.abi.file_stream_error_too_large => error.Full,
        else => error.Io,
    };
}

pub fn wallSeconds(state: r4os.abi.TimeState) ?i64 {
    if (state.valid == 0 or state.month < 1 or state.month > 12 or state.hour > 23 or state.minute > 59 or state.second > 60) return null;
    const month_days = [_]u8{ 31, if (isLeap(state.year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (state.day < 1 or state.day > month_days[state.month - 1]) return null;
    const year: i64 = state.year;
    const month: i64 = state.month;
    const day: i64 = state.day;
    const adjusted_year = year - @intFromBool(month <= 2);
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const adjusted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    const days = era * 146097 + day_of_era - 719468;
    return days * 86400 + @as(i64, state.hour) * 3600 + @as(i64, state.minute) * 60 + state.second;
}

fn isLeap(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}
