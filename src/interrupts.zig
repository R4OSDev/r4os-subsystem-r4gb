pub const Interrupts = struct {
    request: u8 = 0x01,
    enable: u8 = 0,

    pub fn pending(self: *const Interrupts) u8 {
        return self.request & self.enable & 0x1F;
    }

    pub fn readRequest(self: *const Interrupts) u8 {
        return self.request | 0xE0;
    }

    pub fn writeRequest(self: *Interrupts, value: u8) void {
        self.request = value & 0x1F;
    }

    pub fn requestBit(self: *Interrupts, bit: u3) void {
        self.request |= @as(u8, 1) << bit;
    }

    pub fn acknowledge(self: *Interrupts, bit: u3) void {
        self.request &= ~(@as(u8, 1) << bit);
    }

    pub fn priority(self: *const Interrupts) ?u3 {
        const value = self.pending();
        return if (value == 0) null else @intCast(@ctz(value));
    }
};

test "IF masks unused bits and priority is lowest pending bit" {
    const std = @import("std");
    var value = Interrupts{};
    value.writeRequest(0xFF);
    value.enable = 0x1A;
    try std.testing.expectEqual(@as(u8, 0xFF), value.readRequest());
    try std.testing.expectEqual(@as(?u3, 1), value.priority());
    value.acknowledge(1);
    try std.testing.expectEqual(@as(?u3, 3), value.priority());
}
