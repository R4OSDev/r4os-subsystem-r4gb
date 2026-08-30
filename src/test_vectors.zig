const std = @import("std");

pub const Validation = struct {
    vectors: usize,
    cycle_records: usize,
};

pub const Error = error{
    RootNotArray,
    VectorNotObject,
    MissingName,
    MissingInitial,
    MissingFinal,
    MissingCycles,
    InvalidState,
    InvalidRam,
    InvalidCycles,
};

pub fn validateJson(allocator: std.mem.Allocator, bytes: []const u8) !Validation {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const values = switch (parsed.value) {
        .array => |value| value.items,
        else => return error.RootNotArray,
    };
    var cycle_records: usize = 0;
    for (values) |value| {
        const object = switch (value) {
            .object => |entry| entry,
            else => return error.VectorNotObject,
        };
        if (object.get("name") == null or object.get("name").? != .string) return error.MissingName;
        try validateState(object.get("initial") orelse return error.MissingInitial);
        try validateState(object.get("final") orelse return error.MissingFinal);
        const cycles = switch (object.get("cycles") orelse return error.MissingCycles) {
            .array => |entry| entry.items,
            else => return error.InvalidCycles,
        };
        for (cycles) |cycle| {
            const fields = switch (cycle) {
                .array => |entry| entry.items,
                else => return error.InvalidCycles,
            };
            if (fields.len != 3 or fields[0] != .integer or fields[1] != .integer or fields[2] != .string) return error.InvalidCycles;
        }
        cycle_records += cycles.len;
    }
    return .{ .vectors = values.len, .cycle_records = cycle_records };
}

fn validateState(value: std.json.Value) Error!void {
    const object = switch (value) {
        .object => |entry| entry,
        else => return error.InvalidState,
    };
    const fields = [_][]const u8{ "pc", "sp", "a", "b", "c", "d", "e", "f", "h", "l", "ime" };
    for (fields) |name| if (object.get(name) == null or object.get(name).? != .integer) return error.InvalidState;
    const ram = switch (object.get("ram") orelse return error.InvalidRam) {
        .array => |entry| entry.items,
        else => return error.InvalidRam,
    };
    for (ram) |cell| {
        const pair = switch (cell) {
            .array => |entry| entry.items,
            else => return error.InvalidRam,
        };
        if (pair.len != 2 or pair[0] != .integer or pair[1] != .integer) return error.InvalidRam;
    }
}

test "small original SM83 fixture validates" {
    const fixture =
        \\[{"name":"00 0000","initial":{"pc":256,"sp":65534,"a":1,"b":0,"c":19,"d":0,"e":216,"f":176,"h":1,"l":77,"ime":0,"ram":[[256,0]]},"final":{"pc":257,"sp":65534,"a":1,"b":0,"c":19,"d":0,"e":216,"f":176,"h":1,"l":77,"ime":0,"ram":[[256,0]]},"cycles":[[256,0,"r-m"]]}]
    ;
    const result = try validateJson(std.testing.allocator, fixture);
    try std.testing.expectEqual(@as(usize, 1), result.vectors);
    try std.testing.expectEqual(@as(usize, 1), result.cycle_records);
}
