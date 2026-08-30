pub const Button = enum(u3) { right, left, up, down, a, b, select, start };

pub const Joypad = struct {
    select: u8 = 0x30,
    held: u8 = 0,

    pub fn read(self: *const Joypad) u8 {
        return 0xC0 | self.select | self.lines();
    }

    pub fn write(self: *Joypad, value: u8) bool {
        const old_lines = self.lines();
        self.select = value & 0x30;
        return fallingEdge(old_lines, self.lines());
    }

    pub fn set(self: *Joypad, button: Button, down: bool) bool {
        const old_lines = self.lines();
        const mask: u8 = @as(u8, 1) << @intFromEnum(button);
        if (down) self.held |= mask else self.held &= ~mask;
        return fallingEdge(old_lines, self.lines());
    }

    pub fn releaseAll(self: *Joypad) void {
        self.held = 0;
    }

    fn lines(self: *const Joypad) u8 {
        var result: u8 = 0x0F;
        if ((self.select & 0x10) == 0) result &= ~(self.held & 0x0F);
        if ((self.select & 0x20) == 0) result &= ~((self.held >> 4) & 0x0F);
        return result;
    }
};

fn fallingEdge(before: u8, after: u8) bool {
    return (before & ~after & 0x0F) != 0;
}

test "P1 combines selected rows and requests only selected falling edges" {
    const std = @import("std");
    var value = Joypad{};
    try std.testing.expect(!value.set(.right, true));
    try std.testing.expectEqual(@as(u8, 0xFF), value.read());
    try std.testing.expect(value.write(0x20));
    try std.testing.expectEqual(@as(u8, 0xEE), value.read());
    try std.testing.expect(!value.set(.right, true));
    try std.testing.expect(!value.set(.a, true));
    try std.testing.expect(value.write(0x00));
    try std.testing.expectEqual(@as(u8, 0xCE), value.read());
    value.releaseAll();
    try std.testing.expectEqual(@as(u8, 0xCF), value.read());
}
