# Architecture and ownership

Every emulated Game Boy is one `Machine` value. All mutable state is owned by
that instance; there are no process-global CPU, bus, cartridge, clock, audio,
video, input, or persistence variables. Guest addresses are always `u16`
integers. They are resolved by `Bus` and are never converted into or exposed
as host pointers.

The component boundaries are:

| Component | Owns | Does not own |
|---|---|---|
| `cartridge` | immutable ROM view, parsed header, mapper and external-RAM state | CPU or host files |
| `bus` | DMG address decoding, WRAM, HRAM, unusable/open-bus policy | host address space |
| `cpu` | SM83 registers and execution state | timing peripherals |
| `timer` | divider edge state, TIMA/TMA/TAC and reload pipeline | CPU instruction dispatch |
| `interrupts` | IF, IE, IME transition state and priority | peripheral implementation |
| `dma` | OAM DMA source, phase and CPU bus exclusion | PPU rendering |
| `ppu` | VRAM, OAM, LCD registers, dot/mode pipeline and 160x144 indices | host window scaling |
| `apu` | four DMG channels, frame sequencer and deterministic mixer | R4OS audio service buffering |
| `joypad` | P1 selection and eight active-low buttons | keyboard identities |
| `serial` | SB/SC and transfer timing seam | link transport |
| `persistence` | battery SRAM/RTC serialization state | save-state snapshots |
| `host_adapter` | R4SUBSYS1, R4OS files/window/input/audio translation | guest hardware behavior |

`Machine` coordinates components in T-cycle order. Host time is sampled only
by the host adapter. The guest receives monotonic, pause-corrected time through
the common subsystem runtime. Audio uses caller-owned PCM buffers and the
normal application audio service. Window presentation and keyboard mapping
use `r4os.subsystem_host`; neither affects emulated time.

## Boot model

R4GB does not contain or load a proprietary boot ROM. The production profile
is `dmg_c`. It begins at PC `0x0100` with the hardware-observed DMG-ABC
register state and documented post-boot MMIO values. Separate `dmg_0`,
`dmg_a`, and `dmg_b` profiles prevent revision-specific tests from silently
mixing expectations. DMG-0 has its distinct registers and boot-time DIV/LCD
values. Revision identity is immutable after machine construction.

## Error boundary

Cartridge discovery is intentionally broader than execution. The host first
checks file bounds, Nintendo-logo bytes, header checksum, declared ROM size,
and CGB capability. A `.gbc` filename does not imply CGB-only hardware, and a
`.gb` filename cannot bypass a CGB-only header. Unsupported mappers and pure
CGB images fail before a machine is created. The input ROM buffer is never
modified.

## Test boundary

Small original fixtures live in this repository. Large JSON vectors and open
test ROMs remain in the ignored workspace `ExFiles` tree. `reference-test`
derives that tree from the repository location or accepts an explicit root;
missing optional material is reported as `SKIP`, never fetched implicitly.
Commercial ROMs are local manual compatibility inputs only.
