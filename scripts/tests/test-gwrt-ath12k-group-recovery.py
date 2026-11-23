#!/usr/bin/env python3
"""Run the prepared ath12k reset worker and crash entries in a host harness.

Usage: test-gwrt-ath12k-group-recovery.py PREPARED_ATH12K_DIRECTORY
The C functions are extracted verbatim; the workqueue, HIF and dump transport
are simulated. This verifies host recovery ordering, not firmware or RF.
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
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#define U8_MAX UINT8_MAX
#define ATH12K_DBG_BOOT 0
#define ATH12K_FLAG_REGISTERED 0
#define ATH12K_FLAG_UNREGISTERING 1
#define ATH12K_FLAG_QMI_FW_READY_COMPLETE 2
#define ATH12K_FLAG_CRASH_FLUSH 3
#define ATH12K_FLAG_RECOVERY 4
#define ATH12K_FLAG_QMI_FAIL 5
#define ATH12K_GROUP_FLAG_REGISTERED 0
#define ATH12K_GROUP_FLAG_UNREGISTER 1
#define ATH12K_GROUP_FLAG_SHUTDOWN 2
#define ATH12K_RESET_MAX_FAIL_COUNT_FIRST 3
#define ATH12K_RESET_MAX_FAIL_COUNT_FINAL 5
#define ATH12K_RESET_TIMEOUT_HZ 10
#define ATH12K_RESET_FAIL_TIMEOUT_HZ 20
#define ATH12K_AHB_RECOVERY_TIMEOUT 10
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, v) ((x) = (v))
#define container_of(p, t, m) ((t *)((char *)(p) - offsetof(t, m)))
#define ath12k_warn(...) ((void)0)
#define ath12k_info(...) ((void)0)
#define ath12k_dbg(...) ((void)0)
#define EXPORT_SYMBOL_GPL(...)
static bool test_bit(int n, const unsigned long *p) { return !!(*p & (1UL << n)); }
static void set_bit(int n, unsigned long *p) { *p |= 1UL << n; }
static void clear_bit(int n, unsigned long *p) { *p &= ~(1UL << n); }
static void mutex_lock(int *m) { assert(!*m); *m = 1; }
static void mutex_unlock(int *m) { assert(*m); *m = 0; }
#define lockdep_assert_held(m) assert(*(m))
typedef int atomic_t;
static int atomic_read(atomic_t *v) { return *v; }
static void atomic_set(atomic_t *v, int n) { *v = n; }
static int atomic_inc_return(atomic_t *v) { return ++*v; }
static void atomic_dec(atomic_t *v) { --*v; }
static unsigned long jiffies = 100;
#define time_before(a, b) ((long)((a) - (b)) < 0)
struct work_struct { bool pending, running; int kind; };
static unsigned work_busy(struct work_struct *w) { return w->pending || w->running; }
static bool queue_work(void *q, struct work_struct *w) {
    assert(q);
    if (w->pending) return false;
    w->pending = true;
    return true;
}
static void cancel_work_sync(struct work_struct *w) { assert(!w->running); w->pending = false; }
static void reinit_completion(int *c) { *c = 0; }
static long wait_for_completion_timeout(int *c, unsigned long t) { (void)t; return *c; }
struct ath12k_base;
struct ath12k_hw_group {
    int id, mutex, num_devices, num_started;
    unsigned long flags;
    bool mlo_capable;
    struct ath12k_base *ab[3];
};
struct device { struct ath12k_base *ab; };
struct ath12k_base {
    struct ath12k_hw_group *ag;
    struct device *dev;
    struct work_struct reset_work, restart_work, dump_work;
    struct { struct work_struct event_work; unsigned char num_radios; } qmi;
    void *workqueue_aux;
    unsigned long dev_flags, reset_fail_timeout;
    atomic_t reset_count, recovery_count, fail_cont_count;
    int reset_complete, driver_recovery, device_id;
    bool is_reset, hw_group_ref;
};
enum mhi_callback { MHI_CB_IDLE, MHI_CB_SYS_ERROR, MHI_CB_EE_RDDM };
struct ath12k_family_ops { void (*arch_deinit)(struct ath12k_base *); };
struct ath12k_pci {
    enum mhi_callback mhi_pre_cb;
    const struct ath12k_family_ops *device_family_ops;
};
struct platform_device { struct ath12k_base *ab; };
struct pci_dev { struct ath12k_base *ab; };
struct mhi_controller { struct device *cntrl_dev; };
static struct ath12k_base bases[3];
static struct device devices[3];
static struct ath12k_pci pcis[3];
static struct ath12k_hw_group group;
static int downs[3], ups[3], dumps[3], pre_calls, post_calls, mem_resets;
static bool unregister_on_powerdown;
static int removing_bus, remove_powerdowns, group_cleanups, core_deinits, core_frees;
static void (*try_group_recovery)(struct ath12k_base *);
static struct ath12k_base *dev_get_drvdata(struct device *d) { return d->ab; }
static struct ath12k_pci *ath12k_pci_priv(struct ath12k_base *ab) { return &pcis[ab->device_id]; }
static void ath12k_coredump_collect(struct ath12k_base *ab) { dumps[ab->device_id]++; }
static void ath12k_core_pre_reconfigure_recovery(struct ath12k_base *ab) { (void)ab; pre_calls++; }
static void ath12k_core_post_reconfigure_recovery(struct ath12k_base *ab) { (void)ab; post_calls++; }
static void ath12k_dp_ds_stop_group(struct ath12k_hw_group *ag) { assert(ag); }
static void ath12k_hif_irq_disable(struct ath12k_base *ab) { assert(ab); }
static void ath12k_hif_ce_irq_disable(struct ath12k_base *ab) { assert(ab); }
static void ath12k_hif_power_down(struct ath12k_base *ab, bool suspend) {
    assert(!suspend);
    downs[ab->device_id]++;
    if (unregister_on_powerdown) set_bit(ATH12K_GROUP_FLAG_UNREGISTER, &ab->ag->flags);
}
static void ath12k_qmi_reset_mlo_mem(struct ath12k_hw_group *ag) {
    assert(ag->mutex && ag->num_started == 0);
    for (int i = 0; i < ag->num_devices; i++)
        if (ag->ab[i]) assert(downs[i] && !ag->ab[i]->hw_group_ref);
    mem_resets++;
}
static int ath12k_hif_power_up(struct ath12k_base *ab) {
    assert(ab->ag->mutex && ab->ag->num_started == 0 && mem_resets);
    ups[ab->device_id]++;
    return 0;
}
static void assert_quiesced(struct ath12k_base *ab) {
    assert(test_bit(ATH12K_FLAG_UNREGISTERING, &ab->dev_flags));
    assert(!work_busy(&ab->reset_work));
    if (removing_bus == 1) {
        assert(!work_busy(&ab->restart_work));
        assert(!work_busy(&ab->qmi.event_work));
    } else {
        assert(!work_busy(&ab->dump_work));
    }
    /* A partner submitting recovery during removal must not requeue us. */
    try_group_recovery(&bases[1 - ab->device_id]);
    assert(!work_busy(&ab->reset_work));
}
static struct ath12k_base *platform_get_drvdata(struct platform_device *p) { return p->ab; }
static struct ath12k_base *pci_get_drvdata(struct pci_dev *p) { return p->ab; }
static void ath12k_ahb_power_down(struct ath12k_base *ab, bool suspend) {
    assert(!suspend); assert_quiesced(ab); remove_powerdowns++;
}
static void ath12k_pci_power_down(struct ath12k_base *ab, bool suspend) {
    assert(!suspend); assert_quiesced(ab); remove_powerdowns++;
}
static void ath12k_core_hw_group_cleanup(struct ath12k_hw_group *ag) {
    assert_quiesced(ag->ab[removing_bus == 1 ? 0 : 1]); group_cleanups++;
}
static void ath12k_core_deinit(struct ath12k_base *ab) {
    assert_quiesced(ab); core_deinits++; ab->ag = NULL;
}
static void ath12k_core_free(struct ath12k_base *ab) {
    assert(!ab->ag); core_frees++;
}
static void ath12k_ahb_free_resources(struct ath12k_base *ab) { ath12k_core_free(ab); }
static void ath12k_pci_set_irq_affinity_hint(struct ath12k_pci *p, void *hint) { (void)p; (void)hint; }
static void ath12k_mhi_unregister(struct ath12k_pci *p) { (void)p; }
static void ath12k_pci_free_irq(struct ath12k_base *ab) { (void)ab; }
static void ath12k_pci_msi_free(struct ath12k_pci *p) { (void)p; }
static void ath12k_pci_free_region(struct ath12k_pci *p) { (void)p; }
static void ath12k_hal_srng_deinit(struct ath12k_base *ab) { (void)ab; }
static void ath12k_ce_free_pipes(struct ath12k_base *ab) { (void)ab; }
static void arch_deinit(struct ath12k_base *ab) { (void)ab; }
static const struct ath12k_family_ops family_ops = { .arch_deinit = arch_deinit };
'''

MAIN = r'''
static void init(int n, bool mlo) {
    memset(&group, 0, sizeof(group));
    memset(bases, 0, sizeof(bases));
    memset(pcis, 0, sizeof(pcis));
    group.num_devices = group.num_started = n;
    group.mlo_capable = mlo;
    set_bit(ATH12K_GROUP_FLAG_REGISTERED, &group.flags);
    for (int i = 0; i < n; i++) {
        struct ath12k_base *ab = &bases[i];
        group.ab[i] = ab;
        ab->ag = &group;
        ab->hw_group_ref = true;
        ab->device_id = i;
        ab->workqueue_aux = ab;
        pcis[i].device_family_ops = &family_ops;
        ab->dev = &devices[i]; devices[i].ab = ab;
        set_bit(ATH12K_FLAG_REGISTERED, &ab->dev_flags);
        set_bit(ATH12K_FLAG_QMI_FW_READY_COMPLETE, &ab->dev_flags);
    }
}
static void pci_crash(int i) {
    struct mhi_controller m = { .cntrl_dev = bases[i].dev };
    ath12k_mhi_op_status_cb(&m, MHI_CB_EE_RDDM);
}
static void run_one(int i) {
    struct work_struct *w = &bases[i].reset_work;
    assert(w->pending && !w->running);
    w->pending = false; w->running = true;
    ath12k_core_reset(w);
    w->running = false;
}
static void drain(void) {
    for (int rounds = 0; rounds < 8; rounds++) {
        bool ran = false;
        for (int i = 0; i < group.num_devices; i++)
            if (bases[i].reset_work.pending) { run_one(i); ran = true; }
        if (!ran) return;
    }
    assert(!"reset work was queued repeatedly");
}
static void recovered(int n) {
    assert(group.num_started == 0);
    assert(mem_resets == 1);
    assert(pre_calls == n && post_calls == n);
    for (int i = 0; i < n; i++) {
        assert(downs[i] == 1 && ups[i] == 1);
        assert(bases[i].is_reset && bases[i].reset_count == 1);
        assert(test_bit(ATH12K_FLAG_CRASH_FLUSH, &bases[i].dev_flags));
        assert(test_bit(ATH12K_FLAG_RECOVERY, &bases[i].dev_flags));
    }
}
int main(int argc, char **argv) {
    assert(argc == 2);
    const char *c = argv[1];
    int n = !strcmp(c, "single-pci") ? 1 : !strcmp(c, "three-devices") ? 3 : 2;
    init(n, !strcmp(c, "pci-with-mlo"));
    try_group_recovery = GROUP_RECOVERY;
    if (!strncmp(c, "remove-", 7)) {
        removing_bus = strstr(c, "ahb") ? 1 : 2;
        bool qmi_failed = strstr(c, "qmi-failed") != NULL;
        int i = removing_bus == 1 ? 0 : 1;
        struct ath12k_base *ab = &bases[i];
        ab->reset_work.pending = ab->restart_work.pending = true;
        ab->qmi.event_work.pending = ab->dump_work.pending = true;
        set_bit(ATH12K_FLAG_RECOVERY, &ab->dev_flags);
        ab->driver_recovery = 1;
        if (qmi_failed) set_bit(ATH12K_FLAG_QMI_FAIL, &ab->dev_flags);
        if (removing_bus == 1) {
            struct platform_device p = { .ab = ab };
            ath12k_ahb_remove(&p);
        } else {
            struct pci_dev p = { .ab = ab };
            ath12k_pci_remove(&p);
        }
        assert(core_deinits == 1 && core_frees == 1);
        assert(group_cleanups == !qmi_failed && remove_powerdowns == qmi_failed);
        assert(!mem_resets && !ups[i] && !downs[i]);
    } else if (!strcmp(c, "pci-only") || !strcmp(c, "pci-with-mlo") ||
        !strcmp(c, "single-pci") || !strcmp(c, "three-devices")) {
        pci_crash(n - 1); drain(); recovered(n);
    } else if (!strcmp(c, "ahb-first") || !strcmp(c, "simultaneous")) {
        if (!strcmp(c, "simultaneous")) pci_crash(1);
        GROUP_RECOVERY(&bases[0]); drain(); recovered(2);
    } else if (!strcmp(c, "duplicate-rddm")) {
        pci_crash(1); pci_crash(1); drain(); recovered(2);
        pci_crash(1); drain(); recovered(2);
    } else if (!strcmp(c, "barrier")) {
        pci_crash(1); run_one(1);
        assert(group.num_started == 1 && mem_resets == 0 && ups[0] == 0 && ups[1] == 0);
        assert(bases[0].reset_work.pending);
        drain(); recovered(2);
    } else if (!strcmp(c, "before-qmi-ready")) {
        clear_bit(ATH12K_FLAG_QMI_FW_READY_COMPLETE, &bases[1].dev_flags);
        pci_crash(1); drain();
        assert(dumps[1] == 1 && group.num_started == 2);
        assert(pre_calls == 0 && !bases[0].reset_work.pending && !mem_resets);
    } else if (!strcmp(c, "failure-throttle")) {
        bases[1].fail_cont_count = ATH12K_RESET_MAX_FAIL_COUNT_FINAL;
        pci_crash(1); drain();
        assert(pre_calls == 0 && group.num_started == 2 && !mem_resets);
    } else if (!strcmp(c, "worker-unregistering") || !strcmp(c, "worker-unregister-group") ||
               !strcmp(c, "worker-shutdown") || !strcmp(c, "worker-without-group")) {
        pci_crash(1);
        if (!strcmp(c, "worker-unregistering")) set_bit(ATH12K_FLAG_UNREGISTERING, &bases[1].dev_flags);
        if (!strcmp(c, "worker-unregister-group")) set_bit(ATH12K_GROUP_FLAG_UNREGISTER, &group.flags);
        if (!strcmp(c, "worker-shutdown")) set_bit(ATH12K_GROUP_FLAG_SHUTDOWN, &group.flags);
        if (!strcmp(c, "worker-without-group")) bases[1].ag = NULL;
        drain();
        assert(pre_calls == 0 && !mem_resets && group.num_started == 2);
    } else if (!strcmp(c, "unregister-during-powerdown")) {
        init(1, false); unregister_on_powerdown = true;
        pci_crash(0); drain();
        assert(downs[0] == 1 && ups[0] == 0 && mem_resets == 0);
    } else if (!strcmp(c, "ahb-remove-drains-reset")) {
        queue_work(bases[0].workqueue_aux, &bases[0].reset_work);
        ath12k_ahb_remove_prepare(&bases[0]);
        assert(test_bit(ATH12K_FLAG_UNREGISTERING, &bases[0].dev_flags));
        assert(!bases[0].reset_work.pending);
        drain(); assert(downs[0] == 0 && ups[0] == 0 && pre_calls == 0);
    } else {
        /* Direct crash-entry tests: no transport calls should occur here. */
        if (!strcmp(c, "helper-unregister-group")) set_bit(ATH12K_GROUP_FLAG_UNREGISTER, &group.flags);
        if (!strcmp(c, "helper-shutdown")) set_bit(ATH12K_GROUP_FLAG_SHUTDOWN, &group.flags);
        if (!strcmp(c, "helper-unregistered-group")) clear_bit(ATH12K_GROUP_FLAG_REGISTERED, &group.flags);
        if (!strcmp(c, "helper-origin-unregistering")) set_bit(ATH12K_FLAG_UNREGISTERING, &bases[0].dev_flags);
        if (!strcmp(c, "helper-without-group")) bases[0].ag = NULL;
        if (!strcmp(c, "partner-unregistered")) clear_bit(ATH12K_FLAG_REGISTERED, &bases[1].dev_flags);
        if (!strcmp(c, "partner-not-ready")) clear_bit(ATH12K_FLAG_QMI_FW_READY_COMPLETE, &bases[1].dev_flags);
        if (!strcmp(c, "partner-unregistering")) set_bit(ATH12K_FLAG_UNREGISTERING, &bases[1].dev_flags);
        if (!strcmp(c, "partner-already-resetting")) bases[1].is_reset = true;
        if (!strcmp(c, "partner-work-running")) bases[1].reset_work.running = true;
        if (!strcmp(c, "partner-work-pending")) bases[1].reset_work.pending = true;
        if (!strcmp(c, "missing-partner")) group.ab[1] = NULL;
        GROUP_RECOVERY(&bases[0]);
        if (!strncmp(c, "helper-", 7)) {
            assert(!bases[0].reset_work.pending && !bases[1].reset_work.pending);
            assert(!test_bit(ATH12K_FLAG_RECOVERY, &bases[0].dev_flags));
        } else {
            assert(bases[0].reset_work.pending);
            assert(bases[1].reset_work.pending == !strcmp(c, "partner-work-pending"));
        }
        assert(group.mutex == 0 && !mem_resets && pre_calls == 0);
    }
    return 0;
}
'''


def main():
    source = Path(sys.argv[1])
    core = (source / "core.c").read_text()
    ahb = (source / "ahb.c").read_text()
    helper = "ath12k_core_queue_group_recovery"
    # Allow the old AHB-only implementation as a negative control. Its PCI
    # worker never calls the helper and consequently cannot cross the barrier.
    if not re.search(r"\bvoid " + helper + r"\(", core):
        helper = "ath12k_ahb_queue_group_recovery"
    extracted = [function(core, "ath12k_core_to_group_ref_put"),
                 function(core if helper.startswith("ath12k_core") else ahb, helper),
                 function(core, "ath12k_core_reset"),
                 function((source / "mhi.c").read_text(), "ath12k_mhi_op_status_cb"),
                 function(ahb, "ath12k_ahb_remove_prepare"),
                 function(ahb, "ath12k_ahb_remove"),
                 function((source / "pci.c").read_text(), "ath12k_pci_remove")]
    cases = ["pci-only", "pci-with-mlo", "single-pci", "three-devices", "ahb-first",
             "simultaneous", "duplicate-rddm", "barrier", "before-qmi-ready", "failure-throttle",
             "worker-unregistering", "worker-unregister-group", "worker-shutdown", "worker-without-group",
             "unregister-during-powerdown", "ahb-remove-drains-reset",
             "helper-unregister-group", "helper-shutdown", "helper-unregistered-group",
             "helper-origin-unregistering", "helper-without-group", "partner-unregistered",
             "partner-not-ready", "partner-unregistering", "partner-already-resetting",
             "partner-work-running", "partner-work-pending", "missing-partner",
             "remove-ahb", "remove-pci", "remove-ahb-qmi-failed", "remove-pci-qmi-failed"]
    failures = 0
    with tempfile.TemporaryDirectory(prefix="gwrt-ath12k-recovery-test-") as tmp:
        c = Path(tmp) / "harness.c"
        c.write_text(PREAMBLE + "\n\n".join(extracted) + "\n#define GROUP_RECOVERY " + helper + "\n" + MAIN)
        exe = Path(tmp) / "harness"
        subprocess.run([*shlex.split(os.environ.get("CC", "clang")), "-std=gnu11", "-O1", "-g",
                        "-Werror=implicit-function-declaration", "-fsanitize=undefined",
                        "-fno-sanitize-recover=all", str(c), "-o", str(exe)], check=True)
        for case in cases:
            result = subprocess.run([str(exe), case], cwd=tmp, capture_output=True, text=True)
            print(("PASS" if result.returncode == 0 else "FAIL") + " ath12k group recovery: " + case)
            if result.returncode:
                failures += 1
                print(result.stderr.strip())
    if failures:
        raise SystemExit(f"{failures}/{len(cases)} cases failed")


if __name__ == "__main__":
    main()
