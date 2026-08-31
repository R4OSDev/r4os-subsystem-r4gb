const std = @import("std");

pub const frequency_hz: u64 = 4_194_304;
pub const nanoseconds_per_second: u64 = 1_000_000_000;
pub const frame_t_cycles: u32 = 70_224;

/// Converts the monotonic, pause-corrected host time supplied by
/// r4os.subsystem_runtime into a bounded amount of Game Boy work. Host time
/// grants a cycle budget only; emulated devices never observe it directly.
pub const Clock = struct {
    last_host_nanoseconds: ?u64 = null,
    fractional_numerator: u64 = 0,
    pending_t_cycles: u64 = 0,
    ahead_t_cycles: u64 = 0,
    max_slice_t_cycles: u32 = frame_t_cycles,
    paused: bool = true,

    pub fn start(self: *Clock, host_nanoseconds: u64) void {
        self.last_host_nanoseconds = host_nanoseconds;
        self.paused = false;
    }

    pub fn pause(self: *Clock) void {
        self.last_host_nanoseconds = null;
        self.fractional_numerator = 0;
        self.pending_t_cycles = 0;
        self.ahead_t_cycles = 0;
        self.paused = true;
    }

    pub fn budget(self: *Clock, host_nanoseconds: u64) u32 {
        return self.budgetBounded(host_nanoseconds, self.max_slice_t_cycles);
    }

    /// Adds all elapsed guest work to a debt counter, but grants at most one
    /// bounded slice. Repeated calls at the same host timestamp drain debt
    /// without dropping time after a delayed host cycle.
    pub fn budgetBounded(self: *Clock, host_nanoseconds: u64, caller_limit: u32) u32 {
        if (self.paused) {
            self.start(host_nanoseconds);
            return 0;
        }
        const previous = self.last_host_nanoseconds orelse {
            self.last_host_nanoseconds = host_nanoseconds;
            return 0;
        };
        if (host_nanoseconds > previous) {
            self.last_host_nanoseconds = host_nanoseconds;
            const elapsed = host_nanoseconds - previous;
            const scaled: u128 = @as(u128, elapsed) * frequency_hz + self.fractional_numerator;
            const whole: u128 = scaled / nanoseconds_per_second;
            self.fractional_numerator = @intCast(scaled % nanoseconds_per_second);
            var newly_due: u64 = @intCast(@min(whole, std.math.maxInt(u64)));
            const covered = @min(newly_due, self.ahead_t_cycles);
            newly_due -= covered;
            self.ahead_t_cycles -= covered;
            self.pending_t_cycles +|= newly_due;
        }
        const limit = @min(caller_limit, self.max_slice_t_cycles);
        const granted: u32 = @intCast(@min(self.pending_t_cycles, limit));
        self.pending_t_cycles -= granted;
        return granted;
    }

    /// Reconciles the whole-instruction overshoot of the SM83 executor. The
    /// surplus becomes credit against the next elapsed-time grant, so slice
    /// boundaries cannot accumulate rate drift.
    pub fn reconcile(self: *Clock, granted: u32, executed: u32) void {
        if (executed < granted) {
            self.pending_t_cycles +|= granted - executed;
            return;
        }
        var surplus: u64 = executed - granted;
        const pending_covered = @min(surplus, self.pending_t_cycles);
        self.pending_t_cycles -= pending_covered;
        surplus -= pending_covered;
        self.ahead_t_cycles +|= surplus;
    }
};

test "host time translation is fractional, bounded and pause corrected" {
    var value = Clock{ .max_slice_t_cycles = 1000 };
    try std.testing.expectEqual(@as(u32, 0), value.budget(1_000));
    try std.testing.expectEqual(@as(u32, 4), value.budget(2_000));
    try std.testing.expectEqual(@as(u32, 1000), value.budget(1_000_002_000));
    try std.testing.expectEqual(@as(u32, 1000), value.budget(1_000_002_000));
    try std.testing.expect(value.pending_t_cycles > 4_000_000);
    value.reconcile(1000, 1004);
    try std.testing.expectEqual(@as(u64, 0), value.ahead_t_cycles);
    value.pause();
    try std.testing.expectEqual(@as(u32, 0), value.budget(9_000_000_000));
    try std.testing.expectEqual(@as(u32, 4), value.budget(9_000_001_000));
}
