const joypad = @import("joypad.zig");
const interrupts = @import("interrupts.zig");

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
