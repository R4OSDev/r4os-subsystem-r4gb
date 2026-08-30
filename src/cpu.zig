const model = @import("model.zig");

pub const Cpu = struct {
    registers: model.Registers,
    ime: bool = false,
    ime_enable_pending: bool = false,
    halted: bool = false,
    stopped: bool = false,
    halt_bug: bool = false,
    t_cycles: u64 = 0,

    pub fn init(profile: model.Profile) Cpu {
        return .{ .registers = profile.registers };
    }
};
