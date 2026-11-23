#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-cfg-dupcheck.sh — .config 重复符号检查
#
# 为什么需要它：
#   .config 里同一个 CONFIG_xxx 出现两次时，kconfig 解析时**最后一条生效**。
#   如果前面写了 "=y"、后面（另一个 menu 段里）又写了 "is not set"，
#   包就会被静默关掉 —— 而且 `make defconfig` 不会报错，menuconfig 里也看不出
#   哪里不对。
#
#   真实踩过的坑（2026-10-21 查实）：
#     config.cs02-gwrt2-261018-01
#       2121: CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt=y
#       2346: # CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt is not set
#     → ddwrt 固件被关掉，设备退回上游 ath11k-firmware-ipq6018
#     → 10-18 出的 cs-02-gwrt2 固件 manifest 里就是上游固件
#     → 对应 BUILD-NOTES 里"cs-02-gwrt2 用标准 ath11k 固件 → radio 全死"
#
# 用法：
#   sh gwrt-cfg-dupcheck.sh .config config.ss01-261018-01 ...
#   sh gwrt-cfg-dupcheck.sh config.*.config* .config
#
# 退出码：0 = 全部干净；1 = 发现重复符号
# ---------------------------------------------------------------------------
SYM='CONFIG_[A-Za-z0-9_-]+'
rc=0

for f in "$@"; do
  [ -f "$f" ] || { echo "跳过（不存在）: $f"; continue; }
  syms=$(grep -E "^($SYM)=.*$|^# $SYM is not set$" "$f" \
    | sed -E "s/^# ($SYM) is not set\$/\1/; s/^($SYM)=.*\$/\1/")
  dups=$(printf '%s\n' "$syms" | sort | uniq -d)
  if [ -z "$dups" ]; then
    echo "OK  $(basename "$f")  - 无重复符号"
  else
    echo "!!  $(basename "$f")  - 发现重复符号（最后一条生效）:"
    printf '%s\n' "$dups" | while read sym; do
      echo "      $sym"
      grep -nE "^($sym)=.*$|^# $sym is set$|^# $sym is not set$" "$f" | sed 's/^/        /'
    done
    rc=1
  fi
done

exit $rc
