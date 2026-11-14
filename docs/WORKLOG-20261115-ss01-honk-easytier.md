# WORKLOG 2026-11-15 — SS-01 Honk + EasyTier dedicated build

## Scope

This is a separate SS-01 project and workflow. It is based on the latest SS-01
NSS/DTS source in this tree and keeps the physical 12 MiB HLOS layout. The
firmware removes the existing proxy engines and their LuCI pages, then embeds
Honk and EasyTier as independent services:

- `honk-core` is installed as `/usr/bin/honk-core` with `/etc/init.d/honk`.
- EasyTier keeps `/usr/bin/easytier-core`, its web console, LuCI page and Chinese
  translation.
- Honk is disabled on a fresh image until the user enables it, so it cannot
  unexpectedly take over the network before a configuration is supplied.
- The ordinary GWRT agent, device defaults, Mesh services, NSS/SSDK and SS-01
  AHB Wi-Fi packages remain from the current SS-01 profile.

The dedicated build is explicitly labelled `SS-01 Honk + EasyTier` in the
workflow, artifact name, build log and release title. It is not part of the
four-profile `ss01/cs02/cs02-gwrt2/cs07` workflow.

## Honk source and UI

Honk is pinned to `v0.1.0-beta.6`; the workflow checks out the tag and verifies
its pinned Rust toolchains and `bpf-linker`. The Doona release is pinned to
`0.1.0-rc.6` with both standard and Lite archive hashes checked by Honk's own
`ci/fetch-doona.sh`.

The `native-ui` build embeds both editions in `honk-core`:

- `ui: 'embedded'` (the default here) is the complete Doona interface with
  activity/observability, diagnostics and configuration editing.
- `ui: 'embedded-lite'` selects Doona Lite, the smaller preview interface
  focused on the lighter node view and basic operation.

Both editions use the same Honk native API and proxy data plane. Switching the
setting in `/etc/honk/config.dae` does not require a firmware rebuild.

## Verification

Configuration and source preflight pass after `make defconfig`; the residual
`luci-app-passwall_INCLUDE_SmartDNS` Kconfig selection is treated as a disabled
parent package's non-package option and does not add a proxy package. Target,
calibration recovery, SS-01 Mesh, first-boot and roaming regressions pass.

The dedicated GitHub workflow subsequently completed the full firmware build
and artifact audit successfully; the final result is recorded below.

## Build result

GitHub Actions run `43620419381` completed successfully at
`2026-11-14T19:02:01Z` (2026-11-15 04:02:01 Asia/Tokyo). Its build job took
1h43m03s and used implementation commit
`19e673775acea9029189ba5ef2d53e7eac3a3f5f` on
`build/ss01-honk-easytier-261115-01`. The run used `release=false`; no GitHub
Release was published. Configuration, source preflight, calibration recovery,
Mesh, first-boot, roaming, Honk Rust/eBPF compilation, image audit, and
artifact upload all passed.

The downloaded artifact was verified at
`/tmp/gwrt-ss01-honk-easytier-261115-01.zip`. Its factory/sysupgrade hashes
matched the generated checksum file. The checksum file also lists the normal
buildinfo and initramfs outputs; those optional files were not included by the
dedicated artifact upload, so the delivery archive contains the two flashable
images plus manifest, profiles, configuration, source pins, and build logs.

## Archived delivery

Final files are archived under
`/home/godsun/build/gwrt-releases/ss01-honk-easytier-261115-01/` with the
verified physical `12M` label. The delivery checksum is
`sha256sums-261115-01` and is copied to `sha256sums`; `sha256sum -c` passes for
every archived file. Image filenames include `12M-honk-easytier`. Delivery
profiles resolve to those filenames; the original cloud profiles and complete
cloud checksum list are preserved in `original-cloud-metadata/`.

The archived `.local-defconfig` is the local preflight configuration, not an
exact cloud `config.buildinfo`. The cloud checksum references buildinfo and
initramfs files that this workflow did not upload; those omissions are documented
in `README.md`. The two requested firmware hashes match the original cloud
metadata; the original manifest and profile files also passed their source
checksum checks before the delivery profile names were adapted.

Local re-execution of `gwrt-verify-ss01-image.py --variant honk-easytier` passed:
factory rootfs offset is 12 MiB; the kernel and rootfs match sysupgrade; embedded
DTB model, dynamic UNIPHY parents, ports, packaged theme, Mesh and first-boot
files match the source. Honk, EasyTier, LuCI integration and the embedded Doona
payload passed package checks; other proxy engines are absent. The packaged
`v2ray-geoip` and `v2ray-geosite` are Honk's declared data dependencies.

An additional QEMU userspace check printed EasyTier version
`2.6.4-8428a89d`. Honk exited at `prctl(41, 1, 0, 0, 0)` with `EINVAL` under
QEMU before printing its version; Honk runtime behavior and the router's
eBPF/WAN/Wi-Fi behavior remain unverified on hardware.

Flashable image hashes:

```text
factory:    afa3c9a77c2e8aa53eb294c6a0fca8f692c760b26c9b0839ea0e4577d8a763cf
sysupgrade: 3b8eb6add04c4ac6d85b59dc8d87ac40e6a87c7ade9268bc72a9bacf30cc168e
```

The archive has not been flashed and no router has been rebooted.

## GitHub rebuild behavior

The dedicated workflow runs on a fresh `ubuntu-24.04` GitHub-hosted runner. It
caches `dl`, `staging_dir/toolchain-*`, and Cargo registry/Git downloads. It
does not persist `build_dir`, target `staging_dir`, or compiled Cargo `target`
outputs. A cache hit can therefore reuse downloaded sources and the toolchain,
while kernel, packages, Honk and the final images are compiled again for each
new run. This run hit both the source-download and toolchain caches; its Cargo
download cache was initially absent and was saved after success. The actual
cache hit/miss messages are retained in the archived full run log.
