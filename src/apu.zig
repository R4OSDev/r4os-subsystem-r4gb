const std = @import("std");

pub const clock_hz: u32 = 4_194_304;
pub const sample_rate: u32 = 48_000;
pub const channels: u16 = 2;
pub const sample_bytes: usize = @sizeOf(i16) * channels;
pub const pcm_capacity_frames: usize = 8192;

const read_masks = [0x20]u8{
    0x80, 0x3F, 0x00, 0xFF, 0xBF,
    0xFF, 0x3F, 0x00, 0xFF, 0xBF,
    0x7F, 0xFF, 0x9F, 0xFF, 0xBF,
    0xFF, 0xFF, 0x00, 0x00, 0xBF,
    0x00, 0x00, 0x70, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF,
};

const duty_patterns = [4][8]u8{
    .{ 0, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 1, 1, 1 },
    .{ 0, 1, 1, 1, 1, 1, 1, 0 },
};

pub const Pulse = struct {
    enabled: bool = false,
    dac_enabled: bool = false,
    duty: u2 = 0,
    duty_position: u3 = 0,
    first_sample_suppressed: bool = true,
    length: u7 = 0,
    length_enabled: bool = false,
    frequency: u11 = 0,
    timer: u16 = 0,
    volume: u4 = 0,
    envelope_period: u4 = 0,
    envelope_timer: u4 = 0,
    envelope_increase: bool = false,
    envelope_running: bool = false,
};

pub const Sweep = struct {
    shadow_frequency: u11 = 0,
    timer: u4 = 0,
    enabled: bool = false,
    negate_used: bool = false,
};

pub const Wave = struct {
    enabled: bool = false,
    dac_enabled: bool = false,
    length: u9 = 0,
    length_enabled: bool = false,
    frequency: u11 = 0,
    timer: u16 = 0,
    sample_position: u5 = 0,
    sample_buffer: u8 = 0,
    current_sample: u4 = 0,
    access_window: u2 = 0,
};

pub const Noise = struct {
    enabled: bool = false,
    dac_enabled: bool = false,
    length: u7 = 0,
    length_enabled: bool = false,
    timer: u32 = 0,
    lfsr: u15 = 0,
    narrow: bool = false,
    volume: u4 = 0,
    envelope_period: u4 = 0,
    envelope_timer: u4 = 0,
    envelope_increase: bool = false,
    envelope_running: bool = false,
};

pub const AudioStats = struct {
    samples_generated: u64 = 0,
    frames_queued: u64 = 0,
    frames_rendered: u64 = 0,
    frames_dropped: u64 = 0,
    silence_frames: u64 = 0,
    underflow_frames: u64 = 0,
};

/// Dot-clocked DMG audio hardware. Register and channel timing is always
/// advanced with guest T-cycles. PCM capture is optional and copies only into
/// buffers supplied by the caller; no host clock or audio backend enters here.
pub const Apu = struct {
    registers: [0x30]u8 = .{0} ** 0x30,
    powered: bool = false,
    frame_sequencer_step: u3 = 0,
    skip_next_div_event: bool = false,
    pulse: [2]Pulse = .{ .{}, .{} },
    sweep: Sweep = .{},
    wave: Wave = .{},
    noise: Noise = .{},

    sample_phase: u32 = 0,
    high_pass_left: i64 = 0,
    high_pass_right: i64 = 0,
    capture_enabled: bool = false,
    pcm: [pcm_capacity_frames * channels]i16 = .{0} ** (pcm_capacity_frames * channels),
    pcm_read_frame: usize = 0,
    pcm_frame_count: usize = 0,
    stats: AudioStats = .{},

    pub fn init(post_boot: []const u8) Apu {
        var self: Apu = .{};
        const count = @min(post_boot.len, self.registers.len);
        @memcpy(self.registers[0..count], post_boot[0..count]);
        self.powered = (self.registers[0x16] & 0x80) != 0;
        self.pulse[0] = pulseFromRegisters(self.registers[1], self.registers[2], self.registers[3], self.registers[4]);
        self.pulse[1] = pulseFromRegisters(self.registers[6], self.registers[7], self.registers[8], self.registers[9]);
        self.wave = .{
            .enabled = (self.registers[0x16] & 0x04) != 0,
            .dac_enabled = (self.registers[0x0A] & 0x80) != 0,
            .length = waveLength(self.registers[0x0B]),
            .length_enabled = (self.registers[0x0E] & 0x40) != 0,
            .frequency = frequency(self.registers[0x0D], self.registers[0x0E]),
        };
        self.noise = .{
            .enabled = (self.registers[0x16] & 0x08) != 0,
            .dac_enabled = (self.registers[0x11] & 0xF8) != 0,
            .length = pulseLength(self.registers[0x10]),
            .length_enabled = (self.registers[0x13] & 0x40) != 0,
            .narrow = (self.registers[0x12] & 0x08) != 0,
            .volume = @truncate(self.registers[0x11] >> 4),
            .envelope_period = envelopePeriod(self.registers[0x11]),
            .envelope_timer = envelopePeriod(self.registers[0x11]),
            .envelope_increase = (self.registers[0x11] & 0x08) != 0,
        };
        self.pulse[0].enabled = (self.registers[0x16] & 0x01) != 0 and self.pulse[0].dac_enabled;
        self.pulse[1].enabled = (self.registers[0x16] & 0x02) != 0 and self.pulse[1].dac_enabled;
        self.wave.enabled = self.wave.enabled and self.wave.dac_enabled;
        self.noise.enabled = self.noise.enabled and self.noise.dac_enabled;
        return self;
    }

    pub fn read(self: *Apu, address: u8) u8 {
        if (address < 0x10 or address > 0x3F) return 0xFF;
        const index: usize = address - 0x10;
        if (index == 0x16) return self.readNr52();
        if (index >= 0x20) return self.readWave(@intCast(index - 0x20));
        return self.registers[index] | read_masks[index];
    }

    pub fn write(self: *Apu, address: u8, value: u8, divider: u16) void {
        if (address < 0x10 or address > 0x3F) return;
        const index: usize = address - 0x10;
        if (index == 0x16) {
            self.writeNr52(value, divider);
            return;
        }
        if (index >= 0x20) {
            self.writeWave(@intCast(index - 0x20), value);
            return;
        }
        if (!self.powered and index != 1 and index != 6 and index != 0x0B and index != 0x10) return;

        const previous = self.registers[index];
        self.registers[index] = value;
        switch (index) {
            0x00 => self.writeSweep(previous, value),
            0x01 => self.writePulseLength(0, value),
            0x02 => self.writePulseEnvelope(0, previous, value),
            0x03 => self.pulse[0].frequency = frequency(value, self.registers[4]),
            0x04 => self.writePulseControl(0, previous, value),
            0x06 => self.writePulseLength(1, value),
            0x07 => self.writePulseEnvelope(1, previous, value),
            0x08 => self.pulse[1].frequency = frequency(value, self.registers[9]),
            0x09 => self.writePulseControl(1, previous, value),
            0x0A => self.writeWaveDac(value),
            0x0B => self.wave.length = waveLength(value),
            0x0C => {},
            0x0D => self.wave.frequency = frequency(value, self.registers[0x0E]),
            0x0E => self.writeWaveControl(previous, value),
            0x10 => self.noise.length = pulseLength(value),
            0x11 => self.writeNoiseEnvelope(previous, value),
            0x12 => self.writeNoisePolynomial(value),
            0x13 => self.writeNoiseControl(previous, value),
            else => {},
        }
    }

    /// Advances oscillators and the deterministic 48-kHz resampler by one
    /// guest T-cycle. DIV-APU is driven from the same divider transition.
    pub fn tick(self: *Apu, old_divider: u16, new_divider: u16) void {
        if (self.wave.access_window != 0) self.wave.access_window -= 1;
        if (self.powered) {
            self.tickPulse(0);
            self.tickPulse(1);
            self.tickWave();
            self.tickNoise();
        }
        self.dividerChanged(old_divider, new_divider);

        self.sample_phase += sample_rate;
        if (self.sample_phase >= clock_hz) {
            self.sample_phase -= clock_hz;
            const sample = self.mixSample();
            self.stats.samples_generated +%= 1;
            if (self.capture_enabled) self.queueFrame(sample[0], sample[1]);
        }
    }

    /// Applies a DIV write without advancing any oscillator or guest time.
    pub fn dividerChanged(self: *Apu, old_divider: u16, new_divider: u16) void {
        if ((old_divider & 0x1000) != 0 and (new_divider & 0x1000) == 0) self.clockFrameSequencer();
    }

    pub fn beginCapture(self: *Apu) void {
        self.capture_enabled = true;
        self.pcm_read_frame = 0;
        self.pcm_frame_count = 0;
    }

    pub fn endCapture(self: *Apu) void {
        self.capture_enabled = false;
        self.pcm_read_frame = 0;
        self.pcm_frame_count = 0;
    }

    /// Copies as many queued stereo S16LE frames as currently exist into the
    /// caller-owned buffer. A short or zero result lets the shared runtime
    /// accumulate guest PCM without inserting silence between host quanta.
    pub fn renderPcm(self: *Apu, out: []u8) i32 {
        if (out.len == 0 or out.len % sample_bytes != 0 or out.len > std.math.maxInt(i32)) return -1;
        const requested_frames = out.len / sample_bytes;
        const rendered_frames = @min(requested_frames, self.pcm_frame_count);
        self.stats.underflow_frames +%= requested_frames - rendered_frames;
        var frame: usize = 0;
        while (frame < rendered_frames) : (frame += 1) {
            const offset = frame * sample_bytes;
            const sample_index = self.pcm_read_frame * channels;
            const left = self.pcm[sample_index];
            const right = self.pcm[sample_index + 1];
            self.pcm_read_frame = (self.pcm_read_frame + 1) % pcm_capacity_frames;
            self.pcm_frame_count -= 1;
            self.stats.frames_rendered +%= 1;
            std.mem.writeInt(i16, out[offset..][0..2], left, .little);
            std.mem.writeInt(i16, out[offset + 2 ..][0..2], right, .little);
        }
        return @intCast(rendered_frames * sample_bytes);
    }

    pub fn queuedFrames(self: *const Apu) usize {
        return self.pcm_frame_count;
    }

    pub fn channelSample(self: *const Apu, channel: u2) u4 {
        return switch (channel) {
            0 => self.pulseSample(0),
            1 => self.pulseSample(1),
            2 => self.waveSample(),
            3 => self.noiseSample(),
        };
    }

    fn readNr52(self: *const Apu) u8 {
        return 0x70 |
            (if (self.powered) @as(u8, 0x80) else 0) |
            (if (self.pulse[0].enabled) @as(u8, 0x01) else 0) |
            (if (self.pulse[1].enabled) @as(u8, 0x02) else 0) |
            (if (self.wave.enabled) @as(u8, 0x04) else 0) |
            (if (self.noise.enabled) @as(u8, 0x08) else 0);
    }

    fn writeNr52(self: *Apu, value: u8, divider: u16) void {
        const enable = (value & 0x80) != 0;
        if (enable == self.powered) return;
        if (!enable) {
            const wave_ram = self.registers[0x20..0x30].*;
            const lengths = .{ self.pulse[0].length, self.pulse[1].length, self.wave.length, self.noise.length };
            self.registers = .{0} ** 0x30;
            self.registers[0x20..0x30].* = wave_ram;
            self.pulse = .{ .{}, .{} };
            self.wave = .{};
            self.noise = .{};
            self.sweep = .{};
            self.pulse[0].length = lengths[0];
            self.pulse[1].length = lengths[1];
            self.wave.length = lengths[2];
            self.noise.length = lengths[3];
            self.powered = false;
            self.frame_sequencer_step = 0;
            self.skip_next_div_event = false;
            return;
        }
        self.powered = true;
        self.frame_sequencer_step = 0;
        self.skip_next_div_event = (divider & 0x1000) != 0;
        self.wave.sample_buffer = 0;
        self.wave.current_sample = 0;
    }

    fn writeSweep(self: *Apu, previous: u8, value: u8) void {
        if ((previous & 0x08) != 0 and (value & 0x08) == 0 and self.sweep.negate_used) self.pulse[0].enabled = false;
        if ((value & 0x70) == 0) self.sweep.enabled = false;
    }

    fn writePulseLength(self: *Apu, index: usize, value: u8) void {
        self.pulse[index].duty = @truncate(value >> 6);
        self.pulse[index].length = pulseLength(value);
    }

    fn writePulseEnvelope(self: *Apu, index: usize, previous: u8, value: u8) void {
        const channel = &self.pulse[index];
        if (channel.enabled) applyZombie(&channel.volume, previous, value, channel.envelope_running);
        channel.dac_enabled = (value & 0xF8) != 0;
        channel.envelope_period = envelopePeriod(value);
        channel.envelope_increase = (value & 0x08) != 0;
        if (!channel.dac_enabled) channel.enabled = false;
    }

    fn writePulseControl(self: *Apu, index: usize, previous: u8, value: u8) void {
        const channel = &self.pulse[index];
        channel.frequency = frequency(self.registers[if (index == 0) 3 else 8], value);
        const old_length_enable = (previous & 0x40) != 0;
        channel.length_enabled = (value & 0x40) != 0;
        if ((value & 0x80) != 0) self.triggerPulse(index);
        self.extraLengthClock(&channel.length, &channel.enabled, old_length_enable, channel.length_enabled, (value & 0x80) != 0, 64);
    }

    fn triggerPulse(self: *Apu, index: usize) void {
        const channel = &self.pulse[index];
        if (channel.length == 0) channel.length = 64;
        channel.enabled = channel.dac_enabled;
        channel.timer = pulsePeriod(channel.frequency);
        channel.volume = @truncate(self.registers[if (index == 0) 2 else 7] >> 4);
        channel.envelope_period = envelopePeriod(self.registers[if (index == 0) 2 else 7]);
        channel.envelope_timer = channel.envelope_period;
        channel.envelope_increase = (self.registers[if (index == 0) 2 else 7] & 0x08) != 0;
        channel.envelope_running = (self.registers[if (index == 0) 2 else 7] & 0x07) != 0;
        channel.first_sample_suppressed = true;
        if (index == 0) {
            self.sweep.shadow_frequency = channel.frequency;
            self.sweep.timer = sweepPeriod(self.registers[0]);
            self.sweep.enabled = (self.registers[0] & 0x77) != 0;
            self.sweep.negate_used = false;
            if ((self.registers[0] & 0x07) != 0) _ = self.calculateSweep(false);
        }
    }

    fn writeWaveDac(self: *Apu, value: u8) void {
        self.wave.dac_enabled = (value & 0x80) != 0;
        if (!self.wave.dac_enabled) self.wave.enabled = false;
    }

    fn writeWaveControl(self: *Apu, previous: u8, value: u8) void {
        self.wave.frequency = frequency(self.registers[0x0D], value);
        const old_length_enable = (previous & 0x40) != 0;
        self.wave.length_enabled = (value & 0x40) != 0;
        if ((value & 0x80) != 0) self.triggerWave();
        self.extraLengthClock(&self.wave.length, &self.wave.enabled, old_length_enable, self.wave.length_enabled, (value & 0x80) != 0, 256);
    }

    fn triggerWave(self: *Apu) void {
        if (self.wave.enabled and self.wave.timer <= 2) self.corruptWaveRam();
        if (self.wave.length == 0) self.wave.length = 256;
        self.wave.enabled = self.wave.dac_enabled;
        self.wave.timer = wavePeriod(self.wave.frequency) + 6;
        self.wave.sample_position = 0;
    }

    fn writeNoiseEnvelope(self: *Apu, previous: u8, value: u8) void {
        if (self.noise.enabled) applyZombie(&self.noise.volume, previous, value, self.noise.envelope_running);
        self.noise.dac_enabled = (value & 0xF8) != 0;
        self.noise.envelope_period = envelopePeriod(value);
        self.noise.envelope_increase = (value & 0x08) != 0;
        if (!self.noise.dac_enabled) self.noise.enabled = false;
    }

    fn writeNoisePolynomial(self: *Apu, value: u8) void {
        self.noise.narrow = (value & 0x08) != 0;
        if (self.noise.timer == 0) self.noise.timer = noisePeriod(value);
    }

    fn writeNoiseControl(self: *Apu, previous: u8, value: u8) void {
        const old_length_enable = (previous & 0x40) != 0;
        self.noise.length_enabled = (value & 0x40) != 0;
        if ((value & 0x80) != 0) self.triggerNoise();
        self.extraLengthClock(&self.noise.length, &self.noise.enabled, old_length_enable, self.noise.length_enabled, (value & 0x80) != 0, 64);
    }

    fn triggerNoise(self: *Apu) void {
        if (self.noise.length == 0) self.noise.length = 64;
        self.noise.enabled = self.noise.dac_enabled;
        self.noise.lfsr = 0;
        self.noise.narrow = (self.registers[0x12] & 0x08) != 0;
        self.noise.timer = noisePeriod(self.registers[0x12]);
        self.noise.volume = @truncate(self.registers[0x11] >> 4);
        self.noise.envelope_period = envelopePeriod(self.registers[0x11]);
        self.noise.envelope_timer = self.noise.envelope_period;
        self.noise.envelope_increase = (self.registers[0x11] & 0x08) != 0;
        self.noise.envelope_running = (self.registers[0x11] & 0x07) != 0;
    }

    fn tickPulse(self: *Apu, index: usize) void {
        const channel = &self.pulse[index];
        if (!channel.enabled) return;
        if (channel.timer > 1) {
            channel.timer -= 1;
            return;
        }
        channel.timer = pulsePeriod(channel.frequency);
        channel.duty_position +%= 1;
        channel.first_sample_suppressed = false;
    }

    fn tickWave(self: *Apu) void {
        if (!self.wave.enabled) return;
        if (self.wave.timer > 1) {
            self.wave.timer -= 1;
            return;
        }
        self.wave.timer = wavePeriod(self.wave.frequency);
        self.wave.sample_position +%= 1;
        const byte_index: usize = self.wave.sample_position >> 1;
        self.wave.sample_buffer = self.registers[0x20 + byte_index];
        self.wave.current_sample = if ((self.wave.sample_position & 1) == 0)
            @truncate(self.wave.sample_buffer >> 4)
        else
            @truncate(self.wave.sample_buffer);
        self.wave.access_window = 2;
    }

    fn tickNoise(self: *Apu) void {
        if (!self.noise.enabled or self.noise.timer == 0) return;
        if (self.noise.timer > 1) {
            self.noise.timer -= 1;
            return;
        }
        self.noise.timer = noisePeriod(self.registers[0x12]);
        const feedback: u1 = @truncate((self.noise.lfsr ^ (self.noise.lfsr >> 1) ^ 1) & 1);
        self.noise.lfsr >>= 1;
        self.noise.lfsr = (self.noise.lfsr & 0x3FFF) | (@as(u15, feedback) << 14);
        if (self.noise.narrow) self.noise.lfsr = (self.noise.lfsr & ~@as(u15, 0x40)) | (@as(u15, feedback) << 6);
    }

    fn clockFrameSequencer(self: *Apu) void {
        if (!self.powered) return;
        if (self.skip_next_div_event) {
            self.skip_next_div_event = false;
            return;
        }
        const step = self.frame_sequencer_step;
        if ((step & 1) == 0) self.clockLengths();
        if (step == 2 or step == 6) self.clockSweep();
        if (step == 7) self.clockEnvelopes();
        self.frame_sequencer_step +%= 1;
    }

    fn clockLengths(self: *Apu) void {
        for (&self.pulse) |*channel| if (channel.length_enabled and channel.length != 0) {
            channel.length -= 1;
            if (channel.length == 0) channel.enabled = false;
        };
        if (self.wave.length_enabled and self.wave.length != 0) {
            self.wave.length -= 1;
            if (self.wave.length == 0) self.wave.enabled = false;
        }
        if (self.noise.length_enabled and self.noise.length != 0) {
            self.noise.length -= 1;
            if (self.noise.length == 0) self.noise.enabled = false;
        }
    }

    fn clockSweep(self: *Apu) void {
        if (self.sweep.timer != 0) self.sweep.timer -= 1;
        if (self.sweep.timer != 0) return;
        self.sweep.timer = sweepPeriod(self.registers[0]);
        if (!self.sweep.enabled or (self.registers[0] & 0x70) == 0) return;
        const next = self.calculateSweep(true) orelse return;
        if ((self.registers[0] & 0x07) == 0) return;
        self.sweep.shadow_frequency = next;
        self.pulse[0].frequency = next;
        self.registers[3] = @truncate(next);
        self.registers[4] = (self.registers[4] & 0xF8) | @as(u8, @truncate(next >> 8));
        _ = self.calculateSweep(false);
    }

    fn calculateSweep(self: *Apu, mark_negate: bool) ?u11 {
        const shift: u3 = @truncate(self.registers[0] & 0x07);
        const delta: u11 = self.sweep.shadow_frequency >> shift;
        if ((self.registers[0] & 0x08) != 0) {
            if (mark_negate) self.sweep.negate_used = true;
            return self.sweep.shadow_frequency - delta;
        }
        const sum: u12 = @as(u12, self.sweep.shadow_frequency) + delta;
        if (sum > 0x7FF) {
            self.pulse[0].enabled = false;
            return null;
        }
        return @intCast(sum);
    }

    fn clockEnvelopes(self: *Apu) void {
        for (&self.pulse) |*channel| clockEnvelope(
            &channel.volume,
            &channel.envelope_timer,
            channel.envelope_period,
            channel.envelope_increase,
            &channel.envelope_running,
        );
        clockEnvelope(
            &self.noise.volume,
            &self.noise.envelope_timer,
            self.noise.envelope_period,
            self.noise.envelope_increase,
            &self.noise.envelope_running,
        );
    }

    fn extraLengthClock(
        self: *Apu,
        length: anytype,
        enabled: *bool,
        old_length_enable: bool,
        new_length_enable: bool,
        triggered: bool,
        maximum: comptime_int,
    ) void {
        // Powering on while DIV bit 4 is high skips the first DIV-APU edge,
        // while NRx4 still observes the odd internal divider phase. This is
        // the DMG behavior exercised by SameSuite div_write_trigger_10.
        const non_length_phase = (self.frame_sequencer_step & 1) != 0 or self.skip_next_div_event;
        if (old_length_enable or !new_length_enable or !non_length_phase or length.* == 0) return;
        length.* -= 1;
        if (length.* == 0) {
            if (triggered) {
                length.* = maximum - 1;
            } else {
                enabled.* = false;
            }
        }
    }

    fn readWave(self: *Apu, requested: u4) u8 {
        if (!self.wave.enabled) return self.registers[0x20 + @as(usize, requested)];
        if (self.wave.access_window == 0) return 0xFF;
        return self.registers[0x20 + @as(usize, self.wave.sample_position >> 1)];
    }

    fn writeWave(self: *Apu, requested: u4, value: u8) void {
        const actual = if (!self.wave.enabled)
            requested
        else if (self.wave.access_window != 0)
            @as(u4, @truncate(self.wave.sample_position >> 1))
        else
            return;
        self.registers[0x20 + @as(usize, actual)] = value;
    }

    fn corruptWaveRam(self: *Apu) void {
        const source: usize = ((@as(usize, self.wave.sample_position) + 1) >> 1) & 0x0F;
        if (source < 4) {
            self.registers[0x20] = self.registers[0x20 + source];
            return;
        }
        const aligned = source & ~@as(usize, 3);
        const block = self.registers[0x20 + aligned ..][0..4].*;
        self.registers[0x20..0x24].* = block;
    }

    fn pulseSample(self: *const Apu, index: usize) u4 {
        const channel = &self.pulse[index];
        if (!channel.enabled or channel.first_sample_suppressed) return 0;
        return if (duty_patterns[channel.duty][channel.duty_position] != 0) channel.volume else 0;
    }

    fn waveSample(self: *const Apu) u4 {
        if (!self.wave.enabled) return 0;
        return switch ((self.registers[0x0C] >> 5) & 0x03) {
            0 => 0,
            1 => self.wave.current_sample,
            2 => self.wave.current_sample >> 1,
            3 => self.wave.current_sample >> 2,
            else => unreachable,
        };
    }

    fn noiseSample(self: *const Apu) u4 {
        if (!self.noise.enabled or (self.noise.lfsr & 1) == 0) return 0;
        return self.noise.volume;
    }

    fn mixSample(self: *Apu) [2]i16 {
        var left: i32 = 0;
        var right: i32 = 0;
        const routing = self.registers[0x15];
        const digital = [4]u4{ self.pulseSample(0), self.pulseSample(1), self.waveSample(), self.noiseSample() };
        const dacs = [4]bool{ self.pulse[0].dac_enabled, self.pulse[1].dac_enabled, self.wave.dac_enabled, self.noise.dac_enabled };
        var any_dac = false;
        for (digital, dacs, 0..) |sample, dac, index| {
            if (!self.powered or !dac) continue;
            any_dac = true;
            const analog: i32 = 15 - @as(i32, sample) * 2;
            if ((routing & (@as(u8, 1) << @intCast(index))) != 0) right += analog;
            if ((routing & (@as(u8, 0x10) << @intCast(index))) != 0) left += analog;
        }
        const volume = self.registers[0x14];
        left *= @as(i32, (volume >> 4) & 0x07) + 1;
        right *= @as(i32, volume & 0x07) + 1;
        left *= 64;
        right *= 64;
        return .{
            highPass(left, &self.high_pass_left, any_dac),
            highPass(right, &self.high_pass_right, any_dac),
        };
    }

    fn queueFrame(self: *Apu, left: i16, right: i16) void {
        if (self.pcm_frame_count == pcm_capacity_frames) {
            self.pcm_read_frame = (self.pcm_read_frame + 1) % pcm_capacity_frames;
            self.pcm_frame_count -= 1;
            self.stats.frames_dropped +%= 1;
        }
        const write_frame = (self.pcm_read_frame + self.pcm_frame_count) % pcm_capacity_frames;
        self.pcm[write_frame * channels] = left;
        self.pcm[write_frame * channels + 1] = right;
        self.pcm_frame_count += 1;
        self.stats.frames_queued +%= 1;
        if (left == 0 and right == 0) self.stats.silence_frames +%= 1;
    }
};

fn highPass(input: i32, capacitor: *i64, dacs_enabled: bool) i16 {
    if (!dacs_enabled) return 0;
    const coefficient_q30: i64 = 1_069_808_314;
    const input_q16: i64 = @as(i64, input) << 16;
    const output_q16 = input_q16 - capacitor.*;
    capacitor.* = input_q16 - ((output_q16 * coefficient_q30) >> 30);
    const output = output_q16 >> 16;
    return @intCast(@max(@as(i64, std.math.minInt(i16)), @min(@as(i64, std.math.maxInt(i16)), output)));
}

fn pulseFromRegisters(length_duty: u8, envelope: u8, low: u8, high: u8) Pulse {
    return .{
        .dac_enabled = (envelope & 0xF8) != 0,
        .duty = @truncate(length_duty >> 6),
        .length = pulseLength(length_duty),
        .length_enabled = (high & 0x40) != 0,
        .frequency = frequency(low, high),
        .volume = @truncate(envelope >> 4),
        .envelope_period = envelopePeriod(envelope),
        .envelope_timer = envelopePeriod(envelope),
        .envelope_increase = (envelope & 0x08) != 0,
    };
}

fn pulseLength(value: u8) u7 {
    const raw: u7 = @truncate(value & 0x3F);
    return if (raw == 0) 64 else 64 - raw;
}

fn waveLength(value: u8) u9 {
    return if (value == 0) 256 else 256 - @as(u9, value);
}

fn frequency(low: u8, high: u8) u11 {
    return @truncate((@as(u16, high & 0x07) << 8) | low);
}

fn pulsePeriod(value: u11) u16 {
    return @intCast((@as(u32, 2048) - value) * 4);
}

fn wavePeriod(value: u11) u16 {
    return @intCast((@as(u32, 2048) - value) * 2);
}

fn noisePeriod(value: u8) u32 {
    const shift: u4 = @truncate(value >> 4);
    if (shift >= 14) return 0;
    const divisors = [8]u32{ 8, 16, 32, 48, 64, 80, 96, 112 };
    const divisor = divisors[value & 0x07];
    return divisor << shift;
}

fn envelopePeriod(value: u8) u4 {
    const period: u4 = @truncate(value & 0x07);
    return if (period == 0) 8 else period;
}

fn sweepPeriod(value: u8) u4 {
    const period: u4 = @truncate((value >> 4) & 0x07);
    return if (period == 0) 8 else period;
}

fn clockEnvelope(volume: *u4, timer: *u4, period: u4, increase: bool, running: *bool) void {
    if (!running.*) return;
    if (timer.* != 0) timer.* -= 1;
    if (timer.* != 0) return;
    timer.* = period;
    if (increase) {
        if (volume.* == 15) {
            running.* = false;
        } else volume.* += 1;
    } else {
        if (volume.* == 0) {
            running.* = false;
        } else volume.* -= 1;
    }
}

fn applyZombie(volume: *u4, previous: u8, value: u8, envelope_running: bool) void {
    if ((previous & 0x07) == 0) {
        volume.* +%= if (envelope_running) 1 else if ((previous & 0x08) == 0) 2 else 0;
    }
    if (((previous ^ value) & 0x08) != 0) volume.* = @truncate(16 - @as(u5, volume.*));
}

test "NR52 power and read masks retain DMG length registers and wave RAM" {
    var unit: Apu = .{};
    unit.write(0x26, 0x80, 0);
    unit.write(0x11, 0xC1, 0);
    unit.write(0x12, 0xF3, 0);
    unit.write(0x13, 0x34, 0);
    unit.write(0x14, 0x87, 0);
    unit.write(0x30, 0xA5, 0);
    try std.testing.expectEqual(@as(u8, 0xF1), unit.read(0x26));
    try std.testing.expectEqual(@as(u8, 0xFF), unit.read(0x13));
    try std.testing.expectEqual(@as(u8, 0xFF), unit.read(0x11));
    unit.write(0x26, 0, 0);
    try std.testing.expectEqual(@as(u8, 0x70), unit.read(0x26));
    try std.testing.expectEqual(@as(u8, 0xA5), unit.read(0x30));
    unit.write(0x11, 0x3F, 0);
    try std.testing.expectEqual(@as(u7, 1), unit.pulse[0].length);
    unit.write(0x12, 0xF0, 0);
    try std.testing.expectEqual(@as(u8, 0), unit.registers[2]);
}

test "DIV APU clocks length sweep and envelope with power-on skip" {
    var unit: Apu = .{};
    unit.write(0x26, 0x80, 0x1000);
    unit.write(0x11, 0x3F, 0);
    unit.write(0x12, 0xF1, 0);
    unit.write(0x14, 0xC0, 0);
    try std.testing.expectEqual(@as(u7, 63), unit.pulse[0].length);
    unit.dividerChanged(0x1000, 0);
    try std.testing.expect(unit.pulse[0].enabled);
    try std.testing.expectEqual(@as(u7, 63), unit.pulse[0].length);
    unit.dividerChanged(0x1000, 0);
    try std.testing.expect(unit.pulse[0].enabled);
    try std.testing.expectEqual(@as(u7, 62), unit.pulse[0].length);

    unit.write(0x11, 0, 0);
    unit.write(0x12, 0x89, 0);
    unit.write(0x14, 0x80, 0);
    var edges: usize = 0;
    while (edges < 8) : (edges += 1) unit.dividerChanged(0x1000, 0);
    try std.testing.expectEqual(@as(u4, 9), unit.pulse[0].volume);
}

test "pulse sweep applies frequency, overflow, negate history and DAC disable" {
    var unit: Apu = .{};
    unit.write(0x26, 0x80, 0);
    unit.write(0x10, 0x11, 0); // period 1, add, shift 1
    unit.write(0x11, 0x80, 0);
    unit.write(0x12, 0xF0, 0);
    unit.write(0x13, 0xE8, 0);
    unit.write(0x14, 0x83, 0); // frequency 1000 and trigger
    unit.clockSweep();
    try std.testing.expectEqual(@as(u11, 1500), unit.pulse[0].frequency);
    try std.testing.expect(!unit.pulse[0].enabled); // second calculation overflows

    unit.write(0x10, 0x19, 0); // period 1, negate, shift 1
    unit.write(0x13, 0xE8, 0);
    unit.write(0x14, 0x83, 0);
    unit.clockSweep();
    try std.testing.expectEqual(@as(u11, 500), unit.pulse[0].frequency);
    try std.testing.expect(unit.sweep.negate_used);
    unit.write(0x10, 0x11, 0); // clearing negate after use disables channel 1
    try std.testing.expect(!unit.pulse[0].enabled);

    unit.write(0x14, 0x80, 0);
    try std.testing.expect(unit.pulse[0].enabled);
    unit.write(0x12, 0, 0);
    try std.testing.expect(!unit.pulse[0].dac_enabled);
    try std.testing.expect(!unit.pulse[0].enabled);
}

test "pulse wave and noise generators follow documented digital sequences" {
    var unit: Apu = .{};
    unit.write(0x26, 0x80, 0);
    unit.write(0x11, 0x80, 0);
    unit.write(0x12, 0xF0, 0);
    unit.write(0x13, 0xFF, 0);
    unit.write(0x14, 0x87, 0);
    unit.pulse[0].timer = 1;
    unit.tickPulse(0);
    try std.testing.expectEqual(@as(u4, 0), unit.channelSample(0));
    var pulse_steps: usize = 0;
    while (pulse_steps < 4) : (pulse_steps += 1) {
        unit.pulse[0].timer = 1;
        unit.tickPulse(0);
    }
    try std.testing.expectEqual(@as(u4, 15), unit.channelSample(0));

    unit.write(0x30, 0xAB, 0);
    unit.write(0x1A, 0x80, 0);
    unit.write(0x1C, 0x20, 0);
    unit.write(0x1E, 0x80, 0);
    unit.wave.timer = 1;
    unit.tickWave();
    try std.testing.expectEqual(@as(u4, 0x0B), unit.channelSample(2));

    unit.write(0x21, 0xF0, 0);
    unit.write(0x22, 0x08, 0);
    unit.write(0x23, 0x80, 0);
    const expected = [_]u15{ 0x4040, 0x6060, 0x7070, 0x7878 };
    for (expected) |state| {
        unit.noise.timer = 1;
        unit.tickNoise();
        try std.testing.expectEqual(state, unit.noise.lfsr);
    }

    unit.write(0x22, 0xE0, 0);
    unit.write(0x23, 0x80, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.noise.timer);
    const stopped_lfsr = unit.noise.lfsr;
    unit.tickNoise();
    try std.testing.expectEqual(stopped_lfsr, unit.noise.lfsr);
}

test "saturated increasing pulse envelope stays at full volume" {
    var unit: Apu = .{};
    unit.write(0x26, 0x80, 0);
    unit.write(0x11, 0x80, 0);
    unit.write(0x12, 0xF8, 0);
    unit.write(0x14, 0x80, 0);
    try std.testing.expect(unit.pulse[0].enabled);
    try std.testing.expectEqual(@as(u4, 15), unit.pulse[0].volume);

    var clocks: usize = 0;
    while (clocks < 32) : (clocks += 1) unit.clockEnvelopes();
    try std.testing.expectEqual(@as(u4, 15), unit.pulse[0].volume);
    try std.testing.expect(unit.pulse[0].enabled);
}

test "zero envelope pace keeps pulse and noise volume fixed" {
    var unit: Apu = .{};
    unit.write(0x26, 0x80, 0);

    // NRx2=$08 keeps the DAC on while disabling automatic envelope steps.
    unit.write(0x11, 0x80, 0);
    unit.write(0x12, 0x08, 0);
    unit.write(0x14, 0x80, 0);
    unit.write(0x21, 0x08, 0);
    unit.write(0x22, 0x00, 0);
    unit.write(0x23, 0x80, 0);

    try std.testing.expect(unit.pulse[0].enabled);
    try std.testing.expect(unit.noise.enabled);
    try std.testing.expect(!unit.pulse[0].envelope_running);
    try std.testing.expect(!unit.noise.envelope_running);

    var clocks: usize = 0;
    while (clocks < 32) : (clocks += 1) unit.clockEnvelopes();
    try std.testing.expectEqual(@as(u4, 0), unit.pulse[0].volume);
    try std.testing.expectEqual(@as(u4, 0), unit.noise.volume);
}

test "active DMG wave RAM exposes only the fetched byte and restart corruption" {
    var unit: Apu = .{};
    unit.write(0x26, 0x80, 0);
    for (0..16) |index| unit.write(@intCast(0x30 + index), @intCast(0x10 + index), 0);
    unit.write(0x1A, 0x80, 0);
    unit.write(0x1C, 0x20, 0);
    unit.write(0x1D, 0xFF, 0);
    unit.write(0x1E, 0x87, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), unit.read(0x30));

    unit.wave.timer = 1;
    unit.tickWave();
    try std.testing.expectEqual(@as(u5, 1), unit.wave.sample_position);
    try std.testing.expectEqual(@as(u8, 0x10), unit.read(0x3F));
    unit.write(0x3F, 0xAB, 0);
    try std.testing.expectEqual(@as(u8, 0xAB), unit.registers[0x20]);
    unit.wave.access_window = 0;
    unit.write(0x30, 0xEE, 0);
    try std.testing.expectEqual(@as(u8, 0xAB), unit.registers[0x20]);

    unit.wave.sample_position = 9;
    unit.wave.timer = 1;
    const source = unit.registers[0x24..0x28].*;
    unit.write(0x1E, 0x87, 0);
    try std.testing.expectEqualSlices(u8, source[0..], unit.registers[0x20..0x24]);
}

test "48 kHz stereo PCM uses bounded caller buffers without rate drift" {
    var unit: Apu = .{};
    unit.write(0x26, 0x80, 0);
    unit.write(0x24, 0x77, 0);
    unit.write(0x25, 0x11, 0);
    unit.write(0x11, 0x80, 0);
    unit.write(0x12, 0xF0, 0);
    unit.write(0x13, 0x00, 0);
    unit.write(0x14, 0x80, 0);
    unit.beginCapture();
    var divider: u16 = 0;
    var tick_count: u32 = 0;
    while (tick_count < clock_hz) : (tick_count += 1) {
        const old = divider;
        divider +%= 1;
        unit.tick(old, divider);
    }
    try std.testing.expectEqual(@as(u64, sample_rate), unit.stats.samples_generated);
    try std.testing.expectEqual(@as(usize, pcm_capacity_frames), unit.queuedFrames());
    try std.testing.expectEqual(@as(u64, sample_rate - pcm_capacity_frames), unit.stats.frames_dropped);
    var pcm_out: [480 * sample_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(i32, pcm_out.len), unit.renderPcm(pcm_out[0..]));
    try std.testing.expectEqual(@as(usize, pcm_capacity_frames - 480), unit.queuedFrames());
    try std.testing.expect(std.mem.indexOfNone(u8, pcm_out[0..], &.{0}) != null);

    unit.endCapture();
    @memset(pcm_out[0..], 0xA5);
    try std.testing.expectEqual(@as(i32, 0), unit.renderPcm(pcm_out[0..]));
    try std.testing.expect(std.mem.allEqual(u8, pcm_out[0..], 0xA5));
}
