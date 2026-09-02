# R4GB

R4GB is the `r4os.gb` userland subsystem for original monochrome Game Boy
(DMG) cartridges. It is an independent Zig implementation and produces the
GUI module `R4GB.R4X`. Game Boy hardware emulation remains entirely inside
this repository; the R4OS kernel only provides normal program, window, file,
clock, input, and audio contracts.

The production model is DMG-CPU C without a bundled Nintendo boot ROM. The
host establishes a documented post-boot state and starts a cartridge at
`0x0100`. `.gb` and `.gbc` are discovery candidates for the same format;
cartridge header validation decides whether a file can run in DMG mode.
CGB-only cartridges are rejected.

Version 0.10 provides the complete bounded cartridge front end, DMG address
bus, SM83 instruction core, shared hardware clock, dot-clocked PPU, and all
four DMG audio channels. It validates both header and global checksums,
creates an owned immutable ROM image, models cartridge RAM/RTC register
windows, and implements ROM-only, MBC1/MBC1M, MBC2, MBC3/MBC30, MBC5,
MMM01, and digital HuC1 banking. Every legal base and CB opcode runs through
explicit read, write, and idle M-cycle callbacks. Host waits and slice sizes
cannot alter device order or guest results.

DIV/TIMA falling edges, delayed reload writes, IF/IE dispatch retargeting,
HALT/STOP wake behavior, the two-M-cycle DMA start delay, all 160 DMA bytes,
the active-low P1 matrix, and the DMG 8192-Hz internal serial clock are modeled
on the 4.194304-MHz T-cycle axis. A missing serial partner supplies pulled-up
one bits without blocking; no link or network transport exists in this stage.

NR10-NR52 and wave RAM share that same clock. The APU implements both pulse
channels, channel-1 sweep, wave playback and DMG wave-RAM access, noise LFSR,
length/envelope sequencing, NR50/NR51 mixing, DAC centering, and a high-pass
filter. A deterministic phase accumulator produces 48-kHz stereo S16LE into
bounded caller-owned buffers. Only `r4os.subsystem_runtime` forwards those
buffers through App-Audio/AUDSVC; an unavailable audio path degrades audio
without stopping CPU, timer, or PPU progress.

Battery cartridges persist exact raw SRAM as `HASH.SAV` and versioned MBC3
clock state as `HASH.RTC` below
`C:\R4OS\SUBSYSTEMS\r4os.gb\SAVE\`, where `HASH` is the uppercase
SHA-256 digest of the complete ROM. A create-only per-ROM lease permits one
writer. Delayed dirty flushes copy immutable SRAM and RTC snapshots into one
serial application worker, which coalesces newer pending generations and
performs same-directory atomic replacement without stalling guest time, video,
or audio. Clean and failure teardown both drain and join that worker before
releasing the lease. Non-battery cartridges never touch persistence. Lost
filesystem acknowledgements are retried within a bounded transaction. If a
process ends between the NTFS visibility points, the retained stage and
last-good backup are replayed under the cartridge lease on the next open, but
only after the stage has the exact expected size. RTC stages additionally need
a valid version, register set, and checksum. A partial or malformed stage
fails closed and preserves the backup; a backup is never removed unless the
canonical target is independently resolvable with the expected size and, for
RTC, valid content. A real competing writer remains a Busy error. Wall-clock
recovery is bounded and cannot run the RTC backwards; save states are
deliberately absent.
The lease, immutable-snapshot worker and atomic recovery implementation is now
the compiled-in `r4os.subsystem_persistence` SDK source helper shared with
R4SNES. R4GB still owns every cartridge decision, RTC byte format and clock
rule; the migration adds neither an R4L nor a platform ABI and retains the
complete existing persistence behavior.
The former APPDATA path is never probed at runtime. Installations that used the
short-lived pre-release path must copy validated SAV/RTC files to the canonical
root before starting the corresponding cartridge.

Build on Linux with `./Build.sh test` and on Windows with `Build.bat test`.
`reference-test` additionally validates a local, optional reference tree; use
`-Dgb-reference-root=<path>` to override its derived workspace location.
`-Dgb-reference-suite=<id>` selects one manifest suite for diagnosis.
`cartridge-test -Dgb-cartridge=<path>` validates one explicitly supplied local
image and proves that probing leaves its bytes unchanged.
`Tests/dmg_test_matrix.json` is the machine-readable DMG-C qualification
matrix. It records license, pinned revision, content hash, completion protocol,
timeout, and target for 15 executed case sets from six open source families,
plus ten explicit CGB, SGB, AGB, or external-peripheral exclusions. The
reference gate executes all 500,000 SM83 vectors, 28 production-machine mapper
ROMs, 34 applicable Mooneye clock/I/O ROMs, 32 Mooneye PPU ROMs, three
DMG-applicable SameSuite ROMs, 25 pixel-exact Acid2/Mealybug cases, every
RTC3Test v004 group, and the Mealybug MBC3-RTC ROM. Its pinned manifest totals
15 suites, 852 files, and 500,129 result records, with expected digests checked
for every suite. Commercial ROMs never participate in an automated gate.

The repository-native original end-to-end fixture exercises joypad, timer,
interrupt, PPU, all four APU channels, battery RAM, RTC, and finite completion
through the production Machine. A deterministic maturity harness profiles CPU,
PPU, and audio work, proves identical final digests at different host pacing,
and keeps every guest slice bounded. Host and guest persistence tests cover raw
SRAM, corrupt input, exclusive ownership, delayed and atomic writes, injected
storage failures, coalesced asynchronous writes, drain-on-close, and restart
recovery.
The productive `R4SUBSYS1` path now opens each accepted cartridge as a private
GUI instance. It runs one 32,768-T-cycle-bounded guest slice per common runtime
cycle, publishes the native 160x144 Indexed8 surface through
`r4os.subsystem_host`, and sends PCM only through App-Audio. Resize and
maximize preserve aspect ratio and letterboxing; unchanged frames are not
republished. Focus loss releases every held guest button. F5 pauses, F6
resumes, F8 creates a fresh machine generation, F9 mutes, and F10 unmutes.
Reset, runtime failure, normal window Close, and repeated Close all converge
on the same idempotent teardown of audio, video, persistence, machine, and ROM
ownership. Load, CGB, mapper, accessory, save, and runtime failures remain in
the cartridge's own window with a concrete diagnosis.

The installed `MODULES.JSON` entry is the only source for the subsystem host,
display name, `.gb`/`.gbc` candidates, format ID, and bounded cartridge probe.
`ASSOC.R4S` stores only `r4os.gb` plus `gameboy.dmg-cartridge`, so Explorer
double-click and Open With both resolve the installed host and create a new
R4X instance. The headless product gate performs that exact path for two
simultaneous original test cartridges for at least 60 guest seconds on both
one- and four-vCPU QEMU. It injects physical keyboard events, exercises focus
and lifecycle actions, requires bounded slices and scheduling gaps, advancing
PPU frames and lossless APU production, persists SRAM and RTC through the
drained worker, closes each instance separately, and proves a CGB-only image is
rejected in its own visible window. Independent 60-second one- and four-vCPU
QEMU WAV captures verify continuous real App-Audio output and the fixture's
approximately 440-Hz, 2:1 stereo signature across its intentional reset.
The deterministic test cartridges are generated entirely from original source
in this repository and contain no proprietary boot ROM, game data, or brand
assets.

Commercial ROMs, proprietary boot ROMs, and the local `ExFiles` reference
tree are never part of this public repository.
