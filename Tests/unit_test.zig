const std = @import("std");
const core = @import("core");

test "all core component declarations remain independently analyzable" {
    std.testing.refAllDecls(core);
}

test "DMG revision profiles and side-specific keyboard mapping are explicit" {
    const production = core.model.profile(core.model.production_revision);
    try std.testing.expectEqual(core.model.Revision.dmg_c, production.revision);
    try std.testing.expectEqual(@as(u16, 0x0100), production.registers.pc);
    try std.testing.expectEqual(@as(u8, 0xB0), production.registers.f);
    const dmg_zero = core.model.profile(.dmg_0);
    try std.testing.expectEqual(@as(u8, 0), dmg_zero.registers.f);
    try std.testing.expectEqual(@as(u8, 0x19), dmg_zero.mmio[0x04]);
    try std.testing.expectEqual(core.joypad.Button.select, core.host_adapter.buttonForPhysicalUsage(core.host_adapter.physical_usage_right_control).?);
    try std.testing.expect(core.host_adapter.buttonForPhysicalUsage(0xE0) == null);
    try std.testing.expectEqual(core.joypad.Button.b, core.host_adapter.buttonForPhysicalUsage(core.host_adapter.physical_usage_left_alt).?);
}

const CpuEvent = struct {
    address: u16,
    value: u8,
    kind: core.cpu.CycleKind,
};

const CpuMemory = struct {
    bytes: [65536]u8 = .{0} ** 65536,
    events: [32]CpuEvent = undefined,
    event_count: usize = 0,

    fn read(context: *anyopaque, address: u16) u8 {
        const self: *CpuMemory = @ptrCast(@alignCast(context));
        const value = self.bytes[address];
        self.append(address, value, .read);
        return value;
    }

    fn write(context: *anyopaque, address: u16, value: u8) void {
        const self: *CpuMemory = @ptrCast(@alignCast(context));
        self.bytes[address] = value;
        self.append(address, value, .write);
    }

    fn idle(context: *anyopaque, address: u16, value: u8) void {
        const self: *CpuMemory = @ptrCast(@alignCast(context));
        self.append(address, value, .idle);
    }

    fn append(self: *CpuMemory, address: u16, value: u8, kind: core.cpu.CycleKind) void {
        self.events[self.event_count] = .{ .address = address, .value = value, .kind = kind };
        self.event_count += 1;
    }

    fn bus(self: *CpuMemory) core.cpu.Bus {
        return .{ .context = self, .read_fn = read, .write_fn = write, .idle_fn = idle };
    }
};

fn testCpu(pc: u16, sp: u16) core.cpu.Cpu {
    var profile = core.model.profile(.dmg_c);
    profile.registers = .{ .a = 0, .f = 0, .b = 0, .c = 0, .d = 0, .e = 0, .h = 0, .l = 0, .sp = sp, .pc = pc };
    return core.cpu.Cpu.init(profile);
}

test "illegal SM83 opcodes enter a bounded lock state and F low bits stay fixed" {
    const illegal = [_]u8{ 0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD };
    var legal_count: usize = 0;
    var raw: u16 = 0;
    while (raw <= 0xFF) : (raw += 1) {
        if (!core.cpu.isIllegalBaseOpcode(@intCast(raw))) legal_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 245), legal_count);
    for (illegal) |opcode| {
        var memory: CpuMemory = .{};
        memory.bytes[0x100] = opcode;
        var processor = testCpu(0x100, 0xFFFE);
        processor.registers.f = 0xBF;
        const first = processor.step(memory.bus(), 0);
        try std.testing.expectEqual(core.cpu.ExecutionKind.illegal, first.kind);
        try std.testing.expect(processor.locked);
        try std.testing.expectEqual(@as(u8, 0xB0), processor.registers.f);
        const second = processor.step(memory.bus(), 0);
        try std.testing.expectEqual(core.cpu.ExecutionKind.illegal, second.kind);
        try std.testing.expectEqual(@as(u8, 1), second.m_cycles);
    }
}

test "EI delay, DI cancellation and RETI are explicit instruction states" {
    var memory: CpuMemory = .{};
    memory.bytes[0x100] = 0xFB;
    memory.bytes[0x101] = 0x00;
    var processor = testCpu(0x100, 0xC000);
    _ = processor.step(memory.bus(), 0);
    try std.testing.expect(!processor.ime);
    try std.testing.expect(processor.ime_enable_pending);
    _ = processor.step(memory.bus(), 0);
    try std.testing.expect(processor.ime);
    try std.testing.expect(!processor.ime_enable_pending);

    memory = .{};
    memory.bytes[0x100] = 0xFB;
    memory.bytes[0x101] = 0xF3;
    processor = testCpu(0x100, 0xC000);
    _ = processor.step(memory.bus(), 0);
    _ = processor.step(memory.bus(), 0);
    try std.testing.expect(!processor.ime);
    try std.testing.expect(!processor.ime_enable_pending);

    memory = .{};
    memory.bytes[0x100] = 0xD9;
    memory.bytes[0xC000] = 0x34;
    memory.bytes[0xC001] = 0x12;
    processor = testCpu(0x100, 0xC000);
    _ = processor.step(memory.bus(), 0);
    try std.testing.expect(processor.ime);
    try std.testing.expectEqual(@as(u16, 0x1234), processor.registers.pc);
    try std.testing.expectEqual(@as(u16, 0xC002), processor.registers.sp);
}

test "HALT bug, STOP wake and interrupt stack order are deterministic" {
    var memory: CpuMemory = .{};
    memory.bytes[0x100] = 0x76;
    memory.bytes[0x101] = 0x3E;
    memory.bytes[0x102] = 0x42;
    var processor = testCpu(0x100, 0xC000);
    _ = processor.step(memory.bus(), 1);
    try std.testing.expect(processor.halt_bug);
    try std.testing.expect(!processor.halted);
    _ = processor.step(memory.bus(), 0);
    try std.testing.expectEqual(@as(u8, 0x3E), processor.registers.a);
    try std.testing.expectEqual(@as(u16, 0x102), processor.registers.pc);

    memory = .{};
    memory.bytes[0x200] = 0x10;
    memory.bytes[0x201] = 0x00;
    processor = testCpu(0x200, 0xC000);
    _ = processor.step(memory.bus(), 0);
    try std.testing.expect(processor.stopped);
    const stopped = processor.step(memory.bus(), 0);
    try std.testing.expectEqual(core.cpu.ExecutionKind.stopped, stopped.kind);
    const waking = processor.step(memory.bus(), 1);
    try std.testing.expect(!processor.stopped);
    try std.testing.expectEqual(@as(u8, 3), waking.m_cycles);
    try std.testing.expectEqual(@as(u16, 0x0201), processor.registers.pc);

    memory = .{};
    processor = testCpu(0x1234, 0xC000);
    processor.ime = true;
    const accepted = processor.step(memory.bus(), 0x04);
    try std.testing.expectEqual(core.cpu.ExecutionKind.interrupt, accepted.kind);
    try std.testing.expectEqual(@as(?u3, 2), accepted.interrupt_bit);
    try std.testing.expectEqual(@as(u16, 0x0050), processor.registers.pc);
    try std.testing.expectEqual(@as(u16, 0xBFFE), processor.registers.sp);
    try std.testing.expectEqual(@as(u8, 0x12), memory.bytes[0xBFFF]);
    try std.testing.expectEqual(@as(u8, 0x34), memory.bytes[0xBFFE]);
    try std.testing.expectEqual(@as(usize, 5), memory.event_count);
    try std.testing.expectEqual(core.cpu.CycleKind.write, memory.events[2].kind);
    try std.testing.expectEqual(@as(u16, 0xBFFF), memory.events[2].address);
    try std.testing.expectEqual(core.cpu.CycleKind.write, memory.events[3].kind);
    try std.testing.expectEqual(@as(u16, 0xBFFE), memory.events[3].address);
}

test "EI followed by bugged HALT pushes the HALT address" {
    var memory: CpuMemory = .{};
    memory.bytes[0x100] = 0xFB; // EI
    memory.bytes[0x101] = 0x76; // HALT
    var processor = testCpu(0x100, 0xC000);

    _ = processor.step(memory.bus(), 1);
    try std.testing.expect(!processor.ime);
    try std.testing.expect(processor.ime_enable_pending);
    _ = processor.step(memory.bus(), 1);
    try std.testing.expect(processor.ime);
    try std.testing.expect(processor.halt_bug);
    try std.testing.expectEqual(@as(u16, 0x0102), processor.registers.pc);

    const accepted = processor.step(memory.bus(), 1);
    try std.testing.expectEqual(core.cpu.ExecutionKind.interrupt, accepted.kind);
    try std.testing.expectEqual(@as(u16, 0x0040), processor.registers.pc);
    try std.testing.expectEqual(@as(u16, 0xBFFE), processor.registers.sp);
    try std.testing.expectEqual(@as(u8, 0x01), memory.bytes[0xBFFF]);
    try std.testing.expectEqual(@as(u8, 0x01), memory.bytes[0xBFFE]);
    try std.testing.expect(!processor.halt_bug);
}

test "DAA and signed SP offsets cover carry boundaries" {
    var memory: CpuMemory = .{};
    memory.bytes[0x100] = 0x27;
    var processor = testCpu(0x100, 0xC000);
    processor.registers.a = 0x9A;
    _ = processor.step(memory.bus(), 0);
    try std.testing.expectEqual(@as(u8, 0), processor.registers.a);
    try std.testing.expectEqual(@as(u8, core.cpu.flag_z | core.cpu.flag_c), processor.registers.f);

    memory = .{};
    memory.bytes[0x100] = 0xE8;
    memory.bytes[0x101] = 0xFF;
    processor = testCpu(0x100, 0x0001);
    _ = processor.step(memory.bus(), 0);
    try std.testing.expectEqual(@as(u16, 0), processor.registers.sp);
    try std.testing.expectEqual(@as(u8, core.cpu.flag_h | core.cpu.flag_c), processor.registers.f);
}

test "identical CPU instances share no registers, RAM or decode state" {
    var left_memory: CpuMemory = .{};
    var right_memory: CpuMemory = .{};
    const program = [_]u8{ 0xCD, 0x78, 0x56 };
    @memcpy(left_memory.bytes[0x100..0x103], program[0..]);
    @memcpy(right_memory.bytes[0x100..0x103], program[0..]);
    var left = testCpu(0x100, 0xC000);
    var right = testCpu(0x100, 0xC000);
    const left_result = left.step(left_memory.bus(), 0);
    const right_result = right.step(right_memory.bus(), 0);
    try std.testing.expect(std.meta.eql(left, right));
    try std.testing.expect(std.meta.eql(left_result, right_result));
    try std.testing.expectEqualSlices(CpuEvent, left_memory.events[0..left_memory.event_count], right_memory.events[0..right_memory.event_count]);
    try std.testing.expectEqualSlices(u8, left_memory.bytes[0xBFFE..0xC000], right_memory.bytes[0xBFFE..0xC000]);
    left.registers.a = 0xAA;
    left_memory.bytes[0xBFFE] ^= 0xFF;
    try std.testing.expect(left.registers.a != right.registers.a);
    try std.testing.expect(left_memory.bytes[0xBFFE] != right_memory.bytes[0xBFFE]);
}

fn makeRom(allocator: std.mem.Allocator, type_code: u8, rom_code: u8, ram_code: u8, cgb_flag: u8) ![]u8 {
    const size = core.cartridge.romBytes(rom_code) orelse return error.BadFixtureRomSize;
    const bytes = try allocator.alloc(u8, size);
    @memset(bytes, 0);
    var bank: usize = 0;
    while (bank * core.cartridge.rom_bank_bytes < bytes.len) : (bank += 1) {
        const base = bank * core.cartridge.rom_bank_bytes;
        bytes[base] = @truncate(bank);
        bytes[base + 1] = @truncate(bank >> 8);
    }
    @memcpy(bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[0x134..0x13D], "SYNTHETIC");
    bytes[0x143] = cgb_flag;
    bytes[0x146] = 0;
    bytes[0x147] = type_code;
    bytes[0x148] = rom_code;
    bytes[0x149] = ram_code;
    finalize(bytes);
    return bytes;
}

fn finalize(bytes: []u8) void {
    bytes[0x14D] = core.cartridge.headerChecksum(bytes);
    bytes[0x14E] = 0;
    bytes[0x14F] = 0;
    const checksum = core.cartridge.globalChecksum(bytes);
    bytes[0x14E] = @truncate(checksum >> 8);
    bytes[0x14F] = @truncate(checksum);
}

fn addEmbeddedHeader(bytes: []u8, bank: usize) void {
    const base = bank * core.cartridge.rom_bank_bytes;
    @memcpy(bytes[base + core.cartridge.logo_offset .. base + core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[base + 0x134 .. base + 0x13D], "SUBCART01");
    bytes[base + 0x147] = 0;
    bytes[base + 0x148] = 3;
    var checksum: u8 = 0;
    for (bytes[base + 0x134 .. base + 0x14D]) |value| checksum -%= value +% 1;
    bytes[base + 0x14D] = checksum;
    finalize(bytes);
}

test "complete dual-mode image is accepted without mutation and CGB-only is rejected" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x80);
    defer allocator.free(bytes);
    const before = try allocator.dupe(u8, bytes);
    defer allocator.free(before);

    const parsed = try core.cartridge.parse(bytes);
    try std.testing.expectEqual(core.cartridge.Capability.dmg_and_cgb, parsed.capability);
    try std.testing.expectEqualSlices(u8, "SYNTHETIC", parsed.titleSlice());
    try std.testing.expectEqualSlices(u8, before, bytes);

    bytes[0x143] = 0xC0;
    finalize(bytes);
    try std.testing.expectError(error.CgbOnly, core.cartridge.parse(bytes));
}

test "image bounds, both checksums, size codes and mapper consistency are deterministic" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);

    for ([_]usize{ 0, 1, core.cartridge.logo_offset, core.cartridge.header_size - 1 }) |cut| {
        try std.testing.expectError(error.TooSmall, core.cartridge.parse(bytes[0..cut]));
    }
    try std.testing.expectError(error.SizeMismatch, core.cartridge.parse(bytes[0 .. bytes.len - 1]));
    bytes[0] ^= 1;
    try std.testing.expectError(error.InvalidGlobalChecksum, core.cartridge.parse(bytes));
    bytes[0] ^= 1;
    bytes[0x134] ^= 1;
    try std.testing.expectError(error.InvalidHeaderChecksum, core.cartridge.parse(bytes));
    bytes[0x134] ^= 1;
    finalize(bytes);
    bytes[core.cartridge.logo_offset] ^= 1;
    try std.testing.expectError(error.InvalidLogo, core.cartridge.parse(bytes));
    bytes[core.cartridge.logo_offset] ^= 1;

    bytes[0x148] = 0xFF;
    finalize(bytes);
    try std.testing.expectError(error.InvalidRomSizeCode, core.cartridge.parse(bytes));

    bytes[0x148] = 0;
    bytes[0x149] = 0xFF;
    finalize(bytes);
    try std.testing.expectError(error.InvalidRamSizeCode, core.cartridge.parse(bytes));

    const too_large = try allocator.alloc(u8, core.cartridge.max_rom_bytes + 1);
    defer allocator.free(too_large);
    try std.testing.expectError(error.TooLarge, core.cartridge.parse(too_large));
}

test "unknown, digital-gap and accessory-dependent cartridges stay distinct" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);

    bytes[0x147] = 0x04;
    finalize(bytes);
    try std.testing.expectError(error.UnknownCartridgeType, core.cartridge.parse(bytes));
    bytes[0x147] = 0x20;
    finalize(bytes);
    try std.testing.expectError(error.UnsupportedMbc6, core.cartridge.parse(bytes));
    bytes[0x147] = 0x22;
    finalize(bytes);
    try std.testing.expectError(error.UnsupportedMbc7Accessory, core.cartridge.parse(bytes));
    bytes[0x147] = 0xFC;
    finalize(bytes);
    try std.testing.expectError(error.UnsupportedCameraAccessory, core.cartridge.parse(bytes));
    bytes[0x147] = 0xFD;
    finalize(bytes);
    try std.testing.expectError(error.UnsupportedTama5, core.cartridge.parse(bytes));
    bytes[0x147] = 0xFE;
    finalize(bytes);
    try std.testing.expectError(error.UnsupportedHuc3, core.cartridge.parse(bytes));

    bytes[0x147] = 0x00;
    bytes[0x149] = 0x02;
    finalize(bytes);
    try std.testing.expectError(error.InconsistentRam, core.cartridge.parse(bytes));
}

test "cartridge owns an immutable ROM copy" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);
    const original = bytes[0];
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();
    bytes[0] ^= 0xFF;
    try std.testing.expectEqual(original, cart.rom[0]);
    try std.testing.expectEqual(original, cart.readRom(0));
}

test "MBC1 regular banking covers forbidden banks, modes and RAM mirroring" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x01, 0x06, 0x00, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    try std.testing.expectEqual(core.cartridge.MapperKind.mbc1, cart.header.mapper);
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4000));
    cart.writeControl(0x2000, 0x00);
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4000));
    cart.writeControl(0x4000, 0x01);
    try std.testing.expectEqual(@as(u8, 33), cart.readRom(0x4000));
    cart.writeControl(0x6000, 0x01);
    try std.testing.expectEqual(@as(u8, 32), cart.readRom(0x0000));

    const ram_bytes = try makeRom(allocator, 0x03, 0x04, 0x03, 0x00);
    defer allocator.free(ram_bytes);
    var ram_cart = try core.cartridge.Cartridge.init(allocator, ram_bytes);
    defer ram_cart.deinit();
    try std.testing.expectEqual(@as(u8, 0xFF), ram_cart.readExternal(0xA000));
    ram_cart.writeControl(0x0000, 0x1A);
    ram_cart.writeControl(0x6000, 1);
    ram_cart.writeControl(0x4000, 3);
    ram_cart.writeExternal(0xA000, 0x53);
    ram_cart.writeControl(0x4000, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), ram_cart.readExternal(0xA000));
    ram_cart.writeControl(0x4000, 3);
    try std.testing.expectEqual(@as(u8, 0x53), ram_cart.readExternal(0xA000));
}

test "MBC1M embedded header selects multicart wiring" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x01, 0x05, 0x00, 0x00);
    defer allocator.free(bytes);
    addEmbeddedHeader(bytes, 16);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    try std.testing.expectEqual(core.cartridge.MapperKind.mbc1_multicart, cart.header.mapper);
    cart.writeControl(0x4000, 1);
    try std.testing.expectEqual(@as(u8, 17), cart.readRom(0x4000));
    cart.writeControl(0x6000, 1);
    try std.testing.expectEqual(@as(u8, 16), cart.readRom(0x0000));
    cart.writeControl(0x2000, 0x10);
    try std.testing.expectEqual(@as(u8, 16), cart.readRom(0x4000));
}

test "MBC2 uses address bit eight and mirrored four-bit RAM" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x06, 0x03, 0x00, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    cart.writeControl(0x2100, 0x0F);
    try std.testing.expectEqual(@as(u8, 15), cart.readRom(0x4000));
    cart.writeControl(0x0100, 0x00);
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4000));
    cart.writeControl(0x0000, 0x0A);
    cart.writeExternal(0xA000, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xFB), cart.readExternal(0xA200));
    cart.writeControl(0x0000, 0x00);
    try std.testing.expectEqual(@as(u8, 0xFF), cart.readExternal(0xA000));
}

test "MBC3 and MBC30 separate RAM, RTC selection and latch state" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x10, 0x06, 0x03, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    cart.writeControl(0x0000, 0x0A);
    cart.writeControl(0x2000, 0);
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4000));
    cart.writeControl(0x4000, 2);
    cart.writeExternal(0xA000, 0x22);
    cart.writeControl(0x4000, 0x08);
    cart.writeExternal(0xA000, 42);
    cart.writeControl(0x6000, 0);
    cart.writeControl(0x6000, 1);
    try std.testing.expectEqual(@as(u8, 42), cart.readExternal(0xA111));
    cart.writeExternal(0xA000, 12);
    try std.testing.expectEqual(@as(u8, 42), cart.readExternal(0xA000));
    cart.writeControl(0x4000, 0x0D);
    try std.testing.expectEqual(@as(u8, 0xFF), cart.readExternal(0xA000));
    cart.writeControl(0x4000, 2);
    try std.testing.expectEqual(@as(u8, 0x22), cart.readExternal(0xA000));

    const mbc30_bytes = try makeRom(allocator, 0x10, 0x07, 0x05, 0x00);
    defer allocator.free(mbc30_bytes);
    var mbc30 = try core.cartridge.Cartridge.init(allocator, mbc30_bytes);
    defer mbc30.deinit();
    try std.testing.expectEqual(core.cartridge.MapperKind.mbc30, mbc30.header.mapper);
    mbc30.writeControl(0x2000, 0x80);
    try std.testing.expectEqual(@as(u8, 0x80), mbc30.readRom(0x4000));
    mbc30.writeControl(0x0000, 0x0A);
    mbc30.writeControl(0x4000, 7);
    mbc30.writeExternal(0xA000, 0x77);
    try std.testing.expectEqual(@as(u8, 0x77), mbc30.readExternal(0xA000));
}

test "MBC5 keeps ninth ROM bit and rumble separate from RAM bank" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x1E, 0x08, 0x05, 0x80);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    cart.writeControl(0x2000, 0x00);
    cart.writeControl(0x3000, 0x01);
    try std.testing.expectEqual(@as(u8, 0), cart.readRom(0x4000));
    try std.testing.expectEqual(@as(u8, 1), cart.readRom(0x4001));
    cart.writeControl(0x3000, 0);
    try std.testing.expectEqual(@as(u8, 0), cart.readRom(0x4001));

    cart.writeControl(0x0000, 0x0A);
    cart.writeControl(0x4000, 0x0B);
    try std.testing.expect(cart.mapper.rumble_on);
    cart.writeExternal(0xA000, 0x63);
    cart.writeControl(0x4000, 0x03);
    try std.testing.expect(!cart.mapper.rumble_on);
    try std.testing.expectEqual(@as(u8, 0x63), cart.readExternal(0xA000));
}

test "non-power-of-two ROM has electrical mirrors and unpopulated open bus" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x19, 0x52, 0x00, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();

    cart.writeControl(0x2000, 71);
    try std.testing.expectEqual(@as(u8, 71), cart.readRom(0x4000));
    cart.writeControl(0x2000, 72);
    try std.testing.expectEqual(@as(u8, 0xFF), cart.readRom(0x4000));
    cart.writeControl(0x2000, 128);
    try std.testing.expectEqual(@as(u8, 0), cart.readRom(0x4000));
}

test "the complete 64 KiB bus is bounded, mirrored and device-gated" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);
    var cart = try core.cartridge.Cartridge.init(allocator, bytes);
    defer cart.deinit();
    var video_ram = [_]u8{0} ** 0x2000;
    var oam = [_]u8{0} ** 0xA0;
    var io = [_]u8{0xFF} ** 0x80;
    var ie: u8 = 0;
    var bus: core.bus.Bus = .{};
    var devices = core.bus.Devices{
        .cartridge = &cart,
        .video_ram = &video_ram,
        .object_attribute_memory = &oam,
        .io = &io,
        .interrupt_enable = &ie,
    };

    bus.write(devices, 0x8000, 0x80);
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(devices, 0x8000));
    bus.write(devices, 0xC123, 0xC1);
    try std.testing.expectEqual(@as(u8, 0xC1), bus.read(devices, 0xE123));
    bus.write(devices, 0xFDFF, 0xDD);
    try std.testing.expectEqual(@as(u8, 0xDD), bus.read(devices, 0xDDFF));
    bus.write(devices, 0xFE9F, 0x9F);
    try std.testing.expectEqual(@as(u8, 0x9F), bus.read(devices, 0xFE9F));
    bus.write(devices, 0xFEA0, 0xAA);
    try std.testing.expectEqual(@as(u8, 0), bus.read(devices, 0xFEA0));
    bus.write(devices, 0xFF44, 0x44);
    bus.write(devices, 0xFF80, 0x80);
    bus.write(devices, 0xFFFF, 0x1F);
    try std.testing.expectEqual(@as(u8, 0x44), bus.read(devices, 0xFF44));
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(devices, 0xFF80));
    try std.testing.expectEqual(@as(u8, 0x1F), bus.read(devices, 0xFFFF));

    devices.vram_blocked = true;
    devices.oam_blocked = true;
    bus.write(devices, 0x8000, 0x11);
    bus.write(devices, 0xFE00, 0x22);
    try std.testing.expectEqual(@as(u8, 0xFF), bus.read(devices, 0x8000));
    try std.testing.expectEqual(@as(u8, 0xFF), bus.read(devices, 0xFE00));
    try std.testing.expectEqual(@as(u8, 0xFF), bus.read(devices, 0xFEA0));
    devices.vram_blocked = false;
    devices.oam_blocked = false;
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(devices, 0x8000));
    try std.testing.expectEqual(@as(u8, 0), bus.read(devices, 0xFE00));

    devices.dma_blocks_external_bus = true;
    try std.testing.expectEqual(@as(u8, 0xFF), bus.read(devices, 0xC123));
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(devices, 0xFF80));
    bus.write(devices, 0xC123, 0x01);
    devices.dma_blocks_external_bus = false;
    try std.testing.expectEqual(@as(u8, 0xC1), bus.read(devices, 0xC123));

    var raw: u32 = 0;
    while (raw <= 0xFFFF) : (raw += 1) {
        const address: u16 = @intCast(raw);
        _ = bus.read(devices, address);
        bus.write(devices, address, @truncate(raw));
    }
}

test "machine timer, serial and DMA remain identical across host slice partitioning" {
    const allocator = std.testing.allocator;
    const left_bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(left_bytes);
    const right_bytes = try allocator.dupe(u8, left_bytes);
    defer allocator.free(right_bytes);
    var left = core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(allocator, left_bytes));
    defer left.deinit();
    var right = core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(allocator, right_bytes));
    defer right.deinit();

    left.write(0xFF04, 0);
    right.write(0xFF04, 0);
    left.write(0xFF05, 0xFA);
    right.write(0xFF05, 0xFA);
    left.write(0xFF06, 0x61);
    right.write(0xFF06, 0x61);
    left.write(0xFF07, 0x05);
    right.write(0xFF07, 0x05);
    left.write(0xFF01, 0);
    right.write(0xFF01, 0);
    left.write(0xFF02, 0x81);
    right.write(0xFF02, 0x81);
    left.bus.work_ram[0] = 0xD4;
    right.bus.work_ram[0] = 0xD4;
    left.write(0xFF46, 0xC0);
    right.write(0xFF46, 0xC0);

    left.tickTcycles(8192);
    var remaining: u32 = 8192;
    const chunks = [_]u32{ 1, 3, 17, 64, 257, 997 };
    var chunk_index: usize = 0;
    while (remaining != 0) : (chunk_index += 1) {
        const amount = @min(remaining, chunks[chunk_index % chunks.len]);
        right.tickTcycles(amount);
        remaining -= amount;
    }

    try std.testing.expectEqual(left.timer.divider_counter, right.timer.divider_counter);
    try std.testing.expectEqual(left.timer.tima, right.timer.tima);
    try std.testing.expectEqual(left.interrupts.request, right.interrupts.request);
    try std.testing.expectEqual(left.serial.data, right.serial.data);
    try std.testing.expectEqual(left.serial.control, right.serial.control);
    try std.testing.expectEqual(left.dma.active, right.dma.active);
    try std.testing.expectEqualSlices(u8, left.ppu.oam[0..], right.ppu.oam[0..]);
    try std.testing.expectEqual(@as(u8, 0xD4), left.ppu.oam[0]);
}

test "open E2E ROM exercises PPU APU timer input battery RTC and defined completion" {
    const allocator = std.testing.allocator;
    var image: [core.fixture_rom.image_bytes]u8 = undefined;
    try core.fixture_rom.build(image[0..], .battery_rtc);
    var machine = core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(allocator, image[0..]));
    defer machine.deinit();

    var instructions: usize = 0;
    while ((machine.ppu.frames_completed < 3 or machine.bus.work_ram[3] == 0) and instructions < 1_000_000) : (instructions += 1) {
        try std.testing.expect(machine.stepCpu().kind != .illegal);
    }
    try std.testing.expect(machine.ppu.frames_completed >= 3);
    try std.testing.expect(machine.ppu.frame_revision != 0);
    try std.testing.expect(machine.bus.work_ram[3] != 0);
    try std.testing.expect(machine.apu.powered);
    try std.testing.expect(machine.apu.stats.samples_generated != 0);
    var saw_white = false;
    var saw_light = false;
    for (machine.ppu.framebuffer) |pixel| {
        saw_white = saw_white or pixel == 0;
        saw_light = saw_light or pixel == 1;
    }
    try std.testing.expect(saw_white and saw_light);
    try std.testing.expectEqual(@as(u8, 0x5A), machine.cartridge.readExternal(0xA000));
    try std.testing.expectEqual(@as(u8, 7), machine.cartridge.mapper.rtc.seconds);

    machine.setButton(.right, true, false);
    instructions = 0;
    while ((machine.bus.work_ram[0] & 1) != 0 and instructions < 100_000) : (instructions += 1) {
        try std.testing.expect(machine.stepCpu().kind != .illegal);
    }
    try std.testing.expectEqual(@as(u8, 0), machine.bus.work_ram[0] & 1);

    machine.setButton(.a, true, false);
    instructions = 0;
    while ((machine.bus.work_ram[2] & 1) != 0 and instructions < 100_000) : (instructions += 1) {
        try std.testing.expect(machine.stepCpu().kind != .illegal);
    }
    try std.testing.expectEqual(@as(u8, 0), machine.bus.work_ram[2] & 1);

    machine.setButton(.start, true, false);
    machine.setButton(.select, true, false);
    instructions = 0;
    while (machine.bus.work_ram[1] != core.fixture_rom.completion_witness_value and instructions < 100_000) : (instructions += 1) {
        try std.testing.expect(machine.stepCpu().kind != .illegal);
    }
    try std.testing.expectEqual(core.fixture_rom.completion_witness_value, machine.bus.work_ram[1]);
    try std.testing.expect(machine.stepCpu().kind != .illegal);
    try std.testing.expect(machine.cpu.halted);
    try std.testing.expectEqual(@as(u8, 0), machine.interrupts.enable);
    try std.testing.expectEqual(@as(u8, 0xF8), machine.timer.readTac());
}

test "machine interrupt dispatch can cancel or retarget after the IE push" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);
    var machine = core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(allocator, bytes));
    defer machine.deinit();

    machine.cpu.registers.pc = 0x0200;
    machine.cpu.registers.sp = 0x0000;
    machine.cpu.ime = true;
    machine.interrupts.enable = 0x04;
    machine.interrupts.writeRequest(0x04);
    const cancelled = machine.stepCpu();
    try std.testing.expectEqual(core.cpu.ExecutionKind.interrupt, cancelled.kind);
    try std.testing.expect(cancelled.interrupt_bit == null);
    try std.testing.expectEqual(@as(u16, 0), machine.cpu.registers.pc);
    try std.testing.expectEqual(@as(u8, 0x04), machine.interrupts.request);
    try std.testing.expect(!machine.cpu.ime);

    machine.cpu.registers.pc = 0x0200;
    machine.cpu.registers.sp = 0x0000;
    machine.cpu.ime = true;
    machine.interrupts.enable = 0x03;
    machine.interrupts.writeRequest(0x03);
    const retargeted = machine.stepCpu();
    try std.testing.expectEqual(@as(?u3, 1), retargeted.interrupt_bit);
    try std.testing.expectEqual(@as(u16, 0x0048), machine.cpu.registers.pc);
    try std.testing.expectEqual(@as(u8, 0x01), machine.interrupts.request);
}

test "physical keyboard input preserves sides, edges, repeats and focus release" {
    var adapter = core.host_adapter.HostAdapter{};
    var pad = core.joypad.Joypad{};
    var irq = core.interrupts.Interrupts{ .request = 0, .enable = 0 };
    try std.testing.expect(!adapter.physicalKey(&pad, &irq, core.host_adapter.physical_usage_space, true, false));
    adapter.focusGained();
    try std.testing.expect(adapter.physicalKey(&pad, &irq, core.host_adapter.physical_usage_space, true, false));
    try std.testing.expectEqual(@as(u8, 0), irq.request);
    _ = pad.write(0x10);
    try std.testing.expect(adapter.physicalKey(&pad, &irq, core.host_adapter.physical_usage_enter, true, false));
    try std.testing.expectEqual(@as(u8, 0x10), irq.request);
    irq.writeRequest(0);
    try std.testing.expect(adapter.physicalKey(&pad, &irq, core.host_adapter.physical_usage_enter, true, true));
    try std.testing.expectEqual(@as(u8, 0), irq.request);
    try std.testing.expect(adapter.physicalKey(&pad, &irq, core.host_adapter.physical_usage_left_alt, true, false));
    try std.testing.expectEqual(@as(u8, 0x10), irq.request);
    adapter.focusLost(&pad);
    try std.testing.expectEqual(@as(u8, 0), pad.held);
}

test "every canonical keyboard key drives its exact P1 line" {
    const Mapping = struct {
        usage: u32,
        button: core.joypad.Button,
        row_select: u8,
        line: u8,
    };
    const mappings = [_]Mapping{
        .{ .usage = core.host_adapter.physical_usage_right, .button = .right, .row_select = 0x20, .line = 0x01 },
        .{ .usage = core.host_adapter.physical_usage_left, .button = .left, .row_select = 0x20, .line = 0x02 },
        .{ .usage = core.host_adapter.physical_usage_up, .button = .up, .row_select = 0x20, .line = 0x04 },
        .{ .usage = core.host_adapter.physical_usage_down, .button = .down, .row_select = 0x20, .line = 0x08 },
        .{ .usage = core.host_adapter.physical_usage_space, .button = .a, .row_select = 0x10, .line = 0x01 },
        .{ .usage = core.host_adapter.physical_usage_left_alt, .button = .b, .row_select = 0x10, .line = 0x02 },
        .{ .usage = core.host_adapter.physical_usage_right_control, .button = .select, .row_select = 0x10, .line = 0x04 },
        .{ .usage = core.host_adapter.physical_usage_enter, .button = .start, .row_select = 0x10, .line = 0x08 },
    };

    for (mappings) |mapping| {
        var adapter = core.host_adapter.HostAdapter{};
        var pad = core.joypad.Joypad{};
        var irq = core.interrupts.Interrupts{ .request = 0, .enable = 0 };
        adapter.focusGained();
        try std.testing.expectEqual(mapping.button, core.host_adapter.buttonForPhysicalUsage(mapping.usage).?);
        _ = pad.write(mapping.row_select);

        try std.testing.expect(adapter.physicalKey(&pad, &irq, mapping.usage, true, false));
        try std.testing.expectEqual(@as(u8, 0x0F) & ~mapping.line, pad.read() & 0x0F);
        try std.testing.expectEqual(@as(u8, 0x10), irq.request);

        irq.writeRequest(0);
        try std.testing.expect(adapter.physicalKey(&pad, &irq, mapping.usage, true, true));
        try std.testing.expectEqual(@as(u8, 0), irq.request);

        try std.testing.expect(adapter.physicalKey(&pad, &irq, mapping.usage, false, false));
        try std.testing.expectEqual(@as(u8, 0x0F), pad.read() & 0x0F);
        try std.testing.expectEqual(@as(u8, 0), irq.request);
    }
}

test "opposing directions remain independently held and released" {
    var adapter = core.host_adapter.HostAdapter{};
    var pad = core.joypad.Joypad{};
    var irq = core.interrupts.Interrupts{ .request = 0, .enable = 0 };
    adapter.focusGained();
    _ = pad.write(0x20);

    try std.testing.expect(adapter.physicalKey(&pad, &irq, core.host_adapter.physical_usage_left, true, false));
    try std.testing.expect(adapter.physicalKey(&pad, &irq, core.host_adapter.physical_usage_right, true, false));
    try std.testing.expectEqual(@as(u8, 0x0C), pad.read() & 0x0F);

    irq.writeRequest(0);
    try std.testing.expect(adapter.physicalKey(&pad, &irq, core.host_adapter.physical_usage_left, false, false));
    try std.testing.expectEqual(@as(u8, 0x0E), pad.read() & 0x0F);
    try std.testing.expectEqual(@as(u8, 0), irq.request);

    try std.testing.expect(adapter.physicalKey(&pad, &irq, core.host_adapter.physical_usage_right, false, false));
    try std.testing.expectEqual(@as(u8, 0x0F), pad.read() & 0x0F);
}

test "selected P1 falling edge wakes STOP while divider and DMA stay frozen" {
    const allocator = std.testing.allocator;
    const bytes = try makeRom(allocator, 0x00, 0x00, 0x00, 0x00);
    defer allocator.free(bytes);
    var machine = core.machine.Machine.init(.dmg_c, try core.cartridge.Cartridge.init(allocator, bytes));
    defer machine.deinit();

    machine.write(0xFF00, 0x10);
    machine.write(0xFF46, 0xC0);
    machine.tickTcycles(8);
    try std.testing.expect(machine.dma.active);
    machine.cpu.stopped = true;
    const divider = machine.timer.divider_counter;
    const dma_index = machine.dma.byte_index;
    machine.tickTcycles(16);
    try std.testing.expectEqual(divider, machine.timer.divider_counter);
    try std.testing.expectEqual(dma_index, machine.dma.byte_index);

    machine.setButton(.a, true, false);
    try std.testing.expect(machine.cpu.stop_wake_requested);
    const waking = machine.stepCpu();
    try std.testing.expectEqual(core.cpu.ExecutionKind.stopped, waking.kind);
    try std.testing.expectEqual(@as(u8, 3), waking.m_cycles);
    try std.testing.expect(!machine.cpu.stopped);
    try std.testing.expectEqual(divider +% 8, machine.timer.divider_counter);
}
