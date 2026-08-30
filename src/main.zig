const std = @import("std");
const r4os = @import("r4os");
const core = @import("core.zig");

comptime {
    if (core.host_adapter.physical_usage_up != r4os.abi.physical_key_usage_up or
        core.host_adapter.physical_usage_down != r4os.abi.physical_key_usage_down or
        core.host_adapter.physical_usage_left != r4os.abi.physical_key_usage_left or
        core.host_adapter.physical_usage_right != r4os.abi.physical_key_usage_right or
        core.host_adapter.physical_usage_enter != r4os.abi.physical_key_usage_enter or
        core.host_adapter.physical_usage_right_control != r4os.abi.physical_key_usage_right_control or
        core.host_adapter.physical_usage_left_alt != r4os.abi.physical_key_usage_left_alt or
        core.host_adapter.physical_usage_space != r4os.abi.physical_key_usage_space)
    {
        @compileError("R4GB physical input mapping drifted from the public R4DESK HID contract");
    }
}

const error_profile: i32 = 64;
const error_launch: i32 = 65;
const error_path: i32 = 66;
const error_missing: i32 = 67;
const error_directory: i32 = 68;
const error_size: i32 = 69;
const error_read: i32 = 70;
const error_cartridge: i32 = 71;
const error_not_implemented: i32 = 72;
const error_allocator: i32 = 73;

pub fn r4_app_main(app: *r4os.App) i32 {
    if (std.ascii.eqlIgnoreCase(app.args(), "/SELFTEST")) return selfTest(app);
    if (app.profile != .desktop) return error_profile;
    const files = app.files() orelse return r4os.abi.err_no_group;
    const sys = app.system();
    const launch = r4os.subsystem_launch.parse(app.args()) catch {
        sys.println("R4GB: invalid R4SUBSYS1 launch request.");
        return error_launch;
    };
    var path = r4os.AbsoluteFilePath.parse(launch.guest_path) catch {
        sys.println("R4GB: invalid absolute cartridge path.");
        return error_path;
    };
    const info = switch (files.info(path.asZ())) {
        .value => |value| value,
        .missing => {
            sys.println("R4GB: cartridge file not found.");
            return error_missing;
        },
        .failure => {
            sys.println("R4GB: cartridge metadata could not be read.");
            return error_read;
        },
    };
    if (info.is_dir != 0) {
        sys.println("R4GB: cartridge path is a directory.");
        return error_directory;
    }
    const size = std.math.cast(usize, info.size) orelse {
        sys.println("R4GB: cartridge is too large for this host.");
        return error_size;
    };
    if (size < core.cartridge.header_size) {
        sys.println("R4GB: cartridge is smaller than a complete header.");
        return error_cartridge;
    }
    if (size > core.cartridge.max_rom_bytes) {
        sys.println("R4GB: cartridge exceeds the supported 8 MiB DMG limit.");
        return error_size;
    }
    const allocator = app.allocator() orelse {
        sys.println("R4GB: application memory allocator is unavailable.");
        return error_allocator;
    };
    const image = allocator.alloc(u8, size) catch {
        sys.println("R4GB: cartridge image allocation failed.");
        return error_allocator;
    };
    var image_owned = true;
    defer if (image_owned) allocator.free(image);
    var offset: usize = 0;
    while (offset < image.len) {
        const transferred = switch (files.readAt(path.asZ(), @intCast(offset), image[offset..])) {
            .bytes => |count| count,
            .end, .failure => {
                sys.println("R4GB: cartridge header read failed.");
                return error_read;
            },
        };
        if (transferred == 0 or transferred > image.len - offset) {
            sys.println("R4GB: cartridge image read was inconsistent.");
            return error_read;
        }
        offset += transferred;
    }
    var cart = core.cartridge.Cartridge.takeOwned(allocator, image) catch |fault| {
        sys.write("R4GB: cartridge rejected: ");
        sys.println(@errorName(fault));
        return error_cartridge;
    };
    image_owned = false;
    defer cart.deinit();
    sys.write("R4GB: validated DMG cartridge ");
    sys.println(cart.header.titleSlice());
    sys.write("R4GB: mapper ");
    sys.println(@tagName(cart.header.mapper));
    sys.println("R4GB: execution is not implemented in this cartridge build.");
    return error_not_implemented;
}

fn selfTest(app: *r4os.App) i32 {
    const sys = app.system();
    const allocator = app.allocator() orelse return error_allocator;
    const bytes = allocator.alloc(u8, 32 * 1024) catch return error_allocator;
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[core.cartridge.logo_offset .. core.cartridge.logo_offset + core.cartridge.logo.len], core.cartridge.logo[0..]);
    @memcpy(bytes[0x134..0x13A], "R4TEST");
    bytes[0x147] = 0x00;
    bytes[0x148] = 0x00;
    bytes[0x149] = 0x00;
    var checksum: u8 = 0;
    for (bytes[0x134..0x14D]) |value| checksum -%= value +% 1;
    bytes[0x14D] = checksum;
    bytes[0x14E] = 0;
    bytes[0x14F] = 0;
    var global = core.cartridge.globalChecksum(bytes);
    bytes[0x14E] = @truncate(global >> 8);
    bytes[0x14F] = @truncate(global);
    const header = core.cartridge.parse(bytes) catch {
        sys.println("R4GB cartridge selftest FAILED: cartridge");
        return 90;
    };
    if (!std.mem.eql(u8, header.titleSlice(), "R4TEST") or
        core.model.production_revision != .dmg_c or
        core.host_adapter.buttonForPhysicalUsage(core.host_adapter.physical_usage_right_control) != .select)
    {
        sys.println("R4GB cartridge selftest FAILED: model");
        return 91;
    }
    bytes[0x143] = 0xC0;
    checksum = 0;
    for (bytes[0x134..0x14D]) |value| checksum -%= value +% 1;
    bytes[0x14D] = checksum;
    bytes[0x14E] = 0;
    bytes[0x14F] = 0;
    global = core.cartridge.globalChecksum(bytes);
    bytes[0x14E] = @truncate(global >> 8);
    bytes[0x14F] = @truncate(global);
    _ = core.cartridge.parse(bytes) catch |fault| {
        if (fault == error.CgbOnly) {
            sys.println("R4GB cartridge selftest: OK model=dmg-c mapper=rom-only bus=bounded input=physical");
            return 0;
        }
        sys.println("R4GB cartridge selftest FAILED: CGB rejection");
        return 92;
    };
    sys.println("R4GB cartridge selftest FAILED: CGB accepted");
    return 93;
}
