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
- Persistence root: `C:\R4OS\SUBSYSTEMS\r4os.gb\Save\`.
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
| MBC3/MBC30 banking and RTC register/latch window | Implemented; clock progression and persistence attach in 0.72.7 |
| MBC5, including separate ninth ROM and rumble bits | Implemented; no rumble output |
| MMM01, MBC6, TAMA5, HuC1, HuC3 | Known digital mapper, currently rejected as unsupported |
| MBC7 sensor/rumble and Pocket Camera | Known unavailable accessory hardware, explicitly rejected |

All accepted images must match their declared complete ROM length, mapper
limits, RAM declaration, Nintendo logo, header checksum, and global checksum.
ROM data is copied into instance-owned immutable storage before use.

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

The revision-pinned Machine gate currently executes 33 DMG-C-applicable
Mooneye ROMs covering boot phase/MMIO, CPU and stack timing, EI/DI/RETI,
IF/IE, interrupt retargeting, HALT, every timer frequency and reload window,
serial alignment, OAM bytes, complete DMA copy/register behavior, and all DMG
DMA source regions. Twenty tests whose alignment explicitly requires live LCD
scanlines are assigned to the PPU stage; nine DMG-0, MGB, or SGB post-boot
profiles are recorded as foreign to the production DMG-C revision.
