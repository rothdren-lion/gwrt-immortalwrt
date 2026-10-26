#!/bin/sh
# Swap helpers for Route Tool.
#   - detect the RAM size and match a recommended swap capacity
#   - find the swap partition that is already part of the GPT (many router
#     eMMC layouts ship an unformatted "swap" partition)
#   - format / activate it and keep /etc/config/fstab in sync
# Sourced by /usr/libexec/route-tool. POSIX sh compatible (BusyBox ash).

# Smallest swap size we are willing to create (MB).
RT_SWAP_MIN_MB=64
# Priority used for swapon and the fstab entry.
RT_SWAP_PRIO=10
# Label used for swap partitions created by Route Tool.
RT_SWAP_LABEL=rt-swap
# Label / UUID of the ext4 storage partition.
RT_STORAGE_LABEL=storage
RT_STORAGE_UUID=48d0489a-e32f-49be-a46d-91cf1dac4da9

# Physical memory in MB.
rt_mem_total_mb(){
    kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
    case "$kb" in ''|*[!0-9]*) echo 0 ;; *) echo $(( kb / 1024 )) ;; esac
}

# Available memory in MB.
rt_mem_available_mb(){
    kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
    case "$kb" in ''|*[!0-9]*) echo 0 ;; *) echo $(( kb / 1024 )) ;; esac
}

# Recommended swap size (MB) for the given RAM size. 0 means "not needed".
rt_swap_suggest_mb(){
    mem="$1"
    case "$mem" in ''|*[!0-9]*) echo 0; return ;; esac
    [ "$mem" -gt 0 ] || { echo 0; return; }
    if [ "$mem" -le 256 ]; then
        echo 512
    elif [ "$mem" -le 512 ]; then
        echo 512
    elif [ "$mem" -le 768 ]; then
        echo 768
    elif [ "$mem" -le 1024 ]; then
        echo 1024
    else
        echo 0
    fi
}

# Human readable advice for the detected RAM size.
rt_swap_advice(){
    mem="$1"; sug="$2"
    if [ "$sug" -le 0 ] 2>/dev/null; then
        echo "内存 ${mem}MB，内存充足，建议关闭 swap"
    else
        echo "内存 ${mem}MB，建议 swap ${sug}MB"
    fi
}

# Resolve the requested capacity.
#   rt_swap_resolve_size <auto|min|custom> <size_mb> <suggested_mb>
# Echoes the size in MB, 0 when nothing should be created.
rt_swap_resolve_size(){
    mode="$1"; want="$2"; sug="$3"
    case "$mode" in
        min) echo "$RT_SWAP_MIN_MB" ;;
        custom)
            case "$want" in ''|*[!0-9]*) echo "$RT_SWAP_MIN_MB" ;; *) echo "$want" ;; esac ;;
        *) echo "$sug" ;;
    esac
}

# Total / used swap size in MB (from /proc/swaps).
rt_swap_total_mb(){
    awk 'NR>1 && $1 != "" { s += $3 } END { printf "%d\n", s/1024 }' /proc/swaps 2>/dev/null || echo 0
}

rt_swap_used_mb(){
    awk 'NR>1 && $1 != "" { s += $4 } END { printf "%d\n", s/1024 }' /proc/swaps 2>/dev/null || echo 0
}

# Is the device already used as swap?
rt_swap_is_active(){
    dev="$1"
    [ -n "$dev" ] || return 1
    awk -v d="$dev" 'NR>1 && $1 == d { found = 1 } END { exit !found }' /proc/swaps 2>/dev/null
}

# State of a partition: "swap" (formatted), "blank" (no filesystem) or
# "foreign:<type>" when it holds something else.
rt_swap_state(){
    dev="$1"
    [ -b "$dev" ] || [ -f "$dev" ] || { echo "missing"; return; }
    magic="$(dd if="$dev" bs=1 skip=4086 count=10 2>/dev/null | tr -d '\000')"
    if [ "$magic" = "SWAPSPACE2" ]; then
        echo "swap"
        return
    fi
    type="$(blkid -s TYPE -o value "$dev" 2>/dev/null)"
    if [ -z "$type" ]; then
        echo "blank"
    else
        echo "foreign:$type"
    fi
}

# Partitions of the disk that look like a swap partition.
# Prints "<dev>|<label>|<typecode>|<size_mb>" per line.
rt_swap_candidates(){
    disk="$1"
    rt_disk_partitions "$disk" | while IFS='|' read -r dev label code tname size; do
        [ -n "$dev" ] || continue
        case "$code" in
            8200) printf '%s|%s|%s|%s\n' "$dev" "$label" "$code" "$size"; continue ;;
        esac
        case "$tname" in
            *swap*|*Swap*) printf '%s|%s|%s|%s\n' "$dev" "$label" "$code" "$size"; continue ;;
        esac
        case "$label" in
            swap|swapfs|SWAP|rt-swap) printf '%s|%s|%s|%s\n' "$dev" "$label" "$code" "$size"; continue ;;
            *swap*|*SWAP*) printf '%s|%s|%s|%s\n' "$dev" "$label" "$code" "$size"; continue ;;
        esac
    done
}

# The swap partition of the disk (first match), or nothing.
# Echoes "<dev>|<label>|<typecode>|<size_mb>".
rt_swap_find_part(){
    disk="$1"
    rt_swap_candidates "$disk" | head -n 1
}

# ── /etc/config/fstab helpers ────────────────────────────────────────────────

# Names of the fstab swap sections ("@swap[0]" or a named section).
rt_fstab_swap_sections(){
    uci -q show fstab 2>/dev/null | sed -n "s/^fstab\.\(@swap\[[0-9]*\]\|[^.=]*\)=swap$/\1/p"
}

# Names of the fstab mount sections.
rt_fstab_mount_sections(){
    uci -q show fstab 2>/dev/null | sed -n "s/^fstab\.\(@mount\[[0-9]*\]\|[^.=]*\)=mount$/\1/p"
}

# Make sure an enabled fstab swap section exists for the device.
rt_fstab_enable_swap(){
    dev="$1"; label="$2"; prio="${3:-$RT_SWAP_PRIO}"
    [ -n "$dev" ] || return 1
    found=""
    for s in $(rt_fstab_swap_sections); do
        d="$(uci -q get "fstab.$s.device" 2>/dev/null)"
        [ "$d" = "$dev" ] && { found="$s"; break; }
    done
    if [ -z "$found" ]; then
        found="rttool_swap"
        uci -q delete "fstab.$found" >/dev/null 2>&1
        uci set "fstab.$found=swap" >/dev/null 2>&1 || return 1
    fi
    uci set "fstab.$found.device=$dev" >/dev/null 2>&1
    [ -n "$label" ] && uci set "fstab.$found.label=$label" >/dev/null 2>&1
    uci set "fstab.$found.enabled=1" >/dev/null 2>&1
    uci set "fstab.$found.priority=$prio" >/dev/null 2>&1
    uci commit fstab >/dev/null 2>&1
}

# Disable (but keep) the fstab swap section of a device.
rt_fstab_disable_swap(){
    dev="$1"
    for s in $(rt_fstab_swap_sections); do
        d="$(uci -q get "fstab.$s.device" 2>/dev/null)"
        [ "$d" = "$dev" ] || continue
        uci set "fstab.$s.enabled=0" >/dev/null 2>&1
    done
    uci commit fstab >/dev/null 2>&1
}

# Make sure an enabled fstab mount section exists for the ext4 partition.
rt_fstab_enable_mount(){
    dev="$1"; uuid="$2"; label="$3"; target="$4"
    [ -n "$dev" ] || return 1
    found=""
    for s in $(rt_fstab_mount_sections); do
        t="$(uci -q get "fstab.$s.target" 2>/dev/null)"
        d="$(uci -q get "fstab.$s.device" 2>/dev/null)"
        if [ "$t" = "$target" ] || [ "$d" = "$dev" ]; then
            found="$s"
            break
        fi
    done
    if [ -z "$found" ]; then
        found="rttool_storage"
        uci -q delete "fstab.$found" >/dev/null 2>&1
        uci set "fstab.$found=mount" >/dev/null 2>&1 || return 1
    fi
    uci set "fstab.$found.device=$dev" >/dev/null 2>&1
    [ -n "$uuid" ] && uci set "fstab.$found.uuid=$uuid" >/dev/null 2>&1
    [ -n "$label" ] && uci set "fstab.$found.label=$label" >/dev/null 2>&1
    uci set "fstab.$found.target=$target" >/dev/null 2>&1
    uci set "fstab.$found.fstype=ext4" >/dev/null 2>&1
    uci set "fstab.$found.enabled=1" >/dev/null 2>&1
    uci set "fstab.$found.enabled_fsck=0" >/dev/null 2>&1
    uci commit fstab >/dev/null 2>&1
}

# ── swap activation ──────────────────────────────────────────────────────────

# Enable a swap device (with priority, falling back to a plain swapon).
rt_swap_enable(){
    dev="$1"; prio="${2:-$RT_SWAP_PRIO}"
    swapon -p "$prio" "$dev" >/dev/null 2>&1 && return 0
    swapon "$dev" >/dev/null 2>&1 && return 0
    return 1
}

rt_swap_disable(){
    dev="$1"
    swapoff "$dev" >/dev/null 2>&1
}

# Format a partition as swap (busybox mkswap, -L is supported).
rt_swap_format(){
    dev="$1"; label="$2"
    if [ -n "$label" ]; then
        mkswap -L "$label" "$dev" >/dev/null 2>&1 && return 0
    fi
    mkswap "$dev" >/dev/null 2>&1
}

# ── status ───────────────────────────────────────────────────────────────────

# JSON status of the swap setup. Needs the disk device as argument.
rt_swap_info_json(){
    disk="$1"
    mem_total="$(rt_mem_total_mb)"
    mem_avail="$(rt_mem_available_mb)"
    sug="$(rt_swap_suggest_mb "$mem_total")"

    printf '{"ok":true'
    printf ',"mem_total_mb":%s,"mem_available_mb":%s' "$mem_total" "$mem_avail"
    printf ',"swap_total_mb":%s,"swap_used_mb":%s' "$(rt_swap_total_mb)" "$(rt_swap_used_mb)"

    printf ',"swap_devices":['
    first=1
    awk 'NR>1 && $1 != "" { printf "%s{\"dev\":\"%s\",\"size_mb\":%d,\"used_mb\":%d,\"prio\":%d}", sep, $1, $3/1024, $4/1024, $5; sep="," }' /proc/swaps 2>/dev/null
    printf ']'

    printf ',"suggest_mb":%s,"min_mb":%s' "$sug" "$RT_SWAP_MIN_MB"
    printf ',"advice":"%s"' "$(rt_swap_advice "$mem_total" "$sug" | sed 's/"/\\"/g')"

    part="$(rt_swap_find_part "$disk" 2>/dev/null)"
    if [ -n "$part" ]; then
        pdev="$(printf '%s' "$part" | cut -d'|' -f1)"
        plabel="$(printf '%s' "$part" | cut -d'|' -f2)"
        psize="$(printf '%s' "$part" | cut -d'|' -f4)"
        pstate="$(rt_swap_state "$pdev")"
        pact=0
        rt_swap_is_active "$pdev" && pact=1
        printf ',"builtin_swap":{"dev":"%s","label":"%s","size_mb":%s,"state":"%s","active":%s}' \
            "$pdev" "$plabel" "$psize" "$pstate" "$([ "$pact" = 1 ] && echo true || echo false)"
    else
        printf ',"builtin_swap":null'
    fi

    # the ext4 storage partition (if any)
    spart="$(rt_disk_find_label "$disk" "$RT_STORAGE_LABEL" 2>/dev/null)"
    if [ -n "$spart" ]; then
        sdev="$(printf '%s' "$spart" | cut -d'|' -f1)"
        ssize="$(printf '%s' "$spart" | cut -d'|' -f5)"
        smnt="$(awk -v d="$sdev" '$1 == d { print $2; exit }' /proc/mounts 2>/dev/null)"
        printf ',"storage_part":{"dev":"%s","size_mb":%s,"mount":"%s"}' "$sdev" "$ssize" "$smnt"
    else
        printf ',"storage_part":null'
    fi

    if rt_gpt_scan "$disk" >/dev/null 2>&1; then
        printf ',"free_mb":%s,"free_sectors":%s,"next_start":%s,"disk_end":%s' \
            "$RT_GPT_FREE_MB" "$RT_GPT_FREE_SECTORS" "$RT_GPT_NEXT_START" "$RT_GPT_DISK_END"
    else
        printf ',"free_mb":0,"free_sectors":0,"next_start":0,"disk_end":0'
    fi

    printf ',"disk":"%s"' "$disk"
    printf '}'
}
