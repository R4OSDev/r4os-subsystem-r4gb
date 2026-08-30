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
