const std = @import("std");
const r4os = @import("r4os");
const machine_module = @import("machine.zig");

const runtime = r4os.subsystem_runtime;

pub const reset_not_available: i32 = -9701;
pub const illegal_cpu_state: i32 = -9702;
pub const idle_interval_ns: u64 = std.time.ns_per_ms;

/// Maps one private DMG machine to the common cooperative runtime. Guest
/// time grants bounded T-cycle slices; PCM leaves the emulator only through
/// GuestDriver.renderAudio and therefore through App-Audio/AUDSVC.
pub const Adapter = struct {
    machine: *machine_module.Machine,
    observed_frame_revision: u64,
    audio_capture_enabled: bool = true,
    audio_degraded: bool = false,
    audio_prefill_frames: usize = runtime.default_quantum_frames * runtime.default_target_quanta,
    audio_prefill_released: bool = false,
    audio_render_calls: u64 = 0,
    audio_feedback_calls: u64 = 0,
    stop_guest_ns: u64 = 0,
    source_finished: bool = false,
    transport_pending_bytes: u64 = 0,

    pub fn init(machine: *machine_module.Machine) Adapter {
        machine.guest_clock.pause();
        machine.apu.beginCapture();
        return .{
            .machine = machine,
            .observed_frame_revision = machine.ppu.frame_revision,
        };
    }

    pub fn initFinite(machine: *machine_module.Machine, stop_guest_ns: u64) Adapter {
        var result = init(machine);
        result.stop_guest_ns = stop_guest_ns;
        return result;
    }

    pub fn driver(self: *Adapter) runtime.GuestDriver {
        return .{
            .context = self,
            .step_fn = step,
            .reset_fn = reset,
            .render_audio_fn = renderAudio,
            .audio_feedback_fn = audioFeedback,
        };
    }
};

fn step(context: *anyopaque, budget: u32, guest_now_ns: u64) runtime.StepResult {
    const self: *Adapter = @ptrCast(@alignCast(context));
    const effective_guest_ns = if (self.stop_guest_ns == 0) guest_now_ns else @min(guest_now_ns, self.stop_guest_ns);
    const executed = self.machine.runHostSliceBounded(effective_guest_ns, budget);
    if (self.machine.cpu.locked) return runtime.StepResult.fail(illegal_cpu_state).withOperations(executed);

    if (self.stop_guest_ns != 0 and effective_guest_ns == self.stop_guest_ns and self.machine.guest_clock.pending_t_cycles == 0) {
        self.source_finished = true;
    }

    const frame_ready = self.machine.ppu.frame_revision != self.observed_frame_revision;
    if (frame_ready) self.observed_frame_revision = self.machine.ppu.frame_revision;
    if (self.source_finished and self.machine.apu.queuedFrames() == 0 and self.transport_pending_bytes == 0) {
        return runtime.StepResult.complete(0, frame_ready).withOperations(executed);
    }
    if (executed == 0) {
        return runtime.StepResult.waitUntil(guest_now_ns +| idle_interval_ns, frame_ready).withOperations(0);
    }
    return runtime.StepResult.progress(frame_ready).withOperations(executed);
}

fn reset(_: *anyopaque) i32 {
    // A cartridge reset also owns mapper and persistence semantics. It is
    // intentionally added with the productive lifecycle instead of silently
    // performing only a partial CPU reset here.
    return reset_not_available;
}

fn renderAudio(context: *anyopaque, out: []u8) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.audio_render_calls +%= 1;
    if (!self.audio_capture_enabled) {
        @memset(out, 0);
        return @intCast(out.len);
    }
    // Keep live output in complete runtime quanta. Returning each millisecond's
    // freshly generated fragment would make App-Audio submit short packets and
    // leave audible holes between them. The finite source may expose its final
    // partial quantum so shutdown can drain every generated frame.
    const requested_frames = out.len / core_frame_bytes;
    if (!self.audio_prefill_released and !self.source_finished) {
        if (self.machine.apu.queuedFrames() < self.audio_prefill_frames) return 0;
        self.audio_prefill_released = true;
    }
    if (!self.source_finished and self.machine.apu.queuedFrames() < requested_frames) return 0;
    const rendered_before = self.machine.apu.stats.frames_rendered;
    const result = self.machine.apu.renderPcm(out);
    if (result >= 0) {
        const source_frames = self.machine.apu.stats.frames_rendered -| rendered_before;
        self.transport_pending_bytes +|= source_frames * core_frame_bytes;
    }
    return result;
}

fn audioFeedback(context: *anyopaque, feedback: runtime.AudioFeedback) bool {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.audio_feedback_calls +%= 1;
    const resolved = feedback.accepted_bytes +| feedback.suppressed_bytes +| feedback.discarded_bytes;
    self.transport_pending_bytes -|= resolved;
    const unavailable = feedback.muted or switch (feedback.state) {
        .disabled, .degraded, .closed => true,
        .ready, .active => false,
    };
    self.audio_degraded = feedback.state == .degraded or feedback.state == .disabled;
    if (unavailable and self.audio_capture_enabled) {
        self.machine.apu.endCapture();
        self.audio_capture_enabled = false;
        self.audio_prefill_released = false;
        self.transport_pending_bytes = 0;
    } else if (!unavailable and !self.audio_capture_enabled) {
        self.machine.apu.beginCapture();
        self.audio_capture_enabled = true;
        self.audio_prefill_released = false;
    }
    return false;
}

const core_frame_bytes: u64 = @sizeOf(i16) * 2;
