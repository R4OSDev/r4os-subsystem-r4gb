const std = @import("std");
const core = @import("core");

const profile_t_cycles: u64 = core.clock.frequency_hz;
const parity_guest_ns: u64 = 2 * std.time.ns_per_s;
const fast_host_step_ns: u64 = std.time.ns_per_ms;
const slow_host_step_ns: u64 = 17 * std.time.ns_per_ms;
const slice_budget: u32 = 32_768;

const CpuLoopMemory = struct {
    fn read(_: *anyopaque, address: u16) u8 {
        return switch (address) {
            0x0100 => 0x18, // JR -2
            0x0101 => 0xFE,
            else => 0,
        };
    }

    fn write(_: *anyopaque, _: u16, _: u8) void {}
    fn idle(_: *anyopaque, _: u16, _: u8) void {}

    fn bus(self: *CpuLoopMemory) core.cpu.Bus {
        return .{ .context = self, .read_fn = read, .write_fn = write, .idle_fn = idle };
    }
};

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4GB maturity harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const cpu_ns = try profileCpu(init.io);
    const ppu_ns = try profilePpu(init.io);
    const apu_ns = try profileApu(init.io);
    const hottest = if (cpu_ns >= ppu_ns and cpu_ns >= apu_ns)
        "cpu"
    else if (ppu_ns >= apu_ns)
        "ppu"
    else
        "apu";
    std.debug.print(
        "R4GB hotspot profile: OK t_cycles={d} cpu_ns={d} ppu_ns={d} apu_ns={d} largest={s}\n",
        .{ profile_t_cycles, cpu_ns, ppu_ns, apu_ns, hottest },
    );

    var image: [core.fixture_rom.image_bytes]u8 = undefined;
    try core.fixture_rom.build(image[0..], .battery_rtc);
    var fast = core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(init.gpa, image[0..]));
    defer fast.deinit();
    var slow = core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(init.gpa, image[0..]));
    defer slow.deinit();
    fast.apu.beginCapture();
    slow.apu.beginCapture();

    const fast_started = std.Io.Clock.awake.now(init.io);
    try runHostPattern(&fast, fast_host_step_ns);
    const fast_ns = try elapsedNanoseconds(fast_started, std.Io.Clock.awake.now(init.io));
    const slow_started = std.Io.Clock.awake.now(init.io);
    try runHostPattern(&slow, slow_host_step_ns);
    const slow_ns = try elapsedNanoseconds(slow_started, std.Io.Clock.awake.now(init.io));
    try ensureMachineParity(&fast, &slow);

    var fast_pcm: [core.apu.pcm_capacity_frames * core.apu.sample_bytes]u8 = undefined;
    var slow_pcm: [core.apu.pcm_capacity_frames * core.apu.sample_bytes]u8 = undefined;
    const fast_pcm_bytes = fast.apu.renderPcm(fast_pcm[0..]);
    const slow_pcm_bytes = slow.apu.renderPcm(slow_pcm[0..]);
    if (fast_pcm_bytes <= 0 or fast_pcm_bytes != slow_pcm_bytes or
        !std.mem.eql(u8, fast_pcm[0..@intCast(fast_pcm_bytes)], slow_pcm[0..@intCast(slow_pcm_bytes)]))
    {
        return error.HostSpeedPcmMismatch;
    }

    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(fast.ppu.framebuffer[0..]);
    hash.update(fast_pcm[0..@intCast(fast_pcm_bytes)]);
    hash.final(&digest);
    var digest_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(digest_hex[0..], "{x}", .{digest}) catch unreachable;
    const fastest_ns = @min(fast_ns, slow_ns);
    if (fastest_ns > 20 * std.time.ns_per_s) return error.MachineProfileTooSlow;
    const realtime_milli = (parity_guest_ns * 1000) / fastest_ns;
    std.debug.print(
        "R4GB host-speed parity: OK guest_ns={d} fast_step_ns={d} slow_step_ns={d} fast_host_ns={d} slow_host_ns={d} realtime_milli={d} guest_cycles={d} ppu_frames={d} pcm_bytes={d} digest={s}\n",
        .{ parity_guest_ns, fast_host_step_ns, slow_host_step_ns, fast_ns, slow_ns, realtime_milli, fast.guest_t_cycles, fast.ppu.frames_completed, fast_pcm_bytes, digest_hex[0..] },
    );
}

fn profileCpu(io: std.Io) !u64 {
    var memory = CpuLoopMemory{};
    var profile = core.model.profile(.dmg_c);
    profile.registers.pc = 0x0100;
    var processor = core.cpu.Cpu.init(profile);
    const started = std.Io.Clock.awake.now(io);
    while (processor.t_cycles < profile_t_cycles) {
        if (processor.step(memory.bus(), 0).kind == .illegal) return error.CpuProfileIllegalOpcode;
    }
    return elapsedNanoseconds(started, std.Io.Clock.awake.now(io));
}

fn profilePpu(io: std.Io) !u64 {
    var video = core.ppu.Ppu{};
    _ = video.writeLcdc(0x91);
    const started = std.Io.Clock.awake.now(io);
    var cycle: u64 = 0;
    while (cycle < profile_t_cycles) : (cycle += 1) _ = video.tick();
    if (video.frames_completed == 0) return error.PpuProfileNoFrames;
    return elapsedNanoseconds(started, std.Io.Clock.awake.now(io));
}

fn profileApu(io: std.Io) !u64 {
    var audio = core.apu.Apu{};
    audio.write(0x26, 0x80, 0);
    audio.write(0x24, 0x77, 0);
    audio.write(0x25, 0x11, 0);
    audio.write(0x11, 0x80, 0);
    audio.write(0x12, 0xF0, 0);
    audio.write(0x13, 0xD6, 0);
    audio.write(0x14, 0x86, 0);
    var divider: u16 = 0;
    const started = std.Io.Clock.awake.now(io);
    var cycle: u64 = 0;
    while (cycle < profile_t_cycles) : (cycle += 1) {
        const previous = divider;
        divider +%= 1;
        audio.tick(previous, divider);
    }
    if (audio.stats.samples_generated != core.apu.sample_rate) return error.ApuProfileRateMismatch;
    return elapsedNanoseconds(started, std.Io.Clock.awake.now(io));
}

fn runHostPattern(machine: *core.machine.Machine, host_step_ns: u64) !void {
    drainTimestamp(machine, 0);
    var timestamp = host_step_ns;
    while (timestamp < parity_guest_ns) : (timestamp += host_step_ns) drainTimestamp(machine, timestamp);
    drainTimestamp(machine, parity_guest_ns);
    if (machine.cpu.locked or machine.guest_clock.pending_t_cycles != 0) return error.HostPatternDidNotDrain;
}

fn drainTimestamp(machine: *core.machine.Machine, timestamp: u64) void {
    _ = machine.runHostSliceBounded(timestamp, slice_budget);
    while (machine.guest_clock.pending_t_cycles != 0) {
        _ = machine.runHostSliceBounded(timestamp, slice_budget);
    }
}

fn ensureMachineParity(left: *const core.machine.Machine, right: *const core.machine.Machine) !void {
    if (left.guest_t_cycles != right.guest_t_cycles or
        !std.meta.eql(left.cpu, right.cpu) or
        !std.meta.eql(left.timer, right.timer) or
        !std.meta.eql(left.interrupts, right.interrupts) or
        !std.meta.eql(left.dma, right.dma) or
        !std.meta.eql(left.ppu, right.ppu) or
        !std.meta.eql(left.apu, right.apu) or
        !std.meta.eql(left.joypad, right.joypad) or
        !std.meta.eql(left.serial, right.serial) or
        !std.meta.eql(left.guest_clock, right.guest_clock) or
        !std.meta.eql(left.cartridge.mapper, right.cartridge.mapper) or
        left.cartridge.ram_dirty != right.cartridge.ram_dirty or
        left.cartridge.rtc_dirty != right.cartridge.rtc_dirty or
        !std.mem.eql(u8, left.bus.work_ram[0..], right.bus.work_ram[0..]) or
        !std.mem.eql(u8, left.bus.high_ram[0..], right.bus.high_ram[0..]) or
        !std.mem.eql(u8, left.cartridge.external_ram, right.cartridge.external_ram))
    {
        return error.HostSpeedStateMismatch;
    }
}

fn elapsedNanoseconds(started: std.Io.Timestamp, ended: std.Io.Timestamp) !u64 {
    const elapsed = ended.nanoseconds - started.nanoseconds;
    if (elapsed <= 0) return error.ProfileClockUnavailable;
    return @intCast(elapsed);
}
