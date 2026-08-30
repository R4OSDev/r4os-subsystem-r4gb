pub const width: usize = 160;
pub const height: usize = 144;
pub const frame_pixels: usize = width * height;

pub const Ppu = struct {
    vram: [0x2000]u8 = .{0} ** 0x2000,
    oam: [0xA0]u8 = .{0} ** 0xA0,
    framebuffer: [frame_pixels]u8 = .{0} ** frame_pixels,
    lcdc: u8 = 0x91,
    stat: u8 = 0x80,
    scy: u8 = 0,
    scx: u8 = 0,
    ly: u8 = 0,
    lyc: u8 = 0,
    bgp: u8 = 0xFC,
    obp0: u8 = 0xFF,
    obp1: u8 = 0xFF,
    wy: u8 = 0,
    wx: u8 = 0,
    dot: u16 = 0,
    frame_revision: u64 = 0,
};
