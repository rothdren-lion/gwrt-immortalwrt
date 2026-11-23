#!/usr/bin/env python3
"""Exercise prepared ath12k MLO policy and allocation functions on the host.

Usage: test-gwrt-ath12k-mlo-policy.py PREPARED_ATH12K_DIRECTORY
The C functions are extracted verbatim. OF, locks, WMI transport and MAC
allocation are mocked; this does not emulate firmware or verify radio operation.
"""
from pathlib import Path
import os
import re
import shlex
import subprocess
import sys
import tempfile


def function(source, name):
    match = re.search(r"\b" + re.escape(name) + r"\([^;]*?\)\n\{", source)
    if not match:
        raise ValueError(f"missing source function: {name}")
    start = source.rfind("\n\n", 0, match.start()) + 2
    end = source.index("\n}", match.end()) + 2
    return source[start:end]


PREAMBLE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <limits.h>
typedef uint8_t u8;
typedef uint32_t u32;
#define __le32 u32
#define U8_MAX UINT8_MAX
#define ATH12K_MAX_DEVICES 3
#define ATH12K_GROUP_MAX_RADIO 6
#define ATH12K_INVALID_DEVICE_ID 255
#define ATH12K_BUS_AHB 0
#define ATH12K_BUS_PCI 1
#define ATH12K_FW_FEATURE_MLO 0
#define ATH12K_FLAG_RECOVERY 0
#define QMI_WLFW_MAX_NUM_MLO_CHIPS_V01 3
#define QMI_WLFW_MAX_NUM_MLO_CHIPS_V2_V01 4
#define QMI_WLFW_MAX_NUM_MLO_LINKS_PER_CHIP_V01 2
#define QMI_WLFW_MAX_NUM_MLO_ADJ_CHIPS_V01 2
#define lockdep_assert_held(...) ((void)0)
#define mutex_lock(...) ((void)0)
#define mutex_unlock(...) ((void)0)
#define ath12k_info(...) ((void)0)
#define ath12k_dbg(...) ((void)0)
#define ath12k_warn(...) ((void)0)
#define ath12k_err(...) ((void)0)
#define WARN_ON(x) (x)
#define cpu_to_le32(x) (x)
#define TARGET_NUM_VDEVS(ab) 4
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,v) ((x)=(v))
struct device_node { bool disable_mlo; };
struct device { struct device_node *of_node; };
struct ath12k_base;
struct ath12k { struct ath12k_base *ab; int mlo_teardown_done;
    u32 mlo_teardown_status; bool mlo_teardown_pending; int pdev_idx; };
struct ath12k_pdev { struct ath12k *ar; };
struct ath12k_hw { int num_radio; void *dev; bool host_alloc_ml_id; };
struct ath12k_pdev_map { struct ath12k_base *ab; int pdev_idx; };
struct ath12k_hw_group {
    int mutex, id, num_devices, num_hw;
    bool mlo_capable, hw_link_id_init_done;
    struct ath12k_base *ab[3];
    struct ath12k_hw *ah[6];
};
struct ath12k_base {
    struct device *dev; struct ath12k_hw_group *ag;
    struct { bool fw_features_valid; } fw;
    struct { int bus; } hif;
    struct { u8 num_radios; } qmi;
    struct { u32 index, hw_link_id_base; } wsi_info;
    struct hw_params { u32 max_mlo_peer; bool host_alloc_ml_id; } *hw_params;
    bool single_chip_mlo_support, supports_mlo;
    u8 device_id, num_radios;
    unsigned long dev_flags;
    struct ath12k_pdev pdevs[2];
};
struct wlfw_host_mlo_chip_info_s_v01 {
    u8 chip_id, num_local_links, hw_link_id[2], valid_mlo_link_id[2];
};
struct wlfw_host_mlo_chip_info_s_v02 {
    struct wlfw_host_mlo_chip_info_s_v01 mlo_chip_info;
    u8 num_adj_chips;
    struct wlfw_host_mlo_chip_info_s_v01 mlo_adj_chip_info[2];
};
struct qmi_wlanfw_host_cap_req_msg_v01 {
    u8 mlo_capable_valid, mlo_capable, mlo_chip_id_valid, mlo_chip_id;
    u8 mlo_group_id_valid, mlo_group_id, max_mlo_peer_valid;
    u32 max_mlo_peer;
    u8 mlo_num_chips_valid, mlo_num_chips, mlo_chip_info_valid;
    struct wlfw_host_mlo_chip_info_s_v01 mlo_chip_info[3];
    u8 mlo_chip_info_v2_valid;
    struct wlfw_host_mlo_chip_info_s_v02 mlo_chip_info_v2[4];
};
static bool ath12k_ftm_mode;
static int setup_calls, ready_calls, partner_calls, teardown_calls;
static bool of_property_read_bool(struct device_node *n, const char *name) {
    assert(!strcmp(name, "qcom,ath12k-disable-mlo"));
    return n && n->disable_mlo;
}
static bool ath12k_fw_feature_supported(struct ath12k_base *ab, int f) {
    return ab->fw.fw_features_valid && ab->supports_mlo;
}
static bool test_bit(int b, unsigned long *p) { return (*p >> b) & 1; }
static int ath12k_mac_mlo_setup(struct ath12k_hw_group *ag) {setup_calls++; return 0;}
static void ath12k_dp_partner_cc_init(struct ath12k_base *ab) {partner_calls++;}
static int ath12k_mac_mlo_ready(struct ath12k_hw_group *ag) {ready_calls++; return 0;}
static void ath12k_mac_mlo_teardown(struct ath12k_hw_group *ag) {}
static int ath12k_wmi_mlo_ready(struct ath12k *ar) {ready_calls++; return 0;}
static int ath12k_wmi_mlo_teardown(struct ath12k *ar) {teardown_calls++; return 0;}
static void reinit_completion(int *p) {*p=0;}
static void ath12k_mac_set_device_defaults(struct ath12k_base *ab) {}
static struct ath12k_hw *ath12k_mac_hw_allocate(struct ath12k_hw_group *ag,
        struct ath12k_pdev_map *map, u8 radios) {
    struct ath12k_hw *ah=calloc(1,sizeof(*ah));
    assert(ah); ah->num_radio=radios; return ah;
}
static struct ath12k_hw *ath12k_ag_to_ah(struct ath12k_hw_group *ag, int i) {return ag->ah[i];}
static void ath12k_mac_hw_destroy(struct ath12k_hw *ah) {free(ah);}
static void ath12k_ag_set_ah(struct ath12k_hw_group *ag, int i, struct ath12k_hw *ah) {ag->ah[i]=ah;}
'''

MAIN = r'''
int main(int argc, char **argv) {
    struct device_node nodes[3]={}; struct device devs[3]={};
    struct hw_params params[3]={}; struct ath12k_base bases[3]={};
    struct ath12k radios[3]={}; struct ath12k_hw_group ag={.num_devices=2};
    assert(argc==2);
    const char *c=argv[1];
    bool off=!strncmp(c,"disabled-",9), single=strstr(c,"single")!=NULL;
    if (single) ag.num_devices=1;
    if (strstr(c,"three")) ag.num_devices=3;
    for(int i=0;i<ag.num_devices;i++) {
        devs[i].of_node=&nodes[i]; params[i].max_mlo_peer=256;
        bases[i]=(struct ath12k_base){.ag=&ag,.dev=&devs[i],.hw_params=&params[i],
            .device_id=i,.num_radios=1,.supports_mlo=true,.single_chip_mlo_support=true};
        bases[i].fw.fw_features_valid=i!=0; bases[i].hif.bus=i ? ATH12K_BUS_PCI : ATH12K_BUS_AHB;
        bases[i].qmi.num_radios=1; bases[i].wsi_info.index=i;
        radios[i].ab=&bases[i]; bases[i].pdevs[0].ar=&radios[i]; ag.ab[i]=&bases[i];
    }
    if (single) { bases[0].hif.bus=ATH12K_BUS_PCI; bases[0].fw.fw_features_valid=true; }
    if (off) nodes[strstr(c,"last") ? ag.num_devices-1 : 0].disable_mlo=true;
    if (!strcmp(c,"disabled-both")) nodes[1].disable_mlo=true;
    if (!strcmp(c,"disabled-recovery")) ag.mlo_capable=true;
    if (!strcmp(c,"normal-missing-partner")) ag.ab[1]=NULL;
    if (!strcmp(c,"normal-no-of-node")) devs[1].of_node=NULL;
    if (!strcmp(c,"normal-fw-disabled")) bases[1].supports_mlo=false;
    if (!strcmp(c,"normal-single-no-mlo")) bases[0].supports_mlo=false;
    if (!strcmp(c,"normal-single-qmi")) {
        bases[0].fw.fw_features_valid=false; bases[0].single_chip_mlo_support=true;
    }
    if (!strcmp(c,"normal-ftm")) ath12k_ftm_mode=true;
    ath12k_core_hw_group_set_mlo_capable(&ag);
    bool expected=!off && strcmp(c,"normal-fw-disabled") &&
        strcmp(c,"normal-single-no-mlo") && strcmp(c,"normal-ftm");
    if (ag.mlo_capable!=expected) {
        fprintf(stderr,"MLO policy mismatch: %s got %d expected %d\n",c,ag.mlo_capable,expected);
        return 1;
    }
    assert(ag.num_devices==(single ? 1 : (strstr(c,"three") ? 3 : 2)));
    if (!strcmp(c,"normal-missing-partner")) return 0;
    for(int i=0;i<ag.num_devices;i++) {
        struct qmi_wlanfw_host_cap_req_msg_v01 req={};
        assert(ath12k_host_cap_parse_mlo(&bases[i],&req)==0);
        assert(req.mlo_capable_valid==1 && req.mlo_capable==expected);
        if (!expected) {
            assert(!req.mlo_chip_id_valid && !req.mlo_group_id_valid && !req.max_mlo_peer_valid);
            assert(!req.mlo_num_chips_valid && !req.mlo_chip_info_valid && !req.mlo_chip_info_v2_valid);
        } else {
            assert(req.mlo_num_chips==ag.num_devices && req.max_mlo_peer==256);
            assert(req.mlo_chip_info_v2_valid==!single && req.mlo_chip_info_valid==single);
        }
    }
    assert(ath12k_core_mlo_setup(&ag)==0);
    assert(setup_calls==expected && partner_calls==(expected ? ag.num_devices : 0));
    assert(ready_calls==expected); ready_calls=0;
    for(int i=0;i<ag.num_devices;i++) {
        assert(ath12k_get_num_partner_link(&radios[i])==(expected ? ag.num_devices-1 : 0));
        assert(__ath12k_mac_mlo_ready(&radios[i])==0);
        assert(__ath12k_mac_mlo_teardown(&radios[i])==0);
    }
    assert(ready_calls==(expected && !single ? ag.num_devices : 0));
    assert(teardown_calls==ready_calls);
    assert(ath12k_mac_allocate(&ag)==0);
    assert(ag.num_hw==(expected ? 1 : ag.num_devices));
    for(int i=0;i<ag.num_hw;i++) {
        assert(ag.ah[i]->num_radio==(expected ? ag.num_devices : 1));
        free(ag.ah[i]);
    }
    return 0;
}
'''


def main():
    source = Path(sys.argv[1])
    core = (source / "core.c").read_text()
    qmi = (source / "qmi.c").read_text()
    mac = (source / "mac.c").read_text()
    extracted = [function(core, "ath12k_core_hw_group_set_mlo_capable"),
                 function(qmi, "ath12k_host_cap_hw_link_id_init"),
                 function(qmi, "ath12k_qmi_fill_mlo_adjacent_info"),
                 function(qmi, "ath12k_host_cap_parse_mlo"),
                 function(core, "ath12k_core_mlo_setup"),
                 function(core, "ath12k_get_num_partner_link"),
                 function(core, "__ath12k_mac_mlo_ready"),
                 function(mac, "__ath12k_mac_mlo_teardown"),
                 function(mac, "ath12k_mac_allocate")]
    cases = ["disabled-first", "disabled-last", "disabled-both", "disabled-single",
             "disabled-recovery", "disabled-three-last", "normal-mixed-bus",
             "normal-single", "normal-single-qmi", "normal-single-no-mlo",
             "normal-three", "normal-fw-disabled", "normal-no-of-node",
             "normal-missing-partner", "normal-ftm"]
    failures = 0
    with tempfile.TemporaryDirectory(prefix="gwrt-ath12k-mlo-test-") as tmp:
        c = Path(tmp) / "harness.c"
        c.write_text(PREAMBLE + "\n\n".join(extracted) + MAIN)
        exe = Path(tmp) / "harness"
        subprocess.run([*shlex.split(os.environ.get("CC", "clang")), "-std=gnu11", "-O1", "-g",
                        "-Werror=implicit-function-declaration", "-fsanitize=undefined",
                        "-fno-sanitize-recover=all", str(c), "-o", str(exe)], check=True)
        for case in cases:
            result = subprocess.run([str(exe), case], cwd=tmp, capture_output=True, text=True)
            print(("PASS" if result.returncode == 0 else "FAIL") + " ath12k MLO policy: " + case)
            if result.returncode:
                failures += 1
                print(result.stderr.strip())
    if failures:
        raise SystemExit(f"{failures}/{len(cases)} cases failed")


if __name__ == "__main__":
    main()
