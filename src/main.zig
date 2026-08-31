const std = @import("std");
const r4os = @import("r4os");
const core = @import("core.zig");

comptime {
    if (core.host_adapter.physical_usage_up != r4os.abi.physical_key_usage_up or
        core.host_adapter.physical_usage_down != r4os.abi.physical_key_usage_down or
        core.host_adapter.physical_usage_left != r4os.abi.physical_key_usage_left or
        core.host_adapter.physical_usage_right != r4os.abi.physical_key_usage_right or
        core.host_adapter.physical_usage_enter != r4os.abi.physical_key_usage_enter or
        core.host_adapter.physical_usage_right_control != r4os.abi.physical_key_usage_right_control or
        core.host_adapter.physical_usage_left_alt != r4os.abi.physical_key_usage_left_alt or
        core.host_adapter.physical_usage_space != r4os.abi.physical_key_usage_space)
    {
        @compileError("R4GB physical input mapping drifted from the public R4DESK HID contract");
    }
}

const error_profile: i32 = 64;
const error_launch: i32 = 65;
const error_path: i32 = 66;
const error_missing: i32 = 67;
const error_directory: i32 = 68;
const error_size: i32 = 69;
const error_read: i32 = 70;
const error_cartridge: i32 = 71;
const error_not_implemented: i32 = 72;
const error_allocator: i32 = 73;
const error_audio: i32 = 74;
const error_apu_selftest: i32 = 94;
// A short finite hardware path keeps the nested QEMU software-emulation gate
// bounded. The host model test separately proves an exact full second/48 kHz.
const apu_selftest_duration_ns: u64 = 125 * std.time.ns_per_ms;
const apu_selftest_frames: usize = (apu_selftest_duration_ns * core.apu.sample_rate) / std.time.ns_per_s;
const apu_selftest_target_quanta: u16 = @intCast((apu_selftest_frames + runtime_quantum_frames - 1) / runtime_quantum_frames);
const runtime_quantum_frames: usize = r4os.subsystem_runtime.default_quantum_frames;
// Nested software emulation can make the first App-Audio IPC round trip take
// well over the normal two-quantum live catch-up window. Keep the finite gate
// lossless while still bounding its backlog to substantially less than the
// 15-second watchdog.
const apu_selftest_max_catchup_quanta: u16 = 16;
const audio_service_timeout_ns: u64 = 50 * std.time.ns_per_ms;
const audio_close_timeout_ns: u64 = 500 * std.time.ns_per_ms;

const SelfTestHost = struct {
    system: *const r4os.r4sys.Context,
    deadline_tick: u64,
    timed_out: bool = false,

    fn driver(self: *SelfTestHost) r4os.subsystem_runtime.HostDriver {
        return .{
            .context = self,
            .poll_fn = poll,
            .present_fn = present,
            .should_close_fn = shouldClose,
        };
    }

    fn poll(_: *anyopaque) r4os.subsystem_runtime.HostPollResult {
        return .idle;
    }

    fn present(_: *anyopaque) i32 {
        return r4os.subsystem_runtime.host_present_unchanged;
    }

    fn shouldClose(context: *anyopaque) bool {
        const self: *SelfTestHost = @ptrCast(@alignCast(context));
        if (self.system.ticks() < self.deadline_tick) return false;
        self.timed_out = true;
        return true;
    }
};

const CpuSelfTestMemory = struct {
    bytes: [3]u8 = .{ 0x3E, 0x42, 0x00 },

    fn read(context: *anyopaque, address: u16) u8 {
        const self: *CpuSelfTestMemory = @ptrCast(@alignCast(context));
        if (address < 0x0100 or address >= 0x0100 + self.bytes.len) return 0xFF;
        return self.bytes[@as(usize, address) - 0x0100];
    }

    fn write(_: *anyopaque, _: u16, _: u8) void {}
    fn idle(_: *anyopaque, _: u16, _: u8) void {}

    fn bus(self: *CpuSelfTestMemory) core.cpu.Bus {
        return .{ .context = self, .read_fn = read, .write_fn = write, .idle_fn = idle };
    }
};

noinline fn executeCpuProbe(processor: *core.cpu.Cpu, memory: *CpuSelfTestMemory) core.cpu.StepResult {
    return processor.step(memory.bus(), 0);
}

noinline fn executeMachineProbe(machine: *core.machine.Machine) bool {
    const execution = machine.stepCpu();
    machine.write(0xFF04, 0);
    machine.write(0xFF05, 4);
    machine.write(0xFF07, 0x05);
    machine.write(0xFF00, 0x10);
    machine.setButton(.a, true, false);
    machine.bus.work_ram[0] = 0x6D;
    machine.write(0xFF46, 0xC0);
    machine.tickTcycles(648);
    machine.write(0xFF01, 0);
    machine.write(0xFF02, 0x81);
    machine.tickTcycles(4096);
    const first_budget = machine.runHostSlice(1_000_000);
    const second_budget = machine.runHostSlice(1_001_000);
    return execution.kind == .instruction and
        machine.read(0xFF00) == 0xDE and
        machine.ppu.oam[0] == 0x6D and
        machine.serial.data == 0xFF and
        (machine.interrupts.request & 0x18) == 0x18 and
        first_budget == 0 and second_budget >= 4;
}

pub fn r4_app_main(app: *r4os.App) i32 {
    if (std.mem.indexOf(u8, app.args(), "/APUTEST") != null) return apuSelfTest(app);
    if (std.ascii.eqlIgnoreCase(app.args(), "/SELFTEST")) return selfTest(app);
    if (app.profile != .desktop) return error_profile;
    const files = app.files() orelse return r4os.abi.err_no_group;
    const sys = app.system();
    const launch = r4os.subsystem_launch.parse(app.args()) catch {
        sys.println("R4GB: invalid R4SUBSYS1 launch request.");
        return error_launch;
    };
    var path = r4os.AbsoluteFilePath.parse(launch.guest_path) catch {
        sys.println("R4GB: invalid absolute cartridge path.");
        return error_path;
    };
    const info = switch (files.info(path.asZ())) {
        .value => |value| value,
        .missing => {
            sys.println("R4GB: cartridge file not found.");
            return error_missing;
        },
        .failure => {
            sys.println("R4GB: cartridge metadata could not be read.");
            return error_read;
        },
    };
    if (info.is_dir != 0) {
        sys.println("R4GB: cartridge path is a directory.");
        return error_directory;
    }
    const size = std.math.cast(usize, info.size) orelse {
        sys.println("R4GB: cartridge is too large for this host.");
        return error_size;
    };
    if (size < core.cartridge.header_size) {
        sys.println("R4GB: cartridge is smaller than a complete header.");
        return error_cartridge;
    }
    if (size > core.cartridge.max_rom_bytes) {
        sys.println("R4GB: cartridge exceeds the supported 8 MiB DMG limit.");
        return error_size;
    }
    const allocator = app.allocator() orelse {
        sys.println("R4GB: application memory allocator is unavailable.");
        return error_allocator;
    };
    const image = allocator.alloc(u8, size) catch {
        sys.println("R4GB: cartridge image allocation failed.");
        return error_allocator;
    };
    var image_owned = true;
    defer if (image_owned) allocator.free(image);
    var offset: usize = 0;
    while (offset < image.len) {
        const transferred = switch (files.readAt(path.asZ(), @intCast(offset), image[offset..])) {
            .bytes => |count| count,
            .end, .failure => {
                sys.println("R4GB: cartridge header read failed.");
                return error_read;
            },
        };
        if (transferred == 0 or transferred > image.len - offset) {
            sys.println("R4GB: cartridge image read was inconsistent.");
            return error_read;
        }
        offset += transferred;
    }
    var cart = core.cartridge.Cartridge.takeOwned(allocator, image) catch |fault| {
        sys.write("R4GB: cartridge rejected: ");
        sys.println(@errorName(fault));
        return error_cartridge;
    };
    image_owned = false;
    defer cart.deinit();
    sys.write("R4GB: validated DMG cartridge ");
    sys.println(cart.header.titleSlice());
    sys.write("R4GB: mapper ");
    sys.println(@tagName(cart.header.mapper));
    sys.println("R4GB: execution is not implemented in this cartridge build.");
    return error_not_implemented;
}

fn apuSelfTest(app: *r4os.App) i32 {
    const runtime_api = r4os.subsystem_runtime;
    const sys = app.system();
    const allocator = app.allocator() orelse return error_allocator;
    const app_audio = app.audio() orelse {
        sys.println("R4GB APU runtime: FAILED app-audio-unavailable");
        return error_audio;
    };
    const bytes = allocator.alloc(u8, 32 * 1024) catch return error_allocator;
    defer allocator.free(bytes);
    makeSelfTestRom(bytes, "R4APUTEST");
    var machine = core.machine.Machine.init(.dmg_c, core.cartridge.Cartridge.init(allocator, bytes) catch {
        sys.println("R4GB APU runtime: FAILED cartridge");
        return error_apu_selftest;
    });
    defer machine.deinit();
    configureApuSelfTestTone(&machine);

    var guest = core.runtime_adapter.Adapter.initFinite(&machine, apu_selftest_duration_ns);
    // The nested QEMU gate may calculate DMG time slower than the host audio
    // clock. Pre-roll only this finite diagnostic so the recorded hardware
    // path measures transport continuity rather than nested-emulation speed.
    guest.audio_prefill_frames = apu_selftest_frames;
    var sink_storage = runtime_api.R4AudioSink.initWithTimeouts(app_audio, audio_service_timeout_ns, audio_close_timeout_ns);
    var queue: [runtime_quantum_frames * apu_selftest_target_quanta * core.apu.sample_bytes]u8 = undefined;
    var scratch: [runtime_api.default_quantum_frames * core.apu.sample_bytes]u8 = undefined;
    var runtime = runtime_api.Runtime.init(.{
        .slice_budget = core.clock.frame_t_cycles,
        .max_input_events = 1,
        .max_wait_ticks = runtime_api.default_max_wait_ticks,
    }, sys.monotonicHz(), sys.ticks(), .{
        .config = .{
            .sample_rate = core.apu.sample_rate,
            .channels = core.apu.channels,
            .quantum_frames = runtime_api.default_quantum_frames,
            .target_quanta = apu_selftest_target_quanta,
            .max_catchup_quanta = apu_selftest_max_catchup_quanta,
        },
        .queue_storage = queue[0..],
        .scratch = scratch[0..],
        .sink = sink_storage.sink(),
    }) catch {
        sys.println("R4GB APU runtime: FAILED runtime-init");
        return error_apu_selftest;
    };
    var host = SelfTestHost{
        .system = &sys,
        .deadline_tick = sys.ticks() +| sys.ticksFromMilliseconds(15_000),
    };
    const exit_code = runtime.run(&sys, guest.driver(), host.driver());
    runtime.shutdown();

    const expected_frames: u64 = apu_selftest_frames;
    const ok = exit_code == 0 and runtime.state == .completed and !guest.audio_degraded and
        machine.apu.stats.samples_generated == expected_frames and machine.apu.stats.frames_dropped == 0 and
        machine.apu.queuedFrames() == 0 and guest.transport_pending_bytes == 0 and
        runtime.audio.stats.submitted_bytes == expected_frames * core.apu.sample_bytes and
        runtime.audio.stats.suppressed_bytes == 0 and runtime.audio.stats.discarded_bytes == 0 and
        runtime.audio.stats.write_failures == 0;
    if (!ok) {
        sys.write("R4GB APU runtime: FAILED frames=");
        sys.printU64(machine.apu.stats.samples_generated);
        sys.write(" submitted=");
        sys.printU64(runtime.audio.stats.submitted_bytes);
        sys.write(" drops=");
        sys.printU64(machine.apu.stats.frames_dropped);
        sys.write(" suppressed=");
        sys.printU64(runtime.audio.stats.suppressed_bytes);
        sys.write(" discarded=");
        sys.printU64(runtime.audio.stats.discarded_bytes);
        sys.write(" late=");
        sys.printU64(runtime.audio.stats.late_resyncs);
        sys.write(" queued=");
        sys.printU64(machine.apu.queuedFrames());
        sys.write(" transport=");
        sys.printU64(guest.transport_pending_bytes);
        sys.write(" cycles=");
        sys.printU64(machine.guest_t_cycles);
        sys.write(" pending=");
        sys.printU64(machine.guest_clock.pending_t_cycles);
        sys.write(" sourceDone=");
        sys.print(if (guest.source_finished) "1" else "0");
        sys.write(" timeout=");
        sys.print(if (host.timed_out) "1" else "0");
        sys.write(" audio=");
        sys.print(@tagName(runtime.audio.state));
        sys.write(" state=");
        sys.println(@tagName(runtime.state));
        return error_apu_selftest;
    }
    sys.write("R4GB APU runtime: OK rate=48000 channels=2 frames=");
    sys.printU64(machine.apu.stats.samples_generated);
    sys.write(" submitted=");
    sys.printU64(runtime.audio.stats.submitted_bytes);
    sys.println(" drift=0 drops=0");
    return 0;
}

fn configureApuSelfTestTone(machine: *core.machine.Machine) void {
    machine.write(0xFF26, 0);
    machine.write(0xFF26, 0x80);
    // Deliberately use different left/right master volumes. Besides exercising
    // NR50, this makes the R4GB signal distinguishable from AUDIOD's symmetric
    // reference tone in the shared QEMU WAV capture.
    machine.write(0xFF24, 0x73);
    machine.write(0xFF25, 0x11);
    machine.write(0xFF11, 0x80);
    machine.write(0xFF12, 0xF0);
    machine.write(0xFF13, 0xD6);
    machine.write(0xFF14, 0x86);
}

fn makeSelfTestRom(bytes: []u8, title: []const u8) void {
    const title_len: usize = @min(title.len, 16);
    @memset(bytes, 0);
    bytes[0x100] = 0xC3;
    bytes[0x101] = 0x50;
    bytes[0x102] = 0x01;
    @memcpy(bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[0x134 .. 0x134 + title_len], title[0..title_len]);
    bytes[0x147] = 0;
    bytes[0x148] = 0;
    bytes[0x149] = 0;
    bytes[0x150] = 0x18;
    bytes[0x151] = 0xFE;
    bytes[0x14D] = core.cartridge.headerChecksum(bytes);
    bytes[0x14E] = 0;
    bytes[0x14F] = 0;
    const checksum = core.cartridge.globalChecksum(bytes);
    bytes[0x14E] = @truncate(checksum >> 8);
    bytes[0x14F] = @truncate(checksum);
}

fn selfTest(app: *r4os.App) i32 {
    const sys = app.system();
    const allocator = app.allocator() orelse return error_allocator;
    const bytes = allocator.alloc(u8, 32 * 1024) catch return error_allocator;
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[0x134..0x13A], "R4TEST");
    bytes[0x147] = 0x00;
    bytes[0x148] = 0x00;
    bytes[0x149] = 0x00;
    var checksum: u8 = 0;
    for (bytes[0x134..0x14D]) |value| checksum -%= value +% 1;
    bytes[0x14D] = checksum;
    bytes[0x14E] = 0;
    bytes[0x14F] = 0;
    var global = core.cartridge.globalChecksum(bytes);
    bytes[0x14E] = @truncate(global >> 8);
    bytes[0x14F] = @truncate(global);
    const header = core.cartridge.parse(bytes) catch {
        sys.println("R4GB cartridge selftest FAILED: cartridge");
        return 90;
    };
    var machine = core.machine.Machine.init(.dmg_c, core.cartridge.Cartridge.init(allocator, bytes) catch {
        sys.println("R4GB cartridge selftest FAILED: machine allocation");
        return 90;
    });
    defer machine.deinit();
    var cpu_profile = core.model.profile(.dmg_c);
    cpu_profile.registers.pc = 0x0100;
    var processor = core.cpu.Cpu.init(cpu_profile);
    var cpu_memory: CpuSelfTestMemory = .{};
    const cpu_result = executeCpuProbe(&processor, &cpu_memory);
    if (!std.mem.eql(u8, header.titleSlice(), "R4TEST") or
        core.model.production_revision != .dmg_c or
        cpu_result.kind != .instruction or cpu_result.m_cycles != 2 or
        processor.registers.a != 0x42 or processor.registers.pc != 0x0102 or
        core.host_adapter.buttonForPhysicalUsage(core.host_adapter.physical_usage_right_control) != .select or
        !executeMachineProbe(&machine))
    {
        sys.println("R4GB cartridge selftest FAILED: model");
        return 91;
    }
    bytes[0x143] = 0xC0;
    checksum = 0;
    for (bytes[0x134..0x14D]) |value| checksum -%= value +% 1;
    bytes[0x14D] = checksum;
    bytes[0x14E] = 0;
    bytes[0x14F] = 0;
    global = core.cartridge.globalChecksum(bytes);
    bytes[0x14E] = @truncate(global >> 8);
    bytes[0x14F] = @truncate(global);
    _ = core.cartridge.parse(bytes) catch |fault| {
        if (fault == error.CgbOnly) {
            sys.println("R4GB CPU selftest: OK model=dmg-c mapper=rom-only bus=bounded sm83=cycle-callback input=physical");
            return 0;
        }
        sys.println("R4GB cartridge selftest FAILED: CGB rejection");
        return 92;
    };
    sys.println("R4GB cartridge selftest FAILED: CGB accepted");
    return 93;
}
