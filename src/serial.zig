pub const Serial = struct {
    data: u8 = 0,
    control: u8 = 0x7E,
    bits_remaining: u4 = 0,
    clock_t_cycles: u16 = 0,
};
