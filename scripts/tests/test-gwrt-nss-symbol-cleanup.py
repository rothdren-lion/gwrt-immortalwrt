#!/usr/bin/env python3
"""Exercise actual prepared NSS init/exit functions with kernel calls mocked.

Usage: test-gwrt-nss-symbol-cleanup.py path/to/prepared/nss_init.c
This verifies the source functions, not a copy of the patched control flow.
The full module must still be cross-compiled and verified on hardware.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
init = re.search(r'^static int __init nss_init\(void\)\n\{.*?^\}', source, re.M | re.S)[0]
cleanup = re.search(r'^static void __exit nss_cleanup\(void\)\n\{.*?^\}', source, re.M | re.S)[0]
declaration = re.search(r'^static bool nss_driver_initialized;\s*$', source, re.M)
declaration = declaration[0] if declaration else ''
harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define __init
#define __exit
#define KERNEL_VERSION(a,b,c) (((a)<<16)|((b)<<8)|(c))
#define LINUX_VERSION_CODE KERNEL_VERSION(6,18,62)
#define NSS_DT_SUPPORT 1
#define NSS_HAL_IPQ60XX_SUPPORT
#define NSS_DATA_PLANE_GENERIC_SUPPORT
#define EFAULT 14
#define ETH_DATA_LEN 1500
#define nss_info(...) ((void)0)
#define nss_info_always(...) ((void)0)
#define nss_warning(...) ((void)0)
#define spin_lock_init(...) ((void)0)
#define mutex_init(...) ((void)0)
struct device_node { int unused; } node;
static bool has_common, has_pof=true, pof_enabled=true, compatible=true;
static int workqueue_live, workqueue_creates, workqueue_destroys;
static int driver_registers, driver_unregisters, registration_result;
static int workqueue_failure;
static struct device_node *of_find_node_by_name(void *unused, const char *name) {
    return (!strcmp(name,"nss-common") ? has_common : has_pof) ? &node : NULL;
}
static int of_property_read_bool(struct device_node *n, const char *key) {return pof_enabled;}
static int of_machine_is_compatible(const char *s) {return compatible;}
static void of_node_put(struct device_node *n) {}
static int nss_hal_ipq60xx_ops, nss_data_plane_ops, nss_driver;
static struct {void *hal_ops, *data_plane_ops; int num_nss; bool nss_hal_common_init_done; int prev_mtu_sz;} nss_top_main;
static struct {
 int freq_scale_index, freq_scale_ready, freq_scale_rate_limit_down, buffer_index;
 int sum, sample_count, average, message_rate_limit, initialized;
 struct {int frequency;} freq_scale[4];
} nss_runtime_samples;
static struct {int current_freq;} nss_cmd_buf;
static void *nss_clk_hdr, *nss_gen_hdr, *nss_skb_hdr, *nss_wq;
static int nss_freq_table, nss_general_table, nss_skb_reuse_table;
static void *register_sysctl(const char *p, int table) {return &node;}
static void unregister_sysctl_table(void *p) {}
static void *create_workqueue(const char *name) {return &node;}
static int nss_data_plane_init_delay_work(void) {
 if (workqueue_failure) return -1;
 workqueue_creates++; workqueue_live=1; return 0;
}
static void nss_data_plane_destroy_delay_work(void) {
 // This assertion reproduces the real destroy_workqueue(NULL) failure.
 assert(workqueue_live && "destroyed an uninitialized NSS workqueue");
 workqueue_destroys++; workqueue_live=0;
}
static int platform_driver_register(int *driver) {driver_registers++; return registration_result;}
static void platform_driver_unregister(int *driver) {driver_unregisters++;}
#define NOOP(name) static void name(void) {}
NOOP(nss_stats_init) NOOP(nss_strings_init)
NOOP(nss_n2h_single_core_register_sysctl) NOOP(nss_n2h_multi_core_register_sysctl)
NOOP(nss_rps_register_sysctl) NOOP(nss_stats_register_sysctl)
NOOP(nss_project_register_sysctl) NOOP(nss_coredump_notify_register)
NOOP(nss_coredump_init_delay_work) NOOP(nss_n2h_unregister_sysctl)
NOOP(nss_rps_unregister_sysctl) NOOP(nss_project_unregister_sysctl)
'''
main = r'''
int main(int argc, char **argv) {
 assert(argc==2);
 if (!strcmp(argv[1],"symbol-only")) {
  has_common=false; assert(nss_init()==0); nss_cleanup();
  assert(workqueue_creates==0 && workqueue_destroys==0);
  assert(driver_registers==0 && driver_unregisters==0);
 } else if (!strcmp(argv[1],"point-offload-disabled")) {
  has_common=true; pof_enabled=false; assert(nss_init()==0); nss_cleanup();
  assert(workqueue_creates==0 && driver_unregisters==0);
 } else if (!strcmp(argv[1],"normal")) {
  has_common=true; assert(nss_init()==0); nss_cleanup();
  assert(workqueue_creates==1 && workqueue_destroys==1);
  assert(driver_registers==1 && driver_unregisters==1);
 } else if (!strcmp(argv[1],"no-hal")) {
  has_common=true; compatible=false; assert(nss_init()==-EFAULT);
  assert(driver_registers==0 && workqueue_creates==0);
 } else if (!strcmp(argv[1],"workqueue-failure")) {
  has_common=true; workqueue_failure=1; assert(nss_init()==-EFAULT);
  assert(driver_registers==0 && workqueue_destroys==0);
 } else return 2;
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='gwrt-nss-cleanup-test-') as tmp:
    c = Path(tmp) / 'harness.c'
    c.write_text(harness + '\n' + declaration + '\n' + init + '\n' + cleanup + '\n' + main)
    for point_offload in (False, True):
        binary = Path(tmp) / ('point-offload' if point_offload else 'standard')
        subprocess.run(['cc', '-std=c11', '-Werror=implicit-function-declaration',
                        *(['-DNSS_DRV_POINT_OFFLOAD'] if point_offload else []),
                        str(c), '-o', str(binary)], check=True)
        cases = ['symbol-only', 'normal', 'no-hal', 'workqueue-failure']
        if point_offload:
            cases.append('point-offload-disabled')
        for case in cases:
            subprocess.run([str(binary), case], check=True, cwd=tmp)
            print('PASS NSS init/cleanup:', 'point-offload' if point_offload else 'standard', case)
