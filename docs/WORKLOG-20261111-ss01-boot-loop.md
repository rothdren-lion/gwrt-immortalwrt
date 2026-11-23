# WORKLOG 2026-11-11 - SS-01 261111-01 boot loop

## 1. Task

Monitor the SS-01 serial console after the user reported that the firmware built
today does not enter the system normally. No firmware was flashed and no reboot
was requested or initiated by this diagnostic session.

## 2. Device and capture

- Board: `JDCloud RE-SS-01` (`jdcloud,re-ss-01`), 1 GiB RAM.
- Running image: `GWRT 261111-01`, revision `4e20145`, Linux `6.18.62`.
- UART: USB serial adapter, 115200 8N1, `/dev/ttyACM0`.
- Raw capture: `/tmp/gwrt-ss01-boot-20261111-5pslexle/serial.raw`.
- Text capture: `/tmp/gwrt-ss01-boot-20261111-5pslexle/serial.log`.

The kernel mounts squashfs root on `179:18`, starts procd, and presents a shell
at about 18 seconds. Linux does not panic. The visible failure is a software
restart before startup settles, so LAN management is unavailable long enough to
make the unit appear not to boot.

## 3. Confirmed restart cause

The runtime `/etc/init.d/gwrt-caldata` and immutable `/rom/etc/init.d/gwrt-caldata`
have identical SHA-256 `1061271ce126333fe34421bd2b7ad0e29877175c41b018253431cea8bb9a3d79`.
The runtime script is configured as `S18gwrt-caldata`. Its calibration file is
absent from both `/lib` and `/rom` at the start of each observed boot. At uptime
about 102 seconds it extracts 65,536 bytes from `0:ART` (`/dev/mmcblk0p15`, byte
offset `0x1000`), creates `/etc/gwrt-caldata-rebooted`, then starts a worker that
runs `sleep 8; sync; reboot`.

Serial and shell evidence:

| Observation | Evidence |
|---|---|
| First restart | `procd: - shutdown -` at 111.451s; `procd: - reboot -` at 122.597s |
| Next restart | shutdown at 115.772s; reboot at 128.757s |
| Calibration worker | At 102.76s, `S18gwrt-caldata` and child `sleep 8` are running; log says it extracted 65,536 bytes and is rebooting to activate Wi-Fi |
| State after restart | At 71.41s of the next boot, the calibration file and `/etc/gwrt-caldata-rebooted` are both absent; the same extraction and restart sequence runs again |

The repeated file loss is explained by fstools' overlay state machine. At about
17 seconds each boot logs `overlay filesystem has not been fully initialized
yet`. In `overlay.c`, an unknown state is changed to `PENDING`; the pending path
calls `overlay_delete()` and then mounts the F2FS overlay. `/etc/init.d/done`
(`START=95`) is the normal path to `mount_root done`, which sets the state to
`READY`. In the captured boot, `S10boot` was still running when `S18gwrt-caldata`
started around 102 seconds and scheduled its restart. Shutdown began around
110-116 seconds, before the overlay reached `READY`. The next boot therefore
re-enters the unknown/pending path and fstools clears the calibration file and
guard from the overlay. The missing `/overlay/.fs_state` and missing files were
confirmed from the shell after reboot. This explains the repeat without
assuming that `sync` itself failed.

The live UART capture later recorded ten consecutive shutdown/reboot pairs
with the same extraction and restart log, followed by another boot beginning.

The init script itself is the root cause of the restarts. The restart is
particularly disruptive because network interfaces only begin coming up at
about 106 seconds; one LAN link reaches 1 Gbps and bridge forwarding shortly
before shutdown begins.

## 4. Other serial findings

- `board_detect` reports `/etc/board.d/04_defaults: line 32:
  ucidef_set_wireless_channel: not found`. It also reports missing
  `/etc/fw_env.config` and an NVMEM lookup failure. These need separate cleanup;
  they do not explain the logged restart request.
- SSDK prints `ssdk_uniphy_*: ERROR:set parent fail!` during initialization, but
  reports module init success and attaches all four QCA8075 PHYs. A LAN2 link is
  observed; packet counters and effective 125 MHz NSS clock parents were not
  verified before the restart.
- ath11k's `caldata.bin will not be loaded`, QMI calibration failure, and USB
  clock warnings occur after `procd: - shutdown -`; they are shutdown-time
  warnings, not the initiating fault.

## 5. Corrective work to test

Make the calibration available before the first ath11k probe, or defer any
restart until the persistent overlay is initialized and verify the marker/file
survive a subsequent boot. A regression check should exercise a clean first boot
with no calibration file and prove it cannot enter a repeated restart loop.
After startup is stable, separately verify NSS clock parents, LAN TX/RX
counters, and DHCP over a physical LAN port.

No source or device changes were made. No image was built or flashed. After
reproducing the defect, the `ss01-261111-01` release bundle and its temporary
image copies were moved out of the delivery path into the system Trash so they
cannot be mistaken for usable firmware. The verified factory/sysupgrade hashes
were respectively
`a0fe8bff7dd5133508aed4f85206c8f1f4e9868b819ebb0efb8e415ff95cd441` and
`b56157a334f534a0f999bee7f91b4b008d9b21e4766c7f0e4fd4631453888f2b`.
The raw UART capture, extracted DT evidence, and this worklog remain available
for the next firmware fix.
