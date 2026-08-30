pub const Button = enum(u3) { right, left, up, down, a, b, select, start };

pub const Joypad = struct {
    select: u8 = 0x30,
    held: u8 = 0,

    pub fn set(self: *Joypad, button: Button, down: bool) void {
        const mask: u8 = @as(u8, 1) << @intFromEnum(button);
        if (down) self.held |= mask else self.held &= ~mask;
    }
};
