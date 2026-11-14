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

The dedicated GitHub workflow must still complete the full firmware build and
artifact audit before factory/sysupgrade files are considered deliverable.
