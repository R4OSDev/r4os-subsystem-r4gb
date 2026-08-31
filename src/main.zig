const std = @import("std");
const r4os = @import("r4os");
const core = @import("core.zig");
const persistence_r4os = @import("persistence_r4os.zig");

const host_api = r4os.subsystem_host;
const product_host = core.product_host;
const runtime_api = r4os.subsystem_runtime;

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
const error_allocator: i32 = 73;
const error_audio: i32 = 74;
const error_save_busy: i32 = 75;
const error_save_open: i32 = 76;
const error_save_close: i32 = 77;
const error_host_video: i32 = 78;
const error_runtime: i32 = 79;
const error_apu_selftest: i32 = 94;
const error_persistence_selftest: i32 = 95;
const error_host_selftest: i32 = 96;
const error_e2e_trace: i32 = 97;
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
const product_audio_target_quanta: u16 = 2;
const host_selftest_marker_path = "C:\\TEMP\\R4GB.HOST";
const host_selftest_marker = "R4GB host runtime: OK instances=model-2+window-1 slices=bounded input=physical+focus video=160x144+generation audio=app-audio lifecycle=pause+resume+reset+mute+close resources=closed\r\n";
const e2e_fixture_a_path = "C:\\TEMP\\R4GB-E2E-A.GB";
const e2e_fixture_b_path = "C:\\TEMP\\R4GB-E2E-B.GBC";
const e2e_fixture_cgb_path = "C:\\TEMP\\R4GB-CGB-ONLY.GBC";

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
    if (std.mem.indexOf(u8, app.args(), "/PERSISTTEST") != null) return persistenceSelfTest(app);
    if (std.mem.indexOf(u8, app.args(), "/HOSTTEST") != null) return hostSelfTest(app);
    if (std.ascii.eqlIgnoreCase(app.args(), "/SELFTEST")) return selfTest(app);
    return runProduct(app);
}

fn runProduct(app: *r4os.App) i32 {
    if (app.profile != .desktop) return error_profile;
    const sys = app.system();
    const allocator = app.allocator() orelse return error_allocator;
    const files = app.files() orelse return r4os.abi.err_no_group;
    const desk = app.desktop() orelse return r4os.abi.err_no_group;
    const draw = app.drawing() orelse return r4os.abi.err_no_group;
    const launch = r4os.subsystem_launch.parse(app.args()) catch |fault| {
        sys.println("R4GB: invalid R4SUBSYS1 launch request.");
        return showStatus(allocator, sys, desk, draw, "R4GB - Startfehler", &.{
            "Der R4SUBSYS1-Startdatensatz ist ungueltig oder zu gross.",
            @errorName(fault),
            "Eine GB-Datei muss ueber Explorer oder Open With gestartet werden.",
        }, error_launch);
    };
    const e2e_trace = E2eTrace.parse(launch);
    var path = r4os.AbsoluteFilePath.parse(launch.guest_path) catch {
        sys.println("R4GB: invalid absolute cartridge path.");
        return showStatus(allocator, sys, desk, draw, "R4GB - Startfehler", &.{
            "Der uebergebene Cartridge-Pfad ist nicht absolut oder ungueltig.",
            launch.guest_path,
        }, error_path);
    };
    const image = loadRomOwned(allocator, &files, &path) catch |fault| {
        sys.write("R4GB: cartridge load failed: ");
        sys.println(@errorName(fault));
        return showStatus(allocator, sys, desk, draw, "R4GB - Ladefehler", &.{
            loadFailureMessage(fault),
            launch.guest_path,
            @errorName(fault),
        }, loadFailureCode(fault));
    };

    var save_store = persistence_r4os.Store.init(files);
    const save_generation = sys.ticks() | 1;
    var time_context = ProductTimeContext{ .sys = &sys };
    var guest = product_host.Guest.init(
        allocator,
        save_store.backend(),
        time_context.source(),
        save_generation,
    );
    defer _ = guest.close();
    guest.openOwned(image) catch |fault| {
        sys.write("R4GB: cartridge rejected: ");
        sys.println(@errorName(fault));
        const code = openFailureCode(fault);
        const status_result = showStatus(allocator, sys, desk, draw, "R4GB - Cartridgefehler", &.{
            openFailureMessage(fault),
            launch.guest_path,
            @errorName(fault),
        }, code);
        if (e2e_trace.active) {
            if (fault != error.CgbOnly or guest.resourcesOpen() or !writeE2eRejection(&sys, e2e_trace, fault)) {
                _ = writeE2eFailure(&sys, e2e_trace, "open", fault, save_store.failureStageName(), save_store.failureCode());
                return error_e2e_trace;
            }
        }
        return status_result;
    };

    const surface = guest.initialSurface() catch {
        _ = guest.close();
        return showStatus(allocator, sys, desk, draw, "R4GB - Hostfehler", &.{
            "Die native 160x144-Surface konnte nicht angelegt werden.",
        }, error_host_video);
    };
    var raster_scratch: [host_api.tile_max_pixels]u32 = undefined;
    var window = host_api.Host.init(desk, draw, surface, raster_scratch[0..]) catch |fault| {
        _ = guest.close();
        return showStatus(allocator, sys, desk, draw, "R4GB - Hostfehler", &.{
            "Der produktive Game-Boy-Fensterhost ist nicht verfuegbar.",
            @errorName(fault),
        }, error_host_video);
    };
    window.setInputPolicy(.{ .key_text_mode = .key_and_text, .pointer_mode = .ignored });
    _ = window.setMinimumSize(@intCast(core.ppu.width), @intCast(core.ppu.height));
    guest.attachVideo(&window.video) catch |fault| {
        _ = guest.close();
        return showStatus(allocator, sys, desk, draw, "R4GB - Hostfehler", &.{
            "Die Cartridge-Surface konnte nicht an das Fenster gebunden werden.",
            @errorName(fault),
        }, error_host_video);
    };

    var audio_sink_storage: runtime_api.R4AudioSink = undefined;
    var audio_sink: ?runtime_api.AudioSink = null;
    if (app.audio()) |audio| {
        audio_sink_storage = runtime_api.R4AudioSink.initWithTimeouts(audio, audio_service_timeout_ns, audio_close_timeout_ns);
        audio_sink = audio_sink_storage.sink();
    }
    var audio_queue: [runtime_api.default_quantum_frames * product_audio_target_quanta * core.apu.sample_bytes]u8 = undefined;
    var audio_scratch: [runtime_api.default_quantum_frames * core.apu.sample_bytes]u8 = undefined;
    var runtime = runtime_api.Runtime.init(.{
        .slice_budget = product_host.slice_budget_t_cycles,
        .max_input_events = runtime_api.default_max_input_events,
        .max_wait_ticks = runtime_api.default_max_wait_ticks,
    }, sys.monotonicHz(), sys.ticks(), .{
        .config = .{
            .sample_rate = core.apu.sample_rate,
            .channels = core.apu.channels,
            .quantum_frames = runtime_api.default_quantum_frames,
            .target_quanta = product_audio_target_quanta,
            .max_catchup_quanta = runtime_api.default_max_catchup_quanta,
        },
        .queue_storage = audio_queue[0..],
        .scratch = audio_scratch[0..],
        .sink = audio_sink,
    }) catch |fault| {
        _ = guest.close();
        return showStatus(allocator, sys, desk, draw, "R4GB - Hostfehler", &.{
            "Die kooperative Gastlaufzeit konnte nicht initialisiert werden.",
            @errorName(fault),
        }, error_runtime);
    };
    var runtime_host = product_host.WindowHost.init(sys, &window, &guest, &runtime);
    runtime_host.applyTitle();

    sys.write("R4GB: validated DMG cartridge ");
    sys.println(guest.title());
    sys.write("R4GB: mapper ");
    sys.println(@tagName(guest.machine.?.cartridge.header.mapper));
    if (guest.save_session.?.enabled) {
        sys.write("R4GB: persistence ");
        sys.println(core.persistence.save_root);
    }
    sys.println("R4GB: host controls F5=pause F6=resume F8=reset F9=mute F10=unmute");
    const exit_code = runtime.run(&sys, guest.driver(), runtime_host.driver());
    const runtime_state = runtime.state;
    const audio_degraded = runtime.audio.state == .degraded;
    const runtime_stats = runtime.stats;
    const audio_stats = runtime.audio.stats;
    const published_frames = window.video.stats.published_frames;
    const save_enabled = guest.save_session.?.enabled;
    const save_has_rtc = guest.machine.?.cartridge.header.type_info.has_timer;
    const save_ram_bytes = guest.machine.?.cartridge.external_ram.len;
    const save_digest = guest.machine.?.cartridge.rom_digest;
    const guest_cycles = guest.machine.?.guest_t_cycles;
    runtime.shutdown();
    const close_result = guest.close();
    if (e2e_trace.active) {
        const save_files = !save_enabled or persistenceFilesPresent(&files, &save_digest, save_ram_bytes, save_has_rtc);
        const e2e_ok = exit_code == 0 and runtime_state == .closed and close_result == 0 and !guest.resourcesOpen() and
            runtime_stats.slices != 0 and guest.stats.maximum_slice_operations <= product_host.slice_budget_t_cycles + 24 and
            guest.input.input_events >= 2 and !guest.input.focused and published_frames != 0 and
            audio_stats.writes != 0 and !audio_degraded and save_files;
        if (!writeE2eRuntimeReport(
            &sys,
            e2e_trace,
            launch.guest_path,
            e2e_ok,
            save_enabled,
            save_has_rtc,
            save_files,
            guest_cycles,
            runtime_stats,
            audio_stats,
            guest.stats,
            published_frames,
            close_result,
        )) return error_e2e_trace;
        if (!e2e_ok) return error_e2e_trace;
    }
    if (close_result != 0) {
        sys.println("R4GB: clean persistence close failed.");
        return error_save_close;
    }
    if (runtime_state == .closed) return 0;

    var failure_text: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(failure_text[0..], "Laufzeitfehler: {d}", .{exit_code}) catch "Laufzeitfehler";
    return showStatus(allocator, sys, desk, draw, "R4GB - Laufzeitfehler", &.{
        "Die emulierte Game-Boy-Instanz wurde kontrolliert beendet.",
        rendered,
        if (audio_degraded) "Audio war degradiert; Video und Eingabe liefen unabhaengig weiter." else "Alle Instanzressourcen wurden freigegeben.",
    }, if (exit_code == 0) error_runtime else exit_code);
}

const E2eTrace = struct {
    active: bool = false,
    id: []const u8 = "",

    fn parse(request: r4os.subsystem_launch.Request) E2eTrace {
        const mode = (request.option(r4os.subsystem_launch.trace_mode_key) catch null) orelse return .{};
        if (!std.ascii.eqlIgnoreCase(mode, r4os.subsystem_launch.trace_mode_headless)) return .{};
        const id = (request.option(r4os.subsystem_launch.trace_key) catch null) orelse return .{};
        if (id.len != 16) return .{};
        for (id) |byte| if (!std.ascii.isHex(byte)) return .{};
        return .{ .active = true, .id = id };
    }
};

fn e2eReportPath(trace: E2eTrace, storage: *[96]u8) ?[*:0]const u8 {
    const path = std.fmt.bufPrintZ(storage[0..], "C:\\TEMP\\R4GB-{s}.REPORT", .{trace.id}) catch return null;
    return path.ptr;
}

fn writeE2eRejection(sys: *const r4os.r4sys.Context, trace: E2eTrace, fault: anyerror) bool {
    var path_storage: [96]u8 = undefined;
    const path = e2eReportPath(trace, &path_storage) orelse return false;
    var report_storage: [192]u8 = undefined;
    const report = std.fmt.bufPrint(report_storage[0..], "R4GB E2E rejection: OK id={s} error={s} window=closed resources=closed\r\n", .{
        trace.id,
        @errorName(fault),
    }) catch return false;
    return sys.fileWrite(path, report) == @as(i32, @intCast(report.len));
}

fn writeE2eFailure(
    sys: *const r4os.r4sys.Context,
    trace: E2eTrace,
    phase: []const u8,
    fault: anyerror,
    storage_stage: []const u8,
    storage_code: i32,
) bool {
    var path_storage: [96]u8 = undefined;
    const path = e2eReportPath(trace, &path_storage) orelse return false;
    var report_storage: [192]u8 = undefined;
    const report = std.fmt.bufPrint(report_storage[0..], "R4GB E2E diagnostic: FAILED id={s} phase={s} error={s} storage_stage={s} storage_code={d}\r\n", .{
        trace.id,
        phase,
        @errorName(fault),
        storage_stage,
        storage_code,
    }) catch return false;
    return sys.fileWrite(path, report) == @as(i32, @intCast(report.len));
}

fn writeE2eRuntimeReport(
    sys: *const r4os.r4sys.Context,
    trace: E2eTrace,
    guest_path: []const u8,
    ok: bool,
    battery: bool,
    rtc: bool,
    save_files: bool,
    guest_cycles: u64,
    runtime_stats: runtime_api.RuntimeStats,
    audio_stats: runtime_api.AudioStats,
    guest_stats: product_host.GuestStats,
    published_frames: u64,
    close_result: i32,
) bool {
    var path_storage: [96]u8 = undefined;
    const path = e2eReportPath(trace, &path_storage) orelse return false;
    var report_storage: [640]u8 = undefined;
    const extension = if (endsWithIgnoreCase(guest_path, ".gbc")) ".gbc" else ".gb";
    const report = std.fmt.bufPrint(report_storage[0..],
        "R4GB E2E runtime: {s} id={s} extension={s} battery={d} rtc={d} guest_cycles={d} slices={d} max_slice={d} input={d} frames={d} audio_writes={d} pauses={d} resumes={d} resets={d} save_files={d} close={d} resources=closed\r\n",
        .{
            if (ok) "OK" else "FAILED",
            trace.id,
            extension,
            @intFromBool(battery),
            @intFromBool(rtc),
            guest_cycles,
            runtime_stats.slices,
            guest_stats.maximum_slice_operations,
            runtime_stats.input_events,
            published_frames,
            audio_stats.writes,
            runtime_stats.pauses,
            runtime_stats.resumes,
            runtime_stats.resets,
            @intFromBool(save_files),
            close_result,
        },
    ) catch return false;
    return sys.fileWrite(path, report) == @as(i32, @intCast(report.len));
}

fn persistenceFilesPresent(
    files: *const r4os.Files,
    digest: *const [core.persistence.digest_bytes]u8,
    ram_bytes: usize,
    has_rtc: bool,
) bool {
    if (ram_bytes != 0) {
        const path = persistence_r4os.dataPath(digest, .sram) catch return false;
        const info = switch (files.info(path.asZ())) {
            .value => |value| value,
            .missing, .failure => return false,
        };
        if (info.is_dir != 0 or info.size != ram_bytes) return false;
    }
    if (has_rtc) {
        const path = persistence_r4os.dataPath(digest, .rtc) catch return false;
        const info = switch (files.info(path.asZ())) {
            .value => |value| value,
            .missing, .failure => return false,
        };
        if (info.is_dir != 0 or info.size != core.persistence.rtc_record_bytes) return false;
    }
    return true;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

const ProductTimeContext = struct {
    sys: *const r4os.r4sys.Context,

    fn source(self: *ProductTimeContext) product_host.TimeSource {
        return .{ .context = self, .now_fn = now };
    }

    fn now(context: *anyopaque) product_host.TimePoint {
        const self: *ProductTimeContext = @ptrCast(@alignCast(context));
        return .{
            .wall_seconds = persistence_r4os.wallSeconds(self.sys.timeState()),
            .monotonic_ns = self.sys.monotonicNanoseconds() orelse 0,
        };
    }
};

const LoadError = error{
    Missing,
    Directory,
    TooSmall,
    TooLarge,
    Metadata,
    Read,
    OutOfMemory,
};

fn loadRomOwned(
    allocator: std.mem.Allocator,
    files: *const r4os.app_storage.Files,
    path: *r4os.AbsoluteFilePath,
) LoadError![]u8 {
    const info = switch (files.info(path.asZ())) {
        .value => |value| value,
        .missing => return error.Missing,
        .failure => return error.Metadata,
    };
    if (info.is_dir != 0) return error.Directory;
    const size = std.math.cast(usize, info.size) orelse return error.TooLarge;
    if (size < core.cartridge.header_size) return error.TooSmall;
    if (size > core.cartridge.max_rom_bytes) return error.TooLarge;
    const image = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(image);
    var offset: usize = 0;
    while (offset < image.len) {
        const transferred = switch (files.readAt(path.asZ(), @intCast(offset), image[offset..])) {
            .bytes => |count| count,
            .end, .failure => return error.Read,
        };
        if (transferred == 0 or transferred > image.len - offset) return error.Read;
        offset += transferred;
    }
    return image;
}

fn loadFailureMessage(fault: anyerror) []const u8 {
    return switch (fault) {
        error.Missing => "Die Cartridge-Datei wurde nicht gefunden.",
        error.Directory => "Der Cartridge-Pfad bezeichnet ein Verzeichnis.",
        error.TooSmall => "Die Datei ist kleiner als ein vollstaendiger Game-Boy-Header.",
        error.TooLarge => "Die Datei ueberschreitet die unterstuetzte DMG-Grenze von 8 MiB.",
        error.Metadata => "Die Dateiinformationen konnten nicht gelesen werden.",
        error.Read => "Die Cartridge konnte nicht vollstaendig und unveraendert gelesen werden.",
        error.OutOfMemory => "Fuer das unveraenderte ROM-Abbild ist nicht genug Speicher verfuegbar.",
        else => "Die Cartridge konnte nicht geladen werden.",
    };
}

fn loadFailureCode(fault: anyerror) i32 {
    return switch (fault) {
        error.Missing => error_missing,
        error.Directory => error_directory,
        error.TooSmall => error_cartridge,
        error.TooLarge => error_size,
        error.OutOfMemory => error_allocator,
        error.Metadata, error.Read => error_read,
        else => error_read,
    };
}

fn openFailureMessage(fault: anyerror) []const u8 {
    return switch (fault) {
        error.CgbOnly => "Diese Cartridge benoetigt einen Color Game Boy; R4GB emuliert DMG.",
        error.UnsupportedMbc6 => "Der Mapper MBC6 ist noch nicht unterstuetzt.",
        error.UnsupportedTama5 => "Der Mapper TAMA5 ist noch nicht unterstuetzt.",
        error.UnsupportedHuc3 => "Der Mapper HuC3 ist noch nicht unterstuetzt.",
        error.UnsupportedMapper, error.UnknownCartridgeType => "Der Cartridge-Mapper ist nicht unterstuetzt.",
        error.UnsupportedMbc7Accessory => "MBC7-Sensor und Zusatzhardware sind nicht verfuegbar.",
        error.UnsupportedCameraAccessory => "Die Game-Boy-Kamera ist nicht verfuegbar.",
        error.UnavailableAccessory => "Die von dieser Cartridge benoetigte Zusatzhardware ist nicht verfuegbar.",
        error.InvalidLogo, error.InvalidHeaderChecksum, error.InvalidGlobalChecksum => "Die Cartridge-Pruefsummen oder das Nintendo-Logo sind ungueltig.",
        error.InvalidRomSizeCode, error.InvalidRamSizeCode, error.SizeMismatch, error.InconsistentRam => "Die Cartridge-Groessenangaben sind widerspruechlich.",
        error.MapperRomTooLarge, error.MapperRamTooLarge => "ROM oder RAM ueberschreitet die Grenze dieses Mappers.",
        error.CorruptSave => "Die vorhandene SRAM-Datei hat eine ungueltige Groesse.",
        error.CorruptRtc => "Die vorhandene RTC-Datei ist beschaedigt oder inkompatibel.",
        error.Busy => "Der Speicherstand dieser Cartridge ist bereits zum Schreiben geoeffnet.",
        error.Full => "Der Datentraeger fuer den Speicherstand ist voll.",
        error.Io, error.Unsupported => "Der Speicherort der Cartridge-Daten ist nicht verfuegbar.",
        error.OutOfMemory => "Fuer die private Game-Boy-Instanz ist nicht genug Speicher verfuegbar.",
        else => "Die Cartridge wurde durch die DMG-Validierung abgelehnt.",
    };
}

fn openFailureCode(fault: anyerror) i32 {
    return switch (fault) {
        error.Busy => error_save_busy,
        error.CorruptSave, error.CorruptRtc, error.Full, error.Io, error.Unsupported => error_save_open,
        error.OutOfMemory => error_allocator,
        else => error_cartridge,
    };
}

fn showStatus(
    allocator: std.mem.Allocator,
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    title: [*:0]const u8,
    lines: []const []const u8,
    result_code: i32,
) i32 {
    _ = allocator;
    _ = desk.guiSetTitle(title);
    _ = desk.guiSetMinSize(400, 220);
    if (!renderStatus(&draw, lines)) return result_code;
    var activity_sequence: u64 = 0;
    const close_poll_ticks = @max(@as(u64, 1), sys.ticksFromMilliseconds(100));
    while (!sys.programShouldClose()) {
        var event_count: u16 = 0;
        while (event_count < runtime_api.default_max_input_events) : (event_count += 1) {
            var event: r4os.abi.GuiEvent = .{};
            if (desk.guiPollEvent(&event) <= 0) break;
            if (event.kind == @intFromEnum(r4os.abi.GuiEventKind.close)) return result_code;
            if (event.kind == @intFromEnum(r4os.abi.GuiEventKind.key_down) and event.key == 27) return result_code;
            if (event.kind == @intFromEnum(r4os.abi.GuiEventKind.resize)) {
                if (!renderStatus(&draw, lines)) return result_code;
            }
        }
        if (event_count == runtime_api.default_max_input_events) continue;
        if (desk.hasFn("desktop_activity_wait")) {
            var sequence = activity_sequence;
            const raw = desk.desktopActivityWait(activity_sequence, close_poll_ticks, &sequence);
            activity_sequence = sequence;
            if (raw < 0) return result_code;
        } else {
            sys.sleepTicks(1);
        }
    }
    return result_code;
}

fn renderStatus(draw: *const r4os.r4draw.Context, lines: []const []const u8) bool {
    const background: u32 = 0x0014_1820;
    if (draw.guiClear(background) <= 0) return false;
    if (!drawStatusLine(draw, 16, 16, "R4GB", 0x00FF_FFFF, background)) return false;
    var y: i32 = 48;
    for (lines) |line| {
        if (!drawStatusLine(draw, 16, y, line, 0x00E0_E0E0, background)) return false;
        y += 18;
    }
    if (!drawStatusLine(draw, 16, y + 18, "Fenster schliessen oder Escape druecken.", 0x0090_A0B0, background)) return false;
    return draw.guiPresent() >= 0;
}

fn drawStatusLine(
    draw: *const r4os.r4draw.Context,
    x: i32,
    y: i32,
    value: []const u8,
    foreground: u32,
    background: u32,
) bool {
    var storage: [320]u8 = .{0} ** 320;
    const count = @min(value.len, storage.len - 1);
    @memcpy(storage[0..count], value[0..count]);
    return draw.guiDrawText(x, y, @ptrCast(&storage), foreground, background) >= 0;
}

const HostSelfTestStage = enum {
    focus_down,
    focus_up,
    warm,
    resume_running,
    reset,
    warm_after_reset,
    mute,
    unmute,
    close,
    done,
};

const HostSelfTestDriver = struct {
    base: *product_host.WindowHost,
    sys: *const r4os.r4sys.Context,
    guest: *product_host.Guest,
    stage: HostSelfTestStage = .focus_down,
    emitted: bool = false,
    pause_deadline: u64 = 0,
    watchdog_deadline: u64,
    timed_out: bool = false,

    fn driver(self: *HostSelfTestDriver) runtime_api.HostDriver {
        return .{
            .context = self,
            .poll_fn = poll,
            .present_fn = present,
            .wait_fn = wait,
            .should_close_fn = shouldClose,
        };
    }

    fn poll(context: *anyopaque) runtime_api.HostPollResult {
        const self: *HostSelfTestDriver = @ptrCast(@alignCast(context));
        const base_result = self.base.driver().poll();
        switch (base_result) {
            .idle => {},
            else => return base_result,
        }
        if (self.emitted) {
            self.emitted = false;
            return .idle;
        }
        return switch (self.stage) {
            .focus_down => blk: {
                self.guest.focusGained(self.sys.ticks());
                if (!self.guest.physicalKey(core.host_adapter.physical_usage_right, true, false, self.sys.ticks())) {
                    break :blk .{ .failure = error_host_selftest };
                }
                self.stage = .focus_up;
                self.emitted = true;
                break :blk .handled;
            },
            .focus_up => blk: {
                if (!self.guest.physicalKey(core.host_adapter.physical_usage_right, false, false, self.sys.ticks())) {
                    break :blk .{ .failure = error_host_selftest };
                }
                self.stage = .warm;
                self.emitted = true;
                break :blk .handled;
            },
            .warm => blk: {
                const machine = if (self.guest.machine) |*value| value else break :blk .{ .failure = error_host_selftest };
                if (machine.guest_t_cycles < @as(u64, core.clock.frame_t_cycles) * 2) break :blk .idle;
                self.guest.pauseVideo();
                self.pause_deadline = self.sys.ticks() +| self.sys.ticksFromMilliseconds(20);
                self.stage = .resume_running;
                self.emitted = true;
                break :blk .{ .command = .pause };
            },
            .resume_running => blk: {
                if (self.sys.ticks() < self.pause_deadline) break :blk .idle;
                self.guest.resumeVideo();
                self.stage = .reset;
                self.emitted = true;
                break :blk .{ .command = .resume_running };
            },
            .reset => blk: {
                self.stage = .warm_after_reset;
                self.emitted = true;
                break :blk .{ .command = .reset };
            },
            .warm_after_reset => blk: {
                const machine = if (self.guest.machine) |*value| value else break :blk .{ .failure = error_host_selftest };
                if (machine.guest_t_cycles < core.clock.frame_t_cycles) break :blk .idle;
                self.stage = .mute;
                break :blk .idle;
            },
            .mute => blk: {
                self.stage = .unmute;
                self.emitted = true;
                break :blk .{ .command = .mute };
            },
            .unmute => blk: {
                self.stage = .close;
                self.emitted = true;
                break :blk .{ .command = .unmute };
            },
            .close => blk: {
                self.guest.focusLost(self.sys.ticks());
                self.stage = .done;
                self.emitted = true;
                break :blk .{ .command = .close };
            },
            .done => .idle,
        };
    }

    fn present(context: *anyopaque) i32 {
        const self: *HostSelfTestDriver = @ptrCast(@alignCast(context));
        return self.base.driver().present();
    }

    fn wait(context: *anyopaque, timeout_ticks: u64) i32 {
        const self: *HostSelfTestDriver = @ptrCast(@alignCast(context));
        const cap = @max(@as(u64, 1), self.sys.ticksFromMilliseconds(1));
        const bounded = if (timeout_ticks == r4os.abi.io_wait_forever) cap else @min(timeout_ticks, cap);
        return self.base.driver().wait(bounded) orelse blk: {
            self.sys.sleepTicks(bounded);
            break :blk 0;
        };
    }

    fn shouldClose(context: *anyopaque) bool {
        const self: *HostSelfTestDriver = @ptrCast(@alignCast(context));
        if (self.sys.programShouldClose()) return true;
        if (self.sys.ticks() < self.watchdog_deadline) return false;
        self.timed_out = true;
        return true;
    }
};

fn hostSelfTest(app: *r4os.App) i32 {
    const sys = app.system();
    const allocator = app.allocator() orelse return error_allocator;
    const files = app.files() orelse return r4os.abi.err_no_group;
    const desk = app.desktop() orelse return r4os.abi.err_no_group;
    const draw = app.drawing() orelse return r4os.abi.err_no_group;
    const app_audio = app.audio() orelse {
        sys.println("R4GB host runtime: FAILED app-audio-unavailable");
        return error_host_selftest;
    };
    const image = allocator.alloc(u8, 32 * 1024) catch return error_allocator;
    makeSelfTestRom(image, "R4HOSTTEST");

    var save_store = persistence_r4os.Store.init(files);
    const initial_generation = sys.ticks() | 1;
    var time_context = ProductTimeContext{ .sys = &sys };
    var guest = product_host.Guest.init(allocator, save_store.backend(), time_context.source(), initial_generation);
    defer _ = guest.close();
    guest.openOwned(image) catch |fault| {
        sys.write("R4GB host runtime: FAILED open=");
        sys.println(@errorName(fault));
        return error_host_selftest;
    };
    configureApuSelfTestTone(&guest.machine.?);

    const surface = guest.initialSurface() catch {
        sys.println("R4GB host runtime: FAILED surface");
        return error_host_selftest;
    };
    var raster_scratch: [host_api.tile_max_pixels]u32 = undefined;
    var window = host_api.Host.init(desk, draw, surface, raster_scratch[0..]) catch {
        sys.println("R4GB host runtime: FAILED window");
        return error_host_selftest;
    };
    window.setInputPolicy(.{ .key_text_mode = .key_and_text, .pointer_mode = .ignored });
    _ = window.setMinimumSize(@intCast(core.ppu.width), @intCast(core.ppu.height));
    guest.attachVideo(&window.video) catch {
        sys.println("R4GB host runtime: FAILED video-bind");
        return error_host_selftest;
    };

    var sink_storage = runtime_api.R4AudioSink.initWithTimeouts(app_audio, audio_service_timeout_ns, audio_close_timeout_ns);
    var audio_queue: [runtime_api.default_quantum_frames * product_audio_target_quanta * core.apu.sample_bytes]u8 = undefined;
    var audio_scratch: [runtime_api.default_quantum_frames * core.apu.sample_bytes]u8 = undefined;
    var runtime = runtime_api.Runtime.init(.{
        .slice_budget = product_host.slice_budget_t_cycles,
        .max_input_events = runtime_api.default_max_input_events,
        .max_wait_ticks = runtime_api.default_max_wait_ticks,
    }, sys.monotonicHz(), sys.ticks(), .{
        .config = .{
            .sample_rate = core.apu.sample_rate,
            .channels = core.apu.channels,
            .quantum_frames = runtime_api.default_quantum_frames,
            .target_quanta = product_audio_target_quanta,
            .max_catchup_quanta = runtime_api.default_max_catchup_quanta,
        },
        .queue_storage = audio_queue[0..],
        .scratch = audio_scratch[0..],
        .sink = sink_storage.sink(),
    }) catch {
        sys.println("R4GB host runtime: FAILED runtime-init");
        return error_host_selftest;
    };
    var window_host = product_host.WindowHost.init(sys, &window, &guest, &runtime);
    window_host.applyTitle();
    var scripted_host = HostSelfTestDriver{
        .base = &window_host,
        .sys = &sys,
        .guest = &guest,
        .watchdog_deadline = sys.ticks() +| sys.ticksFromMilliseconds(10_000),
    };
    const exit_code = runtime.run(&sys, guest.driver(), scripted_host.driver());
    const generation = guest.generation;
    const maximum_slice = guest.stats.maximum_slice_operations;
    const published_frames = window.video.stats.published_frames;
    const audio_writes = runtime.audio.stats.writes;
    const audio_degraded = runtime.audio.state == .degraded;
    runtime.shutdown();
    const close_result = guest.close();
    const ok = exit_code == 0 and runtime.state == .closed and scripted_host.stage == .done and !scripted_host.timed_out and
        runtime.stats.pauses == 1 and runtime.stats.resumes == 1 and runtime.stats.resets == 1 and
        generation == initial_generation + 1 and maximum_slice <= product_host.slice_budget_t_cycles + 24 and
        published_frames != 0 and audio_writes != 0 and !audio_degraded and
        guest.input.input_events == 2 and !guest.input.focused and close_result == 0 and !guest.resourcesOpen() and
        guest.stats.machine_creates == 2 and guest.stats.machine_destroys == 2 and guest.stats.rom_releases == 1;
    if (!ok) {
        sys.write("R4GB host runtime: FAILED state=");
        sys.write(@tagName(runtime.state));
        sys.write(" stage=");
        sys.write(@tagName(scripted_host.stage));
        sys.write(" slices=");
        sys.printU64(runtime.stats.slices);
        sys.write(" max=");
        sys.printU64(maximum_slice);
        sys.write(" frames=");
        sys.printU64(published_frames);
        sys.write(" writes=");
        sys.printU64(audio_writes);
        sys.write(" timeout=");
        sys.print(if (scripted_host.timed_out) "1" else "0");
        sys.write(" audio=");
        sys.println(if (audio_degraded) "degraded" else "ok");
        return error_host_selftest;
    }
    if (!writeE2eFixtureFiles(&sys, allocator)) {
        sys.println("R4GB host runtime: FAILED fixture-write");
        return error_host_selftest;
    }
    if (sys.fileWrite(host_selftest_marker_path, host_selftest_marker) != @as(i32, @intCast(host_selftest_marker.len))) {
        sys.println("R4GB host runtime: FAILED marker-write");
        return error_host_selftest;
    }
    sys.write(host_selftest_marker);
    return 0;
}

fn writeE2eFixtureFiles(sys: *const r4os.r4sys.Context, allocator: std.mem.Allocator) bool {
    const image = allocator.alloc(u8, core.fixture_rom.image_bytes) catch return false;
    defer allocator.free(image);
    const fixtures = [_]struct { path: [*:0]const u8, kind: core.fixture_rom.Kind }{
        .{ .path = e2e_fixture_a_path, .kind = .rom_only },
        .{ .path = e2e_fixture_b_path, .kind = .battery_rtc },
        .{ .path = e2e_fixture_cgb_path, .kind = .cgb_only },
    };
    for (fixtures) |fixture| {
        core.fixture_rom.build(image, fixture.kind) catch return false;
        if (sys.fileWrite(fixture.path, image) != @as(i32, @intCast(image.len))) return false;
    }
    return true;
}

fn persistenceSelfTest(app: *r4os.App) i32 {
    runPersistenceSelfTest(app) catch |fault| {
        const sys = app.system();
        sys.write("R4GB persistence runtime: FAILED ");
        sys.println(@errorName(fault));
        return error_persistence_selftest;
    };
    app.system().println("R4GB persistence runtime: OK sram=8192 rtc=1 lock=exclusive atomic=1");
    return 0;
}

fn runPersistenceSelfTest(app: *r4os.App) !void {
    const allocator = app.allocator() orelse return error.AllocatorUnavailable;
    const files = app.files() orelse return error.FilesUnavailable;
    const sys = app.system();
    const bytes = try allocator.alloc(u8, 32 * 1024);
    defer allocator.free(bytes);
    makeSelfTestRom(bytes, "R4SAVETEST");
    bytes[0x147] = 0x10;
    bytes[0x149] = 0x02;
    finalizeSelfTestRom(bytes);

    var first_cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer first_cart.deinit();
    var first_store = persistence_r4os.Store.init(files);
    first_store.removeTestFiles(&first_cart.rom_digest);
    defer first_store.removeTestFiles(&first_cart.rom_digest);
    const generation = (sys.ticks() | 1) +| 2;
    const wall = persistence_r4os.wallSeconds(sys.timeState());
    const monotonic = sys.monotonicNanoseconds() orelse 0;
    var first_session = try core.persistence.Session.open(&first_cart, first_store.backend(), generation, wall, monotonic);
    defer if (!first_session.closed) {
        first_session.close(&first_cart, generation, wall, monotonic) catch {};
    };

    first_cart.writeControl(0x0000, 0x0A);
    for (first_cart.external_ram, 0..) |_, index| {
        first_cart.writeExternal(@intCast(0xA000 + index), @truncate(index *% 37 +% 11));
    }
    first_cart.writeControl(0x4000, 0x08);
    first_cart.writeExternal(0xA000, 58);
    first_cart.writeControl(0x4000, 0x09);
    first_cart.writeExternal(0xA000, 59);
    first_cart.writeControl(0x4000, 0x0A);
    first_cart.writeExternal(0xA000, 23);
    first_cart.writeControl(0x4000, 0x0B);
    first_cart.writeExternal(0xA000, 0xFE);
    first_cart.writeControl(0x4000, 0x0C);
    first_cart.writeExternal(0xA000, 0x41); // day bit 8 + halt

    var competing_cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer competing_cart.deinit();
    var competing_store = persistence_r4os.Store.init(files);
    const contention = core.persistence.Session.open(&competing_cart, competing_store.backend(), generation + 1, wall, monotonic);
    if (contention) |opened| {
        var unexpected = opened;
        unexpected.close(&competing_cart, generation + 1, wall, monotonic) catch {};
        return error.ExclusiveWriterAcceptedTwice;
    } else |fault| {
        if (fault != error.Busy) return fault;
    }
    try first_session.close(&first_cart, generation, wall, monotonic);

    var reopened_cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer reopened_cart.deinit();
    var reopened_session = try core.persistence.Session.open(&reopened_cart, competing_store.backend(), generation + 2, wall, monotonic);
    defer if (!reopened_session.closed) {
        reopened_session.close(&reopened_cart, generation + 2, wall, monotonic) catch {};
    };
    for (reopened_cart.external_ram, 0..) |value, index| {
        if (value != @as(u8, @truncate(index *% 37 +% 11))) return error.SramMismatch;
    }
    const rtc = reopened_cart.mapper.rtc;
    if (rtc.seconds != 58 or rtc.minutes != 59 or rtc.hours != 23 or rtc.day_low != 0xFE or rtc.day_high != 0x41)
        return error.RtcMismatch;
    reopened_cart.writeControl(0x0000, 0x0A);
    reopened_cart.writeControl(0x4000, 0);
    reopened_cart.writeExternal(0xA000, 0xA7);
    try reopened_session.close(&reopened_cart, generation + 2, wall, monotonic);

    var final_cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer final_cart.deinit();
    var final_store = persistence_r4os.Store.init(files);
    var final_session = try core.persistence.Session.open(&final_cart, final_store.backend(), generation + 3, wall, monotonic);
    defer if (!final_session.closed) {
        final_session.close(&final_cart, generation + 3, wall, monotonic) catch {};
    };
    if (final_cart.external_ram[0] != 0xA7 or final_cart.external_ram[1] != @as(u8, @truncate(1 * 37 + 11)))
        return error.AtomicReplacementMismatch;
    try final_session.close(&final_cart, generation + 3, wall, monotonic);
}

fn apuSelfTest(app: *r4os.App) i32 {
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
    finalizeSelfTestRom(bytes);
}

fn finalizeSelfTestRom(bytes: []u8) void {
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
