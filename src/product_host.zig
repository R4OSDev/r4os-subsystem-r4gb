const std = @import("std");
const r4os = @import("r4os");
const cartridge = @import("cartridge.zig");
const host_adapter = @import("host_adapter.zig");
const machine_module = @import("machine.zig");
const model = @import("model.zig");
const persistence = @import("persistence.zig");
const runtime_adapter = @import("runtime_adapter.zig");

const host_api = r4os.subsystem_host;
const runtime_api = r4os.subsystem_runtime;

/// About 7.8 ms of DMG work. A complete SM83 operation may cross the boundary
/// by its final few T-cycles, but a delayed host can never turn one runtime
/// cycle into an unbounded catch-up loop.
pub const slice_budget_t_cycles: u32 = 32_768;
pub const close_error_persistence: i32 = -9720;
pub const runtime_error_persistence: i32 = -9721;
pub const reset_error_cartridge: i32 = -9722;
pub const reset_error_persistence: i32 = -9723;
pub const reset_error_video: i32 = -9724;
pub const runtime_error_closed: i32 = -9725;

// USB HID keyboard usages. These deliberately do not overlap any guest key.
pub const physical_usage_f5: u32 = 0x3E;
pub const physical_usage_f6: u32 = 0x3F;
pub const physical_usage_f8: u32 = 0x41;
pub const physical_usage_f9: u32 = 0x42;
pub const physical_usage_f10: u32 = 0x43;

pub const HostAction = enum {
    pause,
    resume_running,
    reset,
    mute,
    unmute,
};

pub fn actionForPhysicalUsage(usage: u32) ?HostAction {
    return switch (usage) {
        physical_usage_f5 => .pause,
        physical_usage_f6 => .resume_running,
        physical_usage_f8 => .reset,
        physical_usage_f9 => .mute,
        physical_usage_f10 => .unmute,
        else => null,
    };
}

pub fn commandForAction(action: HostAction) runtime_api.LifecycleCommand {
    return switch (action) {
        .pause => .pause,
        .resume_running => .resume_running,
        .reset => .reset,
        .mute => .mute,
        .unmute => .unmute,
    };
}

pub const TimePoint = struct {
    wall_seconds: ?i64,
    monotonic_ns: u64,
};

pub const TimeSource = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) TimePoint,

    pub fn now(self: TimeSource) TimePoint {
        return self.now_fn(self.context);
    }
};

pub const GuestState = enum {
    empty,
    running,
    closed,
};

pub const GuestStats = struct {
    slices: u64 = 0,
    maximum_slice_operations: u32 = 0,
    flushes: u64 = 0,
    resets: u64 = 0,
    close_calls: u64 = 0,
    machine_creates: u64 = 0,
    machine_destroys: u64 = 0,
    rom_releases: u64 = 0,
};

/// Owns every mutable resource of one launched cartridge. `init` creates no
/// self-references; `openOwned` is called only after the value has reached its
/// final address, so the runtime adapter and persistence backend remain valid.
pub const Guest = struct {
    allocator: std.mem.Allocator,
    backend: persistence.Backend,
    time: TimeSource,
    generation: u64,
    save_generation: u64,
    state: GuestState = .empty,
    rom_image: ?[]u8 = null,
    machine: ?machine_module.Machine = null,
    save_session: ?persistence.Session = null,
    runtime_guest: runtime_adapter.Adapter = undefined,
    runtime_guest_ready: bool = false,
    completion_witness: ?runtime_adapter.CompletionWitness = null,
    input: host_adapter.HostAdapter = .{},
    video: host_adapter.VideoAdapter = .{},
    palette: [host_api.palette_entries]u32 = .{0} ** host_api.palette_entries,
    presenter: ?*host_api.Presenter = null,
    close_result: i32 = 0,
    stats: GuestStats = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        backend: persistence.Backend,
        time: TimeSource,
        generation: u64,
    ) Guest {
        return .{
            .allocator = allocator,
            .backend = backend,
            .time = time,
            .generation = if (generation == 0) 1 else generation,
            .save_generation = if (generation == 0) 1 else generation,
        };
    }

    /// Takes ownership of `image` on every outcome. The immutable source is
    /// retained solely so Reset can construct a genuinely fresh machine.
    pub fn openOwned(self: *Guest, image: []u8) !void {
        if (self.state != .empty or self.rom_image != null) return error.AlreadyOpen;
        self.rom_image = image;
        errdefer _ = self.close();

        const cart = try cartridge.Cartridge.init(self.allocator, image);
        self.machine = machine_module.Machine.init(model.production_revision, cart);
        self.stats.machine_creates +%= 1;
        const point = self.time.now();
        self.save_session = try persistence.Session.open(
            &self.machine.?.cartridge,
            self.backend,
            self.save_generation,
            point.wall_seconds,
            point.monotonic_ns,
        );
        self.runtime_guest = runtime_adapter.Adapter.init(&self.machine.?);
        self.runtime_guest_ready = true;
        host_adapter.initializeDmgPalette(&self.palette);
        self.state = .running;
    }

    pub fn initialSurface(self: *Guest) !host_api.Surface {
        if (self.state != .running) return error.NotRunning;
        const machine = if (self.machine) |*value| value else return error.NotRunning;
        return host_api.Surface.initIndexed8(
            machine.ppu.framebuffer[0..],
            self.palette[0..],
            @import("ppu.zig").width,
            @import("ppu.zig").height,
        );
    }

    pub fn attachVideo(self: *Guest, presenter: *host_api.Presenter) !void {
        if (self.state != .running) return error.NotRunning;
        const machine = if (self.machine) |*value| value else return error.NotRunning;
        try self.video.bind(&machine.ppu, &self.palette, presenter, self.generation);
        self.presenter = presenter;
    }

    pub fn title(self: *const Guest) []const u8 {
        const machine = if (self.machine) |*value| value else return "Cartridge";
        const value = machine.cartridge.header.titleSlice();
        return if (value.len == 0) "Cartridge" else value;
    }

    pub fn driver(self: *Guest) runtime_api.GuestDriver {
        return .{
            .context = self,
            .step_fn = step,
            .reset_fn = resetCallback,
            .render_audio_fn = renderAudio,
            .audio_feedback_fn = audioFeedback,
        };
    }

    pub fn setCompletionWitness(self: *Guest, witness: runtime_adapter.CompletionWitness) !void {
        if (self.state != .running or !self.runtime_guest_ready) return error.NotRunning;
        try self.runtime_guest.setCompletionWitness(witness);
        self.completion_witness = witness;
    }

    pub fn focusGained(self: *Guest, tick: u64) void {
        self.input.last_host_tick = tick;
        self.input.focusGained();
    }

    pub fn focusLost(self: *Guest, tick: u64) void {
        self.input.last_host_tick = tick;
        if (self.machine) |*machine| self.input.focusLost(&machine.joypad);
    }

    pub fn physicalKey(self: *Guest, usage: u32, down: bool, repeat: bool, tick: u64) bool {
        self.input.last_host_tick = tick;
        if (self.state != .running) return false;
        const machine = if (self.machine) |*value| value else return false;
        const accepted = self.input.physicalKey(
            &machine.joypad,
            &machine.interrupts,
            usage,
            down,
            repeat,
        );
        if (accepted and down and !repeat) machine.cpu.requestStopWake();
        return accepted;
    }

    pub fn pauseVideo(self: *Guest) void {
        self.video.pause();
    }

    pub fn resumeVideo(self: *Guest) void {
        self.video.resumeRunning();
    }

    pub fn syncVideo(self: *Guest, presenter: *host_api.Presenter) bool {
        return self.video.syncVideo(presenter);
    }

    pub fn reset(self: *Guest) i32 {
        if (self.state != .running or !self.runtime_guest_ready) return runtime_error_closed;
        const image = self.rom_image orelse return runtime_error_closed;
        const old_machine = if (self.machine) |*value| value else return runtime_error_closed;
        if (self.save_session) |*session| {
            const point = self.time.now();
            session.flush(&old_machine.cartridge, point.wall_seconds, point.monotonic_ns) catch return reset_error_persistence;
        }

        var replacement_cart = cartridge.Cartridge.init(self.allocator, image) catch return reset_error_cartridge;
        if (self.save_session) |session| if (session.enabled) {
            if (replacement_cart.external_ram.len != old_machine.cartridge.external_ram.len) {
                replacement_cart.deinit();
                return reset_error_cartridge;
            }
            @memcpy(replacement_cart.external_ram, old_machine.cartridge.external_ram);
            replacement_cart.mapper.rtc = old_machine.cartridge.mapper.rtc;
            replacement_cart.mapper.rtc_latched = old_machine.cartridge.mapper.rtc_latched;
            replacement_cart.clearPersistenceDirty();
        };
        const replacement = machine_module.Machine.init(model.production_revision, replacement_cart);

        old_machine.apu.endCapture();
        old_machine.deinit();
        self.stats.machine_destroys +%= 1;
        old_machine.* = replacement;
        self.stats.machine_creates +%= 1;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        if (self.save_session) |*session| session.last_flush_guest_tick = 0;
        self.runtime_guest = runtime_adapter.Adapter.init(old_machine);
        if (self.completion_witness) |witness| self.runtime_guest.setCompletionWitness(witness) catch unreachable;
        if (self.presenter) |presenter| {
            self.video.bind(&old_machine.ppu, &self.palette, presenter, self.generation) catch return reset_error_video;
        }
        self.stats.resets +%= 1;
        return 0;
    }

    /// Releases the complete instance in one fixed order. It is deliberately
    /// idempotent because runtime completion, GUI close and error unwinding all
    /// converge here.
    pub fn close(self: *Guest) i32 {
        self.stats.close_calls +%= 1;
        if (self.state == .closed) return self.close_result;
        self.state = .closed;

        if (self.runtime_guest_ready) {
            if (self.machine) |*machine| machine.apu.endCapture();
            self.runtime_guest_ready = false;
        }
        self.video.close();
        self.presenter = null;
        if (self.save_session) |*session| {
            if (self.machine) |*machine| {
                const point = self.time.now();
                session.close(
                    &machine.cartridge,
                    self.save_generation,
                    point.wall_seconds,
                    point.monotonic_ns,
                ) catch {
                    self.close_result = close_error_persistence;
                };
            }
        }
        self.save_session = null;
        if (self.machine) |*machine| {
            machine.deinit();
            self.stats.machine_destroys +%= 1;
        }
        self.machine = null;
        if (self.rom_image) |image| {
            self.allocator.free(image);
            self.stats.rom_releases +%= 1;
        }
        self.rom_image = null;
        return self.close_result;
    }

    pub fn resourcesOpen(self: *const Guest) bool {
        return self.state == .running or self.machine != null or self.rom_image != null or self.presenter != null;
    }

    fn step(context: *anyopaque, budget: u32, guest_now_ns: u64) runtime_api.StepResult {
        const self: *Guest = @ptrCast(@alignCast(context));
        if (self.state != .running or !self.runtime_guest_ready) return runtime_api.StepResult.fail(runtime_error_closed);
        const result = self.runtime_guest.driver().step(budget, guest_now_ns);
        self.stats.slices +%= 1;
        self.stats.maximum_slice_operations = @max(self.stats.maximum_slice_operations, result.operations);
        if (result.status == .failed) return result;
        if (self.save_session) |*session| {
            const machine = if (self.machine) |*value| value else return runtime_api.StepResult.fail(runtime_error_closed);
            const point = self.time.now();
            const flushed = session.maybeFlush(
                &machine.cartridge,
                machine.guest_t_cycles,
                point.wall_seconds,
                point.monotonic_ns,
            ) catch return runtime_api.StepResult.fail(runtime_error_persistence).withOperations(result.operations);
            if (flushed) self.stats.flushes +%= 1;
        }
        return result;
    }

    fn resetCallback(context: *anyopaque) i32 {
        const self: *Guest = @ptrCast(@alignCast(context));
        return self.reset();
    }

    fn renderAudio(context: *anyopaque, out: []u8) i32 {
        const self: *Guest = @ptrCast(@alignCast(context));
        if (self.state != .running or !self.runtime_guest_ready) return runtime_error_closed;
        return self.runtime_guest.driver().renderAudio(out);
    }

    fn audioFeedback(context: *anyopaque, feedback: runtime_api.AudioFeedback) bool {
        const self: *Guest = @ptrCast(@alignCast(context));
        if (self.state != .running or !self.runtime_guest_ready) return false;
        return self.runtime_guest.driver().audioFeedback(feedback);
    }
};

const TitleState = struct {
    lifecycle: runtime_api.LifecycleState = .ready,
    muted: bool = false,
    audio_degraded: bool = false,

    fn eql(left: TitleState, right: TitleState) bool {
        return left.lifecycle == right.lifecycle and left.muted == right.muted and left.audio_degraded == right.audio_degraded;
    }
};

/// Translates one ordered window event at a time. It never executes guest
/// work itself; the shared Runtime performs the sole bounded slice after the
/// event batch has been drained.
pub const WindowHost = struct {
    sys: r4os.r4sys.Context,
    window: *host_api.Host,
    guest: *Guest,
    runtime: *runtime_api.Runtime,
    activity_sequence: u64 = 0,
    initial_present_pending: bool = true,
    title_state: ?TitleState = null,
    title_storage: [192]u8 = .{0} ** 192,

    pub fn init(
        sys: r4os.r4sys.Context,
        window: *host_api.Host,
        guest: *Guest,
        runtime: *runtime_api.Runtime,
    ) WindowHost {
        return .{ .sys = sys, .window = window, .guest = guest, .runtime = runtime };
    }

    pub fn driver(self: *WindowHost) runtime_api.HostDriver {
        return .{
            .context = self,
            .poll_fn = poll,
            .present_fn = present,
            .wait_fn = if (self.window.desk.hasFn("desktop_activity_wait")) wait else null,
            .should_close_fn = shouldClose,
        };
    }

    pub fn applyTitle(self: *WindowHost) void {
        const state = TitleState{
            .lifecycle = self.runtime.state,
            .muted = self.runtime.audio.muted,
            .audio_degraded = self.runtime.audio.state == .degraded,
        };
        if (self.title_state) |old| if (old.eql(state)) return;
        self.title_state = state;
        const suffix: []const u8 = if (state.audio_degraded)
            " [Audio nicht verfuegbar]"
        else if (state.lifecycle == .paused and state.muted)
            " [Pause, stumm]"
        else if (state.lifecycle == .paused)
            " [Pause]"
        else if (state.muted)
            " [Stumm]"
        else
            "";
        const title = std.fmt.bufPrintZ(self.title_storage[0..], "R4GB - {s}{s}", .{ self.guest.title(), suffix }) catch "R4GB";
        _ = self.window.setTitle(title.ptr);
    }

    fn poll(context: *anyopaque) runtime_api.HostPollResult {
        const self: *WindowHost = @ptrCast(@alignCast(context));
        self.applyTitle();
        if (self.initial_present_pending) {
            self.initial_present_pending = false;
            return .present;
        }
        const event = self.window.pollInput() orelse return .idle;
        return switch (event) {
            .close => |close| blk: {
                self.guest.focusLost(close.tick);
                break :blk .{ .command = .close };
            },
            .resize => blk: {
                self.window.video.invalidateAll();
                break :blk .present;
            },
            .focus => |focus| blk: {
                if (focus.focused) self.guest.focusGained(focus.tick) else self.guest.focusLost(focus.tick);
                break :blk if (focus.focused) .present else .handled;
            },
            .physical_key_down => |key| self.physical(key, true),
            .physical_key_up => |key| self.physical(key, false),
            .key_down, .text, .mouse => .ignored,
        };
    }

    fn physical(self: *WindowHost, key: host_api.PhysicalKeyEvent, down: bool) runtime_api.HostPollResult {
        const repeat = (key.flags & r4os.abi.physical_key_flag_repeat) != 0;
        if (actionForPhysicalUsage(key.key)) |action| {
            if (!down or repeat) return .ignored;
            switch (action) {
                .pause => self.guest.pauseVideo(),
                .resume_running => self.guest.resumeVideo(),
                .reset, .mute, .unmute => {},
            }
            return .{ .command = commandForAction(action) };
        }
        return if (self.guest.physicalKey(key.key, down, repeat, key.tick)) .handled else .ignored;
    }

    fn shouldClose(context: *anyopaque) bool {
        const self: *WindowHost = @ptrCast(@alignCast(context));
        return self.sys.programShouldClose();
    }

    fn wait(context: *anyopaque, timeout_ticks: u64) i32 {
        const self: *WindowHost = @ptrCast(@alignCast(context));
        var sequence = self.activity_sequence;
        const raw = self.window.desk.desktopActivityWait(self.activity_sequence, timeout_ticks, &sequence);
        self.activity_sequence = sequence;
        return raw;
    }

    fn present(context: *anyopaque) i32 {
        const self: *WindowHost = @ptrCast(@alignCast(context));
        _ = self.guest.syncVideo(&self.window.video);
        return switch (self.window.present()) {
            .failure => |raw| raw,
            .hidden => runtime_api.host_present_hidden,
            .unchanged => runtime_api.host_present_unchanged,
            .presented => runtime_api.host_presented,
        };
    }
};

test "host actions are explicit and never overlap guest controls" {
    try std.testing.expectEqual(HostAction.pause, actionForPhysicalUsage(physical_usage_f5).?);
    try std.testing.expectEqual(HostAction.resume_running, actionForPhysicalUsage(physical_usage_f6).?);
    try std.testing.expectEqual(HostAction.reset, actionForPhysicalUsage(physical_usage_f8).?);
    try std.testing.expectEqual(HostAction.mute, actionForPhysicalUsage(physical_usage_f9).?);
    try std.testing.expectEqual(HostAction.unmute, actionForPhysicalUsage(physical_usage_f10).?);
    for ([_]u32{
        host_adapter.physical_usage_up,
        host_adapter.physical_usage_down,
        host_adapter.physical_usage_left,
        host_adapter.physical_usage_right,
        host_adapter.physical_usage_enter,
        host_adapter.physical_usage_right_control,
        host_adapter.physical_usage_left_alt,
        host_adapter.physical_usage_space,
    }) |usage| try std.testing.expect(actionForPhysicalUsage(usage) == null);
}
