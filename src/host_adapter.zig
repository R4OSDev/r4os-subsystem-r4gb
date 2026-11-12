const r4os = @import("r4os");
const std = @import("std");
const joypad = @import("joypad.zig");
const interrupts = @import("interrupts.zig");
const ppu = @import("ppu.zig");

const video_host = r4os.subsystem_host;

pub fn copyBackend(draw: *const r4os.r4draw.Context) video_host.Backend {
    var backend = video_host.Backend.fromDraw(draw);
    // The shared bridge ends its source loan on synchronous copy return.
    // Retained shared-raster/GPU transports require a different receipt.
    backend.supports_shared_raster = false;
    return backend;
}

pub const physical_usage_up: u32 = 0x52;
pub const physical_usage_down: u32 = 0x51;
pub const physical_usage_left: u32 = 0x50;
pub const physical_usage_right: u32 = 0x4F;
pub const physical_usage_enter: u32 = 0x28;
pub const physical_usage_right_control: u32 = 0xE4;
pub const physical_usage_left_alt: u32 = 0xE2;
pub const physical_usage_space: u32 = 0x2C;

pub fn buttonForPhysicalUsage(usage: u32) ?joypad.Button {
    return switch (usage) {
        physical_usage_right => .right,
        physical_usage_left => .left,
        physical_usage_up => .up,
        physical_usage_down => .down,
        physical_usage_space => .a,
        physical_usage_left_alt => .b,
        physical_usage_right_control => .select,
        physical_usage_enter => .start,
        else => null,
    };
}

/// Four native DMG shades followed by unused black palette entries. The PPU
/// publishes shade indices, while scaling and letterboxing remain entirely in
/// `r4os.subsystem_host`.
pub fn initializeDmgPalette(palette: *[video_host.palette_entries]u32) void {
    @memset(palette, 0);
    palette[0] = 0x00FF_FFFF;
    palette[1] = 0x00AA_AAAA;
    palette[2] = 0x0055_5555;
    palette[3] = 0x0000_0000;
}

/// Generation-checked bridge between the private, complete PPU framebuffer
/// and the shared window presenter. The bridge never exposes `working_frame`.
pub const VideoAdapter = struct {
    source: ?*ppu.Ppu = null,
    palette: ?*[video_host.palette_entries]u32 = null,
    bridge: ?r4os.published_frame.Bridge = null,
    ended: bool = false,

    pub fn bind(
        self: *VideoAdapter,
        source: *ppu.Ppu,
        palette: *[video_host.palette_entries]u32,
        presenter: *video_host.Presenter,
        generation: u64,
        backend: video_host.Backend,
    ) !void {
        if (self.ended) return error.Closed;
        if (self.bridge == null) {
            var bridge: r4os.published_frame.Bridge = undefined;
            const rc = r4os.published_frame.Bridge.init(backend, presenter.scratch, &bridge);
            if (rc != 0) return error.UnsupportedPresentation;
            self.bridge = bridge;
        }
        const rc = self.bridge.?.bind(generation);
        if (rc == r4os.published_frame.stale_generation) return error.StaleGeneration;
        if (rc != 0) return error.Busy;
        initializeDmgPalette(palette);
        const surface = try video_host.Surface.initIndexed8(
            source.framebuffer[0..],
            palette[0..],
            ppu.width,
            ppu.height,
        );
        try presenter.setSurface(surface);
        self.source = source;
        self.palette = palette;
        _ = source.takeDamage();
    }

    /// Observation does not consume damage or extend a source loan. The
    /// actual complete-frame loan is acquired and released within presentTo.
    pub fn syncVideo(self: *VideoAdapter, presenter: *video_host.Presenter) bool {
        _ = presenter;
        if (!self.canPresent()) return false;
        const source = self.source orelse return false;
        return source.damage_pending;
    }

    pub fn invalidate(self: *VideoAdapter) void {
        if (self.bridge) |*bridge| bridge.presenter.invalidateAll();
    }

    pub fn presentTo(self: *VideoAdapter, presenter: *video_host.Presenter, width: i32, height: i32) video_host.PresentResult {
        const frame = r4os.published_frame;
        if (!self.canPresent()) return .{ .failure = frame.closed };
        const source = self.source.?;
        const bridge = &self.bridge.?;
        // Revision0 is the fully initialized reset/LCD-off image, not the
        // mutable working raster. Reserve revision1 for that complete image.
        const revision = std.math.add(u64, source.frame_revision, 1) catch return .{ .failure = frame.exhausted };
        var lease: frame.Lease = .{
            .pixels = .{ .address = @intFromPtr(&source.framebuffer), .length = source.framebuffer.len },
            .palette = .{ .address = @intFromPtr(self.palette.?), .length = @sizeOf(@TypeOf(self.palette.?.*)) },
            .binding_generation = bridge.generation,
            .revision = revision,
            .palette_revision = 1,
            .width = ppu.width,
            .height = ppu.height,
            .stride_bytes = ppu.width,
            .flags = frame.published,
        };
        if (bridge.revision != 0) {
            lease.damage_kind = frame.damage_none;
            lease.damage_base_revision = bridge.revision;
            if (source.damage_pending and revision != bridge.revision) {
                lease.damage_kind = frame.damage_rect;
                lease.damage = .{
                    .x = source.damage_min_x,
                    .y = source.damage_min_y,
                    .w = @as(u32, source.damage_max_x) - source.damage_min_x + 1,
                    .h = @as(u32, source.damage_max_y) - source.damage_min_y + 1,
                };
            }
        }
        var acquired: frame.Acquisition = undefined;
        const synced = bridge.syncPublished(lease, &acquired);
        if (synced != 0) return .{ .failure = synced };
        // No emulator step, reset or allocation release can occur while the
        // synchronous CPU-copy backend borrows these two immutable spans.
        defer {
            const retired = bridge.release(acquired.ticket);
            std.debug.assert(retired == 0);
        }
        _ = source.takeDamage();
        var result: frame.Presentation = undefined;
        const rc = bridge.present(acquired.ticket, width, height, &result);
        if (rc != 0) return .{ .failure = rc };
        // Host's presenter retains only the owned source view for input
        // geometry; all publication and damage state belongs to the Bridge.
        presenter.stats = bridge.presenter.stats;
        const viewport = video_host.Viewport{
            .x = result.viewport.x,
            .y = result.viewport.y,
            .w = result.viewport.width,
            .h = result.viewport.height,
            .guest_w = result.viewport.source_width,
            .guest_h = result.viewport.source_height,
            .integer_scale = result.viewport.integer_scale,
        };
        return switch (result.kind) {
            0 => .unchanged,
            1 => .hidden,
            2 => .{ .presented = .{ .mode = @enumFromInt(result.mode), .viewport = viewport,
                .damage_regions = result.damage_regions, .raster_blocks = result.raster_blocks,
                .sampled_pixels = result.sampled_pixels } },
            else => .{ .failure = result.error_code },
        };
    }

    pub fn pause(self: *VideoAdapter) void {
        if (self.bridge) |*bridge| _ = bridge.pause(true);
    }

    pub fn resumeRunning(self: *VideoAdapter) void {
        if (self.bridge) |*bridge| _ = bridge.pause(false);
    }

    pub fn close(self: *VideoAdapter) void {
        if (self.bridge) |*bridge| {
            const retired = bridge.close();
            std.debug.assert(retired == 0);
        }
        self.source = null;
        self.palette = null;
        self.ended = true;
    }

    pub fn canPresent(self: *const VideoAdapter) bool {
        return self.source != null and !self.ended;
    }
};

pub const HostAdapter = struct {
    focused: bool = false,
    input_events: u64 = 0,
    rejected_input_events: u64 = 0,
    last_host_tick: u64 = 0,

    pub fn focusGained(self: *HostAdapter) void {
        self.focused = true;
    }

    pub fn focusLost(self: *HostAdapter, pad: *joypad.Joypad) void {
        self.focused = false;
        pad.releaseAll();
    }

    pub fn physicalKey(
        self: *HostAdapter,
        pad: *joypad.Joypad,
        irq: *interrupts.Interrupts,
        usage: u32,
        down: bool,
        repeat: bool,
    ) bool {
        if (!self.focused) {
            self.rejected_input_events += 1;
            return false;
        }
        const button = buttonForPhysicalUsage(usage) orelse {
            self.rejected_input_events += 1;
            return false;
        };
        if (repeat and down) return true;
        self.input_events += 1;
        if (pad.set(button, down)) irq.requestBit(4);
        return true;
    }
};

test "canonical keyboard mapping distinguishes modifier sides" {
    try std.testing.expectEqual(joypad.Button.select, buttonForPhysicalUsage(physical_usage_right_control).?);
    try std.testing.expect(buttonForPhysicalUsage(0xE0) == null);
    try std.testing.expectEqual(joypad.Button.b, buttonForPhysicalUsage(physical_usage_left_alt).?);
    try std.testing.expect(buttonForPhysicalUsage(0xE6) == null);
}
