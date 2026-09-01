const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4GB cartridge probe FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args[1].len == 0) {
        std.debug.print("R4GB cartridge probe SKIP: no local cartridge supplied\n", .{});
        return;
    }
    const cwd = std.Io.Dir.cwd();
    const image = try cwd.readFileAlloc(
        init.io,
        args[1],
        init.gpa,
        .limited(core.cartridge.max_rom_bytes + 1),
    );
    defer init.gpa.free(image);
    var before: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &before, .{});
    var cart_storage: ?core.cartridge.Cartridge = try core.cartridge.Cartridge.init(init.gpa, image);
    defer if (cart_storage) |*cart| cart.deinit();
    const cart = &cart_storage.?;
    var after: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &after, .{});
    if (!std.mem.eql(u8, before[0..], after[0..])) return error.InputImageMutated;
    std.debug.print(
        "R4GB cartridge probe OK: title={s} mapper={s} mode={s} rom={d} ram={d} battery={} rtc={}\n",
        .{
            cart.header.titleSlice(),
            @tagName(cart.header.mapper),
            @tagName(cart.header.capability),
            cart.header.expected_rom_bytes,
            cart.external_ram.len,
            cart.header.type_info.has_battery,
            cart.header.type_info.has_timer,
        },
    );
    if (args.len >= 3 and args[2].len != 0) {
        const seconds = try std.fmt.parseInt(u32, args[2], 10);
        if (seconds == 0 or seconds > 300) return error.InvalidRunSeconds;
        var machine = core.machine.Machine.init(.dmg_c, cart_storage.?);
        cart_storage = null;
        defer machine.deinit();
        const target_cycles = @as(u64, seconds) * core.clock.frequency_hz;
        const started = std.Io.Clock.awake.now(init.io);
        while (machine.guest_t_cycles < target_cycles) {
            if (machine.stepCpu().kind == .illegal) return error.IllegalOpcodeDuringExecution;
        }
        const ended = std.Io.Clock.awake.now(init.io);
        const elapsed_ns = ended.nanoseconds - started.nanoseconds;
        if (elapsed_ns <= 0) return error.ProfileClockUnavailable;
        const realtime_milli = (@as(u128, seconds) * std.time.ns_per_s * 1000) / @as(u128, @intCast(elapsed_ns));
        std.crypto.hash.sha2.Sha256.hash(image, &after, .{});
        if (!std.mem.eql(u8, before[0..], after[0..])) return error.InputImageMutated;
        std.debug.print(
            "R4GB cartridge execution OK: guest_seconds={d} host_ns={d} realtime_milli={d} cycles={d} ppu_frames={d} changed_frames={d} audio_frames={d}\n",
            .{
                seconds,
                elapsed_ns,
                realtime_milli,
                machine.guest_t_cycles,
                machine.ppu.frames_completed,
                machine.ppu.frame_revision,
                machine.apu.stats.samples_generated,
            },
        );
    }
}
