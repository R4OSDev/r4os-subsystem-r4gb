pub const Dma = struct {
    active: bool = false,
    pending: bool = false,
    source_high: u8 = 0,
    active_source_high: u8 = 0,
    byte_index: u8 = 0,
    startup_t_cycles: u8 = 0,
    phase: u8 = 0,

    pub fn start(self: *Dma, source_high: u8) void {
        self.source_high = source_high;
        self.pending = true;
        self.startup_t_cycles = 8;
    }

    /// Advances one T-cycle. The returned address is copied to the current
    /// OAM byte by the owning machine, which keeps all bus ownership local.
    pub fn tick(self: *Dma) ?u16 {
        var source: ?u16 = null;
        if (self.active) {
            self.phase += 1;
            if (self.phase == 4) {
                self.phase = 0;
                source = (@as(u16, self.active_source_high) << 8) | self.byte_index;
                if (self.byte_index == 0x9F) {
                    self.active = false;
                } else {
                    self.byte_index += 1;
                }
            }
        }

        if (self.pending) {
            self.startup_t_cycles -= 1;
            if (self.startup_t_cycles == 0) {
                self.pending = false;
                self.active = true;
                self.active_source_high = self.source_high;
                self.byte_index = 0;
                self.phase = 0;
            }
        }
        return source;
    }
};

test "DMA starts after two M-cycles, copies 160 bytes and restarts" {
    const std = @import("std");
    var value = Dma{};
    value.start(0x80);
    var index: usize = 0;
    while (index < 7) : (index += 1) try std.testing.expect(value.tick() == null);
    try std.testing.expect(!value.active);
    _ = value.tick();
    try std.testing.expect(value.active);
    index = 0;
    while (index < 3) : (index += 1) try std.testing.expect(value.tick() == null);
    try std.testing.expectEqual(@as(?u16, 0x8000), value.tick());
    value.start(0x90);
    index = 0;
    while (index < 8) : (index += 1) _ = value.tick();
    try std.testing.expectEqual(@as(u8, 0x90), value.active_source_high);
    try std.testing.expectEqual(@as(u8, 0), value.byte_index);
}
