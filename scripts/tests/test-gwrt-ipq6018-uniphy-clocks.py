#!/usr/bin/env python3
"""Exercise real CCF lookup/reparent and IPQ6018 RCG functions on the host.

Usage: test-gwrt-ipq6018-uniphy-clocks.py PREPARED_KERNEL [GCC_SOURCE]
Apply the target GCC patch to GCC_SOURCE first. This does not test hardware.
Kernel functions and parent/frequency tables are extracted, not reimplemented.
Only firmware/clkdev/global clock discovery and register access are mocked.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

kernel = Path(sys.argv[1])
gcc = Path(sys.argv[2]) if len(sys.argv) > 2 else kernel / 'drivers/clk/qcom/gcc-ipq6018.c'
driver = gcc.read_text()
ccf = (kernel / 'drivers/clk/clk.c').read_text()
rcg = (kernel / 'drivers/clk/qcom/clk-rcg2.c').read_text()


def function(source, name):
    match = re.search(r'\b' + re.escape(name) + r'\([^;]*?\)\n\{', source)
    assert match, name
    start = source.rfind('\n\n', 0, match.start()) + 2
    end = source.index('\n}', match.end()) + 2
    return source[start:end]


def table(kind, name):
    match = re.search(r'^static const struct ' + kind + r'\s+' + name +
                      r'\[\] = \{.*?^\};', driver, re.M | re.S)
    assert match, name
    return match[0]


groups = ['gcc_xo_uniphy0_rx_tx_uniphy1_rx_tx_ubi32_bias',
          'gcc_xo_uniphy0_tx_rx_uniphy1_tx_rx_ubi32_bias',
          'gcc_xo_uniphy0_rx_tx_ubi32_bias', 'gcc_xo_uniphy0_tx_rx_ubi32_bias']
tables = [table('clk_parent_data', name).replace('static const struct clk_parent_data',
                                              'static struct clk_parent_map')
          for name in groups]
for direction in ('rx', 'tx'):
    tables.append(table('parent_map', groups[0 if direction == 'rx' else 1] + '_map'))
    for speed in ('25', '125'):
        tables.append(table('freq_conf', 'ftbl_nss_port5_' + direction + '_clk_src_' + speed))

harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
typedef uint8_t u8;
typedef uint32_t u32;
#define EPROBE_DEFER 517
#define ERR_PTR(n) ((void *)(intptr_t)(n))
#define PTR_ERR(p) ((intptr_t)(p))
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define ERR_CAST(p) ((void *)(p))
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define unlikely(x) (x)
#define WARN(...) assert(!"RCG parent missing")
#define mult_frac(x,n,d) ((x) * (n) / (d))
#define abs_diff(a,b) ((a) > (b) ? (a) - (b) : (b) - (a))
struct clk_core;
struct clk_hw { struct clk_core *core; };
struct clk_parent_map {
 struct clk_hw *hw; struct clk_core *core;
 const char *fw_name, *name; int index;
};
struct device { int unused; };
struct device_node { int unused; };
struct of_phandle_args { struct device_node *np; const char *name; };
struct clk_core {
 struct clk_parent_map *parents; int num_parents;
 struct device *dev; struct device_node *of_node;
 struct clk_hw *hw; const char *name; unsigned long rate;
};
static struct { struct { struct clk_hw hw; } clkr; } ubi32_pll;
static struct clk_core sdk[4], firmware[4];
static struct clk_hw sdk_hw[4], firmware_hw[4];
static const char *names[] = { "uniphy0_gcc_rx_clk", "uniphy0_gcc_tx_clk",
                             "uniphy1_gcc_rx_clk", "uniphy1_gcc_tx_clk" };
static bool sdk_registered, clkdev_found;
static int of_mode; /* 0: no provider, 1: firmware provider, 2: deferred */
static const char *dev_name(struct device *dev) { return "gcc"; }
static int name_index(const char *name) {
 for (int i=0; i<4; i++) if (name && !strcmp(name,names[i])) return i;
 return -1;
}
static int of_parse_clkspec(struct device_node *np, int index,
 const char *name, struct of_phandle_args *spec) {
 if (!of_mode || name_index(name)<0) return -ENOENT;
 spec->np=np; spec->name=name; return 0;
}
static struct clk_hw *of_clk_get_hw_from_clkspec(struct of_phandle_args *spec) {
 if (of_mode==2) return ERR_PTR(-EPROBE_DEFER);
 return &firmware_hw[name_index(spec->name)];
}
static void of_node_put(struct device_node *np) {}
static struct clk_hw *clk_find_hw(const char *dev_id, const char *name) {
 int i=name_index(name);
 return clkdev_found && i>=0 ? &firmware_hw[i] : ERR_PTR(-ENOENT);
}
static struct clk_core *clk_core_lookup(const char *name) {
 int i=name_index(name);
 return sdk_registered && i>=0 ? &sdk[i] : NULL;
}
struct parent_map { int src, cfg; };
struct freq_conf { int src; u32 pre_div, m, n; };
struct freq_multi_tbl { const struct freq_conf *confs; int num_confs; };
struct clk_rcg2 { struct clk_hw hw; const struct parent_map *parent_map; };
#define to_clk_rcg2(hw) ((struct clk_rcg2 *)(hw))
#define C(s,d,mn,nn) { .src=(s), .pre_div=(u32)(2*(d)-1), .m=(mn), .n=(nn) }
'''

bridge = r'''
static struct clk_hw *clk_hw_get_parent_by_index(struct clk_hw *hw, int index) {
 struct clk_core *p=clk_core_get_parent_by_index(hw->core,index);
 return p ? p->hw : NULL;
}
static unsigned long clk_hw_get_rate(struct clk_hw *hw) { return hw->core->rate; }
static const char *clk_hw_get_name(struct clk_hw *hw) { return hw->core->name; }
static int qcom_find_src_index(struct clk_hw *hw, const struct parent_map *map, int src) {
 for(int i=0;i<hw->core->num_parents;i++) if(map[i].src==src) return i;
 return -EINVAL;
}
'''

main = r'''
static unsigned cases;
static void test_group(struct clk_parent_map *map, int count) {
 struct device_node node={0};
 struct clk_core rcg={.parents=map,.num_parents=count,.of_node=&node};
 for(int i=0;i<count;i++) {
  int n=name_index(map[i].fw_name); if(n<0) continue;
  /* SDK clocks arrive after GCC; failed lookups must remain retryable. */
  of_mode=0; clkdev_found=false; sdk_registered=false; map[i].core=NULL;
  assert(clk_core_get_parent_by_index(&rcg,i)==NULL);
  sdk_registered=true;
  assert(clk_core_get_parent_by_index(&rcg,i)==&sdk[n]);
  assert(clk_fetch_parent_index(&rcg,&sdk[n])==i); cases++;
  /* An explicit SSDK parent switch must also work before the cache fills. */
  map[i].core=NULL;
  assert(clk_fetch_parent_index(&rcg,&sdk[n])==i); cases++;
  /* Upstream PCS firmware clocks retain priority over the global fallback. */
  of_mode=1; map[i].core=NULL;
  assert(clk_core_get_parent_by_index(&rcg,i)==&firmware[n]);
  assert(clk_fetch_parent_index(&rcg,&sdk[n])==-EINVAL); cases++;
  /* Deferred firmware probes must not be replaced by a global clock. */
  of_mode=2; map[i].core=NULL;
  assert(clk_core_get_parent_by_index(&rcg,i)==NULL); cases++;
  /* Existing clkdev lookups still precede globally named clocks. */
  of_mode=0; clkdev_found=true; map[i].core=NULL;
  assert(clk_core_get_parent_by_index(&rcg,i)==&firmware[n]); cases++;
  map[i].core=NULL;
 }
}
static void test_rate(struct clk_parent_map *map, const struct parent_map *mux,
 const struct freq_conf *conf, unsigned long rate, int expected) {
 struct device_node node={0};
 struct clk_core core={.parents=map,.num_parents=7,.of_node=&node,.name="port5"};
 struct clk_rcg2 rcg={.hw={.core=&core},.parent_map=mux};
 struct freq_multi_tbl freq={.confs=conf,.num_confs=2};
 for(int i=0;i<7;i++) map[i].core=NULL;
 of_mode=0; clkdev_found=false; sdk_registered=true;
 const struct freq_conf *selected=__clk_rcg2_select_conf(&rcg.hw,&freq,rate);
 assert(!IS_ERR(selected) && selected->src==expected); cases++;
}
int main(void) {
 for(int i=0;i<4;i++) {
  sdk[i]=(struct clk_core){.hw=&sdk_hw[i],.name=names[i],.rate=125000000};
  sdk_hw[i].core=&sdk[i];
  firmware[i]=(struct clk_core){.hw=&firmware_hw[i],.name=names[i],.rate=125000000};
  firmware_hw[i].core=&firmware[i];
 }
 GROUP_TESTS
 /* PSGMII uses UNIPHY0; unused UNIPHY1 remains at the SDK 125MHz default. */
 RATE_TESTS_PSGMII
 /* A real 2.5G UNIPHY1 parent must remain selectable at 312.5MHz. */
 sdk[2].rate=sdk[3].rate=312500000;
 RATE_TESTS_UNIPHY1
 printf("PASS IPQ6018 CCF lookup/reparent and RCG rate selection: %u cases\n",cases);
 return 0;
}
'''
group_tests = '\n'.join(f'test_group({name},ARRAY_SIZE({name}));' for name in groups)
rate_tests = {}
for mode, uniphy in [('PSGMII', 0), ('UNIPHY1', 1)]:
    calls = []
    for direction in ('rx', 'tx'):
        group = groups[0 if direction == 'rx' else 1]
        for speed, rate in [('25', 25000000), ('125', 125000000)]:
            calls.append(f'test_rate({group},{group}_map,'
                         f'ftbl_nss_port5_{direction}_clk_src_{speed},{rate},'
                         f'P_UNIPHY{uniphy}_{direction.upper()});')
    rate_tests[mode] = '\n'.join(calls)
main = main.replace('GROUP_TESTS', group_tests)
for mode, calls in rate_tests.items():
    main = main.replace('RATE_TESTS_' + mode, calls)

enum = re.search(r'^enum \{.*?^\};', driver, re.M | re.S)[0]
functions = '\n'.join(function(ccf, name) for name in
                      ('clk_core_get', 'clk_core_fill_parent_index',
                       'clk_core_get_parent_by_index', 'clk_fetch_parent_index'))
functions += '\n' + bridge + '\n' + function(rcg, 'calc_rate')
functions += '\n' + function(rcg, '__clk_rcg2_select_conf')
with tempfile.TemporaryDirectory(prefix='gwrt-ipq6018-clocks-') as temp:
    c = Path(temp) / 'harness.c'
    c.write_text(harness + enum + '\n' + '\n'.join(tables) + '\n' + functions + main)
    binary = Path(temp) / 'harness'
    subprocess.run(['cc', '-std=gnu11', '-Werror=implicit-function-declaration',
                    str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, cwd=temp)
