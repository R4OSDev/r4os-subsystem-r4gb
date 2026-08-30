const std = @import("std");
const core = @import("core");
const r4os = @import("r4os");

const host = r4os.subsystem_host;

const FakeBackend = struct {
    full_begins: u32 = 0,
    damage_begins: u32 = 0,
    commits: u32 = 0,
    rasters: u32 = 0,
    invalid_raster: bool = false,
    first_color: ?u32 = null,

    fn backend(self: *FakeBackend) host.Backend {
        return .{
            .context = self,
            .begin_full_fn = beginFull,
            .begin_damage_fn = beginDamage,
            .clear_fn = clear,
            .raster_fn = raster,
            .indexed8_fn = indexed8,
            .commit_full_fn = commit,
            .commit_damage_fn = commit,
            .cancel_fn = cancel,
        };
    }

    fn state(context: *anyopaque) *FakeBackend {
        return @ptrCast(@alignCast(context));
    }

    fn beginFull(context: *anyopaque) i32 {
        state(context).full_begins += 1;
        return 0;
    }

    fn beginDamage(context: *anyopaque, _: []const r4os.abi.DisplayDamageRect) i32 {
        state(context).damage_begins += 1;
        return 0;
    }

    fn clear(_: *anyopaque, _: u32) i32 {
        return 0;
    }

    fn raster(context: *anyopaque, _: i32, _: i32, width: u32, height: u32, _: u32, pixels: []const u32) i32 {
        const self = state(context);
        self.rasters += 1;
        if (width == 0 or height == 0 or width > host.tile_max_width or height > host.tile_max_height or
            pixels.len != @as(usize, width) * height)
        {
            self.invalid_raster = true;
        }
        if (self.first_color == null and pixels.len != 0) self.first_color = pixels[0];
        return 0;
    }

    fn indexed8(_: *anyopaque, _: host.IndexedBatch) i32 {
        return -1;
    }

    fn commit(context: *anyopaque) i32 {
        state(context).commits += 1;
        return 0;
    }

    fn cancel(_: *anyopaque) i32 {
        return 0;
    }
};

test "DMG video bridge publishes only native complete frames and bounded raster blocks" {
    var display: core.ppu.Ppu = .{};
    display.framebuffer[0] = 0;
    var palette: [host.palette_entries]u32 = undefined;
    var placeholder_pixels = [_]u8{0};
    var placeholder_palette = [_]u32{0} ** host.palette_entries;
    var scratch: [host.tile_max_pixels]u32 = undefined;
    var presenter = try host.Presenter.init(
        try host.Surface.initIndexed8(placeholder_pixels[0..], placeholder_palette[0..], 1, 1),
        scratch[0..],
    );
    var adapter: core.host_adapter.VideoAdapter = .{};
    try adapter.bind(&display, &palette, &presenter, 1);

    try std.testing.expectEqual(@as(u32, 160), presenter.surface.width);
    try std.testing.expectEqual(@as(u32, 144), presenter.surface.height);
    try std.testing.expectEqual(host.PixelFormat.indexed8, presenter.surface.format());
    try std.testing.expectEqualSlices(u32, &.{ 0x00FF_FFFF, 0x00AA_AAAA, 0x0055_5555, 0 }, palette[0..4]);
    try std.testing.expectEqual(@intFromPtr(&display.framebuffer[0]), @intFromPtr(presenter.surface.indexedPixels().?.ptr));
    try std.testing.expect(@intFromPtr(&display.working_frame[0]) != @intFromPtr(presenter.surface.indexedPixels().?.ptr));

    var backend: FakeBackend = .{};
    const first = presenter.presentTo(backend.backend(), 320, 288);
    switch (first) {
        .presented => |info| try std.testing.expectEqual(host.PresentMode.full, info.mode),
        else => return error.UnexpectedPresentResult,
    }
    try std.testing.expectEqual(@as(?u32, 0x00FF_FFFF), backend.first_color);
    try std.testing.expect(!backend.invalid_raster);
    try std.testing.expect(!adapter.syncVideo(&presenter));
    try std.testing.expect(presenter.presentTo(backend.backend(), 320, 288) == .unchanged);

    display.framebuffer[12 * core.ppu.width + 23] = 3;
    display.frame_revision = 1;
    display.damage_pending = true;
    display.damage_min_x = 23;
    display.damage_max_x = 23;
    display.damage_min_y = 12;
    display.damage_max_y = 12;
    try std.testing.expect(adapter.syncVideo(&presenter));
    const damaged = presenter.presentTo(backend.backend(), 320, 288);
    switch (damaged) {
        .presented => |info| {
            try std.testing.expectEqual(host.PresentMode.damage, info.mode);
            try std.testing.expectEqual(@as(u32, 1), info.damage_regions);
        },
        else => return error.UnexpectedPresentResult,
    }
    try std.testing.expect(!backend.invalid_raster);

    const resized = presenter.presentTo(backend.backend(), 400, 288);
    switch (resized) {
        .presented => |info| {
            try std.testing.expectEqual(host.PresentMode.full, info.mode);
            try std.testing.expect(info.viewport.x > 0);
            try std.testing.expect(info.viewport.mapClientPoint(0, 144) == null);
        },
        else => return error.UnexpectedPresentResult,
    }
}

test "pause reset LCD shutdown and close cannot expose stale video generations" {
    var first_display: core.ppu.Ppu = .{};
    var second_display: core.ppu.Ppu = .{};
    @memset(&first_display.framebuffer, 3);
    first_display.frame_published = true;
    var palette: [host.palette_entries]u32 = undefined;
    var scratch: [host.tile_max_pixels]u32 = undefined;
    var presenter = try host.Presenter.init(
        try host.Surface.initIndexed8(first_display.framebuffer[0..], palette[0..], core.ppu.width, core.ppu.height),
        scratch[0..],
    );
    var adapter: core.host_adapter.VideoAdapter = .{};
    try adapter.bind(&first_display, &palette, &presenter, 1);

    adapter.pause();
    try std.testing.expectEqual(core.host_adapter.VideoState.paused, adapter.state);
    const lcd_event = first_display.writeLcdc(first_display.lcdc & ~@as(u8, 0x80));
    try std.testing.expect(lcd_event.frame_ready);
    try std.testing.expect(adapter.syncVideo(&presenter));
    for (first_display.framebuffer) |pixel| try std.testing.expectEqual(@as(u8, 0), pixel);
    adapter.resumeRunning();

    second_display.framebuffer[0] = 2;
    try adapter.bind(&second_display, &palette, &presenter, 2);
    try std.testing.expectEqual(@intFromPtr(&second_display.framebuffer[0]), @intFromPtr(presenter.surface.indexedPixels().?.ptr));
    try std.testing.expectError(error.StaleGeneration, adapter.bind(&first_display, &palette, &presenter, 1));

    adapter.close();
    adapter.close();
    try std.testing.expectEqual(core.host_adapter.VideoState.closed, adapter.state);
    try std.testing.expect(!adapter.canPresent());
    try std.testing.expect(!adapter.syncVideo(&presenter));
    try std.testing.expectError(error.Closed, adapter.bind(&first_display, &palette, &presenter, 3));
}
