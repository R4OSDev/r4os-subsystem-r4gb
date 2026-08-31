const std = @import("std");
const r4os = @import("r4os");
const persistence = @import("persistence.zig");

const PathRole = enum { sram, rtc, lock, atomic_lock, sram_stage, rtc_stage, sram_backup, rtc_backup };
const create_retry_attempts: usize = 8;
const create_retry_delay_ms: u64 = 25;

pub const FailureStage = enum {
    none,
    async_unavailable,
    async_allocate,
    async_start,
    async_join,
    save_root,
    lock_begin,
    lock_write,
    lock_finish,
    lock_abort,
    atomic_cleanup,
    atomic_begin,
    atomic_stage,
    atomic_publish,
    sram_info,
    sram_read,
    rtc_info,
    rtc_read,
};

pub const Store = struct {
    files: r4os.app_storage.Files,
    lock_writer: ?r4os.app_storage.OwnedStageWriter = null,
    lock_generation: u64 = 0,
    lock_digest: [persistence.digest_bytes]u8 = .{0} ** persistence.digest_bytes,
    failure_stage: FailureStage = .none,
    failure_code: i32 = 0,

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

    pub fn failureStageName(self: *const Store) []const u8 {
        return @tagName(self.failure_stage);
    }

    pub fn failureCode(self: *const Store) i32 {
        return self.failure_code;
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
        self.failure_stage = .none;
        self.failure_code = 0;
        ensureSaveRoot(&self.files) catch |fault| {
            self.recordFailure(.save_root, 0);
            return fault;
        };
        const path = makePath(digest, .lock) catch return error.Io;
        for (0..create_retry_attempts) |attempt| {
            const writer = createOwnedLock(self, &path, generation) catch |fault| {
                if (fault != error.Io or self.failure_stage == .lock_abort or attempt + 1 == create_retry_attempts) return fault;
                waitForCreateRetry(&self.files);
                continue;
            };
            self.lock_writer = writer;
            self.lock_generation = generation;
            self.lock_digest = digest.*;
            self.failure_stage = .none;
            self.failure_code = 0;
            return;
        }
        unreachable;
    }

    fn release(context: *anyopaque, digest: *const [persistence.digest_bytes]u8, generation: u64) persistence.BackendError!void {
        const self: *Store = @ptrCast(@alignCast(context));
        if (self.lock_writer == null) return;
        if (self.lock_generation != generation or !std.mem.eql(u8, self.lock_digest[0..], digest[0..])) return error.Io;
        const path = makePath(digest, .lock) catch return error.Io;
        if (!abortOwnedPathWithRetry(self, &path)) return error.Io;
        self.lock_writer = null;
        self.lock_generation = 0;
    }

    fn readExact(
        context: *anyopaque,
        digest: *const [persistence.digest_bytes]u8,
        kind: persistence.FileKind,
        out: []u8,
    ) persistence.ReadResult {
        const self: *Store = @ptrCast(@alignCast(context));
        const path = makePath(digest, if (kind == .sram) .sram else .rtc) catch return .io;
        const info = info_retry: {
            for (0..create_retry_attempts) |attempt| {
                switch (self.files.info(path.asZ())) {
                    .value => |value| break :info_retry value,
                    .missing => return .missing,
                    .failure => |fault| {
                        if (attempt + 1 == create_retry_attempts) {
                            self.recordFailure(if (kind == .sram) .sram_info else .rtc_info, fault);
                            return .io;
                        }
                        waitForCreateRetry(&self.files);
                    },
                }
            }
            unreachable;
        };
        if (info.is_dir != 0 or info.size != out.len) return .wrong_size;
        var offset: usize = 0;
        while (offset < out.len) {
            const transferred = switch (self.files.readAt(path.asZ(), @intCast(offset), out[offset..])) {
                .bytes => |count| count,
                .end => return .io,
                .failure => |fault| {
                    self.recordFailure(if (kind == .sram) .sram_read else .rtc_read, fault);
                    return .io;
                },
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
        // The fixed 8.3 scratch names are reused by every periodic flush.
        // Once the cartridge lease is held, leftovers from a completed or
        // interrupted prior replace belong exclusively to this digest and
        // must be retired before opening the next transaction.
        try removeAtomicScratch(self, &transaction);
        try removeAtomicScratch(self, &stage);
        try removeAtomicScratch(self, &backup);
        var transaction_writer = switch (self.files.ownedCreateWriter(transaction.asZ())) {
            .writer => |value| value,
            .failure => |fault| {
                self.recordFailure(.atomic_begin, fault);
                return mapOpenFault(fault);
            },
        };
        defer _ = transaction_writer.abort();
        switch (transaction_writer.finishKeepOwnership()) {
            .ok => {},
            .failure => |fault| {
                self.recordFailure(.atomic_begin, fault);
                return mapOpenFault(fault);
            },
            .missing => {
                self.recordFailure(.atomic_begin, 0);
                return error.Io;
            },
        }
        var writer = switch (self.files.streamWriter(stage.asZ(), r4os.abi.file_stream_open_replace)) {
            .writer => |value| value,
            .failure => |fault| {
                self.recordFailure(.atomic_stage, fault);
                return mapOpenFault(fault);
            },
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
                .failure => |fault| {
                    self.recordFailure(.atomic_stage, fault);
                    return mapOpenFault(fault);
                },
                .missing => {
                    self.recordFailure(.atomic_stage, 0);
                    return error.Io;
                },
            }
            offset = end;
        }
        switch (writer.finish()) {
            .ok => finished = true,
            .failure => |fault| {
                self.recordFailure(.atomic_stage, fault);
                return mapOpenFault(fault);
            },
            .missing => {
                self.recordFailure(.atomic_stage, 0);
                return error.Io;
            },
        }
        switch (self.files.replaceAtomic(target.asZ(), stage.asZ(), backup.asZ(), .{})) {
            .ok => {},
            .unsupported => {
                self.recordFailure(.atomic_publish, r4os.r4sys.file_replace_atomic_error_unsupported);
                return error.Unsupported;
            },
            .failure => |fault| {
                self.recordFailure(.atomic_publish, fault);
                return error.Io;
            },
            else => {
                self.recordFailure(.atomic_publish, 0);
                return error.Io;
            },
        }
        try removeAtomicScratch(self, &backup);
        self.failure_stage = .none;
        self.failure_code = 0;
    }

    fn recordFailure(self: *Store, stage: FailureStage, code: i32) void {
        self.failure_stage = stage;
        self.failure_code = code;
    }
};

const async_write_stack: u64 = 128 * 1024;

const AsyncWriteResult = enum {
    pending,
    ok,
    busy,
    io,
    full,
    unsupported,
};

const AsyncWriteJob = struct {
    store: *Store,
    digest: [persistence.digest_bytes]u8,
    kind: persistence.FileKind,
    bytes: []u8,
    sequence: u64,
    result: AsyncWriteResult = .pending,
};

const ActiveWrite = struct {
    job: *AsyncWriteJob,
    handle: r4os.abi.ProgramJoinHandle,
};

pub const AsyncStats = struct {
    enqueued: u64 = 0,
    started: u64 = 0,
    completed: u64 = 0,
    coalesced: u64 = 0,
    errors: u64 = 0,
    maximum_queued: u8 = 0,
};

/// Product persistence wrapper. The emulation thread only copies an immutable
/// SRAM/RTC snapshot; a joinable app thread performs the slow atomic namespace
/// transaction. One worker serializes both file kinds so Store and its writer
/// lease never need cross-thread locking. New snapshots are coalesced per kind,
/// while close drains every accepted write before releasing the cartridge.
pub const AsyncStore = struct {
    allocator: std.mem.Allocator,
    store: Store,
    active: ?ActiveWrite = null,
    pending: [2]?*AsyncWriteJob = .{ null, null },
    next_sequence: u64 = 1,
    latched_failure: ?persistence.BackendError = null,
    stats: AsyncStats = .{},

    pub fn init(files: r4os.app_storage.Files, allocator: std.mem.Allocator) AsyncStore {
        return .{ .allocator = allocator, .store = Store.init(files) };
    }

    pub fn backend(self: *AsyncStore) persistence.Backend {
        return .{
            .context = self,
            .acquire_fn = acquire,
            .release_fn = release,
            .read_exact_fn = readExact,
            .write_atomic_fn = writeAtomic,
            .poll_fn = poll,
        };
    }

    pub fn failureStageName(self: *const AsyncStore) []const u8 {
        return self.store.failureStageName();
    }

    pub fn failureCode(self: *const AsyncStore) i32 {
        return self.store.failureCode();
    }

    pub fn removeTestFiles(self: *AsyncStore, digest: *const [persistence.digest_bytes]u8) void {
        self.store.removeTestFiles(digest);
    }

    fn acquire(context: *anyopaque, digest: *const [persistence.digest_bytes]u8, generation: u64) persistence.BackendError!void {
        const self: *AsyncStore = @ptrCast(@alignCast(context));
        if (self.active != null or self.pendingCount() != 0) return error.Busy;
        if (!self.store.files.sys.hasFn("thread_create_handle") or !self.store.files.sys.hasFn("thread_handle_join")) {
            self.store.recordFailure(.async_unavailable, r4os.abi.thread_error_unsupported);
            return error.Unsupported;
        }
        self.latched_failure = null;
        try self.store.backend().acquire(digest, generation);
    }

    fn release(context: *anyopaque, digest: *const [persistence.digest_bytes]u8, generation: u64) persistence.BackendError!void {
        const self: *AsyncStore = @ptrCast(@alignCast(context));
        var write_fault: ?persistence.BackendError = null;
        self.drain() catch |fault| {
            write_fault = fault;
        };
        var release_fault: ?persistence.BackendError = null;
        self.store.backend().release(digest, generation) catch |fault| {
            release_fault = fault;
        };
        self.clearPending();
        if (write_fault) |fault| return fault;
        if (self.latched_failure) |fault| return fault;
        if (release_fault) |fault| return fault;
    }

    fn readExact(
        context: *anyopaque,
        digest: *const [persistence.digest_bytes]u8,
        kind: persistence.FileKind,
        out: []u8,
    ) persistence.ReadResult {
        const self: *AsyncStore = @ptrCast(@alignCast(context));
        if (self.active != null or self.pendingCount() != 0) return .io;
        return self.store.backend().readExact(digest, kind, out);
    }

    fn writeAtomic(
        context: *anyopaque,
        digest: *const [persistence.digest_bytes]u8,
        kind: persistence.FileKind,
        bytes: []const u8,
    ) persistence.BackendError!void {
        const self: *AsyncStore = @ptrCast(@alignCast(context));
        try self.pollOne(0);
        if (self.latched_failure) |fault| return fault;
        if (self.store.lock_writer == null or !std.mem.eql(u8, self.store.lock_digest[0..], digest[0..])) return error.Busy;

        const job = try self.createJob(digest, kind, bytes);
        self.stats.enqueued +%= 1;
        if (self.active == null) {
            self.startJob(job) catch |fault| {
                self.destroyJob(job);
                return fault;
            };
        } else {
            const index = kindIndex(kind);
            if (self.pending[index]) |older| {
                self.destroyJob(older);
                self.stats.coalesced +%= 1;
            }
            self.pending[index] = job;
        }
        self.recordMaximumQueued();
    }

    fn poll(context: *anyopaque) persistence.BackendError!void {
        const self: *AsyncStore = @ptrCast(@alignCast(context));
        try self.pollOne(0);
    }

    fn createJob(
        self: *AsyncStore,
        digest: *const [persistence.digest_bytes]u8,
        kind: persistence.FileKind,
        bytes: []const u8,
    ) persistence.BackendError!*AsyncWriteJob {
        const snapshot = self.allocator.dupe(u8, bytes) catch {
            self.store.recordFailure(.async_allocate, r4os.abi.thread_error_no_memory);
            return error.Full;
        };
        errdefer self.allocator.free(snapshot);
        const job = self.allocator.create(AsyncWriteJob) catch {
            self.store.recordFailure(.async_allocate, r4os.abi.thread_error_no_memory);
            return error.Full;
        };
        job.* = .{
            .store = &self.store,
            .digest = digest.*,
            .kind = kind,
            .bytes = snapshot,
            .sequence = self.next_sequence,
        };
        self.next_sequence +%= 1;
        if (self.next_sequence == 0) self.next_sequence = 1;
        return job;
    }

    fn startJob(self: *AsyncStore, job: *AsyncWriteJob) persistence.BackendError!void {
        std.debug.assert(self.active == null);
        var handle: r4os.abi.ProgramJoinHandle = .{};
        const rc = self.store.files.sys.threadCreateHandle(asyncWriteWorker, @intFromPtr(job), async_write_stack, 0, &handle);
        if (rc != r4os.abi.thread_ok) {
            self.store.recordFailure(.async_start, rc);
            return mapThreadFault(rc);
        }
        self.active = .{ .job = job, .handle = handle };
        self.stats.started +%= 1;
    }

    fn pollOne(self: *AsyncStore, timeout_ticks: u64) persistence.BackendError!void {
        if (self.latched_failure) |fault| return fault;
        if (self.active) |active| {
            var exit_code: i32 = 0;
            const rc = self.store.files.sys.threadHandleJoin(&active.handle, timeout_ticks, &exit_code);
            if (rc == r4os.abi.thread_error_timeout) return;
            self.active = null;
            self.stats.completed +%= 1;
            const job = active.job;
            const result = if (rc == r4os.abi.thread_ok and exit_code == 0) job.result else AsyncWriteResult.io;
            if (rc != r4os.abi.thread_ok or exit_code != 0) self.store.recordFailure(.async_join, if (rc != r4os.abi.thread_ok) rc else exit_code);
            self.destroyJob(job);
            if (asyncResultFault(result)) |fault| {
                self.stats.errors +%= 1;
                self.latched_failure = fault;
                self.clearPending();
                return fault;
            }
        }

        if (self.active == null) if (self.takeOldestPending()) |job| {
            self.startJob(job) catch |fault| {
                self.destroyJob(job);
                self.stats.errors +%= 1;
                self.latched_failure = fault;
                self.clearPending();
                return fault;
            };
        };
        if (self.latched_failure) |fault| return fault;
    }

    fn drain(self: *AsyncStore) persistence.BackendError!void {
        while (self.active != null or self.pendingCount() != 0) {
            if (self.active == null) {
                const job = self.takeOldestPending() orelse break;
                self.startJob(job) catch |fault| {
                    self.destroyJob(job);
                    self.stats.errors +%= 1;
                    self.latched_failure = fault;
                    self.clearPending();
                    return fault;
                };
            }
            try self.pollOne(r4os.abi.thread_wait_forever);
        }
        if (self.latched_failure) |fault| return fault;
    }

    fn takeOldestPending(self: *AsyncStore) ?*AsyncWriteJob {
        var selected: ?usize = null;
        for (self.pending, 0..) |candidate, index| {
            if (candidate == null) continue;
            if (selected == null or candidate.?.sequence < self.pending[selected.?].?.sequence) selected = index;
        }
        const index = selected orelse return null;
        const job = self.pending[index].?;
        self.pending[index] = null;
        return job;
    }

    fn clearPending(self: *AsyncStore) void {
        for (&self.pending) |*candidate| {
            if (candidate.*) |job| self.destroyJob(job);
            candidate.* = null;
        }
    }

    fn pendingCount(self: *const AsyncStore) u8 {
        var count: u8 = 0;
        for (self.pending) |candidate| count += @intFromBool(candidate != null);
        return count;
    }

    fn recordMaximumQueued(self: *AsyncStore) void {
        const queued = self.pendingCount() + @as(u8, @intFromBool(self.active != null));
        self.stats.maximum_queued = @max(self.stats.maximum_queued, queued);
    }

    fn destroyJob(self: *AsyncStore, job: *AsyncWriteJob) void {
        self.allocator.free(job.bytes);
        self.allocator.destroy(job);
    }
};

fn asyncWriteWorker(arg: u64) callconv(.c) i32 {
    const job: *AsyncWriteJob = @ptrFromInt(arg);
    job.store.backend().writeAtomic(&job.digest, job.kind, job.bytes) catch |fault| {
        job.result = asyncResultForFault(fault);
        return 0;
    };
    job.result = .ok;
    return 0;
}

fn kindIndex(kind: persistence.FileKind) usize {
    return switch (kind) {
        .sram => 0,
        .rtc => 1,
    };
}

fn asyncResultForFault(fault: persistence.BackendError) AsyncWriteResult {
    return switch (fault) {
        error.Busy => .busy,
        error.Io => .io,
        error.Full => .full,
        error.Unsupported => .unsupported,
    };
}

fn asyncResultFault(result: AsyncWriteResult) ?persistence.BackendError {
    return switch (result) {
        .pending, .io => error.Io,
        .busy => error.Busy,
        .full => error.Full,
        .unsupported => error.Unsupported,
        .ok => null,
    };
}

fn mapThreadFault(code: i32) persistence.BackendError {
    return switch (code) {
        r4os.abi.thread_error_no_memory, r4os.abi.thread_error_no_slots => error.Full,
        r4os.abi.thread_error_unsupported => error.Unsupported,
        else => error.Io,
    };
}

fn removeAtomicScratch(self: *Store, path: *const r4os.AbsoluteFilePath) persistence.BackendError!void {
    switch (self.files.delete(path.asZ())) {
        .ok, .missing => {},
        .failure => |fault| {
            self.recordFailure(.atomic_cleanup, fault);
            return mapOpenFault(fault);
        },
    }
}

/// Exposes only the two durable data names for product diagnostics. Atomic
/// staging, backups and writer leases remain private implementation details.
pub fn dataPath(digest: *const [persistence.digest_bytes]u8, kind: persistence.FileKind) !r4os.AbsoluteFilePath {
    return makePath(digest, if (kind == .sram) .sram else .rtc);
}

fn ensureSaveRoot(files: *const r4os.app_storage.Files) persistence.BackendError!void {
    const directories = [_][]const u8{
        "C:\\R4OS\\APPDATA",
        "C:\\R4OS\\APPDATA\\SUBSYSTEMS",
        "C:\\R4OS\\APPDATA\\SUBSYSTEMS\\r4os.gb",
        "C:\\R4OS\\APPDATA\\SUBSYSTEMS\\r4os.gb\\SAVE",
    };
    for (directories) |raw| {
        const path = r4os.AbsoluteFilePath.parse(raw) catch return error.Io;
        var visible = false;
        for (0..create_retry_attempts) |attempt| {
            _ = files.createDirectory(path.asZ());
            visible = switch (files.info(path.asZ())) {
                .value => |info| info.is_dir != 0,
                .missing, .failure => false,
            };
            if (visible) break;
            if (attempt + 1 != create_retry_attempts) waitForCreateRetry(files);
        }
        if (!visible) return error.Io;
    }
}

fn createOwnedLock(
    self: *Store,
    path: *const r4os.AbsoluteFilePath,
    generation: u64,
) persistence.BackendError!r4os.app_storage.OwnedStageWriter {
    var writer = switch (self.files.ownedCreateWriter(path.asZ())) {
        .writer => |value| value,
        .failure => |fault| {
            self.recordFailure(.lock_begin, fault);
            if (fault == r4os.abi.file_stream_error_io and !abortOwnedPathWithRetry(self, path)) return error.Io;
            return mapOpenFault(fault);
        },
    };

    var body: [96]u8 = undefined;
    const lock_body = std.fmt.bufPrint(body[0..], "R4GB_SAVE_LOCK=1\nGENERATION={d}\n", .{generation}) catch {
        if (!abortOwnedPathWithRetry(self, path)) return error.Io;
        return error.Io;
    };
    switch (writer.write(lock_body)) {
        .ok => {},
        .failure => |fault| {
            self.recordFailure(.lock_write, fault);
            if (!abortOwnedPathWithRetry(self, path)) return error.Io;
            return mapOpenFault(fault);
        },
        .missing => {
            self.recordFailure(.lock_write, 0);
            if (!abortOwnedPathWithRetry(self, path)) return error.Io;
            return error.Io;
        },
    }
    switch (writer.finishKeepOwnership()) {
        .ok => {},
        .failure => |fault| {
            self.recordFailure(.lock_finish, fault);
            if (!abortOwnedPathWithRetry(self, path)) return error.Io;
            return mapOpenFault(fault);
        },
        .missing => {
            self.recordFailure(.lock_finish, 0);
            if (!abortOwnedPathWithRetry(self, path)) return error.Io;
            return error.Io;
        },
    }
    return writer;
}

/// A failed stream operation may have crossed its namespace visibility point
/// while losing the acknowledgement. Abort is ownership-checked by R4SYS, so
/// bounded retries can retire only this process' exact lease before Begin is
/// attempted again; a competing cartridge instance is never deleted by path.
fn abortOwnedPathWithRetry(self: *Store, path: *const r4os.AbsoluteFilePath) bool {
    for (0..create_retry_attempts) |attempt| {
        const raw = self.files.sys.fileStreamAbort(path.asZ().ptr);
        if (raw == r4os.abi.file_stream_result_ok or raw == r4os.abi.file_stream_error_not_found) return true;
        if (raw != r4os.abi.file_stream_error_io or attempt + 1 == create_retry_attempts) {
            self.recordFailure(.lock_abort, raw);
            return false;
        }
        waitForCreateRetry(&self.files);
    }
    unreachable;
}

fn waitForCreateRetry(files: *const r4os.app_storage.Files) void {
    const delay = @max(@as(u64, 1), files.sys.ticksFromMilliseconds(create_retry_delay_ms));
    files.sys.sleepTicks(delay);
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
