#!/bin/sh
# 兼容 wrapper：文件名已改为 gwrt-mk-xingloo-ax3000-config.sh
# （机型正式名 XINGLOO AX3000，原 COMFAST CF-WR630AX）
exec sh "$(cd "$(dirname "$0")" && pwd)/gwrt-mk-xingloo-ax3000-config.sh" "$@"
