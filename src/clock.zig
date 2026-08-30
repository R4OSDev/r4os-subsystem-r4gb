pub const frequency_hz: u64 = 4_194_304;
pub const nanoseconds_per_second: u64 = 1_000_000_000;
pub const frame_t_cycles: u32 = 70_224;

/// Converts the monotonic, pause-corrected host time supplied by
/// r4os.subsystem_runtime into a bounded amount of Game Boy work. Host time
/// grants a cycle budget only; emulated devices never observe it directly.
pub const Clock = struct {
    last_host_nanoseconds: ?u64 = null,
    fractional_numerator: u64 = 0,
    max_slice_t_cycles: u32 = frame_t_cycles,
    paused: bool = true,

    pub fn start(self: *Clock, host_nanoseconds: u64) void {
        self.last_host_nanoseconds = host_nanoseconds;
        self.paused = false;
    }

    pub fn pause(self: *Clock) void {
        self.last_host_nanoseconds = null;
        self.fractional_numerator = 0;
        self.paused = true;
    }

    pub fn budget(self: *Clock, host_nanoseconds: u64) u32 {
        if (self.paused) {
            self.start(host_nanoseconds);
            return 0;
        }
        const previous = self.last_host_nanoseconds orelse {
            self.last_host_nanoseconds = host_nanoseconds;
            return 0;
        };
        self.last_host_nanoseconds = host_nanoseconds;
        if (host_nanoseconds <= previous) return 0;

        const elapsed = host_nanoseconds - previous;
        const scaled: u128 = @as(u128, elapsed) * frequency_hz + self.fractional_numerator;
        const whole: u128 = scaled / nanoseconds_per_second;
        self.fractional_numerator = @intCast(scaled % nanoseconds_per_second);
        return @intCast(@min(whole, self.max_slice_t_cycles));
    }
};

test "host time translation is fractional, bounded and pause corrected" {
    const std = @import("std");
    var value = Clock{ .max_slice_t_cycles = 1000 };
    try std.testing.expectEqual(@as(u32, 0), value.budget(1_000));
    try std.testing.expectEqual(@as(u32, 4), value.budget(2_000));
    try std.testing.expectEqual(@as(u32, 1000), value.budget(1_000_002_000));
    value.pause();
    try std.testing.expectEqual(@as(u32, 0), value.budget(9_000_000_000));
    try std.testing.expectEqual(@as(u32, 4), value.budget(9_000_001_000));
}
