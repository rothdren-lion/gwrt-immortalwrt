#!/bin/sh
# Storage chip identification keys for Route Tool.
# Thin KEY=VALUE adapter over /usr/libexec/route-tool-storage-info.

INFO=/usr/libexec/route-tool-storage-info
[ -x "$INFO" ] || INFO="${0%/*}/../route-tool-storage-info"
[ -r "$INFO" ] || exit 0

JSON=$("$INFO" 2>/dev/null)
[ -n "$JSON" ] || exit 0

chip_str() {
    printf '%s' "$JSON" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p'
}

chip_num() {
    printf '%s' "$JSON" | sed -n 's/.*"'"$1"'":\([0-9][0-9]*\).*/\1/p'
}

v=$(chip_str type);             [ -n "$v" ] && echo "CHIP_TYPE=$v"
v=$(chip_str type_cn);          [ -n "$v" ] && echo "CHIP_TYPE_CN=$v"
v=$(chip_str brand);            [ -n "$v" ] && echo "CHIP_BRAND=$v"
v=$(chip_str brand_cn);         [ -n "$v" ] && echo "CHIP_BRAND_CN=$v"
v=$(chip_str model);            [ -n "$v" ] && echo "CHIP_MODEL=$v"
v=$(chip_num life_pct);         [ -n "$v" ] && echo "CHIP_LIFE_PCT=$v"
v=$(chip_str life_text);        [ -n "$v" ] && echo "CHIP_LIFE_TEXT=$v"
v=$(chip_num bad_blocks);       [ -n "$v" ] && echo "CHIP_BAD_BLOCKS=$v"
v=$(chip_str bad_text);         [ -n "$v" ] && echo "CHIP_BAD_TEXT=$v"
v=$(chip_str size);             [ -n "$v" ] && echo "CHIP_SIZE=$v"

exit 0
