const r4os = @import("r4os");
const joypad = @import("joypad.zig");
const interrupts = @import("interrupts.zig");
const ppu = @import("ppu.zig");

const video_host = r4os.subsystem_host;

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

pub const VideoState = enum {
    unbound,
    running,
    paused,
    closed,
};

/// Generation-checked bridge between the private, complete PPU framebuffer
/// and the shared window presenter. The bridge never exposes `working_frame`.
pub const VideoAdapter = struct {
    source: ?*ppu.Ppu = null,
    generation: u64 = 0,
    observed_revision: u64 = 0,
    state: VideoState = .unbound,

    pub fn bind(
        self: *VideoAdapter,
        source: *ppu.Ppu,
        palette: *[video_host.palette_entries]u32,
        presenter: *video_host.Presenter,
        generation: u64,
    ) !void {
        if (self.state == .closed) return error.Closed;
        if (generation == 0 or generation <= self.generation) return error.StaleGeneration;
        initializeDmgPalette(palette);
        const surface = try video_host.Surface.initIndexed8(
            source.framebuffer[0..],
            palette[0..],
            ppu.width,
            ppu.height,
        );
        try presenter.setSurface(surface);
        self.source = source;
        self.generation = generation;
        self.observed_revision = source.frame_revision;
        self.state = .running;
        _ = source.takeDamage();
    }

    /// Transfers only damage belonging to a completely published frame.
    /// Pausing does not discard a frame that became complete before the pause.
    pub fn syncVideo(self: *VideoAdapter, presenter: *video_host.Presenter) bool {
        if (!self.canPresent()) return false;
        const source = self.source orelse return false;
        const damage = source.takeDamage() orelse return false;
        if (damage.revision <= self.observed_revision) return false;
        presenter.invalidate(.{
            .x = damage.x,
            .y = damage.y,
            .w = damage.width,
            .h = damage.height,
        });
        self.observed_revision = damage.revision;
        return true;
    }

    pub fn pause(self: *VideoAdapter) void {
        if (self.state == .running) self.state = .paused;
    }

    pub fn resumeRunning(self: *VideoAdapter) void {
        if (self.state == .paused) self.state = .running;
    }

    pub fn close(self: *VideoAdapter) void {
        self.source = null;
        self.state = .closed;
    }

    pub fn canPresent(self: *const VideoAdapter) bool {
        return self.source != null and (self.state == .running or self.state == .paused);
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
    const std = @import("std");
    try std.testing.expectEqual(joypad.Button.select, buttonForPhysicalUsage(physical_usage_right_control).?);
    try std.testing.expect(buttonForPhysicalUsage(0xE0) == null);
    try std.testing.expectEqual(joypad.Button.b, buttonForPhysicalUsage(physical_usage_left_alt).?);
    try std.testing.expect(buttonForPhysicalUsage(0xE6) == null);
}
