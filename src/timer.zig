pub const Timer = struct {
    divider_counter: u16 = 0,
    tima: u8 = 0,
    tma: u8 = 0,
    tac: u8 = 0,
    reload_delay: u8 = 0,
    reload_write_window: u8 = 0,

    pub fn init(divider_counter: u16, tima: u8, tma: u8, tac: u8) Timer {
        return .{
            .divider_counter = divider_counter,
            .tima = tima,
            .tma = tma,
            .tac = tac & 0x07,
        };
    }

    pub fn readDiv(self: *const Timer) u8 {
        return @truncate(self.divider_counter >> 8);
    }

    pub fn readTac(self: *const Timer) u8 {
        return self.tac | 0xF8;
    }

    /// Advances one 4.194304 MHz T-cycle and reports a TIMA reload/IRQ edge.
    pub fn tick(self: *Timer) bool {
        if (self.reload_write_window != 0) self.reload_write_window -= 1;
        var request_interrupt = false;
        if (self.reload_delay != 0) {
            self.reload_delay -= 1;
            if (self.reload_delay == 0) {
                self.tima = self.tma;
                self.reload_write_window = 4;
                request_interrupt = true;
            }
        }

        const old_signal = self.inputSignal();
        self.divider_counter +%= 1;
        const new_signal = self.inputSignal();
        if (old_signal and !new_signal) self.incrementTima();
        return request_interrupt;
    }

    pub fn writeDiv(self: *Timer) void {
        const old_signal = self.inputSignal();
        self.divider_counter = 0;
        if (old_signal and !self.inputSignal()) self.incrementTima();
    }

    pub fn writeTima(self: *Timer, value: u8) void {
        if (self.reload_write_window != 0) return;
        self.tima = value;
        self.reload_delay = 0;
    }

    pub fn writeTma(self: *Timer, value: u8) void {
        self.tma = value;
        if (self.reload_write_window != 0) self.tima = value;
    }

    pub fn writeTac(self: *Timer, value: u8) void {
        const old_signal = self.inputSignal();
        self.tac = value & 0x07;
        if (old_signal and !self.inputSignal()) self.incrementTima();
    }

    fn inputSignal(self: *const Timer) bool {
        if ((self.tac & 0x04) == 0) return false;
        const bit: u4 = switch (self.tac & 0x03) {
            0 => 9,
            1 => 3,
            2 => 5,
            3 => 7,
            else => unreachable,
        };
        return (self.divider_counter & (@as(u16, 1) << bit)) != 0;
    }

    fn incrementTima(self: *Timer) void {
        // Falling edges during the four-cycle overflow pipeline are ignored.
        if (self.reload_delay != 0) return;
        self.tima +%= 1;
        if (self.tima == 0) self.reload_delay = 4;
    }
};

test "falling edges, DIV and TAC writes use the same timer input" {
    const std = @import("std");
    var value = Timer.init(0, 4, 0, 0x05);
    var count: usize = 0;
    while (count < 16) : (count += 1) _ = value.tick();
    try std.testing.expectEqual(@as(u8, 5), value.tima);
    value.divider_counter = 8;
    value.writeDiv();
    try std.testing.expectEqual(@as(u8, 6), value.tima);
    value.divider_counter = 0x0200;
    value.writeTac(0);
    try std.testing.expectEqual(@as(u8, 7), value.tima);
}

test "overflow exposes zero then reloads and can be cancelled" {
    const std = @import("std");
    var value = Timer.init(15, 0xFF, 0x42, 0x05);
    try std.testing.expect(!value.tick());
    try std.testing.expectEqual(@as(u8, 0), value.tima);
    try std.testing.expectEqual(@as(u8, 4), value.reload_delay);
    try std.testing.expect(!value.tick());
    try std.testing.expect(!value.tick());
    try std.testing.expect(!value.tick());
    try std.testing.expect(value.tick());
    try std.testing.expectEqual(@as(u8, 0x42), value.tima);

    value = Timer.init(15, 0xFF, 0x42, 0x05);
    _ = value.tick();
    value.writeTima(0x77);
    var index: usize = 0;
    while (index < 8) : (index += 1) try std.testing.expect(!value.tick());
    try std.testing.expectEqual(@as(u8, 0x77), value.tima);
}
