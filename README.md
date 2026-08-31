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

Version 0.9 provides the complete bounded cartridge front end, DMG address
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
`C:\R4OS\APPDATA\SUBSYSTEMS\r4os.gb\SAVE\`, where `HASH` is the uppercase
SHA-256 digest of the complete ROM. A create-only per-ROM lease permits one
writer, delayed dirty flushes use same-directory atomic replacement, and a
clean close always attempts the final flush. Non-battery cartridges never
touch persistence. Lost filesystem acknowledgements are retried only after an
ownership-checked lease abort; a real competing writer remains a Busy error.
Wall-clock recovery is bounded and cannot run the RTC backwards; save states
are deliberately absent.

Build on Linux with `./Build.sh test` and on Windows with `Build.bat test`.
`reference-test` additionally validates a local, optional reference tree; use
`-Dgb-reference-root=<path>` to override its derived workspace location.
`-Dgb-reference-suite=<id>` selects one manifest suite for diagnosis.
`cartridge-test -Dgb-cartridge=<path>` validates one explicitly supplied local
image and proves that probing leaves its bytes unchanged.
The pinned DMG SameSuite APU selection and the QEMU WAV analyzer cover the
DIV-APU/NR52 edge cases and the real R4OS audio path independently. Automated
RTC3Test v004 and Mealybug MBC3-RTC execution cover tick, latch, halt, write,
overflow, and subsecond behavior; host and guest persistence tests cover raw
SRAM, corrupt input, exclusive ownership, delayed and atomic writes, and
restart recovery.
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
simultaneous original test cartridges, injects physical keyboard events,
requires frames and App-Audio, persists SRAM and RTC, closes each instance
separately, and proves a CGB-only image is rejected in its own visible window.
The deterministic test cartridges are generated entirely from original source
in this repository and contain no proprietary boot ROM, game data, or brand
assets.

Commercial ROMs, proprietary boot ROMs, and the local `ExFiles` reference
tree are never part of this public repository.
