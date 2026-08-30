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
    var cart = try core.cartridge.Cartridge.init(init.gpa, image);
    defer cart.deinit();
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
}
