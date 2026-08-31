const std = @import("std");
const core = @import("core");
const r4os = @import("r4os");

const runtime_api = r4os.subsystem_runtime;

const FailingSink = struct {
    fail_writes: bool = true,
    opens: u32 = 0,
    writes: u32 = 0,
    closes: u32 = 0,
    bytes: u64 = 0,

    fn sink(self: *FailingSink) runtime_api.AudioSink {
        return .{
            .context = self,
            .open_fn = open,
            .write_fn = write,
            .volume_fn = volume,
            .close_fn = close,
        };
    }

    fn open(context: *anyopaque, config: runtime_api.AudioConfig) i32 {
        const self: *FailingSink = @ptrCast(@alignCast(context));
        self.opens += 1;
        if (config.sample_rate != core.apu.sample_rate or config.channels != core.apu.channels) return -78;
        return 0;
    }

    fn write(context: *anyopaque, data: []const u8) i32 {
        const self: *FailingSink = @ptrCast(@alignCast(context));
        self.writes += 1;
        if (self.fail_writes) return -77;
        self.bytes += data.len;
        return @intCast(data.len);
    }

    fn volume(_: *anyopaque, _: u32) i32 {
        return 0;
    }

    fn close(context: *anyopaque) i32 {
        const self: *FailingSink = @ptrCast(@alignCast(context));
        self.closes += 1;
        return 0;
    }
};

const Host = struct {
    close_requested: bool = false,

    fn driver(self: *Host) runtime_api.HostDriver {
        return .{ .context = self, .poll_fn = poll, .present_fn = present };
    }

    fn poll(context: *anyopaque) runtime_api.HostPollResult {
        const self: *Host = @ptrCast(@alignCast(context));
        if (!self.close_requested) return .idle;
        self.close_requested = false;
        return .{ .command = .close };
    }

    fn present(_: *anyopaque) i32 {
        return runtime_api.host_presented;
    }
};

fn makeMachine() !core.machine.Machine {
    var bytes: [32 * 1024]u8 = .{0} ** (32 * 1024);
    bytes[0x100] = 0xC3; // JP $0150
    bytes[0x101] = 0x50;
    bytes[0x102] = 0x01;
    @memcpy(bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[0x134..0x13B], "APUTEST");
    bytes[0x147] = 0;
    bytes[0x148] = 0;
    bytes[0x149] = 0;
    bytes[0x150] = 0x18; // JR $0150
    bytes[0x151] = 0xFE;
    bytes[0x14D] = core.cartridge.headerChecksum(bytes[0..]);
    const checksum = core.cartridge.globalChecksum(bytes[0..]);
    bytes[0x14E] = @truncate(checksum >> 8);
    bytes[0x14F] = @truncate(checksum);
    return core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(std.testing.allocator, bytes[0..]));
}

test "finite runtime drains every generated APU frame before completion" {
    var machine = try makeMachine();
    defer machine.deinit();
    configureTone(&machine);
    var adapter = core.runtime_adapter.Adapter.initFinite(&machine, 125 * std.time.ns_per_ms);
    var sink = FailingSink{ .fail_writes = false };
    var host = Host{};
    var queue: [3840]u8 = undefined;
    var scratch: [1920]u8 = undefined;
    var runtime = try runtime_api.Runtime.init(.{
        .slice_budget = core.clock.frame_t_cycles,
        .max_wait_ticks = 1000,
    }, 1000, 0, .{
        .config = .{
            .sample_rate = core.apu.sample_rate,
            .channels = core.apu.channels,
            .quantum_frames = 480,
            .target_quanta = 2,
            .max_catchup_quanta = 2,
        },
        .queue_storage = queue[0..],
        .scratch = scratch[0..],
        .sink = sink.sink(),
    });

    var completed = false;
    var tick: u64 = 0;
    while (tick < 2000) : (tick += 1) {
        switch (runtime.cycle(tick, adapter.driver(), host.driver())) {
            .wait => {},
            .finished => |result| {
                try std.testing.expectEqual(runtime_api.LifecycleState.completed, result.state);
                completed = true;
                break;
            },
        }
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(u64, 6000), machine.apu.stats.samples_generated);
    try std.testing.expectEqual(@as(u64, 0), machine.apu.stats.frames_dropped);
    try std.testing.expectEqual(@as(usize, 0), machine.apu.queuedFrames());
    try std.testing.expectEqual(@as(u64, 0), adapter.transport_pending_bytes);
    try std.testing.expectEqual(@as(u64, 6000 * core.apu.sample_bytes), sink.bytes);
}

test "WRAM completion witness stops guest work and drains audio exactly once" {
    var machine = try makeMachine();
    defer machine.deinit();
    configureTone(&machine);
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    try std.testing.expectError(
        error.InvalidCompletionWitnessAddress,
        adapter.setCompletionWitness(.{ .address = 0xBFFF, .value = 0xA5 }),
    );
    try adapter.setCompletionWitness(.{ .address = 0xC001, .value = 0xA5 });

    const driver = adapter.driver();
    _ = driver.step(core.clock.frame_t_cycles, 0);
    _ = driver.step(core.clock.frame_t_cycles, 20 * std.time.ns_per_ms);
    machine.bus.work_ram[1] = 0xA5;
    _ = driver.step(core.clock.frame_t_cycles, 20 * std.time.ns_per_ms);
    try std.testing.expect(adapter.source_finished);
    const finished_cycles = machine.guest_t_cycles;

    var audio: [480 * core.apu.sample_bytes]u8 = undefined;
    while (machine.apu.queuedFrames() != 0) {
        const rendered = driver.renderAudio(audio[0..]);
        try std.testing.expect(rendered > 0);
        _ = driver.audioFeedback(.{ .state = .active, .muted = false, .accepted_bytes = @intCast(rendered) });
    }
    const completed = driver.step(core.clock.frame_t_cycles, 10 * std.time.ns_per_s);
    try std.testing.expectEqual(runtime_api.StepStatus.completed, completed.status);
    try std.testing.expectEqual(finished_cycles, machine.guest_t_cycles);
    try std.testing.expectEqual(@as(u64, 0), adapter.transport_pending_bytes);
}

fn configureTone(machine: *core.machine.Machine) void {
    machine.write(0xFF26, 0);
    machine.write(0xFF26, 0x80);
    machine.write(0xFF24, 0x73);
    machine.write(0xFF25, 0x11);
    machine.write(0xFF11, 0x80);
    machine.write(0xFF12, 0xF0);
    machine.write(0xFF13, 0xD6);
    machine.write(0xFF14, 0x86);
}

test "runtime adapter keeps guest devices bounded after audio backend degradation" {
    var machine = try makeMachine();
    defer machine.deinit();
    configureTone(&machine);
    var adapter = core.runtime_adapter.Adapter.init(&machine);
    adapter.audio_prefill_frames = 96;
    var sink = FailingSink{};
    var host = Host{};
    var queue: [384]u8 = undefined;
    var scratch: [192]u8 = undefined;
    var runtime = try runtime_api.Runtime.init(.{
        .slice_budget = core.clock.frame_t_cycles,
        .max_wait_ticks = 1000,
    }, 1000, 0, .{
        .config = .{
            .sample_rate = core.apu.sample_rate,
            .channels = core.apu.channels,
            .quantum_frames = 48,
            .target_quanta = 2,
            .max_catchup_quanta = 2,
        },
        .queue_storage = queue[0..],
        .scratch = scratch[0..],
        .sink = sink.sink(),
    });

    _ = runtime.cycle(0, adapter.driver(), host.driver());
    _ = runtime.cycle(10, adapter.driver(), host.driver());
    try std.testing.expectEqual(runtime_api.AudioState.active, runtime.audio.state);
    try std.testing.expectEqual(@as(u32, 1), sink.opens);
    const cycles_before_failure = machine.guest_t_cycles;
    const divider_before_failure = machine.timer.divider_counter;

    _ = runtime.cycle(10, adapter.driver(), host.driver());
    try std.testing.expectEqual(runtime_api.AudioState.degraded, runtime.audio.state);
    try std.testing.expectEqual(@as(i32, -77), runtime.audio.last_error);
    try std.testing.expect(adapter.audio_degraded);
    try std.testing.expect(!adapter.audio_capture_enabled);
    const renders_after_failure = adapter.audio_render_calls;

    _ = runtime.cycle(50, adapter.driver(), host.driver());
    _ = runtime.cycle(50, adapter.driver(), host.driver());
    try std.testing.expect(machine.guest_t_cycles > cycles_before_failure);
    try std.testing.expect(machine.timer.divider_counter != divider_before_failure);
    try std.testing.expect(machine.ppu.line != 0 or machine.ppu.frames_completed != 0);
    try std.testing.expectEqual(renders_after_failure, adapter.audio_render_calls);
    try std.testing.expectEqual(runtime_api.LifecycleState.running, runtime.state);

    machine.write(0xFF00, 0x10);
    machine.interrupts.request = 0;
    machine.setButton(.a, true, false);
    try std.testing.expectEqual(@as(u8, 0xDE), machine.read(0xFF00));
    try std.testing.expect((machine.interrupts.request & 0x10) != 0);

    host.close_requested = true;
    const closed = runtime.cycle(51, adapter.driver(), host.driver());
    try std.testing.expectEqual(runtime_api.LifecycleState.closed, closed.finished.state);
    try std.testing.expect(runtime.resources_closed);
    try std.testing.expectEqual(@as(u32, 1), sink.closes);
}
