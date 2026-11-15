# WORKLOG 2026-11-15 — Four-model IPQ60xx Honk firmware

## Scope

The user requested a build of SS-01, CS-02 standard, CS-02 GWRT2, and CS-07
using the latest SS-01 Honk application selection, without connecting to any
router. No device was queried, changed, rebooted, or flashed.

The build matrix keeps the board-specific DTS and Ethernet stack for each
profile. All four current image definitions specify `KERNEL_SIZE=12288k`, so
the artifacts are 12M. SS-01 keeps NSS/SSDK and its integrated AHB radio;
CS-02 and GWRT2 keep their distinct DTS/port maps, both radios, Athena display,
and DSA PPE/EDMA; CS-07 remains wired-only with DSA PPE/EDMA and no radio,
wireless firmware/AP stack, Wi-Fi LuCI page, or Athena package.

The common app selection includes Honk with embedded Doona editions, EasyTier
LuCI/Chinese only, GWRT ad blocking, IPTV/UDPXY, Vlmcsd, the GWRT theme, device
defaults, and Mesh services. It does not embed EasyTier runtime binaries or
other proxy engines. The pinned Honk source remains `v0.1.0-beta.6` and its
Doona archives are checked by the upstream pinned hashes.

## Build workflow

The existing, registered `gwrt-ss01-honk-easytier.yml` workflow is extended to
run a four-device matrix under a single version, defaulting to `261115-04`.
Each matrix job creates one profile, performs configuration/source and behavior
preflights, builds at J6, audits the profile manifest and embedded image, checks
the generated image checksums, and uploads a board-specific artifact. It does
not create a GitHub Release.

The 12M factory offset is explicit at the build command through
`GWRT_CS02_KERNEL_SIZE=12288k`; sysupgrade images continue to contain separate
kernel and root members.

## Local validation

- Python syntax and generation passed for all four profiles.
- `make defconfig`, `gwrt-check-target.sh`, and the Honk package/hardware
  validator passed for all four profiles. The Kconfig output still contains
  76 feed recursive-dependency diagnostics per run, but `make defconfig`
  exits successfully and the resulting target/package selections pass.
- Source preflight, adblock query classification, and 176 local IPv4/IPv6 UDP/
  TCP DNS regression queries passed.
- Modal package UI tests passed at six desktop/mobile viewport sizes.
- IPQ60xx factory layout, Mesh roaming, and roaming autopair tests passed.
- The Lua CBI validation test could not run on this host because no Lua
  interpreter is installed; the cloud workflow installs Lua 5.1 and runs it.

The local checkout has about 17 GB free, so no full local firmware build was
attempted. No cloud build has been started yet; the next step is to commit only
the firmware-related candidate changes, push the build branch, and dispatch
version `261115-04` with the four profiles.
