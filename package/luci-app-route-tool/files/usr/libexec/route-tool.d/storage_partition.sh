#!/bin/sh
# GPT partition helpers shared by the Route Tool storage flows.
# Sourced by /usr/libexec/route-tool (ext4 "storage" partition + swap partition).
# Keep this POSIX sh compatible: these files run under BusyBox ash on OpenWrt.

# 1MB alignment expressed in 512-byte sectors.
RT_ALIGN_SECTORS=2048
# Tail reserve (4MB) so the GPT backup header always has room at the disk end.
RT_RESERVE_SECTORS=8192

# Round a sector number up to the next 1MB boundary.
rt_align_up(){
    echo $(( ($1 + RT_ALIGN_SECTORS - 1) / RT_ALIGN_SECTORS * RT_ALIGN_SECTORS ))
}

# The kernel exports PARTNAME/PARTUUID; older layouts prefix the name with
# "<partno>:" when the name itself contains a colon. Strip that prefix.
rt_clean_name(){
    printf '%s\n' "$1" | sed 's/^[0-9][0-9]*://'
}

# Label of a partition, read from the sysfs uevent.
rt_sys_part_label(){
    v="$(sed -n 's/^PARTNAME=//p' "$1/uevent" 2>/dev/null | head -n 1)"
    rt_clean_name "$v"
}

# Size of a partition in MB (sysfs reports 512-byte sectors).
rt_sys_part_size_mb(){
    s="$(cat "$1/size" 2>/dev/null || echo 0)"
    echo $(( s * 512 / 1024 / 1024 ))
}

# Partition number of a device node (/dev/mmcblk0p12 -> 12).
rt_part_num(){
    b="$(basename "$1")"
    case "$b" in
        *p[0-9]*) echo "${b##*p}" ;;
        *) echo 0 ;;
    esac
}

# Normalise a GPT type code/UUID into the 4 hex digit type code.
# Empty output means "unknown type".
rt_type_code(){
    t="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
    case "$t" in
        0657fd6d-a4ab-43c4-84e5-0933c84b4f4f|8200) echo 8200 ;;   # Linux swap
        0fc63daf-8483-4772-8e79-3d69d8477de4|8300) echo 8300 ;;   # Linux filesystem
        c12a7328-f81f-11d2-ba4b-00a0c93ec93b|ef00) echo ef00 ;;   # EFI system
        e3c9e316-0b5c-4db8-817d-f92df00215ae|0f00) echo 0f00 ;;   # Microsoft reserved
        21686148-6449-6e6f-744e-656564454649) echo 8304 ;;       # BIOS boot
        0x*) t="${t#0x}"; case "$t" in 8200) echo 8200 ;; 8300) echo 8300 ;; 0f00) echo 0f00 ;; esac ;;
    esac
}

# lsblk prints shell friendly pairs; extract one value from a pair line.
# The key must start a field, otherwise NAME would match PARTTYPENAME.
rt_lsblk_val(){
    printf '%s\n' "$1" | awk -v k="$2" '{
        q = sprintf("%c", 34)
        pat = "(^|[[:space:]])" k "=" q "[^" q "]*" q
        if (match($0, pat)) {
            s = substr($0, RSTART, RLENGTH)
            p = index(s, "=")
            v = substr(s, p + 2)
            sub(q, "", v)
            print v
        }
    }'
}

# List the partitions of a GPT disk, one per line:
#   <dev>|<label>|<typecode>|<typename>|<size_mb>
# Sources: lsblk (PARTLABEL/PARTTYPE) -> sgdisk -p -> sysfs PARTNAME.
rt_disk_partitions(){
    disk="$1"; base="$(basename "$disk")"
    [ -n "$disk" ] || return 0
    [ -n "$base" ] || return 0

    if command -v lsblk >/dev/null 2>&1; then
        out="$(lsblk -n -b -P -o NAME,PARTLABEL,PARTTYPE,PARTTYPENAME "$disk" 2>/dev/null |
        while read -r line; do
            nm="$(rt_lsblk_val "$line" NAME)"
            case "$nm" in
                ${base}p*) ;;
                *) continue ;;
            esac
            label="$(rt_lsblk_val "$line" PARTLABEL)"
            [ -n "$label" ] || label="$(rt_sys_part_label "/sys/class/block/$nm")"
            code="$(rt_type_code "$(rt_lsblk_val "$line" PARTTYPE)")"
            tname="$(rt_lsblk_val "$line" PARTTYPENAME)"
            sz="$(cat "/sys/class/block/$nm/size" 2>/dev/null || echo 0)"
            printf '%s|%s|%s|%s|%s\n' "/dev/$nm" "$label" "$code" "$tname" "$(( sz * 512 / 1024 / 1024 ))"
        done)"
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi

    if command -v sgdisk >/dev/null 2>&1; then
        # "sgdisk -p" columns: Number Start End <size...> <code> <name...>
        # The size takes one or two columns ("256.0 MiB"), so the type code is
        # the first 4 hex digit field behind the end sector.
        sgdisk -p "$disk" 2>/dev/null |
        awk -v base="$base" '
            $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
                pnum = $1 + 0
                code = ""
                name = ""
                for (i = 4; i <= NF; i++) {
                    if (code == "") {
                        if (length($i) == 4 && $i ~ /^[0-9a-fA-F]+$/) code = tolower($i)
                        continue
                    }
                    name = name (name == "" ? "" : " ") $i
                }
                printf "/dev/%sp%d|%s|%s|%s|%d\n", base, pnum, name, code, "", ($3 - $2 + 1) / 2048
            }'
        return 0
    fi

    for p in /sys/class/block/${base}p*; do
        [ -d "$p" ] || continue
        printf '%s|%s|||%s\n' "/dev/$(basename "$p")" "$(rt_sys_part_label "$p")" "$(rt_sys_part_size_mb "$p")"
    done
}

# Find a partition of a disk by label (exact match).
# Echoes "<dev>|<label>|<typecode>|<typename>|<size_mb>" or nothing.
rt_disk_find_label(){
    disk="$1"; want="$2"
    [ -n "$want" ] || return 1
    rt_disk_partitions "$disk" | while IFS='|' read -r dev label code tname size; do
        [ "$label" = "$want" ] || continue
        printf '%s|%s|%s|%s|%s\n' "$dev" "$label" "$code" "$tname" "$size"
        break
    done
}

# Scan the free tail area of a GPT disk.
# Sets: RT_GPT_NEXT_START RT_GPT_DISK_END RT_GPT_FREE_SECTORS RT_GPT_FREE_MB
rt_gpt_scan(){
    disk="$1"; base="$(basename "$disk")"

    RT_GPT_NEXT_START=0
    RT_GPT_DISK_END=0
    RT_GPT_FREE_SECTORS=0
    RT_GPT_FREE_MB=0

    sectors="$(cat "/sys/class/block/$base/size" 2>/dev/null || echo 0)"
    case "$sectors" in ''|*[!0-9]*) return 1 ;; esac
    [ "$sectors" -gt 0 ] || return 1
    disk_end=$(( sectors - 1 ))

    last_end=0
    if command -v sgdisk >/dev/null 2>&1; then
        out="$(sgdisk -p "$disk" 2>/dev/null)" || out=""
        if ! printf '%s\n' "$out" | grep -qE '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+'; then
            out2="$(sgdisk -p --no-backup-headers "$disk" 2>/dev/null)" || out2=""
            if printf '%s\n' "$out2" | grep -qE '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+'; then
                out="$out2"
            fi
        fi
        last_end="$(printf '%s\n' "$out" | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { if ($3+0 > m) m = $3+0 } END { print m+0 }')"
    fi

    if [ "$last_end" -le 0 ] 2>/dev/null; then
        for p in /sys/class/block/${base}p*; do
            [ -f "$p/size" ] && [ -f "$p/start" ] || continue
            pe=$(( $(cat "$p/start" 2>/dev/null || echo 0) + $(cat "$p/size" 2>/dev/null || echo 0) - 1 ))
            [ "$pe" -gt "$last_end" ] 2>/dev/null && last_end=$pe
        done
    fi

    [ "$last_end" -gt 0 ] 2>/dev/null || last_end=0
    # No partitions at all -> the whole disk is free (the GPT itself starts at
    # sector 34, so the first usable 1MB boundary is 2048).
    [ "$last_end" -le "$disk_end" ] 2>/dev/null || last_end=$disk_end

    next_start=$(rt_align_up $(( last_end + 1 )))
    free_sectors=$(( disk_end - next_start + 1 ))
    [ "$free_sectors" -lt 0 ] && free_sectors=0

    RT_GPT_NEXT_START=$next_start
    RT_GPT_DISK_END=$disk_end
    RT_GPT_FREE_SECTORS=$free_sectors
    RT_GPT_FREE_MB=$(( free_sectors * 512 / 1024 / 1024 ))
    return 0
}

# Verify the GPT of a disk. A damaged backup header is repaired automatically,
# a damaged main partition table is fatal (the disk must not be touched then).
rt_gpt_verify(){
    disk="$1"
    command -v sgdisk >/dev/null 2>&1 || return 0

    verify_out="$(sgdisk -v "$disk" 2>&1)" || true
    if printf '%s\n' "$verify_out" | grep -qi "Main header.*ERROR\|Main partition table.*ERROR"; then
        echo "GPT 主分区表/头损坏，拒绝操作。详情: $verify_out"
        echo "建议先用编程器备份整片 eMMC，再手动修复 GPT。"
        return 1
    fi

    if printf '%s\n' "$verify_out" | grep -qi "Backup header.*ERROR\|Backup partition table.*ERROR"; then
        echo "⚠️ GPT 备份头/表损坏（主分区表正常），正在自动修复..."
        if sgdisk -e "$disk" >/dev/null 2>&1; then
            echo "✅ GPT 备份头已修复（移至磁盘末尾）"
            verify2="$(sgdisk -v "$disk" 2>&1)" || true
            if printf '%s\n' "$verify2" | grep -qi "Main header.*ERROR\|Main partition table.*ERROR"; then
                echo "修复后主GPT异常，拒绝操作: $verify2"
                return 1
            fi
        else
            echo "GPT 备份头修复失败，但主分区表正常，尝试继续..."
        fi
    fi
    return 0
}

# Next free partition number of a disk.
rt_gpt_next_pnum(){
    disk="$1"; base="$(basename "$disk")"
    max=0
    for p in /sys/class/block/${base}p*; do
        [ -f "$p/size" ] || continue
        pn="$(basename "$p" | sed "s/${base}p//")"
        case "$pn" in ''|*[!0-9]*) continue ;; esac
        [ "$pn" -gt "$max" ] 2>/dev/null && max=$pn
    done
    echo $(( max + 1 ))
}

# Create a GPT partition. start/end are sector numbers, end=0 means "to the
# last usable sector". Prints progress messages, returns non zero on failure.
rt_gpt_create(){
    disk="$1"; pnum="$2"; start="$3"; end="$4"; label="$5"; type="$6"

    command -v sgdisk >/dev/null 2>&1 || { echo "缺少 sgdisk，无法创建分区"; return 1; }

    dry_err="$(sgdisk -P -n "${pnum}:${start}:${end}" -c "${pnum}:${label}" -t "${pnum}:${type}" "$disk" 2>&1)" || {
        echo "sgdisk dry-run 验证失败，拒绝创建分区: $dry_err"
        return 1
    }

    sgdisk --backup="/tmp/route-tool-gpt-before-alloc-$$.bin" "$disk" >/dev/null 2>&1 || true

    create_out="$(sgdisk -n "${pnum}:${start}:${end}" -c "${pnum}:${label}" -t "${pnum}:${type}" "$disk" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        check_out="$(sgdisk -i "${pnum}" "$disk" 2>&1)" || true
        if ! printf '%s\n' "$check_out" | grep -qi "$label"; then
            echo "sgdisk 新建分区失败 (rc=$rc): $create_out"
            return 1
        fi
        echo "⚠️ sgdisk 返回非零但分区已创建，继续执行"
    fi
    return 0
}

# Delete a GPT partition by number.
rt_gpt_delete(){
    disk="$1"; pnum="$2"
    command -v sgdisk >/dev/null 2>&1 || { echo "缺少 sgdisk，无法删除分区"; return 1; }
    out="$(sgdisk -d "${pnum}" "$disk" 2>&1)" || { echo "sgdisk 删除分区失败: $out"; return 1; }
    return 0
}

# Wait until a freshly created partition shows up as a device node.
# Echoes the device path. label may be empty.
rt_gpt_wait_dev(){
    base="$1"; pnum="$2"; label="$3"
    disk="/dev/$base"

    partprobe "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true

    waited=0
    while [ "$waited" -lt 10 ]; do
        [ -b "/dev/${base}p${pnum}" ] && { echo "/dev/${base}p${pnum}"; return 0; }
        if [ -n "$label" ]; then
            for p in /sys/class/block/${base}p*; do
                [ -f "$p/uevent" ] || continue
                [ "$(rt_sys_part_label "$p")" = "$label" ] || continue
                echo "/dev/$(basename "$p")"
                return 0
            done
        fi
        sleep 1
        waited=$(( waited + 1 ))
        partprobe "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
    done
    return 1
}
