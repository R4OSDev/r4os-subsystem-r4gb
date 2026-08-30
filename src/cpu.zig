const model = @import("model.zig");

pub const flag_z: u8 = 0x80;
pub const flag_n: u8 = 0x40;
pub const flag_h: u8 = 0x20;
pub const flag_c: u8 = 0x10;

pub const CycleKind = enum { read, write, idle };

pub const Bus = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, u16) u8,
    write_fn: *const fn (*anyopaque, u16, u8) void,
    idle_fn: *const fn (*anyopaque, u16, u8) void,
    pending_interrupts_fn: ?*const fn (*anyopaque) u8 = null,
    acknowledge_interrupt_fn: ?*const fn (*anyopaque, u3) void = null,
};

pub const ExecutionKind = enum {
    instruction,
    interrupt,
    halted,
    stopped,
    illegal,
};

pub const StepResult = struct {
    kind: ExecutionKind,
    opcode: u8 = 0,
    cb_opcode: ?u8 = null,
    interrupt_bit: ?u3 = null,
    m_cycles: u8,
};

pub const Cpu = struct {
    registers: model.Registers,
    ime: bool = false,
    ime_enable_pending: bool = false,
    halted: bool = false,
    stopped: bool = false,
    stop_wake_requested: bool = false,
    halt_bug: bool = false,
    locked: bool = false,
    illegal_opcode: ?u8 = null,
    t_cycles: u64 = 0,
    last_bus_address: u16 = 0,
    last_bus_value: u8 = 0xFF,

    pub fn init(profile: model.Profile) Cpu {
        var registers = profile.registers;
        registers.f &= 0xF0;
        return .{ .registers = registers };
    }

    pub fn step(self: *Cpu, bus: Bus, pending_interrupts: u8) StepResult {
        const before = self.t_cycles;
        self.registers.f &= 0xF0;
        if (self.locked) {
            self.idle(bus);
            return self.makeResult(.illegal, self.illegal_opcode orelse 0, null, null, before);
        }

        const pending = pending_interrupts & 0x1F;
        if (self.stopped) {
            if (pending == 0 and !self.stop_wake_requested) {
                self.idle(bus);
                return self.makeResult(.stopped, 0x10, null, null, before);
            }
            self.stop_wake_requested = false;
            // DMG resumes after the wake-detection M-cycle plus two internal
            // M-cycles. Instruction execution continues on the next step.
            self.idle(bus);
            self.stopped = false;
            self.idle(bus);
            self.idle(bus);
            return self.makeResult(.stopped, 0x10, null, null, before);
        }
        if (self.halted) {
            if (pending == 0) {
                self.idle(bus);
                return self.makeResult(.halted, 0x76, null, null, before);
            }
            self.halted = false;
        }
        if (self.ime and pending != 0) {
            const bit: u3 = @intCast(@ctz(pending));
            const dispatched = self.serviceInterrupt(bus, bit);
            return self.makeResult(.interrupt, 0, null, dispatched, before);
        }

        const enable_after_instruction = self.ime_enable_pending;
        self.ime_enable_pending = false;
        const opcode = self.fetchOpcode(bus);
        var cb_opcode: ?u8 = null;
        const legal = self.executeBase(bus, opcode, pending, &cb_opcode);
        if (!legal) {
            self.locked = true;
            self.illegal_opcode = opcode;
            return self.makeResult(.illegal, opcode, cb_opcode, null, before);
        }
        if (enable_after_instruction and opcode != 0xF3) self.ime = true;
        self.registers.f &= 0xF0;
        return self.makeResult(.instruction, opcode, cb_opcode, null, before);
    }

    pub fn requestStopWake(self: *Cpu) void {
        if (self.stopped) self.stop_wake_requested = true;
    }

    fn makeResult(
        self: *const Cpu,
        kind: ExecutionKind,
        opcode: u8,
        cb_opcode: ?u8,
        interrupt_bit: ?u3,
        before: u64,
    ) StepResult {
        return .{
            .kind = kind,
            .opcode = opcode,
            .cb_opcode = cb_opcode,
            .interrupt_bit = interrupt_bit,
            .m_cycles = @intCast((self.t_cycles - before) / 4),
        };
    }

    fn serviceInterrupt(self: *Cpu, bus: Bus, initial_bit: u3) ?u3 {
        self.ime = false;
        self.ime_enable_pending = false;
        self.halt_bug = false;
        self.idle(bus);
        self.idle(bus);
        self.registers.sp -%= 1;
        self.write(bus, self.registers.sp, @truncate(self.registers.pc >> 8));

        // The upper PC push may target IE at $FFFF. Hardware samples the
        // enabled requests again here: dispatch can be cancelled or retargeted.
        const pending = if (bus.pending_interrupts_fn) |callback|
            callback(bus.context) & 0x1F
        else
            @as(u8, 1) << initial_bit;
        const dispatched: ?u3 = if (pending == 0) null else @intCast(@ctz(pending));

        self.registers.sp -%= 1;
        self.write(bus, self.registers.sp, @truncate(self.registers.pc));
        if (dispatched) |bit| {
            if (bus.acknowledge_interrupt_fn) |callback| callback(bus.context, bit);
            self.registers.pc = 0x0040 + @as(u16, bit) * 8;
        } else {
            self.registers.pc = 0;
        }
        self.idle(bus);
        return dispatched;
    }

    fn executeBase(self: *Cpu, bus: Bus, opcode: u8, pending_interrupts: u8, cb_opcode: *?u8) bool {
        const x: u2 = @truncate(opcode >> 6);
        const y: u3 = @truncate(opcode >> 3);
        const z: u3 = @truncate(opcode);
        const p: u2 = @truncate(y >> 1);
        const q = (y & 1) != 0;
        switch (x) {
            0 => switch (z) {
                0 => switch (y) {
                    0 => {}, // NOP
                    1 => {
                        const address = self.fetch16(bus);
                        self.write(bus, address, @truncate(self.registers.sp));
                        self.write(bus, address +% 1, @truncate(self.registers.sp >> 8));
                    },
                    2 => {
                        // STOP is represented by the hardware core as entering
                        // its state after the opcode M-cycle; the padding byte
                        // is not a separate memory read.
                        self.idle(bus);
                        self.idle(bus);
                        self.stopped = true;
                    },
                    3 => self.relativeJump(bus, true),
                    4...7 => self.relativeJump(bus, self.condition(y - 4)),
                },
                1 => if (!q) {
                    self.setPair(p, self.fetch16(bus));
                } else {
                    self.idle(bus);
                    self.addHl(self.pair(p));
                },
                2 => {
                    const address = switch (p) {
                        0 => self.bc(),
                        1 => self.de(),
                        2, 3 => self.hl(),
                    };
                    if (!q) {
                        self.write(bus, address, self.registers.a);
                    } else {
                        self.registers.a = self.read(bus, address);
                    }
                    if (p == 2) self.setHl(address +% 1);
                    if (p == 3) self.setHl(address -% 1);
                },
                3 => {
                    self.idle(bus);
                    if (!q) self.setPair(p, self.pair(p) +% 1) else self.setPair(p, self.pair(p) -% 1);
                },
                4 => {
                    const value = self.readRegister(bus, y);
                    self.writeRegister(bus, y, self.increment8(value));
                },
                5 => {
                    const value = self.readRegister(bus, y);
                    self.writeRegister(bus, y, self.decrement8(value));
                },
                6 => self.writeRegister(bus, y, self.fetch8(bus)),
                7 => self.executeAccumulatorSpecial(y),
            },
            1 => {
                if (opcode == 0x76) {
                    self.idle(bus);
                    self.idle(bus);
                    if (!self.ime and pending_interrupts != 0) {
                        self.halt_bug = true;
                    } else {
                        self.halted = true;
                    }
                } else {
                    self.writeRegister(bus, y, self.readRegister(bus, z));
                }
            },
            2 => self.alu(y, self.readRegister(bus, z)),
            3 => switch (z) {
                0 => switch (y) {
                    0...3 => self.conditionalReturn(bus, self.condition(y)),
                    4 => {
                        const offset = self.fetch8(bus);
                        self.write(bus, 0xFF00 | @as(u16, offset), self.registers.a);
                    },
                    5 => {
                        const offset = self.fetch8(bus);
                        self.idle(bus);
                        self.idle(bus);
                        const old_sp = self.registers.sp;
                        self.registers.sp = addSigned(old_sp, offset);
                        self.setSignedFlags(old_sp, offset);
                    },
                    6 => {
                        const offset = self.fetch8(bus);
                        self.registers.a = self.read(bus, 0xFF00 | @as(u16, offset));
                    },
                    7 => {
                        const offset = self.fetch8(bus);
                        self.idle(bus);
                        self.setHl(addSigned(self.registers.sp, offset));
                        self.setSignedFlags(self.registers.sp, offset);
                    },
                },
                1 => if (!q) {
                    self.setStackPair(p, self.pop16(bus));
                } else switch (p) {
                    0 => self.returnFromCall(bus),
                    1 => {
                        self.returnFromCall(bus);
                        self.ime = true;
                        self.ime_enable_pending = false;
                    },
                    2 => self.registers.pc = self.hl(),
                    3 => {
                        self.idle(bus);
                        self.registers.sp = self.hl();
                    },
                },
                2 => switch (y) {
                    0...3 => {
                        const target = self.fetch16(bus);
                        if (self.condition(y)) {
                            self.idle(bus);
                            self.registers.pc = target;
                        }
                    },
                    4 => self.write(bus, 0xFF00 | @as(u16, self.registers.c), self.registers.a),
                    5 => self.write(bus, self.fetch16(bus), self.registers.a),
                    6 => self.registers.a = self.read(bus, 0xFF00 | @as(u16, self.registers.c)),
                    7 => self.registers.a = self.read(bus, self.fetch16(bus)),
                },
                3 => switch (y) {
                    0 => {
                        const target = self.fetch16(bus);
                        self.idle(bus);
                        self.registers.pc = target;
                    },
                    1 => {
                        const extended = self.fetch8(bus);
                        cb_opcode.* = extended;
                        self.executeCb(bus, extended);
                    },
                    6 => {
                        self.ime = false;
                        self.ime_enable_pending = false;
                    },
                    7 => self.ime_enable_pending = true,
                    else => return false,
                },
                4 => {
                    if (y >= 4) return false;
                    const target = self.fetch16(bus);
                    if (self.condition(y)) {
                        self.idle(bus);
                        self.push16(bus, self.registers.pc);
                        self.registers.pc = target;
                    }
                },
                5 => if (!q) {
                    self.idle(bus);
                    self.push16(bus, self.stackPair(p));
                } else {
                    if (p != 0) return false;
                    const target = self.fetch16(bus);
                    self.idle(bus);
                    self.push16(bus, self.registers.pc);
                    self.registers.pc = target;
                },
                6 => self.alu(y, self.fetch8(bus)),
                7 => {
                    self.idle(bus);
                    self.push16(bus, self.registers.pc);
                    self.registers.pc = @as(u16, y) * 8;
                },
            },
        }
        return true;
    }

    fn executeAccumulatorSpecial(self: *Cpu, operation: u3) void {
        switch (operation) {
            0 => {
                const carry = (self.registers.a & 0x80) != 0;
                self.registers.a = (self.registers.a << 1) | @intFromBool(carry);
                self.registers.f = if (carry) flag_c else 0;
            },
            1 => {
                const carry = (self.registers.a & 1) != 0;
                self.registers.a = (self.registers.a >> 1) | (@as(u8, @intFromBool(carry)) << 7);
                self.registers.f = if (carry) flag_c else 0;
            },
            2 => {
                const carry_in: u8 = @intFromBool((self.registers.f & flag_c) != 0);
                const carry_out = (self.registers.a & 0x80) != 0;
                self.registers.a = (self.registers.a << 1) | carry_in;
                self.registers.f = if (carry_out) flag_c else 0;
            },
            3 => {
                const carry_in: u8 = @intFromBool((self.registers.f & flag_c) != 0);
                const carry_out = (self.registers.a & 1) != 0;
                self.registers.a = (self.registers.a >> 1) | (carry_in << 7);
                self.registers.f = if (carry_out) flag_c else 0;
            },
            4 => self.decimalAdjust(),
            5 => {
                self.registers.a = ~self.registers.a;
                self.registers.f = (self.registers.f & (flag_z | flag_c)) | flag_n | flag_h;
            },
            6 => self.registers.f = (self.registers.f & flag_z) | flag_c,
            7 => self.registers.f = (self.registers.f & flag_z) |
                (if ((self.registers.f & flag_c) == 0) flag_c else 0),
        }
    }

    fn executeCb(self: *Cpu, bus: Bus, opcode: u8) void {
        const group: u2 = @truncate(opcode >> 6);
        const operation: u3 = @truncate(opcode >> 3);
        const register: u3 = @truncate(opcode);
        const value = self.readRegister(bus, register);
        switch (group) {
            0 => {
                var result: u8 = undefined;
                var carry = false;
                switch (operation) {
                    0 => {
                        carry = (value & 0x80) != 0;
                        result = (value << 1) | @intFromBool(carry);
                    },
                    1 => {
                        carry = (value & 1) != 0;
                        result = (value >> 1) | (@as(u8, @intFromBool(carry)) << 7);
                    },
                    2 => {
                        const carry_in: u8 = @intFromBool((self.registers.f & flag_c) != 0);
                        carry = (value & 0x80) != 0;
                        result = (value << 1) | carry_in;
                    },
                    3 => {
                        const carry_in: u8 = @intFromBool((self.registers.f & flag_c) != 0);
                        carry = (value & 1) != 0;
                        result = (value >> 1) | (carry_in << 7);
                    },
                    4 => {
                        carry = (value & 0x80) != 0;
                        result = value << 1;
                    },
                    5 => {
                        carry = (value & 1) != 0;
                        result = (value >> 1) | (value & 0x80);
                    },
                    6 => result = (value << 4) | (value >> 4),
                    7 => {
                        carry = (value & 1) != 0;
                        result = value >> 1;
                    },
                }
                self.registers.f = (if (result == 0) flag_z else 0) | (if (carry) flag_c else 0);
                self.writeRegister(bus, register, result);
            },
            1 => {
                const mask: u8 = @as(u8, 1) << operation;
                self.registers.f = (self.registers.f & flag_c) | flag_h |
                    (if ((value & mask) == 0) flag_z else 0);
            },
            2 => self.writeRegister(bus, register, value & ~(@as(u8, 1) << operation)),
            3 => self.writeRegister(bus, register, value | (@as(u8, 1) << operation)),
        }
    }

    fn alu(self: *Cpu, operation: u3, value: u8) void {
        switch (operation) {
            0 => self.addA(value, false),
            1 => self.addA(value, true),
            2 => self.subtractA(value, false, true),
            3 => self.subtractA(value, true, true),
            4 => {
                self.registers.a &= value;
                self.registers.f = flag_h | if (self.registers.a == 0) flag_z else 0;
            },
            5 => {
                self.registers.a ^= value;
                self.registers.f = if (self.registers.a == 0) flag_z else 0;
            },
            6 => {
                self.registers.a |= value;
                self.registers.f = if (self.registers.a == 0) flag_z else 0;
            },
            7 => self.subtractA(value, false, false),
        }
    }

    fn addA(self: *Cpu, value: u8, include_carry: bool) void {
        const carry: u8 = if (include_carry and (self.registers.f & flag_c) != 0) 1 else 0;
        const old = self.registers.a;
        const wide = @as(u16, old) + @as(u16, value) + carry;
        const result: u8 = @truncate(wide);
        self.registers.a = result;
        self.registers.f = (if (result == 0) flag_z else 0) |
            (if (@as(u16, old & 0x0F) + @as(u16, value & 0x0F) + carry > 0x0F) flag_h else 0) |
            (if (wide > 0xFF) flag_c else 0);
    }

    fn subtractA(self: *Cpu, value: u8, include_carry: bool, store: bool) void {
        const carry: u8 = if (include_carry and (self.registers.f & flag_c) != 0) 1 else 0;
        const old = self.registers.a;
        const subtrahend = @as(u16, value) + carry;
        const result = old -% value -% carry;
        if (store) self.registers.a = result;
        self.registers.f = flag_n |
            (if (result == 0) flag_z else 0) |
            (if (@as(u16, old & 0x0F) < @as(u16, value & 0x0F) + carry) flag_h else 0) |
            (if (@as(u16, old) < subtrahend) flag_c else 0);
    }

    fn increment8(self: *Cpu, value: u8) u8 {
        const result = value +% 1;
        self.registers.f = (self.registers.f & flag_c) |
            (if (result == 0) flag_z else 0) |
            (if ((value & 0x0F) == 0x0F) flag_h else 0);
        return result;
    }

    fn decrement8(self: *Cpu, value: u8) u8 {
        const result = value -% 1;
        self.registers.f = (self.registers.f & flag_c) | flag_n |
            (if (result == 0) flag_z else 0) |
            (if ((value & 0x0F) == 0) flag_h else 0);
        return result;
    }

    fn addHl(self: *Cpu, value: u16) void {
        const old = self.hl();
        const wide = @as(u32, old) + value;
        self.setHl(@truncate(wide));
        self.registers.f = (self.registers.f & flag_z) |
            (if (@as(u32, old & 0x0FFF) + @as(u32, value & 0x0FFF) > 0x0FFF) flag_h else 0) |
            (if (wide > 0xFFFF) flag_c else 0);
    }

    fn decimalAdjust(self: *Cpu) void {
        var correction: u8 = 0;
        var carry = (self.registers.f & flag_c) != 0;
        if ((self.registers.f & flag_n) == 0) {
            if ((self.registers.f & flag_h) != 0 or (self.registers.a & 0x0F) > 9) correction |= 0x06;
            if (carry or self.registers.a > 0x99) {
                correction |= 0x60;
                carry = true;
            }
            self.registers.a +%= correction;
        } else {
            if ((self.registers.f & flag_h) != 0) correction |= 0x06;
            if (carry) correction |= 0x60;
            self.registers.a -%= correction;
        }
        self.registers.f = (self.registers.f & flag_n) |
            (if (self.registers.a == 0) flag_z else 0) |
            (if (carry) flag_c else 0);
    }

    fn setSignedFlags(self: *Cpu, base: u16, offset: u8) void {
        self.registers.f = (if (@as(u16, base & 0x0F) + @as(u16, offset & 0x0F) > 0x0F) flag_h else 0) |
            (if (@as(u16, base & 0xFF) + @as(u16, offset) > 0xFF) flag_c else 0);
    }

    fn relativeJump(self: *Cpu, bus: Bus, take: bool) void {
        const offset = self.fetch8(bus);
        if (!take) return;
        self.idle(bus);
        self.registers.pc = addSigned(self.registers.pc, offset);
    }

    fn conditionalReturn(self: *Cpu, bus: Bus, take: bool) void {
        self.idle(bus);
        if (!take) return;
        const low = self.read(bus, self.registers.sp);
        self.registers.sp +%= 1;
        const high = self.read(bus, self.registers.sp);
        self.registers.sp +%= 1;
        self.idle(bus);
        self.registers.pc = (@as(u16, high) << 8) | low;
    }

    fn returnFromCall(self: *Cpu, bus: Bus) void {
        const low = self.read(bus, self.registers.sp);
        self.registers.sp +%= 1;
        const high = self.read(bus, self.registers.sp);
        self.registers.sp +%= 1;
        self.idle(bus);
        self.registers.pc = (@as(u16, high) << 8) | low;
    }

    fn condition(self: *const Cpu, index: u3) bool {
        return switch (index & 3) {
            0 => (self.registers.f & flag_z) == 0,
            1 => (self.registers.f & flag_z) != 0,
            2 => (self.registers.f & flag_c) == 0,
            3 => (self.registers.f & flag_c) != 0,
            else => unreachable,
        };
    }

    fn readRegister(self: *Cpu, bus: Bus, index: u3) u8 {
        return switch (index) {
            0 => self.registers.b,
            1 => self.registers.c,
            2 => self.registers.d,
            3 => self.registers.e,
            4 => self.registers.h,
            5 => self.registers.l,
            6 => self.read(bus, self.hl()),
            7 => self.registers.a,
        };
    }

    fn writeRegister(self: *Cpu, bus: Bus, index: u3, value: u8) void {
        switch (index) {
            0 => self.registers.b = value,
            1 => self.registers.c = value,
            2 => self.registers.d = value,
            3 => self.registers.e = value,
            4 => self.registers.h = value,
            5 => self.registers.l = value,
            6 => self.write(bus, self.hl(), value),
            7 => self.registers.a = value,
        }
    }

    pub fn bc(self: *const Cpu) u16 {
        return (@as(u16, self.registers.b) << 8) | self.registers.c;
    }

    pub fn de(self: *const Cpu) u16 {
        return (@as(u16, self.registers.d) << 8) | self.registers.e;
    }

    pub fn hl(self: *const Cpu) u16 {
        return (@as(u16, self.registers.h) << 8) | self.registers.l;
    }

    pub fn af(self: *const Cpu) u16 {
        return (@as(u16, self.registers.a) << 8) | (self.registers.f & 0xF0);
    }

    pub fn setBc(self: *Cpu, value: u16) void {
        self.registers.b = @truncate(value >> 8);
        self.registers.c = @truncate(value);
    }

    pub fn setDe(self: *Cpu, value: u16) void {
        self.registers.d = @truncate(value >> 8);
        self.registers.e = @truncate(value);
    }

    pub fn setHl(self: *Cpu, value: u16) void {
        self.registers.h = @truncate(value >> 8);
        self.registers.l = @truncate(value);
    }

    pub fn setAf(self: *Cpu, value: u16) void {
        self.registers.a = @truncate(value >> 8);
        self.registers.f = @truncate(value & 0xF0);
    }

    fn pair(self: *const Cpu, index: u2) u16 {
        return switch (index) {
            0 => self.bc(),
            1 => self.de(),
            2 => self.hl(),
            3 => self.registers.sp,
        };
    }

    fn setPair(self: *Cpu, index: u2, value: u16) void {
        switch (index) {
            0 => self.setBc(value),
            1 => self.setDe(value),
            2 => self.setHl(value),
            3 => self.registers.sp = value,
        }
    }

    fn stackPair(self: *const Cpu, index: u2) u16 {
        return switch (index) {
            0 => self.bc(),
            1 => self.de(),
            2 => self.hl(),
            3 => self.af(),
        };
    }

    fn setStackPair(self: *Cpu, index: u2, value: u16) void {
        switch (index) {
            0 => self.setBc(value),
            1 => self.setDe(value),
            2 => self.setHl(value),
            3 => self.setAf(value),
        }
    }

    fn fetchOpcode(self: *Cpu, bus: Bus) u8 {
        const value = self.read(bus, self.registers.pc);
        if (self.halt_bug) {
            self.halt_bug = false;
        } else {
            self.registers.pc +%= 1;
        }
        return value;
    }

    fn fetch8(self: *Cpu, bus: Bus) u8 {
        const value = self.read(bus, self.registers.pc);
        self.registers.pc +%= 1;
        return value;
    }

    fn fetch16(self: *Cpu, bus: Bus) u16 {
        const low = self.fetch8(bus);
        const high = self.fetch8(bus);
        return (@as(u16, high) << 8) | low;
    }

    fn push16(self: *Cpu, bus: Bus, value: u16) void {
        self.registers.sp -%= 1;
        self.write(bus, self.registers.sp, @truncate(value >> 8));
        self.registers.sp -%= 1;
        self.write(bus, self.registers.sp, @truncate(value));
    }

    fn pop16(self: *Cpu, bus: Bus) u16 {
        const low = self.read(bus, self.registers.sp);
        self.registers.sp +%= 1;
        const high = self.read(bus, self.registers.sp);
        self.registers.sp +%= 1;
        return (@as(u16, high) << 8) | low;
    }

    fn read(self: *Cpu, bus: Bus, address: u16) u8 {
        const value = bus.read_fn(bus.context, address);
        self.last_bus_address = address;
        self.last_bus_value = value;
        self.t_cycles +%= 4;
        return value;
    }

    fn write(self: *Cpu, bus: Bus, address: u16, value: u8) void {
        bus.write_fn(bus.context, address, value);
        self.last_bus_address = address;
        self.last_bus_value = value;
        self.t_cycles +%= 4;
    }

    fn idle(self: *Cpu, bus: Bus) void {
        bus.idle_fn(bus.context, self.last_bus_address, self.last_bus_value);
        self.t_cycles +%= 4;
    }
};

pub fn addSigned(base: u16, offset: u8) u16 {
    if ((offset & 0x80) == 0) return base +% offset;
    return base -% (@as(u16, 0x100) - offset);
}

pub fn isIllegalBaseOpcode(opcode: u8) bool {
    return switch (opcode) {
        0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD => true,
        else => false,
    };
}
