pub const Apu = struct {
    registers: [0x30]u8 = .{0} ** 0x30,
    frame_sequencer_step: u3 = 0,
    frame_sequencer_counter: u16 = 0,
    sample_phase: u64 = 0,
};
