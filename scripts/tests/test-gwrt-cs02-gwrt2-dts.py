#!/usr/bin/env python3
"""Guard the GWRT2 port layout: labels move, PHY/PCS bindings do not.

The GWRT2 board has the QCA8081 2.5G PHY behind the jack labelled LAN1, so
the label swap has to live in the DTS. Moving phy-mode/pcs-handle along with
it is not allowed: qca-ppe reparents each port RCG to the PCS clock from that
port's pcs-handle, and the GCC RCG behind switch port 1 only lists the uniphy0
parents, so a 2500base-x port 1 fails PPE probe with
"failed to set port clock parents" (-EINVAL) and the box comes up without any
LAN/WAN netdev.
"""

import re
import sys
from pathlib import Path

DTS = Path('target/linux/qualcommax/dts/ipq6010-re-cs-02-gwrt2.dts')


def block(text, node):
    m = re.search(r'&' + node + r'\s*\{(.*?)\n\};', text, re.S)
    return m.group(1) if m else ''


def main():
    if not DTS.is_file():
        print('FAIL: missing', DTS)
        return 1
    text = DTS.read_text()

    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)

    check('label = "wan";' in block(text, 'swport1'),
          'swport1 must be labelled wan on GWRT2')
    check('label = "lan1";' in block(text, 'swport5'),
          'swport5 must be labelled lan1 on GWRT2')

    for node, mode, pcs in (('swport1', 'psgmii', 'uniphy0'),
                            ('swport5', '2500base-x', 'uniphy1')):
        body = block(text, node)
        check('phy-mode' not in body,
              '{}: must not override phy-mode, port {} keeps the stock PHY'.format(node, node))
        check('phy-handle' not in body,
              '{}: must not override phy-handle, the stock PHY binding stays'.format(node))
        check('pcs-handle' not in body,
              '{}: must not override pcs-handle, PPE cannot reparent that RCG'.format(node))
        _ = (mode, pcs)

    check('failed to set port clock parents' in text,
          'keep the comment explaining why the PHY/PCS bindings must not move')

    if failures:
        for msg in failures:
            print('FAIL:', msg)
        return 1
    print('PASS GWRT2 DTS moves the port labels only')
    return 0


if __name__ == '__main__':
    sys.exit(main())
