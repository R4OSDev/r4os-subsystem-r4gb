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

Version 0.6 provides the complete bounded cartridge front end, DMG address
bus, SM83 instruction core, shared hardware clock, dot-clocked PPU, and all
four DMG audio channels. It validates both header and global checksums,
creates an owned immutable ROM image, models cartridge RAM/RTC register
windows, and implements ROM-only, MBC1/MBC1M, MBC2, MBC3/MBC30, and MBC5
banking. Every legal base and CB opcode runs through explicit read, write, and
idle M-cycle callbacks. Host waits and slice sizes cannot alter device order
or guest results.

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

Build on Linux with `./Build.sh test` and on Windows with `Build.bat test`.
`reference-test` additionally validates a local, optional reference tree; use
`-Dgb-reference-root=<path>` to override its derived workspace location.
`-Dgb-reference-suite=<id>` selects one manifest suite for diagnosis.
`cartridge-test -Dgb-cartridge=<path>` validates one explicitly supplied local
image and proves that probing leaves its bytes unchanged.
The pinned DMG SameSuite APU selection and the QEMU WAV analyzer cover the
DIV-APU/NR52 edge cases and the real R4OS audio path independently.
Commercial ROMs, proprietary boot ROMs, and the local `ExFiles` reference
tree are never part of this public repository.
