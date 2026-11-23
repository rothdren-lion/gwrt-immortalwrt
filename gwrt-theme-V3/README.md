# GWRT Theme Project

This directory is the standalone source and integration entry point for the
GWRT LuCI theme. It is independent of the OpenWrt `package/` scan, so keeping
it in the firmware repository does not create a duplicate package.

## Layout

- `theme/luci-theme-gwrt/`: canonical `luci-theme-gwrt` package source.
- `overlays/`: compatibility files required by the theme, currently the OAF
  per-app checkbox fix and package release.
- `manifest/config.fragment`: theme feature packages enabled for firmware
  builds (OAF, Bandix, Coremark and OTA download tools).
- `theme/luci-theme-gwrt/root/etc/uci-defaults/30_gwrt-banner`: generates the
  SSH login banner from `/etc/openwrt_release`, keeps the firmware version
  aligned with the homepage first card, colors the middle logo row blue,
  shows the DTS model from `/tmp/sysinfo/model` with `/tmp/sysinfo/board_name`
  as fallback, and appends `|https://gwrt.uk` directly to the Source line.
- `scripts/integrate.sh`: syncs the canonical source into both flat and nested
  package trees, rejects the retired dashboard injector and backup files,
  merges the config fragment and runs `make defconfig`.
- `scripts/build-with-theme.sh`: integrates first, then runs the requested
  firmware `make` command.

## Usage

From the ImmortalWrt source root:

```sh
./gwrt-theme-project/scripts/integrate.sh --tree .
./gwrt-theme-project/scripts/integrate.sh --tree . --check
```

To integrate and build in one command:

```sh
taskset -c 0-5 ./gwrt-theme-project/scripts/build-with-theme.sh --tree . -j6
```

The wrapper does not switch hardware profiles. Select and validate the target
profile first, then invoke it with the normal build arguments.

Do not edit generated copies under `package/gwrt-theme/luci-theme-gwrt/` after
adopting this workflow. Edit `theme/luci-theme-gwrt/`, run `integrate.sh`, and
verify with `--check`.

## AP8220 OTA notes

- AP8220 uses board `aliyun,ap8220`, target `qualcommax/ipq807x`, and OTA device manifest `gwrt-ota/stable/devices/aliyun_ap8220.json`.
- `31_luci-theme-gwrt` clears only the old built-in `gwrt-ota.json` manifest URL so the OTA helper can select `devices/<board>.json`.
- `32_gwrt-ota-github-hosts` conditionally adds a tagged `/etc/hosts` GitHub bypass only when DNS returns `198.18/198.19` fake-ip addresses, which was required for AP8220 router-local OTA downloads in the lab.
- Future OTA patches that carry `32_gwrt-ota-github-hosts` should keep `reboot: true` in the manifest, or the OTA backend must execute the script explicitly.

