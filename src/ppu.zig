const std = @import("std");
const model = @import("model.zig");

pub const width: usize = 160;
pub const height: usize = 144;
pub const frame_pixels: usize = width * height;
pub const dots_per_line: u16 = 456;
pub const lines_per_frame: u8 = 154;
pub const oam_dots: u16 = 80;

pub const Mode = enum(u2) {
    hblank = 0,
    vblank = 1,
    oam = 2,
    transfer = 3,
};

pub const Events = struct {
    vblank_irq: bool = false,
    stat_irq: bool = false,
    frame_ready: bool = false,
};

pub const Damage = struct {
    revision: u64,
    x: u8,
    y: u8,
    width: u8,
    height: u8,
};

pub const OamAccess = enum { read, write, read_and_write };

const Sprite = struct {
    y: u8,
    x: u8,
    tile: u8,
    flags: u8,
    index: u8,
};

const ObjectPixel = struct {
    color: u2 = 0,
    palette_one: bool = false,
    behind_background: bool = false,
    sprite_x: u8 = 0xFF,
    oam_index: u8 = 0xFF,
};

const PendingObjectFetch = struct {
    sprite: Sprite = undefined,
    low: u8 = 0,
    low_step: u8 = 0,
    high_step: u8 = 0,
    low_read: bool = false,
    active: bool = false,
};

const BgFifo = struct {
    pixels: [16]u2 = .{0} ** 16,
    read_index: u4 = 0,
    count: u5 = 0,

    fn clear(self: *BgFifo) void {
        self.read_index = 0;
        self.count = 0;
    }

    fn pushRow(self: *BgFifo, low: u8, high: u8) void {
        if (self.count != 0) return;
        var pixel: u4 = 0;
        while (pixel < 8) : (pixel += 1) {
            const bit: u3 = @intCast(7 - pixel);
            self.pixels[pixel] = @intCast(((high >> bit) & 1) << 1 | ((low >> bit) & 1));
        }
        self.read_index = 0;
        self.count = 8;
    }

    fn pushPixel(self: *BgFifo, pixel: u2) void {
        if (self.count != 0) return;
        self.pixels[0] = pixel;
        self.read_index = 0;
        self.count = 1;
    }

    fn pop(self: *BgFifo) ?u2 {
        if (self.count == 0) return null;
        const value = self.pixels[self.read_index];
        self.read_index +%= 1;
        self.count -= 1;
        return value;
    }

    fn peek(self: *const BgFifo) ?u2 {
        return if (self.count == 0) null else self.pixels[self.read_index];
    }
};

const FetchState = enum(u3) {
    tile_address,
    tile_read,
    low_address,
    low_read,
    high_address,
    high_read,
    push,
};

const PaletteSource = enum(u2) { background, object_zero, object_one };

/// Dot-clocked monochrome LCD controller. `working_frame` is private to the
/// guest PPU; only complete frames are copied into the host-facing
/// `framebuffer`, so a host can never observe a half-rendered scanline.
pub const Ppu = struct {
    vram: [0x2000]u8 = .{0} ** 0x2000,
    oam: [0xA0]u8 = .{0} ** 0xA0,
    framebuffer: [frame_pixels]u8 = .{0} ** frame_pixels,
    working_frame: [frame_pixels]u8 = .{0} ** frame_pixels,

    lcdc: u8 = 0x91,
    stat: u8 = 0x82,
    scy: u8 = 0,
    scx: u8 = 0,
    ly: u8 = 0,
    lyc: u8 = 0,
    bgp: u8 = 0xFC,
    obp0: u8 = 0xFF,
    obp1: u8 = 0xFF,
    wy: u8 = 0,
    wx: u8 = 0,
    pending_wx: u8 = 0,
    wx_write_pending: bool = false,
    wx_just_changed: bool = false,
    pending_lcdc_fetch_bits: u8 = 0,
    lcdc_fetch_bits_delay: u3 = 0,

    dot: u16 = 0,
    line: u8 = 0,
    current_mode: Mode = .oam,
    stat_irq_line: bool = false,
    lcd_startup_line: bool = false,
    lcd_startup_mode2_delay: bool = false,

    scan_index: u8 = 0,
    sprites: [10]Sprite = undefined,
    sprite_count: u4 = 0,
    sprite_timing_done: [10]bool = .{false} ** 10,
    sprite_tiles_seen: [64]bool = .{false} ** 64,
    x_zero_fetch_seen: bool = false,
    sprite_stall: u8 = 0,
    sprite_bg_steps: u8 = 0,
    sprite_fetch_step: u8 = 0,
    object_fetches: [10]PendingObjectFetch = [_]PendingObjectFetch{.{}} ** 10,
    object_fetch_count: u4 = 0,
    shared_sprite_fetch: bool = false,
    object_line: [width]ObjectPixel = [_]ObjectPixel{.{}} ** width,

    fifo: BgFifo = .{},
    fetch_state: FetchState = .tile_address,
    fetch_map_address: u16 = 0,
    fetch_data_address: u16 = 0,
    fetch_tile: u8 = 0,
    fetch_low: u8 = 0,
    fetch_high: u8 = 0,
    window_tile_x: u5 = 0,
    window_line: u8 = 0,
    wy_triggered: bool = false,
    window_active: bool = false,
    window_drawn_on_line: bool = false,
    window_fetch_start: bool = false,
    insert_background_pixel: bool = false,
    window_start_stall: u1 = 0,
    disable_window_pixel_insertion_glitch: bool = false,
    repeat_window_exit_pixel: bool = false,
    window_crop: u3 = 0,
    lcd_x: u8 = 0,
    discard_pixels: u5 = 0,
    scroll_latched: bool = false,
    startup_delay: u3 = 0,
    pending_pixel: bool = false,
    pending_pixel_index: u15 = 0,
    pending_color: u2 = 0,
    pending_palette: PaletteSource = .background,
    pending_background: u2 = 0,
    pending_object: ObjectPixel = .{},

    frame_revision: u64 = 0,
    frames_completed: u64 = 0,
    frame_published: bool = false,
    damage_pending: bool = false,
    damage_min_x: u8 = 0,
    damage_min_y: u8 = 0,
    damage_max_x: u8 = 0,
    damage_max_y: u8 = 0,

    /// Reconciles the internal state with the post-boot MMIO snapshot used by
    /// a selected DMG revision. It is called exactly once by Machine.init.
    pub fn initializeDmgBootVram(self: *Ppu, logo: []const u8) void {
        // The DMG bootstrap expands the 48-byte cartridge logo into tiles
        // 1..24 and leaves the trademark glyph in tile 25. Software is free
        // to reuse that post-boot VRAM, and several hardware tests do.
        var target: usize = 0x10;
        for (logo) |logo_byte| {
            for ([_]u4{ @truncate(logo_byte >> 4), @truncate(logo_byte) }) |nibble| {
                const expanded = expandLogoNibble(nibble);
                self.vram[target] = expanded;
                self.vram[target + 2] = expanded;
                target += 4;
            }
        }
        const trademark = [_]u8{ 0x3C, 0x42, 0xB9, 0xA5, 0xB9, 0xA5, 0x42, 0x3C };
        for (trademark, 0..) |row, index| self.vram[0x190 + index * 2] = row;

        var tile: u8 = 24;
        var map_index: usize = 0x1800 + 9 * 32 + 15;
        var column: u8 = 0;
        while (tile != 0) : (tile -= 1) {
            self.vram[map_index] = tile;
            map_index -= 1;
            column += 1;
            if (column == 12) {
                column = 0;
                map_index = 0x1800 + 8 * 32 + 15;
            }
        }
        self.vram[0x1800 + 8 * 32 + 16] = 25;
    }

    pub fn synchronizeAfterBoot(self: *Ppu, revision: model.Revision) void {
        if (revision == .dmg_0) {
            self.line = if (self.ly < lines_per_frame) self.ly else 0;
            self.current_mode = @enumFromInt(self.stat & 0x03);
            self.dot = switch (self.current_mode) {
                .oam => 0,
                .transfer => oam_dots,
                .hblank => 252,
                .vblank => 0,
            };
        } else {
            // DMG CPU A/B/C leave the boot ROM late on physical line 153.
            // Starting at dot 264 makes the later boot_hwio probe observe
            // STAT=$80 in line 9 HBlank and LY=$0A at the following boundary,
            // matching the measured Mooneye DMG-ABC phase.
            self.line = 153;
            self.ly = 0;
            self.dot = 264;
            self.current_mode = .vblank;
        }
        if (!self.lcdEnabled()) {
            self.line = 0;
            self.ly = 0;
            self.dot = 0;
            self.current_mode = .hblank;
        }
        self.syncStat();
        self.stat_irq_line = self.statSource();
    }

    pub fn mode(self: *const Ppu) Mode {
        return self.current_mode;
    }

    pub fn lcdEnabled(self: *const Ppu) bool {
        return (self.lcdc & 0x80) != 0;
    }

    pub fn cpuVramBlocked(self: *const Ppu) bool {
        if (!self.lcdEnabled()) return false;
        return self.current_mode == .transfer or
            (self.current_mode == .oam and self.dot >= oam_dots - 2);
    }

    pub fn cpuVramWriteBlocked(self: *const Ppu) bool {
        return self.lcdEnabled() and self.current_mode == .transfer;
    }

    pub fn cpuOamBlocked(self: *const Ppu) bool {
        if (!self.lcdEnabled()) return false;
        if (self.lcd_startup_line and self.dot >= dots_per_line - 4) return true;
        if (self.lcd_startup_mode2_delay and self.dot >= 2) return true;
        if (self.current_mode == .hblank and self.dot >= dots_per_line - 4) return true;
        return self.current_mode == .oam or self.current_mode == .transfer;
    }

    pub fn cpuOamWriteBlocked(self: *const Ppu) bool {
        if (!self.lcdEnabled()) return false;
        if (self.lcd_startup_mode2_delay and self.dot >= 2) return true;
        return self.current_mode == .transfer or
            (self.current_mode == .oam and self.dot < oam_dots - 4);
    }

    pub fn readStat(self: *const Ppu) u8 {
        var value = self.stat | 0x80;
        if (self.lcd_startup_line and self.dot >= dots_per_line - 4) {
            // LY has advanced on the external latch while the mode pins still
            // expose zero for this short LCD-start boundary.
            value &= ~@as(u8, 0x04);
        } else if (self.lcd_startup_mode2_delay and self.dot >= 2) {
            value = (value & 0xFC) | 0x02;
        } else if (self.current_mode == .hblank and self.dot >= dots_per_line - 4) {
            const next_ly = self.line + 1;
            value = (value & ~@as(u8, 0x04)) |
                (if (next_ly == self.lyc) @as(u8, 0x04) else 0);
        }
        if (self.current_mode == .transfer and self.sprite_count != 0 and self.startup_delay == 0 and
            self.discard_pixels == 0 and self.window_crop == 0)
        {
            const pixels_left: u8 = @intCast(width - self.lcd_x);
            // STAT's mode pins are sampled on T3 of the CPU read. A transfer
            // completing in the next three dots is therefore already seen as
            // mode 0, while a boundary four dots away remains mode 3.
            const dots_left: u16 = @as(u16, self.sprite_stall) + pixels_left;
            const sampled_hblank = dots_left == 1;
            if (sampled_hblank and self.fifo.count >= pixels_left) value &= 0xFC;
        }
        return value;
    }

    /// LY changes during the CPU memory phase on a read that straddles the
    /// line boundary; expose the value driven at the end of that phase.
    pub fn readLy(self: *const Ppu) u8 {
        if (!self.lcdEnabled()) return 0;
        if (self.line == 153) return if (self.dot < 4) 153 else 0;
        if (self.dot >= dots_per_line - 4) return self.line + 1;
        return self.ly;
    }

    pub fn writeLcdc(self: *Ppu, value: u8) Events {
        const was_enabled = self.lcdEnabled();
        const objects_were_enabled = (self.lcdc & 0x02) != 0;
        const previous_fetch_bits = self.lcdc & 0x50;
        if ((self.lcdc & 0x20) != 0 and (value & 0x20) == 0 and self.window_fetch_start) {
            self.disable_window_pixel_insertion_glitch = true;
        }
        if (self.pending_pixel and self.pending_pixel_index % width == 0) {
            // LCD X=0 is still on the first panel latch when the CPU write
            // phase arrives; control-bit changes can therefore affect that
            // pending pixel. Later X positions have already crossed the
            // latch and retain the previous LCDC composition.
            self.selectPendingPixel(value);
        }
        self.commitPendingPixel();
        self.lcdc = value;
        const first_visible_object_fetch = self.current_mode == .transfer and self.lcd_x == 0 and
            self.fetch_state == .tile_read and self.fifo.count == 8 and self.sprite_count != 0 and
            self.sprites[0].x == 8 and self.sprite_timing_done[0];
        if (was_enabled and (value & 0x80) != 0 and previous_fetch_bits != (value & 0x50) and
            first_visible_object_fetch)
        {
            self.pending_lcdc_fetch_bits = value & 0x50;
            self.lcdc_fetch_bits_delay = 4;
            self.lcdc = (self.lcdc & ~@as(u8, 0x50)) | previous_fetch_bits;
        }
        if (objects_were_enabled and (value & 0x02) == 0 and self.sprite_stall != 0) {
            self.abortObjectFetch();
        }
        const enabled = self.lcdEnabled();
        var events = Events{};
        if (was_enabled == enabled) return events;

        if (!enabled) {
            self.line = 0;
            self.ly = 0;
            self.dot = 0;
            self.current_mode = .hblank;
            self.wy_triggered = false;
            self.window_line = 0;
            self.window_active = false;
            self.lcd_startup_line = false;
            self.lcd_startup_mode2_delay = false;
            self.fifo.clear();
            @memset(&self.working_frame, 0);
            events.frame_ready = self.publishFrame();
        } else {
            // DMG starts LCD line 0 in mode 0, skips its OAM search, and enters
            // mode 3 two dots late. Line 1 briefly exposes mode 0 before the
            // regular mode-2/3/0 cadence takes over.
            self.line = 0;
            self.ly = 0;
            self.dot = 0;
            self.window_line = 0;
            self.wy_triggered = self.wy == 0;
            self.current_mode = .hblank;
            self.scan_index = 0;
            self.sprite_count = 0;
            self.lcd_startup_line = true;
            self.lcd_startup_mode2_delay = false;
        }
        if (enabled) {
            self.syncStat();
        } else {
            // LCD-off forces mode 0 but freezes the last LY=LYC result.
            self.stat &= 0xFC;
        }
        if (enabled) self.updateStatIrq(&events);
        return events;
    }

    /// DMG STAT writes briefly behave as if all enable bits were set. The
    /// returned event represents both that quirk and a normal newly-rising
    /// selected source after the control bits take effect.
    pub fn writeStat(self: *Ppu, value: u8) Events {
        var events = Events{};
        if (self.lcdEnabled() and !self.stat_irq_line and
            (self.current_mode != .transfer or self.ly == self.lyc))
        {
            events.stat_irq = true;
        }
        self.stat = (self.stat & 0x07) | (value & 0x78) | 0x80;
        self.syncStat();
        self.updateStatIrq(&events);
        return events;
    }

    pub fn writeLyc(self: *Ppu, value: u8) Events {
        self.lyc = value;
        var events = Events{};
        if (!self.lcdEnabled()) return events;
        self.syncStat();
        self.updateStatIrq(&events);
        return events;
    }

    pub fn writeBgp(self: *Ppu, value: u8) void {
        self.writePalette(.background, &self.bgp, value);
    }

    pub fn writeObp0(self: *Ppu, value: u8) void {
        self.writePalette(.object_zero, &self.obp0, value);
    }

    pub fn writeObp1(self: *Ppu, value: u8) void {
        self.writePalette(.object_one, &self.obp1, value);
    }

    /// WX reaches the PPU one T-cycle after the CPU starts its write cycle.
    /// Keeping that latch separate is observable when the old coordinate
    /// triggers the window on the same T-cycle as a new WX value is written.
    pub fn writeWx(self: *Ppu, value: u8) void {
        self.pending_wx = value;
        self.wx_write_pending = true;
    }

    pub fn tick(self: *Ppu) Events {
        defer self.finishWxCycle();
        defer self.finishLcdcFetchBitsCycle();
        var events = Events{};
        self.commitPendingPixel();
        if (!self.lcdEnabled()) return events;

        switch (self.current_mode) {
            .oam => {
                if ((self.dot & 1) != 0 and self.scan_index < 40) self.scanObject(self.scan_index);
                self.dot += 1;
                self.scan_index = @intCast(@min(self.dot / 2, 40));
                if (self.dot == oam_dots) {
                    self.beginTransfer();
                    self.setMode(.transfer, &events);
                }
            },
            .transfer => {
                self.tickTransfer();
                self.dot += 1;
                if (self.lcd_x == width) self.setMode(.hblank, &events);
            },
            .hblank => {
                self.dot += 1;
                if (self.lcd_startup_line and self.dot == 80) {
                    self.beginTransfer();
                    self.setMode(.transfer, &events);
                } else if (self.lcd_startup_line and self.dot == dots_per_line - 2) {
                    self.dot = 0;
                    self.line = 1;
                    self.ly = 1;
                    self.lcd_startup_line = false;
                    self.lcd_startup_mode2_delay = true;
                    self.syncStat();
                    self.updateStatIrq(&events);
                } else if (self.lcd_startup_mode2_delay and self.dot == 4) {
                    self.lcd_startup_mode2_delay = false;
                    self.beginVisibleLine();
                    self.updateStatIrq(&events);
                } else if (!self.lcd_startup_line and !self.lcd_startup_mode2_delay and self.dot == dots_per_line) {
                    self.advanceLine(&events);
                }
            },
            .vblank => {
                self.dot += 1;
                // On DMG, LY exposes zero for nearly all of line 153 even
                // though the PPU remains in mode 1 until dot 456.
                if (self.line == 153 and self.dot == 4) {
                    self.ly = 0;
                    self.syncStat();
                    self.updateStatIrq(&events);
                }
                if (self.dot == dots_per_line) self.advanceLine(&events);
            },
        }
        return events;
    }

    fn finishWxCycle(self: *Ppu) void {
        if (self.wx_write_pending) {
            self.wx = self.pending_wx;
            self.wx_write_pending = false;
            self.wx_just_changed = true;
        } else {
            self.wx_just_changed = false;
        }
    }

    fn finishLcdcFetchBitsCycle(self: *Ppu) void {
        if (self.lcdc_fetch_bits_delay == 0) return;
        self.lcdc_fetch_bits_delay -= 1;
        if (self.lcdc_fetch_bits_delay != 0) return;
        self.lcdc = (self.lcdc & ~@as(u8, 0x50)) | self.pending_lcdc_fetch_bits;
    }

    pub fn takeDamage(self: *Ppu) ?Damage {
        if (!self.damage_pending) return null;
        self.damage_pending = false;
        return .{
            .revision = self.frame_revision,
            .x = self.damage_min_x,
            .y = self.damage_min_y,
            .width = self.damage_max_x - self.damage_min_x + 1,
            .height = self.damage_max_y - self.damage_min_y + 1,
        };
    }

    /// A running DMG CPU samples the next mode-2 STAT source on the final
    /// M-cycle of HBlank. HALT wake-up remains tied to the visible mode edge;
    /// the machine therefore calls this only while the CPU is executing.
    pub fn sampleRunningMode2Edge(self: *Ppu) bool {
        if (!self.lcdEnabled() or self.lcd_startup_line or self.lcd_startup_mode2_delay) return false;
        if (self.current_mode != .hblank or self.dot != dots_per_line - 4 or self.line + 1 >= height) return false;
        if ((self.stat & 0x20) == 0 or self.stat_irq_line) return false;
        self.stat_irq_line = true;
        return true;
    }

    /// Applies the documented monochrome OAM row corruption for a CPU access
    /// during mode 2. Addresses are irrelevant on the physical 16-bit bus;
    /// the row currently scanned by the PPU determines the affected data.
    pub fn corruptOam(self: *Ppu, access: OamAccess) void {
        if (!self.lcdEnabled() or self.current_mode != .oam) return;
        const row: usize = @min(@as(usize, self.dot / 4), 19);
        if (row == 0) return;
        const current = row * 8;
        const previous = current - 8;
        const a = readWord(&self.oam, current);
        const b = readWord(&self.oam, previous);
        const c = readWord(&self.oam, previous + 4);
        const first = switch (access) {
            .read => b | (a & c),
            .write, .read_and_write => ((a ^ c) & (b ^ c)) ^ c,
        };
        writeWord(&self.oam, current, first);
        @memcpy(self.oam[current + 2 .. current + 8], self.oam[previous + 2 .. previous + 8]);
    }

    fn beginVisibleLine(self: *Ppu) void {
        self.current_mode = .oam;
        self.scan_index = 0;
        self.sprite_count = 0;
        self.window_active = false;
        self.window_drawn_on_line = false;
        self.window_fetch_start = false;
        self.insert_background_pixel = false;
        self.window_start_stall = 0;
        self.disable_window_pixel_insertion_glitch = false;
        self.repeat_window_exit_pixel = false;
        if (self.line == self.wy) self.wy_triggered = true;
        self.syncStat();
    }

    fn scanObject(self: *Ppu, index: u8) void {
        if (self.sprite_count == 10) return;
        const base: usize = @as(usize, index) * 4;
        const y = self.oam[base];
        const sprite_height: u8 = if ((self.lcdc & 0x04) != 0) 16 else 8;
        const line_plus_16: u16 = @as(u16, self.line) + 16;
        if (line_plus_16 < y or line_plus_16 >= @as(u16, y) + sprite_height) return;
        self.sprites[self.sprite_count] = .{
            .y = y,
            .x = self.oam[base + 1],
            .tile = self.oam[base + 2],
            .flags = self.oam[base + 3],
            .index = index,
        };
        self.sprite_count += 1;
    }

    fn beginTransfer(self: *Ppu) void {
        self.fifo.clear();
        self.fifo.pushRow(0, 0);
        self.fetch_state = .tile_address;
        self.fetch_map_address = 0;
        self.fetch_data_address = 0;
        self.fetch_tile = 0;
        self.fetch_low = 0;
        self.fetch_high = 0;
        self.window_tile_x = 0;
        self.window_active = false;
        self.window_drawn_on_line = false;
        self.window_crop = 0;
        self.lcd_x = 0;
        self.discard_pixels = 8;
        self.scroll_latched = false;
        // Four setup dots plus the eight discarded FIFO pixels produce the
        // measured 12-dot baseline penalty and a mode-0 edge at dot 252.
        self.startup_delay = 4;
        self.sprite_stall = 0;
        self.sprite_bg_steps = 0;
        self.sprite_fetch_step = 0;
        self.object_fetch_count = 0;
        @memset(&self.object_fetches, .{});
        self.shared_sprite_fetch = false;
        @memset(&self.object_line, .{});
        @memset(&self.sprite_timing_done, false);
        @memset(&self.sprite_tiles_seen, false);
        self.x_zero_fetch_seen = false;
    }

    fn tickTransfer(self: *Ppu) void {
        if (self.startup_delay != 0) {
            self.startup_delay -= 1;
            return;
        }
        if (self.sprite_stall != 0) {
            self.sprite_fetch_step +|= 1;
            self.processObjectFetches();
            if (self.sprite_bg_steps != 0) {
                self.advanceFetcher();
                self.sprite_bg_steps -= 1;
            }
            self.sprite_stall -= 1;
            return;
        }
        if (self.hasPendingObjectFetch()) {
            self.sprite_fetch_step +|= 1;
            self.processObjectFetches();
        }

        if (!self.scroll_latched) {
            self.discard_pixels += @as(u5, @intCast(self.scx & 7));
            self.scroll_latched = true;
        }

        self.maybeLeaveWindow();
        self.maybeStartWindow();
        if (self.window_start_stall != 0) {
            self.window_start_stall = 0;
            return;
        }
        self.maybeInsertWindowPixel();
        if (self.beginSpritePenalty()) return;

        const background: ?u2 = if (self.insert_background_pixel) blk: {
            self.insert_background_pixel = false;
            break :blk 0;
        } else if (self.repeat_window_exit_pixel) blk: {
            self.repeat_window_exit_pixel = false;
            break :blk self.fifo.peek();
        } else self.fifo.pop();
        if (background) |pixel| {
            self.window_fetch_start = false;
            if (self.discard_pixels != 0) {
                self.discard_pixels -= 1;
            } else if (self.window_crop != 0) {
                self.window_crop -= 1;
            } else if (self.lcd_x < width) {
                self.renderPixel(pixel);
                self.lcd_x += 1;
            }
        }
        self.advanceFetcher();
    }

    fn maybeStartWindow(self: *Ppu) void {
        if (self.window_active or !self.wy_triggered or (self.lcdc & 0x20) == 0 or self.wx > 166) return;
        const position: i16 = if (self.discard_pixels != 0)
            -@as(i16, self.discard_pixels)
        else
            self.lcd_x;
        const starts_here = if (self.wx == 0)
            position >= -15 and position <= -7
        else
            position + 7 == self.wx or
                (!self.wx_just_changed and position + 6 == self.wx);
        if (!starts_here) return;
        if (self.window_drawn_on_line) self.window_line +%= 1;
        self.window_active = true;
        self.window_drawn_on_line = true;
        self.window_fetch_start = true;
        self.window_start_stall = @intFromBool(self.wx == 0 and (self.scx & 7) != 0);
        self.window_tile_x = 0;
        self.window_crop = 0;
        self.fifo.clear();
        self.fetch_state = .tile_address;
    }

    fn maybeInsertWindowPixel(self: *Ppu) void {
        if (!self.window_active or self.window_fetch_start or self.insert_background_pixel) return;
        if (self.fetch_state != .tile_address or self.fifo.count != 8) return;
        const position: i16 = if (self.discard_pixels != 0)
            -@as(i16, self.discard_pixels)
        else
            self.lcd_x;
        if (position + 7 == self.wx) self.insert_background_pixel = true;
    }

    fn maybeLeaveWindow(self: *Ppu) void {
        if (!self.window_active or (self.lcdc & 0x20) != 0) return;
        // WIN_EN is sampled when the fetcher starts its next tile. Pixels
        // already queued from the current window tile continue to the LCD,
        // while that next fetch is redirected to the background map.
        if (self.fetch_state != .tile_address and self.fetch_state != .tile_read) return;
        // WX=0 is the DMG's exceptional left-edge phase. If WIN_EN falls on
        // the first visible tile boundary, the LCD consumes the first queued
        // window pixel twice before the background stream takes over.
        if (self.wx == 0 and self.lcd_x == 0 and self.discard_pixels == 0 and self.fifo.count == 8) {
            self.repeat_window_exit_pixel = true;
        }
        self.window_active = false;
        self.window_fetch_start = false;
    }

    fn advanceFetcher(self: *Ppu) void {
        switch (self.fetch_state) {
            .tile_address => {
                self.fetch_state = .tile_read;
            },
            .tile_read => {
                const map_base: u16 = if (self.window_active)
                    (if ((self.lcdc & 0x40) != 0) 0x1C00 else 0x1800)
                else
                    (if ((self.lcdc & 0x08) != 0) 0x1C00 else 0x1800);
                const y: u8 = if (self.window_active) self.window_line else self.line +% self.scy;
                const tile_x: u5 = if (self.window_active)
                    self.window_tile_x
                else
                    self.backgroundMapX();
                self.fetch_map_address = map_base + @as(u16, y / 8) * 32 + tile_x;
                self.fetch_tile = self.vram[self.fetch_map_address];
                self.fetch_state = .low_address;
            },
            .low_address => {
                self.fetch_state = .low_read;
            },
            .low_read => {
                self.fetch_data_address = self.tileLineAddress(false);
                self.fetch_low = self.vram[self.fetch_data_address];
                self.fetch_state = .high_address;
            },
            .high_address => {
                self.fetch_state = .high_read;
            },
            .high_read => {
                self.fetch_data_address = self.tileLineAddress(true);
                self.fetch_high = self.vram[self.fetch_data_address];
                self.fetch_state = .push;
                self.pushFetchedBackground();
            },
            .push => {
                self.pushFetchedBackground();
            },
        }
    }

    fn backgroundMapX(self: *const Ppu) u5 {
        // The fetcher's coordinate is based on its signed output position,
        // not on the number of queued FIFO pixels. This distinction is
        // observable when an OBJ fetch pauses output before the initial junk
        // pixels have been discarded.
        const fetch_x: u16 = if (self.discard_pixels >= 8)
            self.scx
        else if (self.discard_pixels != 0)
            @as(u16, self.scx) + 8 - self.discard_pixels
        else
            @as(u16, self.scx) + self.lcd_x + self.fifo.count;
        return @intCast(fetch_x / 8 & 0x1F);
    }

    fn pushFetchedBackground(self: *Ppu) void {
        if (self.fifo.count != 0) return;
        if (!self.window_active and self.wy_triggered and (self.lcdc & 0x20) == 0 and
            !self.disable_window_pixel_insertion_glitch)
        {
            const position: i16 = if (self.discard_pixels != 0)
                -@as(i16, self.discard_pixels)
            else
                self.lcd_x;
            var logical_position = position + 7;
            if (logical_position > 167) logical_position = 0;
            if (logical_position == self.wx) {
                self.fifo.pushPixel(0);
                return;
            }
        }
        self.fifo.pushRow(self.fetch_low, self.fetch_high);
        if (self.window_active) self.window_tile_x +%= 1;
        self.fetch_state = .tile_address;
    }

    fn tileLineAddress(self: *const Ppu, high_byte: bool) u16 {
        const unsigned_tiles = (self.lcdc & 0x10) != 0;
        const tile_base: u16 = if (unsigned_tiles)
            @as(u16, self.fetch_tile) * 16
        else
            @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(self.fetch_tile))) * 16 + 0x1000));
        const y: u8 = if (self.window_active) self.window_line else self.line +% self.scy;
        return tile_base + @as(u16, y & 7) * 2 + @intFromBool(high_byte);
    }

    fn beginSpritePenalty(self: *Ppu) bool {
        var penalty: u16 = 0;
        var background_steps: u16 = 0;
        var batch_count: u8 = 0;
        var batch_x: u8 = 0;
        var same_x = true;
        var sprite_index: usize = 0;
        const object_match_x: u8 = if (self.discard_pixels != 0)
            8 -| @as(u8, @intCast(self.discard_pixels))
        else
            self.lcd_x +| 8;
        while (sprite_index < self.sprite_count) : (sprite_index += 1) {
            if (self.sprite_timing_done[sprite_index]) continue;
            const sprite = self.sprites[sprite_index];
            if (sprite.x > object_match_x) continue;
            self.sprite_timing_done[sprite_index] = true;
            if ((self.lcdc & 0x02) == 0) continue;
            if (batch_count == 0) {
                self.sprite_fetch_step = 0;
                self.object_fetch_count = 0;
                @memset(&self.object_fetches, .{});
                batch_x = sprite.x;
            } else if (sprite.x != batch_x) {
                same_x = false;
            }
            batch_count += 1;
            if (sprite.x == 0) {
                // X=0 pays the exceptional five-dot tile wait only once;
                // further objects at the same fetch position still cost the
                // normal six-dot OBJ fetch. Its clipped fetch is separate
                // from background tile zero, which matters for an X=8 object.
                const extra: u8 = if (self.x_zero_fetch_seen) 0 else 5;
                self.x_zero_fetch_seen = true;
                self.scheduleObjectFetch(sprite, penalty, extra);
                penalty += 6 + extra;
                background_steps += extra + 2;
                continue;
            }
            const signed_left: i16 = @as(i16, sprite.x) - 8;
            const scroll: i16 = if (self.window_active) 0 else self.scx;
            const source_tile: u5 = @intCast(@mod(@divFloor(signed_left + scroll, 8), 32));
            const key_offset: u6 = if (self.window_active) 32 else 0;
            const key: u6 = key_offset + @as(u6, source_tile);
            var extra: u8 = 0;
            if (!self.sprite_tiles_seen[key]) {
                self.sprite_tiles_seen[key] = true;
                const pixel_in_tile: u8 = @intCast(@mod(signed_left + scroll, 8));
                const pixels_right: u8 = 7 - pixel_in_tile;
                extra = pixels_right -| 2;
            }
            self.scheduleObjectFetch(sprite, penalty, extra);
            penalty += 6 + extra;
            background_steps += extra + 2;
        }
        if (penalty == 0) return false;
        // Multiple objects beginning on the same dot share the final fetcher
        // hand-off on DMG. Objects at distinct X positions do not.
        if (batch_count > 1 and same_x) self.shared_sprite_fetch = true;
        if (batch_count > 1 and same_x and batch_x == 0) penalty -= 1;
        // This dot is the first dot of the accumulated fetch penalty.
        self.sprite_stall = @intCast(@min(penalty - 1, 255));
        self.sprite_bg_steps = @intCast(@min(background_steps, 255));
        if (self.sprite_bg_steps != 0) {
            self.advanceFetcher();
            self.sprite_bg_steps -= 1;
        }
        self.processObjectFetches();
        return true;
    }

    fn renderPixel(self: *Ppu, fetched_background: u2) void {
        self.pending_pixel = true;
        self.pending_pixel_index = @intCast(@as(usize, self.line) * width + self.lcd_x);
        self.pending_background = fetched_background;
        self.pending_object = self.objectPixel(self.lcd_x) orelse .{};
        self.selectPendingPixel(self.lcdc);
    }

    fn commitPendingPixel(self: *Ppu) void {
        if (!self.pending_pixel) return;
        const palette = switch (self.pending_palette) {
            .background => self.bgp,
            .object_zero => self.obp0,
            .object_one => self.obp1,
        };
        self.working_frame[self.pending_pixel_index] = paletteShade(palette, self.pending_color);
        self.pending_pixel = false;
    }

    fn selectPendingPixel(self: *Ppu, control: u8) void {
        const background: u2 = if ((control & 0x01) != 0) self.pending_background else 0;
        self.pending_color = background;
        self.pending_palette = .background;
        if ((control & 0x02) == 0 or self.pending_object.color == 0) return;
        if (self.pending_object.behind_background and background != 0) return;
        self.pending_color = self.pending_object.color;
        self.pending_palette = if (self.pending_object.palette_one) .object_one else .object_zero;
    }

    fn writePalette(self: *Ppu, source: PaletteSource, register: *u8, value: u8) void {
        if (self.pending_pixel and self.pending_palette == source) {
            const old_shade = paletteShade(register.*, self.pending_color);
            const new_shade = paletteShade(value, self.pending_color);
            // A DMG palette write overlaps the pending LCD dot: its two shade
            // bits observe the wired-OR of the old and new register values.
            self.working_frame[self.pending_pixel_index] = old_shade | new_shade;
            self.pending_pixel = false;
        }
        register.* = value;
    }

    fn objectPixel(self: *const Ppu, x: u8) ?ObjectPixel {
        const object = self.object_line[x];
        return if (object.color == 0) null else object;
    }

    fn scheduleObjectFetch(self: *Ppu, sprite: Sprite, prior_penalty: u16, background_wait: u8) void {
        if (self.object_fetch_count == self.object_fetches.len) return;
        const slot = &self.object_fetches[self.object_fetch_count];
        slot.* = .{
            .sprite = sprite,
            .low_step = @intCast(@min(prior_penalty + background_wait + 3, 255)),
            .high_step = @intCast(@min(prior_penalty + background_wait + 6, 255)),
            .active = true,
        };
        self.object_fetch_count += 1;
    }

    fn processObjectFetches(self: *Ppu) void {
        var index: usize = 0;
        while (index < self.object_fetch_count) : (index += 1) {
            const pending = &self.object_fetches[index];
            if (!pending.active) continue;
            if (!pending.low_read and self.sprite_fetch_step >= pending.low_step) {
                pending.low = self.vram[self.objectLineAddress(pending.sprite, false)];
                pending.low_read = true;
            }
            if (self.sprite_fetch_step >= pending.high_step) {
                const high = self.vram[self.objectLineAddress(pending.sprite, true)];
                self.overlayObjectRow(pending.sprite, pending.low, high);
                pending.active = false;
            }
        }
    }

    fn hasPendingObjectFetch(self: *const Ppu) bool {
        var index: usize = 0;
        while (index < self.object_fetch_count) : (index += 1) {
            if (self.object_fetches[index].active) return true;
        }
        return false;
    }

    fn abortObjectFetch(self: *Ppu) void {
        self.sprite_stall = 0;
        self.sprite_bg_steps = 0;
        var index: usize = 0;
        while (index < self.object_fetch_count) : (index += 1) self.object_fetches[index].active = false;
        // A DMG releases the fetcher on the very dot which observes OBJ_EN
        // going low. The CPU write callback precedes that dot in this model,
        // so consume the newly released transfer slot immediately.
        if (self.current_mode == .transfer and self.lcdEnabled()) self.tickTransfer();
    }

    fn objectLineAddress(self: *const Ppu, sprite: Sprite, high_byte: bool) usize {
        const sprite_height: u8 = if ((self.lcdc & 0x04) != 0) 16 else 8;
        var row: u8 = self.line +% 16 -% sprite.y;
        if ((sprite.flags & 0x40) != 0) row = sprite_height -% 1 -% row;
        const tile = if (sprite_height == 16) (sprite.tile & 0xFE) + row / 8 else sprite.tile;
        return @as(usize, tile) * 16 + @as(usize, row & 7) * 2 + @intFromBool(high_byte);
    }

    /// Overlay the two bitplanes only after the OBJ fetch has completed.
    /// Register and VRAM changes after this point cannot retroactively alter
    /// pixels already waiting in the object FIFO.
    fn overlayObjectRow(self: *Ppu, sprite: Sprite, low: u8, high: u8) void {
        const left: i16 = @as(i16, sprite.x) - 8;
        var offset: u4 = 0;
        while (offset < 8) : (offset += 1) {
            const screen_x = left + offset;
            if (screen_x < 0 or screen_x >= width) continue;
            const source_bit: u3 = if ((sprite.flags & 0x20) != 0)
                @intCast(offset)
            else
                @intCast(7 - offset);
            const color: u2 = @intCast(((high >> source_bit) & 1) << 1 |
                ((low >> source_bit) & 1));
            if (color == 0) continue;
            const target: usize = @intCast(screen_x);
            const previous = self.object_line[target];
            if (previous.color != 0 and
                (previous.sprite_x < sprite.x or
                    (previous.sprite_x == sprite.x and previous.oam_index < sprite.index))) continue;
            self.object_line[target] = .{
                .color = color,
                .palette_one = (sprite.flags & 0x10) != 0,
                .behind_background = (sprite.flags & 0x80) != 0,
                .sprite_x = sprite.x,
                .oam_index = sprite.index,
            };
        }
    }

    fn advanceLine(self: *Ppu, events: *Events) void {
        self.dot = 0;
        if (self.current_mode == .vblank) {
            if (self.line == 153) {
                self.line = 0;
                self.ly = 0;
                self.window_line = 0;
                self.wy_triggered = self.wy == 0;
                self.beginVisibleLine();
                self.updateStatIrq(events);
                return;
            }
            self.line += 1;
            self.ly = self.line;
            self.syncStat();
            self.updateStatIrq(events);
            return;
        }

        if (self.window_drawn_on_line) self.window_line +%= 1;
        self.line += 1;
        self.ly = self.line;
        if (self.line == height) {
            const mode2_vblank_edge = (self.stat & 0x20) != 0 and !self.stat_irq_line;
            self.setMode(.vblank, events);
            // On monochrome hardware, the mode-2 STAT source also pulses at
            // the line-144 boundary even though the externally visible mode
            // becomes 1. It is simultaneous with the VBlank request.
            if (mode2_vblank_edge) events.stat_irq = true;
            events.vblank_irq = true;
            self.frames_completed +%= 1;
            events.frame_ready = self.publishFrame();
        } else {
            self.beginVisibleLine();
            self.updateStatIrq(events);
        }
    }

    fn setMode(self: *Ppu, next: Mode, events: *Events) void {
        self.current_mode = next;
        self.syncStat();
        self.updateStatIrq(events);
    }

    fn syncStat(self: *Ppu) void {
        self.stat = (self.stat & 0xF8) | @intFromEnum(self.current_mode) |
            (if (self.ly == self.lyc) @as(u8, 0x04) else 0);
    }

    fn statSource(self: *const Ppu) bool {
        if (!self.lcdEnabled()) return false;
        return ((self.stat & 0x40) != 0 and self.ly == self.lyc) or
            ((self.stat & 0x20) != 0 and self.current_mode == .oam) or
            ((self.stat & 0x10) != 0 and self.current_mode == .vblank) or
            ((self.stat & 0x08) != 0 and self.current_mode == .hblank);
    }

    fn updateStatIrq(self: *Ppu, events: *Events) void {
        const active = self.statSource();
        if (active and !self.stat_irq_line) events.stat_irq = true;
        self.stat_irq_line = active;
    }

    fn publishFrame(self: *Ppu) bool {
        var min_x: usize = width;
        var min_y: usize = height;
        var max_x: usize = 0;
        var max_y: usize = 0;
        var changed = !self.frame_published;
        if (self.frame_published) {
            for (self.working_frame, 0..) |pixel, index| {
                if (pixel == self.framebuffer[index]) continue;
                changed = true;
                const x = index % width;
                const y = index / width;
                min_x = @min(min_x, x);
                min_y = @min(min_y, y);
                max_x = @max(max_x, x);
                max_y = @max(max_y, y);
            }
        }
        if (!changed) return false;
        @memcpy(&self.framebuffer, &self.working_frame);
        self.frame_published = true;
        self.frame_revision +%= 1;
        if (min_x == width) {
            min_x = 0;
            min_y = 0;
            max_x = width - 1;
            max_y = height - 1;
        }
        if (!self.damage_pending) {
            self.damage_min_x = @intCast(min_x);
            self.damage_min_y = @intCast(min_y);
            self.damage_max_x = @intCast(max_x);
            self.damage_max_y = @intCast(max_y);
            self.damage_pending = true;
        } else {
            self.damage_min_x = @min(self.damage_min_x, @as(u8, @intCast(min_x)));
            self.damage_min_y = @min(self.damage_min_y, @as(u8, @intCast(min_y)));
            self.damage_max_x = @max(self.damage_max_x, @as(u8, @intCast(max_x)));
            self.damage_max_y = @max(self.damage_max_y, @as(u8, @intCast(max_y)));
        }
        return true;
    }
};

fn paletteShade(palette: u8, color: u2) u2 {
    return @intCast((palette >> (@as(u3, color) * 2)) & 3);
}

fn expandLogoNibble(nibble: u4) u8 {
    var result: u8 = 0;
    for (0..4) |offset| {
        const source_bit: u2 = @intCast(3 - offset);
        const pair: u2 = if (((nibble >> source_bit) & 1) != 0) 3 else 0;
        result |= @as(u8, pair) << @intCast(6 - offset * 2);
    }
    return result;
}

fn readWord(memory: *const [0xA0]u8, offset: usize) u16 {
    return @as(u16, memory[offset]) | (@as(u16, memory[offset + 1]) << 8);
}

fn writeWord(memory: *[0xA0]u8, offset: usize, value: u16) void {
    memory[offset] = @truncate(value);
    memory[offset + 1] = @truncate(value >> 8);
}

test "LCD modes cover 154 lines and line 153 exposes the LY zero quirk" {
    var unit = Ppu{};
    var vblanks: usize = 0;
    var ticks: usize = 0;
    while (ticks < @as(usize, dots_per_line) * lines_per_frame) : (ticks += 1) {
        const events = unit.tick();
        if (events.vblank_irq) vblanks += 1;
        if (unit.line < 144 and unit.dot < 80) try std.testing.expectEqual(Mode.oam, unit.mode());
    }
    try std.testing.expectEqual(@as(usize, 1), vblanks);
    try std.testing.expectEqual(@as(u8, 0), unit.line);
    try std.testing.expectEqual(@as(u8, 0), unit.ly);
    try std.testing.expectEqual(Mode.oam, unit.mode());
}

test "tile pipeline publishes exact DMG shade indices and suppresses unchanged frames" {
    var unit = Ppu{};
    unit.lcdc = 0x91;
    unit.bgp = 0xE4;
    unit.vram[0x1800] = 0;
    unit.vram[0] = 0x55;
    unit.vram[1] = 0x33;
    var ticks: usize = 0;
    while (ticks < @as(usize, dots_per_line) * 144) : (ticks += 1) _ = unit.tick();
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 0, 1, 2, 3 }, unit.framebuffer[0..8]);
    const first = unit.takeDamage().?;
    try std.testing.expectEqual(@as(u8, 160), first.width);
    try std.testing.expectEqual(@as(u8, 144), first.height);
    ticks = 0;
    while (ticks < @as(usize, dots_per_line) * lines_per_frame) : (ticks += 1) _ = unit.tick();
    try std.testing.expect(unit.takeDamage() == null);
}

test "LCD disable publishes white and restores unrestricted mode zero" {
    var unit = Ppu{};
    @memset(&unit.framebuffer, 3);
    unit.frame_published = true;
    const events = unit.writeLcdc(unit.lcdc & ~@as(u8, 0x80));
    try std.testing.expect(events.frame_ready);
    try std.testing.expectEqual(Mode.hblank, unit.mode());
    try std.testing.expectEqual(@as(u8, 0), unit.ly);
    try std.testing.expect(!unit.cpuVramBlocked());
    try std.testing.expect(!unit.cpuOamBlocked());
    for (unit.framebuffer) |pixel| try std.testing.expectEqual(@as(u8, 0), pixel);
}

test "mode two OAM access applies row corruption without touching row zero" {
    var unit = Ppu{};
    var index: usize = 0;
    while (index < unit.oam.len) : (index += 1) unit.oam[index] = @truncate(index * 3 + 1);
    const first_row = unit.oam[0..8].*;
    unit.dot = 8;
    const before = unit.oam[16..24].*;
    unit.corruptOam(.read);
    try std.testing.expectEqualSlices(u8, first_row[0..], unit.oam[0..8]);
    try std.testing.expect(!std.mem.eql(u8, before[0..], unit.oam[16..24]));
}
