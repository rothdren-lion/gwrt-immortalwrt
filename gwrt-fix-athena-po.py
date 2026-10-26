#!/usr/bin/env python3
"""
gwrt-fix-athena-po.py —— 修 athena-led .po 里"查表必然落空"的词条

根因（上游 po2lmo 与运行时 lmo_canon_hash 不一致）：
    运行时查表用 lmo_canon_hash()，它会**去掉首尾空白**再算 hash：
        canon_hash("Channel ") == sfh_hash("Channel", 7, 7)     ← 尾空格被丢
    而 po2lmo 写索引时用的是 msgid 的**原始长度**：
        sfh_hash("Channel ", 8, 8)                              ← 尾空格还在
    两个 hash 对不上 → 这类词条在运行时**永远查不到译文**，
    界面永远显示英文。

    触发条件：msgid 带**首尾空白**。本次只命中 "Channel " 一条。

修法：把 msgid 的首尾空白去掉（同时把 msgstr 的对应空白去掉），
    使 msgid 与 canon_hash 的规范化形式一致。
    改完 "Channel " → "Channel"，运行时 canon_hash("Channel")
    == sfh_hash("Channel",7,7)，与 po2lmo 写入的 key 一致 → 能查到。
"""
import re
import sys

PO = 'package/gwrt-athena-led/luci-app-athena-led/po/zh_Hans/athena_led.po'

# 被 JS 以拼接方式引用、且原文带尾随空白的条目：
#   JS:  o.value(String(c), _('Channel ') + c);
# 改成 '_("Channel") + c' 就不需要尾随空格了。
JS = 'package/gwrt-athena-led/luci-app-athena-led/htdocs/luci-static/resources/view/athena_led/settings.js'

t = open(PO, encoding='utf-8').read()
j = open(JS, encoding='utf-8').read()

# 找出所有 msgid 带首尾空白的条目
pat = re.compile(r'^(msgid ")(.*?)("\nmsgstr ")(.*?)(")$', re.M)
fixed = []

def repl(m):
    mid = m.group(2)
    mstr = m.group(4)
    if mid != mid.strip():
        new_mid = mid.strip()
        # 译文也跟着去首尾空白（保持词条对齐）
        new_mstr = mstr.strip()
        fixed.append((mid, new_mid, mstr, new_mstr))
        return f'{m.group(1)}{new_mid}{m.group(3)}{new_mstr}{m.group(5)}'
    return m.group(0)

t2 = pat.sub(repl, t)

if not fixed:
    print('  没有需要修正的条目')
    sys.exit(0)

for old, new, o_s, n_s in fixed:
    print(f'  msgid {old!r} → {new!r}   (msgstr {o_s!r} → {n_s!r})')

# 同步改 JS：去掉拼接串里的尾随空格
js_old = "_('Channel ') + c"
js_new = "_('Channel') + c"
if js_old in j:
    j = j.replace(js_old, js_new)
    open(JS, 'w', encoding='utf-8').write(j)
    print(f"  JS: {js_old} → {js_new}")

open(PO, 'w', encoding='utf-8').write(t2)
print(f'  ✓ 修正 {len(fixed)} 条')
