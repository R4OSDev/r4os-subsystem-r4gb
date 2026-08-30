pub const save_root = "C:\\R4OS\\SUBSYSTEMS\\r4os.gb\\Save\\";

pub const Persistence = struct {
    dirty: bool = false,
    last_flush_guest_tick: u64 = 0,
    generation: u64 = 0,
};
