# Compatibility target

- Target hardware: Nintendo Game Boy DMG, production profile DMG-CPU C.
- Secondary conformance profiles: DMG-CPU 0, A, and B where observable
  revision differences are backed by hardware research or revision-specific
  tests.
- Cartridge candidates: `.gb` and `.gbc`; the extension is not a capability
  claim.
- Color Game Boy: dual-mode cartridges may execute through their DMG path;
  CGB-only cartridges are rejected. CGB hardware features are out of scope.
- Boot: no proprietary Nintendo boot ROM is distributed or required.
- Persistence root: `C:\R4OS\APPDATA\SUBSYSTEMS\r4os.gb\SAVE\`.
- Save states are intentionally out of scope. Battery SRAM and MBC3 RTC
  persistence are product requirements.
- Link emulation is not part of 0.72.X. The serial hardware remains a distinct
  component so a later TCP/IP transport can attach without changing the CPU.
- Initial input: keyboard only. Arrows=D-pad, Enter=Start, right Ctrl=Select,
  left Alt=B, Space=A.

## Cartridge hardware

| Hardware | Status |
|---|---|
| ROM-only and ROM+RAM | Implemented |
| MBC1, large-ROM wiring, MBC1M | Implemented |
| MBC2 internal 512x4-bit RAM | Implemented |
| MBC3/MBC30 banking, clock, register/latch window and persistence | Implemented |
| MBC5, including separate ninth ROM and rumble bits | Implemented; no rumble output |
| MMM01 | Implemented, including final-header discovery and one-way mapper lock |
| HuC1 | Implemented for digital ROM/RAM banking and deterministic digital IR reads; no physical IR output |
| MBC6, HuC3, TAMA5 | Recognized and rejected with a mapper-specific unsupported error |
| MBC7 sensor/rumble and Pocket Camera | Recognized and rejected with an accessory-specific unavailable error |

All accepted images must match their declared complete ROM length, mapper
limits, RAM declaration, Nintendo logo, header checksum, and global checksum.
ROM data is copied into instance-owned immutable storage before use.

## Persistence and real-time clock

- The SHA-256 digest of the complete ROM is its save identity, so renaming or
  moving a cartridge preserves its data while different content cannot alias.
- Battery SRAM is the exact declared byte sequence in `HASH.SAV`; non-battery
  cartridges never create persistence files.
- MBC3 state is a fixed-size, versioned and checksummed `HASH.RTC` record with
  subsecond T-cycles, seconds/minutes/hours, 9-bit day, carry, halt, latch and
  time anchors.
- One `HASH.LCK` writer lease prevents last-writer-wins corruption across
  instances. Crash cleanup and release are generation-bound.
- Dirty data is delayed and atomically replaced in the same directory. Clean
  Close performs a mandatory final flush; a failed replacement leaves the
  previously published save intact.
- Missing files initialize clean state. Wrong SRAM sizes and malformed RTC
  records are explicit errors. Backward wall-clock movement adds no time and
  implausible forward movement is capped at 512 days.

## CPU

- All 244 legal base paths and all 256 CB-prefixed operations are implemented.
- Register, flag, RAM, PC, SP, IME and M-cycle bus results match all 500,000
  pinned SM83 SingleStep cases.
- Mooneye `daa`, `bits/reg_f`, and `boot_regs-dmgABC` execute to their success
  signatures through both the CPU-only path and the clocked Machine path.
- Illegal opcodes lock only the guest CPU; they cannot escape the guest budget
  or cause a host memory access.

## Clocked DMG hardware

| Hardware | Status |
|---|---|
| 4.194304-MHz system clock | Implemented with bounded monotonic, pause-corrected host budgets |
| DIV/TIMA/TMA/TAC | Implemented, including write-created falling edges and four-T-cycle reload behavior |
| IF/IE and interrupt entry | Implemented, including five-M-cycle entry and IE-push cancellation/retargeting |
| HALT and STOP | Implemented with HALT bug, IME behavior, selected-P1 STOP wake, and stopped clock/DMA |
| OAM DMA | Implemented with two-M-cycle start, 160 transfers, restart, DMG blocking and source decoding |
| P1 joypad | Implemented as two active-low rows with edge IRQ, side-specific HID mapping, repeat suppression and focus release |
| SB/SC serial | Implemented for DMG internal/external clock state; a disconnected internal transfer receives `0xFF` and never blocks |
| APU power/frame sequencer | Implemented for NR52, DIV-APU edges, length clocks, trigger/DAC behavior and DMG power-on sequencing |
| Pulse 1/2 | Implemented with duty, frequency, length, envelopes and channel-1 sweep |
| Wave channel | Implemented with wave RAM, access windows, restart behavior, length and output level |
| Noise channel | Implemented with frequency control and 15/7-bit LFSR modes |
| Stereo output | Implemented with NR50/NR51, DAC centering, high-pass filtering and deterministic 48-kHz S16LE output through App-Audio/AUDSVC |

The revision-pinned Machine gate currently executes 33 DMG-C-applicable
Mooneye ROMs covering boot phase/MMIO, CPU and stack timing, EI/DI/RETI,
IF/IE, interrupt retargeting, HALT, every timer frequency and reload window,
serial alignment, OAM bytes, complete DMA copy/register behavior, and all DMG
DMA source regions. Twenty tests whose alignment explicitly requires live LCD
scanlines are assigned to the PPU stage; nine DMG-0, MGB, or SGB post-boot
profiles are recorded as foreign to the production DMG-C revision.

Both DMG-applicable SameSuite APU ROMs pass in the Machine harness. Targeted
unit cases cover register masks, power, trigger, sweep, envelope, wave RAM,
noise sequences, mixing, sample-rate drift, bounded buffering, and isolated
audio degradation. The automated QEMU capture additionally requires 6,000
source frames to reach AUDSVC without loss and detects one continuous,
non-silent stereo waveform after QEMU's host-rate conversion. CGB- and
SGB-specific SameSuite audio cases are intentionally outside the DMG target.

RTC3Test v004 passes all three automated UI-driven groups, and the generated
Mealybug MBC3-RTC reference ROM reaches its pass state. The complete reference
harness currently covers 15 suites, 850 files and 500127 execution vectors or
result records. Persistence additionally has injected host-backend tests and
a marker-gated QEMU test through the real R4SYS filesystem path.
