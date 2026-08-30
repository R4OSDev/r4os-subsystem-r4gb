pub const Interrupts = struct {
    request: u8 = 0xE1,
    enable: u8 = 0,

    pub fn pending(self: *const Interrupts) u8 {
        return self.request & self.enable & 0x1F;
    }
};
