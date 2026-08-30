pub const Serial = struct {
    data: u8 = 0,
    control: u8 = 0x7E,
    bits_remaining: u4 = 0,
    master_clock: bool = false,

    pub fn readControl(self: *const Serial) u8 {
        return self.control | 0x7E;
    }

    pub fn writeControl(self: *Serial, value: u8) void {
        // A control write brings an already-high internal serial clock back to
        // its low phase before arming the transfer (observable on DMG ABC).
        if (self.master_clock) self.master_clock = false;
        self.control = (value & 0x81) | 0x7E;
        self.bits_remaining = if ((value & 0x80) != 0) 8 else 0;
    }

    /// DMG internal serial clock is divided from the shared system counter.
    /// A disconnected partner supplies pulled-up one bits and never blocks.
    pub fn tick(self: *Serial, old_divider: u16, new_divider: u16) bool {
        if ((old_divider & 0x0080) == 0 or (new_divider & 0x0080) != 0) return false;
        self.master_clock = !self.master_clock;
        if (self.master_clock or (self.control & 0x81) != 0x81) return false;
        self.data = (self.data << 1) | 1;
        self.bits_remaining -= 1;
        if (self.bits_remaining != 0) return false;
        self.control &= ~@as(u8, 0x80);
        return true;
    }
};

test "internal serial transfer is aligned, bounded and receives FF" {
    const std = @import("std");
    var value = Serial{ .data = 0x00 };
    value.writeControl(0x81);
    var divider: u16 = 0;
    var index: usize = 0;
    while (index < 4095) : (index += 1) {
        const old = divider;
        divider +%= 1;
        try std.testing.expect(!value.tick(old, divider));
    }
    const old = divider;
    divider +%= 1;
    try std.testing.expect(value.tick(old, divider));
    try std.testing.expectEqual(@as(u8, 0xFF), value.data);
    try std.testing.expectEqual(@as(u8, 0), value.readControl() & 0x80);

    value.writeControl(0x80);
    index = 0;
    while (index < 8192) : (index += 1) {
        const previous = divider;
        divider +%= 1;
        try std.testing.expect(!value.tick(previous, divider));
    }
    try std.testing.expectEqual(@as(u8, 0x80), value.readControl() & 0x80);
}
