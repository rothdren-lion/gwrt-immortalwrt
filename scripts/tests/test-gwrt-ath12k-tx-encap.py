#!/usr/bin/env python3
"""Test actual ath12k TX policy/VIF functions with mocked OF/WMI, not firmware."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile


def function(source, name):
    match = re.search(r"\b" + re.escape(name) + r"\([^;]*?\)\n\{", source)
    if not match:
        raise ValueError("missing source function: " + name)
    start = source.rfind("\n\n", 0, match.start()) + 2
    return source[start:source.index("\n}", match.end()) + 2]


source = (Path(sys.argv[1]) / "mac.c").read_text()
policy = function(source, "ath12k_mac_set_tx_encap_offload")
update = function(source, "ath12k_mac_update_vif_offload")
register = function(source, "ath12k_mac_hw_register")
assert "ath12k_mac_set_tx_encap_offload(hw, ar);" in register
assert "ieee80211_hw_set(hw, SUPPORTS_TX_ENCAP_OFFLOAD)" not in register
assert "SUPPORTS_RX_DECAP_OFFLOAD" in register
preamble = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
typedef unsigned int u32;
#define WMI_TLV_SERVICE_ETH_OFFLOAD 0
#define SUPPORTS_TX_ENCAP_OFFLOAD 1
#define ATH12K_FLAG_RAW_MODE 0
#define IEEE80211_OFFLOAD_ENCAP_ENABLED 1
#define IEEE80211_OFFLOAD_DECAP_ENABLED 2
#define IEEE80211_OFFLOAD_ENCAP_MCAST 4
#define IEEE80211_OFFLOAD_ENCAP_4ADDR 8
#define NL80211_IFTYPE_AP 1
#define NL80211_IFTYPE_STATION 2
#define WMI_VDEV_PARAM_TX_ENCAP_TYPE 1
#define WMI_VDEV_PARAM_RX_DECAP_TYPE 2
#define ATH12K_HW_TXRX_ETHERNET 0
#define ATH12K_HW_TXRX_RAW 1
#define ATH12K_HW_TXRX_NATIVE_WIFI 2
#define ath12k_info(...) ((void)0)
#define ath12k_warn(...) ((void)0)
struct device_node { bool disable; };
struct device { struct device_node *of_node; };
struct ath12k_base { struct device *dev; unsigned long dev_flags; };
struct wmi_ab { unsigned long svc_map[1]; };
struct wmi { struct wmi_ab *wmi_ab; };
struct ath12k { struct ath12k_base *ab; struct wmi *wmi; };
struct ieee80211_hw { bool tx; };
struct ieee80211_vif { int offload_flags, type; };
struct ath12k_vif { struct ieee80211_vif *vif; struct { int tx_encap_type; } dp_vif; };
struct ath12k_link_vif { struct ath12k_vif *ahvif; struct ath12k *ar; int vdev_id; };
#define ath12k_ahvif_to_vif(v) ((v)->vif)
#define test_bit(bit, map) ((*(map) & (1UL << (bit))) != 0)
#define ieee80211_hw_set(hw, flag) ((hw)->tx = true)
static bool of_property_read_bool(struct device_node *node, const char *name) {
    assert(!strcmp(name, "qcom,ath12k-disable-tx-encap-offload"));
    return node && node->disable;
}
static int tx = -1, rx = -1;
static int ath12k_wmi_vdev_set_param_cmd(struct ath12k *ar, int id, u32 p, u32 v) {
    if (p == WMI_VDEV_PARAM_TX_ENCAP_TYPE) tx = v; else rx = v;
    return 0;
}
static bool ath12k_mac_supports_mcast_encap(struct ath12k *ar) { return true; }
'''
main = r'''
int main(void) {
    int count = 0;
    for (int node_state = 0; node_state < 3; node_state++) {
        for (int service = 0; service < 2; service++) {
            for (int raw = 0; raw < 2; raw++) {
                struct device_node node = { .disable = node_state == 2 };
                struct device dev = { .of_node = node_state ? &node : NULL };
                struct ath12k_base ab = { .dev = &dev, .dev_flags = raw };
                struct wmi_ab wa = { .svc_map = { service } };
                struct wmi wmi = { .wmi_ab = &wa };
                struct ath12k ar = { .ab = &ab, .wmi = &wmi };
                struct ieee80211_hw hw = { 0 };
                ath12k_mac_set_tx_encap_offload(&hw, &ar);
                bool expected = service && node_state != 2;
                assert(hw.tx == expected);
                struct ieee80211_vif vif = { .type = NL80211_IFTYPE_AP,
                    .offload_flags = IEEE80211_OFFLOAD_DECAP_ENABLED |
                        (hw.tx ? IEEE80211_OFFLOAD_ENCAP_ENABLED : 0) };
                struct ath12k_vif ahvif = { .vif = &vif };
                struct ath12k_link_vif arvif = { .ar = &ar, .ahvif = &ahvif };
                ath12k_mac_update_vif_offload(&arvif);
                assert(tx == (expected ? ATH12K_HW_TXRX_ETHERNET :
                       raw ? ATH12K_HW_TXRX_RAW : ATH12K_HW_TXRX_NATIVE_WIFI));
                assert(rx == ATH12K_HW_TXRX_ETHERNET);
                assert(!!(vif.offload_flags & IEEE80211_OFFLOAD_ENCAP_4ADDR) == expected);
                assert(!!(vif.offload_flags & IEEE80211_OFFLOAD_ENCAP_MCAST) == expected);
                printf("PASS ath12k TX encap: node=%d service=%d raw=%d\n", node_state, service, raw);
                count++;
            }
        }
    }
    assert(count == 12);
}
'''
with tempfile.TemporaryDirectory(prefix="ath12k-tx-encap-") as temp:
    path = Path(temp)
    (path / "test.c").write_text(preamble + policy + update + main)
    subprocess.run([os.environ.get("CC", "cc"), "-std=gnu11", "-Wall", "-Werror",
                    "-Wno-unused-parameter", "-o", str(path / "test"),
                    str(path / "test.c")], check=True)
    subprocess.run([str(path / "test")], check=True)
