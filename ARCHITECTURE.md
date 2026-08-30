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
| `clock` | bounded host-to-guest cycle budgets and fractional conversion | device state or wall-clock decisions |
| `timer` | divider edge state, TIMA/TMA/TAC and reload pipeline | CPU instruction dispatch |
| `interrupts` | IF, IE, request/acknowledge state and priority | peripheral implementation or CPU IME |
| `dma` | OAM DMA source, phase and CPU bus exclusion | PPU rendering |
| `ppu` | VRAM, OAM, LCD registers, dot/mode pipeline and 160x144 indices | host window scaling |
| `apu` | four DMG channels, frame sequencer and deterministic mixer | R4OS audio service buffering |
| `joypad` | P1 selection and eight active-low buttons | keyboard identities |
| `serial` | SB/SC and transfer timing seam | link transport |
| `persistence` | battery SRAM/RTC serialization state | save-state snapshots |
| `host_adapter` | R4SUBSYS1, R4OS files/window/input/audio translation | guest hardware behavior |

`Machine` coordinates components in the stable T-cycle order timer/divider,
DMA, serial, and the later PPU/APU stages. Every CPU read, write, or idle
M-cycle advances exactly four T-cycles. Host time is sampled only by the host
adapter. The guest receives monotonic, pause-corrected time through the common
subsystem runtime; a host delay grants at most one bounded slice and discarded
excess time is never replayed as catch-up. Audio uses caller-owned PCM buffers
and the normal application audio service. Window presentation and keyboard
mapping use `r4os.subsystem_host`; neither affects emulated time.

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
global checksum, mapper/RAM consistency, and CGB capability. A `.gbc` filename
does not imply CGB-only hardware, and a
`.gb` filename cannot bypass a CGB-only header. Unsupported mappers and pure
CGB images fail before a machine is created. The input ROM buffer is never
modified.

The cartridge owns its complete ROM allocation as a read-only slice. Mapper
register writes can only select bounded ROM, SRAM, nibble RAM, or RTC register
indices. Physically absent banks read as `0xFF`; missing power-of-two address
lines mirror existing storage. MBC1M is selected only after a valid embedded
bank-`0x10` header is found. MBC5 rumble state is recorded separately and can
never become a RAM-bank bit.

The bus classifies every `u16` address into exactly one DMG region. WRAM echo,
DMG unusable-area values, VRAM/OAM mode gates, and DMA CPU exclusion are
handled before indexing device storage. A guest address is never widened into
an unchecked host address.

## CPU execution boundary

The SM83 decoder is complete for all 244 legal non-prefix base opcodes and all
256 CB operations. One `Cpu.step` executes either one instruction, one
interrupt entry, or one bounded halted/stopped/locked cycle. Every memory read,
memory write, and internal M-cycle crosses a caller-owned callback interface;
the CPU never owns or bypasses guest memory. The callback order therefore
preserves conditional timing, stack byte order, and read-modify-write points
for timer, DMA, PPU, and interrupt integration.

Flags are masked to their four physical upper bits at the CPU boundary. IME,
delayed EI, DI, RETI, HALT, the HALT bug, STOP, interrupt vectors, and the
documented illegal-opcode lock are explicit instance fields. No decode table,
scratch register, or pending transition is shared between machines.

## Clocked I/O boundary

DIV is the visible high byte of one 16-bit system counter. TIMA observes the
selected counter bit's falling edge, including edges created by DIV and TAC
writes. Overflow exposes zero for four T-cycles before TMA reload and the timer
request; TIMA and TMA writes honor the reload cancellation and write windows.
The counter and DMA freeze in STOP. A selected P1 high-to-low transition wakes
STOP independently of IE while also requesting the joypad interrupt.

Interrupt entry is five M-cycles. IF is acknowledged only after the stack's
low-byte write. The enabled request set is sampled again after the high-byte
write, so an IE write at `0xFFFF` can cancel dispatch or select a new
higher-priority vector exactly as on DMG hardware. HALT, delayed EI, immediate
DMG DI, RETI, and the HALT bug remain CPU-owned state.

OAM DMA starts after two M-cycles, transfers one byte per M-cycle, and exposes
only HRAM plus the DMA control register to the CPU while active. A new FF46
write preserves the old transfer during the start delay and then restarts at
byte zero. DMG source decoding covers ROM, VRAM, cartridge RAM, WRAM, and the
E000-FFFF echo behavior without routing a DMA address through the blocked CPU
bus.

P1 combines either or both active-low four-line rows. Physical HID usages are
mapped by side, repeated make events do not create edges, and focus loss
releases all held buttons. SB/SC use the shared post-boot divider phase; an
internal transfer shifts eight pulled-up input bits and requests Serial, while
external-clock mode remains pending without host blocking or network access.

## Test boundary

Small original fixtures live in this repository. Large JSON vectors and open
test ROMs remain in the ignored workspace `ExFiles` tree. `reference-test`
derives that tree from the repository location or accepts an explicit root;
missing optional material is reported as `SKIP`, never fetched implicitly.
The DMG-C machine selection executes 33 revision-applicable Mooneye cases and
records PPU-dependent and foreign-revision cases separately. Commercial ROMs
are local manual compatibility inputs only.
