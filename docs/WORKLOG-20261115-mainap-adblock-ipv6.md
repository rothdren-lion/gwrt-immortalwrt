# WORKLOG 2026-11-15 — Main AP ad blocking on IPv4/IPv6

The user explicitly authorized applying and verifying the ad blocker directly
on `192.168.9.9`. The device reports `jdcloud,re-cs-02-gwrt2`, Linux 6.18.52,
dnsmasq 2.93, and BusyBox 1.38.0. This work is limited to the main AP's DNS
ad-blocking path and related LuCI validation. No firmware was built or flashed.

## Changes on the main AP

Before changing files, an admin-only backup was made at
`/root/gwrt-backups/20261115-072806-adblock-ipv6/` and copied to the private
evidence directory. `files.tar.gz` SHA-256 is
`2e0ff20be186c1d85ca7443f18b72136e5e2f0dbea25b9845075bc4189547a92`.
Pre-change DHCP/firewall config checksums are saved there.

The adblock init/CLI/query helper and LuCI controller/CBI were installed from
the isolated candidate; dnsmasq was reloaded to apply generated rules. Existing
`/etc/config/gwrt-tv-adblock` and its user library were preserved. All five
existing categories remained enabled, and `cat_360=1` was added. The legacy
564-line active library was preserved and extended with the seven 360 roots;
the original was saved as `ads-library.txt.before-360`. Root and subdomain A
and AAAA queries return NXDOMAIN.

The first client tests exposed that daed intercepts DNS before ordinary fw4
redirects or dnsmasq. The selected daed DNS configuration therefore now sends
the ad-library suffixes to local dnsmasq over TCP and UDP on loopback. The
existing domestic/foreign DNS split remains for all other domains. The current
library was collapsed to 464 suffixes; dnsmasq evaluates all configured
categories and the custom allow list. The machine-local synchronization tool is
`scripts/gwrt-sync-daed-adblock.py`; it reads the live library and custom block
list, signs a five-minute API token in memory, changes only the selected DNS
policy, and supports `--check` and `--restore`. Its original policy snapshot
must remain in the private state directory for rollback. The tool is manual:
after replacing/adding library domains or changing the daed DNS policy, run it
again. New library suffixes are not synchronized automatically.

A persistent fw4 redirect catches LAN TCP/UDP port 53 for both families when
ordinary DNS reaches the firewall. `fw4 check` and `fw4 reload` passed; it did
not replace the need for the daed DNS rule. Existing warnings mention missing
optional OpenClash/Passwall include files. The redirect's nft counters stayed
at zero during client checks because daed handles these queries first.

An actual Lua 5.1 test revealed that the previous CBI regex rejected every
custom domain. Validation now checks legal labels without unsupported repeated
Lua capture groups. Twenty-six valid/invalid block-list and allow-list cases
pass on the target Lua runtime. The LuCI adblock page returned HTTP 200, showed
the enabled 360 selector and successful A/AAAA status, and had no mobile
horizontal overflow.

The new DNS query helper initially classified real target queries as unknown:
this firmware's BusyBox `tr` does not interpret POSIX `[:upper:]`/`[:lower:]`
classes. It now normalizes query types using explicit `a-z`/`A-Z` ranges and
accepts uppercase `A`/`AAAA`; both the live CLI and LuCI checks pass. Source
package versions are 2.2-r3 and LuCI 1.0-r3. These files were hot-updated on the
router; the installed APK version metadata was not rewritten.

## Verification

- 416 of 416 checks passed across the router IPv4 DNS address, an external IPv4
  resolver, and two ISP IPv6 resolvers. The matrix covered all seven 360 roots,
  `www` and nested subdomains, A and AAAA, UDP and TCP, plus existing Xiaomi TV,
  Baidu analytics and forced-kill rules. All blocked-domain checks returned
  NXDOMAIN. A positive `www.baidu.com` A/AAAA control resolved successfully.
- A separate 48-query final check confirmed the main 360 behavior and normal
  site resolution after restoring the original test whitelist setting. The
  earlier temporary nft probe table was deleted; the owned temporary TC filter
  was removed, with daed's ingress BPF filter retained.
- Actual workstation HTTPS requests using curl to `https://www.360.cn/` failed
  during DNS resolution, while Baidu and Google returned HTTP 200.
- Adblock CLI status confirms all existing categories remain enabled and
  `www.360.cn`, nested 360 subdomains, and their A/AAAA lookups are blocked.
- Main AP boot ID remained `6e3ed4d3-29ef-4ec1-b5ee-48347bca2d1c`; daed PID
  remained 6354. No router reboot, Wi-Fi/network restart, or proxy-node/config
  change was made. dnsmasq was reloaded when applying the new rules and during
  allow-list verification.
- Router IPv6 link-local DNS queries timed out. This is recorded as unavailable,
  not a block result. Global IPv6 DNS paths were independently tested and
  returned NXDOMAIN for the blocked domains.
- DoH/DoT, already cached application content, hard-coded IPs, and clients that
  bypass router DNS remain outside this DNS filter's coverage.

## Source synchronization and rollback

After live validation, 15 adblock package/test/documentation files were
selectively copied from the isolated `261115-03` candidate to this source tree.
No feed reset, whole-tree sync, build, firmware publication, or unrelated
source cleanup was performed. SHA-256 for every copied path matches the
manifest in `/home/godsun/build/gwrt-mainap-adblock-20261115/nas-sync-manifest.json`.
The pre-sync copy of changed NAS files is
`/home/godsun/build/gwrt-mainap-adblock-20261115/nas-adblock-before-sync.tar.gz`.

To roll back the device, run the host-side
`/home/godsun/build/gwrt-mainap-adblock-20261115/complete-rollback.sh` from the
repository tree. It restores the original selected daed DNS policy through the
API, then runs the board-guarded device rollback script, which restores the
adblock/firewall files, reloads fw4, and restarts dnsmasq. It does not reboot.

The SS-01 Honk/EasyTier/IPTV/theme/Mesh candidate remains separate and is not
claimed as live-validated or built by this main-AP change.
