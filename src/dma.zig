pub const Dma = struct {
    active: bool = false,
    source_high: u8 = 0,
    byte_index: u8 = 0,
    startup_t_cycles: u8 = 0,
    phase: u8 = 0,
};
