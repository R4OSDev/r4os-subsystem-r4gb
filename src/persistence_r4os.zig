const r4os = @import("r4os");
const persistence = @import("persistence.zig");

const Config = struct {
    pub const save_root = persistence.save_root;
    pub const root_directories = [_][]const u8{
        "C:\\R4OS\\SUBSYSTEMS",
        "C:\\R4OS\\SUBSYSTEMS\\r4os.gb",
        "C:\\R4OS\\SUBSYSTEMS\\r4os.gb\\SAVE",
    };
    pub const rtc_record_bytes = persistence.rtc_record_bytes;

    pub fn validateRtc(bytes: []const u8) bool {
        _ = persistence.decodeRtc(bytes) catch return false;
        return true;
    }
};

const engine = r4os.subsystem_persistence.R4osStore(Config);

pub const FailureStage = engine.FailureStage;
pub const RecoveryTestState = engine.RecoveryTestState;
pub const Store = engine.Store;
pub const AsyncStats = engine.AsyncStats;
pub const AsyncStore = engine.AsyncStore;
pub const dataPath = engine.dataPath;
pub const wallSeconds = engine.wallSeconds;

test {
    _ = engine;
}
