#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-bdy-g98-config.sh — BDY G98 (RK3588)
# ---------------------------------------------------------------------------
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
BOOT=${BOOT:-direct}
OUT=${OUT:-$TOP/configs/config.bdy-g98-${BOOT}-$VER}

mkdir -p "$TOP/configs"

if [ "$BOOT" = "uefi" ]; then
	cat > "$OUT" <<EOF
CONFIG_TARGET_armsr=y
CONFIG_TARGET_armsr_armv8=y
CONFIG_TARGET_armsr_armv8_DEVICE_generic=y
CONFIG_TARGET_KERNEL_PARTSIZE=256
CONFIG_TARGET_ROOTFS_PARTSIZE=1024
CONFIG_VERSION_NUMBER="$VER"
CONFIG_VERSION_DIST="GWRT"
EOF
else
	cat > "$OUT" <<EOF
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_bdy_g98=y
CONFIG_TARGET_KERNEL_PARTSIZE=256
CONFIG_TARGET_ROOTFS_PARTSIZE=1024
CONFIG_VERSION_NUMBER="$VER"
CONFIG_VERSION_DIST="GWRT"
EOF
fi

cat >> "$OUT" <<'EOF'
# GWRT base
CONFIG_PACKAGE_gwrt-agent=y
CONFIG_PACKAGE_gwrt-device-defaults=y
CONFIG_PACKAGE_gwrt-mesh-apmode=y
CONFIG_PACKAGE_gwrt-mesh-led=y
CONFIG_PACKAGE_luci-theme-gwrt=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_wget-ssl=y
CONFIG_PACKAGE_ca-certificates=y
# network
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_kmod-inet-diag=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-nft-socket=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_iptables-nft=y
CONFIG_PACKAGE_ip6tables-nft=y
CONFIG_PACKAGE_odhcpd-ipv6only=y
CONFIG_PACKAGE_dnsmasq-full=y
# storage
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-fs-btrfs=y
CONFIG_PACKAGE_kmod-fs-exfat=y
CONFIG_PACKAGE_kmod-fs-ntfs3=y
CONFIG_PACKAGE_kmod-fs-vfat=y
CONFIG_PACKAGE_kmod-nls-cp437=y
CONFIG_PACKAGE_kmod-nls-iso8859-1=y
CONFIG_PACKAGE_kmod-nls-utf8=y
CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-usb-storage-uas=y
CONFIG_PACKAGE_kmod-scsi-core=y
CONFIG_PACKAGE_kmod-ata-ahci=y
CONFIG_PACKAGE_kmod-ata-core=y
CONFIG_PACKAGE_kmod-nvme-core=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_fdisk=y
CONFIG_PACKAGE_parted=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_btrfs-progs=y
CONFIG_PACKAGE_ntfs-3g=y
CONFIG_PACKAGE_exfat-fsck=y
CONFIG_PACKAGE_exfat-mkfs=y
CONFIG_PACKAGE_dosfstools=y
# podman
CONFIG_PACKAGE_podman=y
CONFIG_PACKAGE_podman-remote=y
CONFIG_PACKAGE_kmod-veth=y
CONFIG_PACKAGE_kmod-br-netfilter=y
CONFIG_PACKAGE_kmod-xt-nat=y
CONFIG_PACKAGE_kmod-ipt-nat=y
CONFIG_PACKAGE_kmod-ipt-nat6=y
CONFIG_PACKAGE_kmod-ip6tables=y
CONFIG_PACKAGE_kmod-iptables=y
CONFIG_PACKAGE_kmod-macvlan=y
CONFIG_PACKAGE_kmod-dummy=y
CONFIG_PACKAGE_cgroupfs-mount=y
CONFIG_PACKAGE_containerd=y
CONFIG_PACKAGE_runc=y
CONFIG_PACKAGE_iptables-mod-extra=y
CONFIG_PACKAGE_iptables-mod-tproxy=y
CONFIG_PACKAGE_ipset=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y
# ucode
CONFIG_PACKAGE_ucode-mod-socket=y
CONFIG_PACKAGE_ucode-mod-digest=y
# ssr
CONFIG_PACKAGE_gwrt-ssr-plus-luci=y
CONFIG_PACKAGE_luci-app-ssr-plus=y
CONFIG_PACKAGE_luci-i18n-ssr-plus-zh-cn=y
CONFIG_PACKAGE_xray-core=y
CONFIG_PACKAGE_hysteria=y
CONFIG_PACKAGE_tuic-client=y
CONFIG_PACKAGE_naiveproxy=y
CONFIG_PACKAGE_shadowsocks-rust-sslocal=y
CONFIG_PACKAGE_shadowsocks-rust-ssserver=y
CONFIG_PACKAGE_v2ray-plugin=y
CONFIG_PACKAGE_shadowsocksr-libev-ssr-local=y
CONFIG_PACKAGE_shadowsocksr-libev-ssr-redir=y
CONFIG_PACKAGE_shadowsocksr-libev-ssr-server=y
CONFIG_PACKAGE_simple-obfs-client=y
CONFIG_PACKAGE_dns2socks=y
CONFIG_PACKAGE_dns2tcp=y
CONFIG_PACKAGE_microsocks=y
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_v2ray-geoip=y
CONFIG_PACKAGE_v2ray-geosite=y
# homeproxy
CONFIG_PACKAGE_luci-app-homeproxy=y
CONFIG_PACKAGE_luci-i18n-homeproxy-zh-cn=y
CONFIG_PACKAGE_sing-box=y
# adguardhome
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y
# iptv/upnp/ddns
CONFIG_PACKAGE_igmpproxy=y
CONFIG_PACKAGE_udpxy=y
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y
CONFIG_PACKAGE_miniupnpd-nftables=y
CONFIG_PACKAGE_luci-app-ddns=y
CONFIG_PACKAGE_luci-i18n-ddns-zh-cn=y
# stats/tools
CONFIG_PACKAGE_nlbwmon=y
CONFIG_PACKAGE_luci-app-nlbwmon=y
CONFIG_PACKAGE_luci-i18n-nlbwmon-zh-cn=y
CONFIG_PACKAGE_bandix-plus=y
CONFIG_PACKAGE_luci-app-bandix-plus=y
CONFIG_PACKAGE_luci-i18n-bandix-plus-zh-cn=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_btop=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_vim-fuller=y
CONFIG_PACKAGE_tmux=y
CONFIG_PACKAGE_screen=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_pciutils=y
CONFIG_PACKAGE_coreutils=y
CONFIG_PACKAGE_coreutils-base64=y
CONFIG_PACKAGE_coreutils-nohup=y
CONFIG_PACKAGE_coreutils-timeout=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_iperf3=y
CONFIG_PACKAGE_ethtool=y
CONFIG_PACKAGE_irqbalance=y
CONFIG_PACKAGE_smartmontools=y
CONFIG_PACKAGE_hdparm=y
CONFIG_PACKAGE_unzip=y
CONFIG_PACKAGE_zip=y
CONFIG_PACKAGE_tar=y
CONFIG_PACKAGE_gzip=y
# tty/file
CONFIG_PACKAGE_ttyd=y
CONFIG_PACKAGE_luci-app-ttyd=y
CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y
CONFIG_PACKAGE_luci-app-filebrowser=y
CONFIG_PACKAGE_luci-i18n-filebrowser-zh-cn=y
# easytier
CONFIG_PACKAGE_luci-app-easytier=y
CONFIG_PACKAGE_luci-i18n-easytier-zh-cn=y
# argon
CONFIG_PACKAGE_luci-app-argon-config=y
CONFIG_PACKAGE_odhcp6c=y
EOF

echo "==> $OUT (BOOT=$BOOT)"
