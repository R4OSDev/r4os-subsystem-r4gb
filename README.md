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

Version 0.2 provides the complete bounded cartridge front end and DMG address
bus. It validates both header and global checksums, creates an owned immutable
ROM image, models cartridge RAM/RTC register windows, and implements ROM-only,
MBC1/MBC1M, MBC2, MBC3/MBC30, and MBC5 banking. Known unsupported mapper and
physical-accessory cartridge types fail with separate classifications.

Build on Linux with `./Build.sh test` and on Windows with `Build.bat test`.
`reference-test` additionally validates a local, optional reference tree; use
`-Dgb-reference-root=<path>` to override its derived workspace location.
`cartridge-test -Dgb-cartridge=<path>` validates one explicitly supplied local
image and proves that probing leaves its bytes unchanged.
Commercial ROMs, proprietary boot ROMs, and the local `ExFiles` reference
tree are never part of this public repository.
