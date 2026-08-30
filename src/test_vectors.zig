const std = @import("std");
const cpu = @import("cpu.zig");
const model = @import("model.zig");

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
    TooManyCycles,
    UnexpectedExecutionState,
    CpuStateMismatch,
    PendingEiMismatch,
    RamMismatch,
    CycleCountMismatch,
    CycleMismatch,
};

const LoggedCycle = struct {
    address: u16,
    value: u8,
    kind: cpu.CycleKind,
};

const max_instruction_cycles: usize = 16;

const VectorMemory = struct {
    values: [65536]u8 = .{0} ** 65536,
    stamps: [65536]u16 = .{0} ** 65536,
    generation: u16 = 0,
    cycles: [max_instruction_cycles]LoggedCycle = undefined,
    cycle_count: usize = 0,
    overflow: bool = false,

    fn begin(self: *VectorMemory) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(&self.stamps, 0);
            self.generation = 1;
        }
        self.cycle_count = 0;
        self.overflow = false;
    }

    fn set(self: *VectorMemory, address: u16, value: u8) void {
        self.values[address] = value;
        self.stamps[address] = self.generation;
    }

    fn get(self: *const VectorMemory, address: u16) u8 {
        return if (self.stamps[address] == self.generation) self.values[address] else 0;
    }

    fn append(self: *VectorMemory, event: LoggedCycle) void {
        if (self.cycle_count >= self.cycles.len) {
            self.overflow = true;
            return;
        }
        self.cycles[self.cycle_count] = event;
        self.cycle_count += 1;
    }

    fn read(context: *anyopaque, address: u16) u8 {
        const self: *VectorMemory = @ptrCast(@alignCast(context));
        const value = self.get(address);
        self.append(.{ .address = address, .value = value, .kind = .read });
        return value;
    }

    fn write(context: *anyopaque, address: u16, value: u8) void {
        const self: *VectorMemory = @ptrCast(@alignCast(context));
        self.set(address, value);
        self.append(.{ .address = address, .value = value, .kind = .write });
    }

    fn idle(context: *anyopaque, address: u16, value: u8) void {
        const self: *VectorMemory = @ptrCast(@alignCast(context));
        self.append(.{ .address = address, .value = value, .kind = .idle });
    }

    fn bus(self: *VectorMemory) cpu.Bus {
        return .{
            .context = self,
            .read_fn = read,
            .write_fn = write,
            .idle_fn = idle,
        };
    }
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
        const cycles = try cycleItems(object.get("cycles") orelse return error.MissingCycles);
        cycle_records += cycles.len;
    }
    return .{ .vectors = values.len, .cycle_records = cycle_records };
}

pub fn executeJson(allocator: std.mem.Allocator, bytes: []const u8) !Validation {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const values = switch (parsed.value) {
        .array => |value| value.items,
        else => return error.RootNotArray,
    };
    const memory = try allocator.create(VectorMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    var cycle_records: usize = 0;
    for (values) |value| {
        const object = switch (value) {
            .object => |entry| entry,
            else => return error.VectorNotObject,
        };
        const name = switch (object.get("name") orelse return error.MissingName) {
            .string => |entry| entry,
            else => return error.MissingName,
        };
        const initial = object.get("initial") orelse return error.MissingInitial;
        const final = object.get("final") orelse return error.MissingFinal;
        const expected_cycles = try cycleItems(object.get("cycles") orelse return error.MissingCycles);
        memory.begin();
        try loadRam(memory, initial);
        var processor = CpuFromState(initial) catch return error.InvalidState;
        const result = processor.step(memory.bus(), 0);
        if (result.kind != .instruction) {
            std.debug.print("R4GB SM83 mismatch {s}: execution state={s}\n", .{ name, @tagName(result.kind) });
            return error.UnexpectedExecutionState;
        }
        if (memory.overflow) {
            std.debug.print("R4GB SM83 mismatch {s}: cycle log overflow\n", .{name});
            return error.TooManyCycles;
        }
        try compareState(name, &processor, final);
        try compareRam(name, memory, final);
        try compareCycles(name, memory, expected_cycles);
        cycle_records += expected_cycles.len;
    }
    return .{ .vectors = values.len, .cycle_records = cycle_records };
}

fn CpuFromState(value: std.json.Value) Error!cpu.Cpu {
    const registers = try registersFromState(value);
    const object = switch (value) {
        .object => |entry| entry,
        else => return error.InvalidState,
    };
    return .{
        .registers = registers,
        .ime = (try integerField(object, "ime")) != 0,
    };
}

fn registersFromState(value: std.json.Value) Error!model.Registers {
    const object = switch (value) {
        .object => |entry| entry,
        else => return error.InvalidState,
    };
    return .{
        .a = try u8Field(object, "a"),
        .f = try u8Field(object, "f"),
        .b = try u8Field(object, "b"),
        .c = try u8Field(object, "c"),
        .d = try u8Field(object, "d"),
        .e = try u8Field(object, "e"),
        .h = try u8Field(object, "h"),
        .l = try u8Field(object, "l"),
        .sp = try u16Field(object, "sp"),
        .pc = try u16Field(object, "pc"),
    };
}

fn compareState(name: []const u8, processor: *const cpu.Cpu, value: std.json.Value) Error!void {
    const expected = try registersFromState(value);
    const object = switch (value) {
        .object => |entry| entry,
        else => return error.InvalidState,
    };
    if (!std.meta.eql(processor.registers, expected) or processor.ime != ((try integerField(object, "ime")) != 0)) {
        std.debug.print(
            "R4GB SM83 mismatch {s}: CPU expected A={x:0>2} F={x:0>2} BC={x:0>2}{x:0>2} DE={x:0>2}{x:0>2} HL={x:0>2}{x:0>2} SP={x:0>4} PC={x:0>4} IME={} got A={x:0>2} F={x:0>2} BC={x:0>2}{x:0>2} DE={x:0>2}{x:0>2} HL={x:0>2}{x:0>2} SP={x:0>4} PC={x:0>4} IME={}\n",
            .{
                name,
                expected.a,
                expected.f,
                expected.b,
                expected.c,
                expected.d,
                expected.e,
                expected.h,
                expected.l,
                expected.sp,
                expected.pc,
                (try integerField(object, "ime")) != 0,
                processor.registers.a,
                processor.registers.f,
                processor.registers.b,
                processor.registers.c,
                processor.registers.d,
                processor.registers.e,
                processor.registers.h,
                processor.registers.l,
                processor.registers.sp,
                processor.registers.pc,
                processor.ime,
            },
        );
        return error.CpuStateMismatch;
    }
    const expected_ei = if (object.get("ei")) |entry| switch (entry) {
        .integer => |number| number != 0,
        else => return error.InvalidState,
    } else false;
    if (processor.ime_enable_pending != expected_ei) {
        std.debug.print("R4GB SM83 mismatch {s}: pending EI expected={} got={}\n", .{ name, expected_ei, processor.ime_enable_pending });
        return error.PendingEiMismatch;
    }
}

fn loadRam(memory: *VectorMemory, value: std.json.Value) Error!void {
    const cells = try ramItems(value);
    for (cells) |cell| {
        const pair = switch (cell) {
            .array => |entry| entry.items,
            else => return error.InvalidRam,
        };
        if (pair.len != 2) return error.InvalidRam;
        memory.set(try valueU16(pair[0]), try valueU8(pair[1]));
    }
}

fn compareRam(name: []const u8, memory: *const VectorMemory, value: std.json.Value) Error!void {
    const cells = try ramItems(value);
    for (cells) |cell| {
        const pair = switch (cell) {
            .array => |entry| entry.items,
            else => return error.InvalidRam,
        };
        if (pair.len != 2) return error.InvalidRam;
        const address = try valueU16(pair[0]);
        const expected = try valueU8(pair[1]);
        const actual = memory.get(address);
        if (actual != expected) {
            std.debug.print("R4GB SM83 mismatch {s}: RAM[{x:0>4}] expected={x:0>2} got={x:0>2}\n", .{ name, address, expected, actual });
            return error.RamMismatch;
        }
    }
}

fn compareCycles(name: []const u8, memory: *const VectorMemory, expected: []const std.json.Value) Error!void {
    if (memory.cycle_count != expected.len) {
        std.debug.print("R4GB SM83 mismatch {s}: cycles expected={d} got={d}\n", .{ name, expected.len, memory.cycle_count });
        return error.CycleCountMismatch;
    }
    for (expected, 0..) |value, index| {
        const fields = switch (value) {
            .array => |entry| entry.items,
            else => return error.InvalidCycles,
        };
        if (fields.len != 3) return error.InvalidCycles;
        const expected_address = try valueU16(fields[0]);
        const expected_value = try valueU8(fields[1]);
        const expected_kind: cpu.CycleKind = switch (fields[2]) {
            .string => |text| if (std.mem.eql(u8, text, "r-m"))
                .read
            else if (std.mem.eql(u8, text, "-wm"))
                .write
            else if (std.mem.eql(u8, text, "---"))
                .idle
            else
                return error.InvalidCycles,
            else => return error.InvalidCycles,
        };
        const actual = memory.cycles[index];
        if (actual.address != expected_address or actual.value != expected_value or actual.kind != expected_kind) {
            std.debug.print(
                "R4GB SM83 mismatch {s}: cycle {d} expected {x:0>4}:{x:0>2}:{s} got {x:0>4}:{x:0>2}:{s}\n",
                .{ name, index, expected_address, expected_value, @tagName(expected_kind), actual.address, actual.value, @tagName(actual.kind) },
            );
            return error.CycleMismatch;
        }
    }
}

fn validateState(value: std.json.Value) Error!void {
    _ = try registersFromState(value);
    const object = switch (value) {
        .object => |entry| entry,
        else => return error.InvalidState,
    };
    _ = try integerField(object, "ime");
    _ = try ramItems(value);
}

fn cycleItems(value: std.json.Value) Error![]const std.json.Value {
    const cycles = switch (value) {
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
    return cycles;
}

fn ramItems(value: std.json.Value) Error![]const std.json.Value {
    const object = switch (value) {
        .object => |entry| entry,
        else => return error.InvalidState,
    };
    const cells = switch (object.get("ram") orelse return error.InvalidRam) {
        .array => |entry| entry.items,
        else => return error.InvalidRam,
    };
    for (cells) |cell| {
        const pair = switch (cell) {
            .array => |entry| entry.items,
            else => return error.InvalidRam,
        };
        if (pair.len != 2 or pair[0] != .integer or pair[1] != .integer) return error.InvalidRam;
    }
    return cells;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) Error!i64 {
    return switch (object.get(name) orelse return error.InvalidState) {
        .integer => |value| value,
        else => error.InvalidState,
    };
}

fn u8Field(object: std.json.ObjectMap, name: []const u8) Error!u8 {
    return std.math.cast(u8, try integerField(object, name)) orelse error.InvalidState;
}

fn u16Field(object: std.json.ObjectMap, name: []const u8) Error!u16 {
    return std.math.cast(u16, try integerField(object, name)) orelse error.InvalidState;
}

fn valueU8(value: std.json.Value) Error!u8 {
    return switch (value) {
        .integer => |number| std.math.cast(u8, number) orelse error.InvalidCycles,
        else => error.InvalidCycles,
    };
}

fn valueU16(value: std.json.Value) Error!u16 {
    return switch (value) {
        .integer => |number| std.math.cast(u16, number) orelse error.InvalidCycles,
        else => error.InvalidCycles,
    };
}

test "small original SM83 fixture validates and executes" {
    const fixture =
        \\[{"name":"00 0000","initial":{"pc":256,"sp":65534,"a":1,"b":0,"c":19,"d":0,"e":216,"f":176,"h":1,"l":77,"ime":0,"ram":[[256,0]]},"final":{"pc":257,"sp":65534,"a":1,"b":0,"c":19,"d":0,"e":216,"f":176,"h":1,"l":77,"ime":0,"ram":[[256,0]]},"cycles":[[256,0,"r-m"]]}]
    ;
    const validation = try validateJson(std.testing.allocator, fixture);
    try std.testing.expectEqual(@as(usize, 1), validation.vectors);
    const execution = try executeJson(std.testing.allocator, fixture);
    try std.testing.expectEqual(@as(usize, 1), execution.vectors);
    try std.testing.expectEqual(@as(usize, 1), execution.cycle_records);
}
