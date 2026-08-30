#!/bin/sh
#
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 Ronald Pagani Jr.
#
# Update the EFI bootloader on the ESP and BIOS bootcode on freebsd-boot
# partitions during FreeBSD upgrades.  See freebsd-update(8).

# Guard against double-sourcing
[ -n "${_EFI_BOOTLOADER_UPDATE_SH:-}" ] && return 0
_EFI_BOOTLOADER_UPDATE_SH=1

# ============================================================
# CONFIGURATION  (overridable via environment)
# ============================================================

: "${EFI_LOADER_SRC:=/boot/loader.efi}"
: "${EFI_DRY_RUN:=0}"
: "${EFI_VERBOSE:=0}"
: "${EFI_NVRAM_UPDATE:=1}"     # Set to 0 to skip NVRAM boot entry management
: "${EFI_BIOS_PMBR:=/boot/pmbr}"
: "${EFI_BIOS_ZFS_BOOT:=/boot/gptzfsboot}"
: "${EFI_BIOS_UFS_BOOT:=/boot/gptboot}"

# Minimum number of FreeBSD-specific strings that must be present in an EFI
# binary for it to be classified as a FreeBSD loader (reduces false-positives).
_EFI_FINGERPRINT_THRESHOLD=2

# Path to the EFI runtime services character device.  Overridable in tests
# (e.g. _EFI_DEV_EFI=/dev/null to simulate EFIRT present on a non-FreeBSD host).
: "${_EFI_DEV_EFI:=/dev/efi}"

# Directory containing geom_diskid(4) provider device nodes.  Overridable in
# tests to point at a temporary directory populated with stub files.
: "${_EFI_DISKID_DEV:=/dev/diskid}"

# ============================================================
# LOGGING
# ============================================================

_efi_log()  { echo "freebsd-update: [bootloader] $*" >&2; }
_efi_info() { _efi_log "INFO:  $*"; }
_efi_warn() { _efi_log "WARN:  $*" >&2; }
_efi_err()  { _efi_log "ERROR: $*" >&2; }
_efi_verb() { [ "${EFI_VERBOSE}" = "1" ] && _efi_log "DEBUG: $*" || true; }

# ============================================================
# ARCHITECTURE → EFI BINARY MAPPING
# ============================================================

# Returns the UEFI fallback binary name for the given machine architecture.
# Argument: output of `uname -m`
efi_fallback_binary_for_arch() {
    case "$1" in
        amd64|x86_64)   echo "BOOTx64.efi"    ;;
        arm64|aarch64)  echo "BOOTaa64.efi"   ;;
        arm|armv7)      echo "BOOTarm.efi"    ;;
        i386)           echo "BOOTia32.efi"    ;;
        riscv64)        echo "BOOTriscv64.efi" ;;
        *)              return 1               ;;
    esac
}

# Returns the fallback binary name for the currently running machine.
efi_fallback_binary() {
    local arch
    arch=$(uname -m 2>/dev/null) || arch="unknown"
    efi_fallback_binary_for_arch "$arch" || {
        _efi_warn "Unsupported/unknown architecture for EFI: ${arch}"
        return 1
    }
}

# ============================================================
# PREREQUISITE CHECKS
# ============================================================

# Returns:
#   0  all checks passed — proceed
#   1  fatal failure     — abort
#   2  in jail           — skip gracefully (not an error)
efi_check_prerequisites() {
    local ok=0

    if [ "$(id -u)" != "0" ]; then
        _efi_err "Must be run as root"
        ok=1
    fi

    if [ "$(sysctl -n security.jail.jailed 2>/dev/null)" = "1" ]; then
        _efi_warn "Running inside a jail — bootloader update skipped"
        return 2
    fi

    if [ ! -f "${EFI_LOADER_SRC}" ]; then
        _efi_err "Source loader not found: ${EFI_LOADER_SRC}"
        ok=1
    elif [ ! -s "${EFI_LOADER_SRC}" ]; then
        _efi_err "Source loader is empty: ${EFI_LOADER_SRC}"
        ok=1
    fi

    return $ok
}

# ============================================================
# SYSTEM DETECTION
# ============================================================

# Returns "UEFI", "BIOS", or "unknown"
efi_boot_method() {
    local m
    m=$(sysctl -n machdep.bootmethod 2>/dev/null) || {
        # machdep.bootmethod is absent on some platforms (e.g. aarch64 with
        # certain firmware).  Any modern FreeBSD platform lacking this OID
        # uses UEFI — there is no BIOS boot on arm64, armv7, or riscv64.
        _efi_verb "machdep.bootmethod unavailable; assuming UEFI"
        echo "UEFI"
        return
    }
    [ -n "$m" ] && { echo "$m"; return; }
    _efi_verb "machdep.bootmethod returned empty; assuming UEFI"
    echo "UEFI"
}

# Returns the root filesystem type: "zfs", "ufs", or the raw type string.
# Uses mount --libxo json (available FreeBSD 10.1+) for reliable parsing.
efi_root_fs_type() {
    mount --libxo json 2>/dev/null | tr '}' '\n' | awk -F'"' '
        /"node":"\/"/ {
            for (i = 1; i <= NF; i++)
                if ($i == "fstype") { print $(i+2); exit }
        }
    '
}

# ============================================================
# DISK AND PARTITION DISCOVERY
# ============================================================

# Internal helper: emit gpart partition data for a disk in line-per-field format.
#
# Tries "gpart show -p --libxo json" first (FreeBSD 14.x+, where --libxo is
# available).  Falls back to "gpart show -p" text parsing on FreeBSD 13.x and
# earlier, which do not support --libxo.  Either way the output is the same
# set of lines that the callers' awk scripts already parse:
#   "scheme":"GPT"   (or MBR)
#   "index":N
#   "type":"efi"     (or freebsd-boot, freebsd-zfs, …)
#
# The text-mode fallback synthesises those lines from the columnar output of
# "gpart show -p".  With -p, the third field of each partition row is the full
# partition device name (e.g. "nda0p1"); stripping the disk prefix and the
# p/s separator yields the numeric index.
_efi_gpart_show_norm() {
    local disk="$1" out rc
    out=$(gpart show -p --libxo json "$disk" 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
        printf '%s\n' "$out" | tr ',{}[]' '\n'
        return 0
    fi
    # FreeBSD 13.x text-mode fallback (--libxo not supported)
    _efi_verb "gpart --libxo unavailable for ${disk}; using text-mode fallback (FreeBSD 13.x)"
    gpart show -p "$disk" 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++)
                if ($i == "GPT" || $i == "MBR") { scheme = $i }
        }
        scheme != "" && NF >= 4 && $3 ~ /[ps][0-9]+$/ {
            name = $3; type = $4
            sub(/^.*[ps]/, "", name); idx = name + 0
            if (idx > 0) {
                print "\"scheme\":\"" scheme "\""
                print "\"index\":" idx
                print "\"type\":\"" type "\""
            }
        }
    '
}

# Scan all disks visible to the kernel for EFI System Partitions.
# Outputs one "disk part_index scheme" tuple per line.
#
# GPT: partitions of type "efi"
# MBR: partitions of type "fat32lba" (0x0C), "fat32" (0x0B), or "efi" (0xEF)
#       gpart uses symbolic names for known types; "!12"/"!ef" kept as fallback.
#
# The fingerprint check in efi_update_esp is the safety gate for MBR partitions:
# if the mounted FAT32 does not contain a FreeBSD loader the partition is skipped.
efi_discover_all_esps() {
    local disks
    disks=$(sysctl -n kern.disks 2>/dev/null | tr ' ' '\n') || {
        _efi_warn "Cannot enumerate disks via sysctl kern.disks"
        return 1
    }

    local disk found=0
    for disk in $disks; do
        [ -z "$disk" ] && continue
        # _efi_gpart_show_norm emits one key:value per line (JSON on 14.x+,
        # synthesised equivalent on 13.x).  See helper comment for details.
        local parts
        parts=$(_efi_gpart_show_norm "$disk" | \
            awk -v d="$disk" '
                /^"scheme":/ {
                    gsub(/^"scheme":"/, ""); gsub(/"$/, ""); scheme = $0
                }
                /^"index":/ {
                    gsub(/^"index":/, ""); idx = $0 + 0; type = ""
                }
                /^"type":/ {
                    gsub(/^"type":"/, ""); gsub(/"$/, ""); type = $0
                    if (idx > 0 &&
                        ((scheme == "GPT" && type == "efi") ||
                         (scheme == "MBR" && (type == "fat32lba" ||
                                              type == "fat32"    ||
                                              type == "efi"      ||
                                              type == "!12"      ||
                                              type == "!ef")))) {
                        print d, idx, scheme
                    }
                }
            ')

        if [ -n "$parts" ]; then
            printf '%s\n' "$parts"
            found=1
        fi
    done

    [ "$found" -eq 0 ] && return 1
    return 0
}

# Scan all disks for freebsd-boot partitions (GPT only; type is FreeBSD-specific).
# Outputs one "disk part_index" tuple per line.
efi_discover_all_bios_parts() {
    local disks
    disks=$(sysctl -n kern.disks 2>/dev/null | tr ' ' '\n') || {
        _efi_warn "Cannot enumerate disks via sysctl kern.disks"
        return 1
    }

    local disk found=0
    for disk in $disks; do
        [ -z "$disk" ] && continue
        local parts
        parts=$(_efi_gpart_show_norm "$disk" | \
            awk -v d="$disk" '
                /^"index":/ {
                    gsub(/^"index":/, ""); idx = $0 + 0; type = ""
                }
                /^"type":/ {
                    gsub(/^"type":"/, ""); gsub(/"$/, ""); type = $0
                    if (idx > 0 && type == "freebsd-boot") { print d, idx }
                }
            ') || true
        if [ -n "$parts" ]; then
            printf '%s\n' "$parts"
            found=1
        fi
    done

    [ "$found" -eq 0 ] && return 1
    return 0
}

# ============================================================
# ROOT FILESYSTEM DISK IDENTIFICATION
# ============================================================

# Returns disk names (one per line) hosting the current root filesystem.
# Argument: root filesystem type ("zfs" or "ufs")
# ZFS: parses zpool status to find leaf vdev member disks; strips partition suffix.
#      Handles diskid/ and gptid/ aliases via realpath.
# UFS: parses mount --libxo json root "special" device; strips /dev/ prefix and suffix.
# Returns 1 on failure or unknown type.
efi_root_disks() {
    local root_type="$1"

    case "$root_type" in
        zfs)
            # Extract pool name from root "special" field (e.g. "zroot/ROOT/default" -> "zroot")
            local pool_name
            pool_name=$(mount --libxo json 2>/dev/null | tr '}' '\n' | awk -F'"' '
                /"node":"\/"/ {
                    for (i = 1; i <= NF; i++)
                        if ($i == "special") { print $(i+2); exit }
                }
            ' | cut -d/ -f1)

            if [ -z "$pool_name" ]; then
                _efi_warn "efi_root_disks: cannot determine ZFS pool name from mount output"
                return 1
            fi

            local zpool_out
            zpool_out=$(zpool status "$pool_name" 2>/dev/null) || {
                _efi_warn "efi_root_disks: zpool status ${pool_name} failed"
                return 1
            }

            # Parse leaf vdev members from the config: section of zpool status.
            # Skips pool-level metadata (state:, scan:) by starting after "config:".
            # Excludes the pool name itself, the NAME header, and vdev group names
            # (mirror-0, raidz1-0, etc.).  Handles raw device names (nda0p4),
            # GEOM labels (gpt/OptBzfs), and aliases (diskid/DISK-xxx, gptid/GUID).
            printf '%s\n' "$zpool_out" | awk -v pool="$pool_name" '
                /^config:/ { in_config = 1; next }
                in_config &&
                $1 != pool && $1 !~ /^NAME$/ &&
                $2 ~ /^(ONLINE|DEGRADED|FAULTED|OFFLINE|REMOVED|UNAVAIL)$/ &&
                $1 !~ /-[0-9]+$/ {
                    print $1
                }
            ' | while IFS= read -r vdev; do
                case "$vdev" in
                    diskid/*|gptid/*|gpt/*)
                        # Resolve alias to real device.  On some FreeBSD versions
                        # GEOM label paths are device nodes, not symlinks, so
                        # realpath(1) returns the path unchanged.  Fall back to
                        # glabel status to find the backing partition.
                        local real
                        real=$(realpath "/dev/${vdev}" 2>/dev/null) || continue
                        case "$real" in
                            /dev/gpt/*|/dev/gptid/*)
                                # GPT partition and gptid labels are managed by
                                # geom_label(4) and appear in glabel(8) status.
                                local component
                                component=$(glabel status 2>/dev/null | awk \
                                    -v lbl="${vdev}" \
                                    '$1 == lbl { print $NF; exit }')
                                [ -n "$component" ] || continue
                                real="/dev/${component}"
                                ;;
                            /dev/diskid/*)
                                # diskid(4) is managed by geom_diskid(4), a
                                # separate GEOM class not present in glabel(8).
                                # On newer kernels (including FreeBSD-CURRENT)
                                # /dev/diskid/* is a character device node so
                                # realpath returns the path unchanged, and
                                # gpart list <shortname> (nda0, etc.) also
                                # returns empty on those systems.
                                # gpart list/show and partition device paths
                                # accept diskid provider names directly
                                # (e.g. /dev/diskid/DISK-abc123p1), so strip
                                # the partition suffix and use the diskid base
                                # name as the disk reference — no kern.disks
                                # scan needed.
                                local disk_lbl
                                disk_lbl=$(printf '%s' "${vdev#diskid/}" | \
                                    sed 's/[sp][0-9][0-9]*$//')
                                [ -n "$disk_lbl" ] || continue
                                real="/dev/diskid/${disk_lbl}"
                                ;;
                        esac
                        real="${real#/dev/}"
                        real=$(printf '%s' "$real" | sed 's/[sp][0-9]*$//')
                        [ -n "$real" ] && echo "$real"
                        ;;
                    *)
                        # Strip partition suffix
                        local disk
                        disk=$(printf '%s' "$vdev" | sed 's/[sp][0-9]*$//')
                        [ -n "$disk" ] && echo "$disk"
                        ;;
                esac
            done | sort -u
            ;;

        ufs)
            # Get root device from mount --libxo json "special" field
            local root_dev
            root_dev=$(mount --libxo json 2>/dev/null | tr '}' '\n' | awk -F'"' '
                /"node":"\/"/ {
                    for (i = 1; i <= NF; i++)
                        if ($i == "special") { print $(i+2); exit }
                }
            ')

            if [ -z "$root_dev" ]; then
                _efi_warn "efi_root_disks: cannot determine UFS root device from mount output"
                return 1
            fi

            # Strip /dev/ prefix
            root_dev="${root_dev#/dev/}"

            # Resolve GEOM label and alias paths to real device names.
            # mount --libxo json reports the device as the kernel's geom provider
            # name (e.g. "gpt/PBaseUFS", "ufs/rootfs", "diskid/DISK-XXXpN"),
            # which gpart cannot accept as a disk argument.  realpath(1) resolves
            # the label when /dev/X is a symlink; on newer kernels these are device
            # nodes so realpath returns the path unchanged.  glabel status is
            # used as a fallback to find the backing partition in that case.
            case "$root_dev" in
                gpt/*|diskid/*|gptid/*|ufs/*)
                    local real
                    real=$(realpath "/dev/${root_dev}" 2>/dev/null) || {
                        _efi_warn "efi_root_disks: cannot resolve /dev/${root_dev} to real device"
                        return 1
                    }
                    case "$real" in
                        /dev/gpt/*|/dev/gptid/*|/dev/ufs/*)
                            # GPT partition, gptid, and UFS labels are managed
                            # by geom_label(4) and appear in glabel(8) status.
                            local component
                            component=$(glabel status 2>/dev/null | awk \
                                -v lbl="${root_dev}" \
                                '$1 == lbl { print $NF; exit }')
                            if [ -z "$component" ]; then
                                _efi_warn "efi_root_disks: cannot find backing device for /dev/${root_dev}"
                                return 1
                            fi
                            real="/dev/${component}"
                            ;;
                        /dev/diskid/*)
                            # diskid(4) is managed by geom_diskid(4), a
                            # separate GEOM class not present in glabel(8).
                            # On newer kernels (including FreeBSD-CURRENT)
                            # /dev/diskid/* is a character device node so
                            # realpath returns the path unchanged, and
                            # gpart list <shortname> (nda0, etc.) also
                            # returns empty on those systems.
                            # gpart list/show and partition device paths
                            # accept diskid provider names directly
                            # (e.g. /dev/diskid/DISK-abc123p1), so strip
                            # the partition suffix and use the diskid base
                            # name as the disk reference — no kern.disks
                            # scan needed.
                            local disk_lbl
                            disk_lbl=$(printf '%s' "${root_dev#diskid/}" | \
                                sed 's/[sp][0-9][0-9]*$//')
                            if [ -z "$disk_lbl" ]; then
                                _efi_warn "efi_root_disks: cannot determine diskid base from /dev/${root_dev}"
                                return 1
                            fi
                            real="/dev/diskid/${disk_lbl}"
                            ;;
                    esac
                    root_dev="${real#/dev/}"
                    ;;
            esac

            # Strip partition suffix (GPT: pN; MBR slice: sN; MBR BSD: sNa).
            # Require at least one digit after [sp] so bare trailing letters in
            # GEOM label names (e.g. "rootfs") are never accidentally stripped.
            root_dev=$(printf '%s' "$root_dev" | sed 's/[sp][0-9]\{1,\}[a-z]\{0,1\}$//')
            [ -n "$root_dev" ] && echo "$root_dev"
            ;;

        *)
            _efi_warn "efi_root_disks: unknown root type '${root_type}'"
            return 1
            ;;
    esac
}

# ============================================================
# BOOT-SPECIFIC PARTITION DISCOVERY
# ============================================================

# Identify EFI System Partitions belonging to the current system only.
# Uses the union of:
#   1. EFI BootCurrent NVRAM variable -> PARTUUID -> gpart list rawuuid match
#   2. Root filesystem disk(s) via efi_root_disks
# Outputs one "disk part_index scheme" tuple per line.
# Returns 1 if no ESPs found.
efi_boot_esps() {
    local root_type
    root_type=$(efi_root_fs_type)

    # ── Step 1: Try efibootmgr to identify BootCurrent disk ──────────────────
    local boot_partuuid=""
    if command -v efibootmgr >/dev/null 2>&1; then
        local efibm_out
        if ! [ -c "${_EFI_DEV_EFI}" ]; then
            _efi_verb "EFIRT (/dev/efi) unavailable — skipping BootCurrent NVRAM lookup"
            efibm_out=""
        else
            efibm_out=$(efibootmgr -v 2>/dev/null) || efibm_out=""
        fi

        local current_num
        current_num=$(printf '%s\n' "$efibm_out" | sed -n 's/^BootCurrent: *//p')

        if [ -n "$current_num" ]; then
            # Extract PARTUUID from HD(N,GPT,<UUID>,...) for the BootCurrent entry.
            # Two efibootmgr -v formats exist:
            #   Inline:  "+Boot0004* desc<TAB>HD(1,GPT,UUID,...)/File(...)"
            #   dp-line: "+Boot0004* desc\n       dp: HD(1,GPT,UUID,...)/File(...)"
            # Use awk to match the entry line then scan forward for HD(N,GPT,...),
            # stopping if the next boot entry is reached.
            boot_partuuid=$(printf '%s\n' "$efibm_out" | awk \
                -v pat="Boot${current_num}[* ]" '
                $0 ~ pat { found = 1 }
                found && /HD\([0-9]*,GPT,/ {
                    s = $0
                    sub(/.*HD\([0-9]*,GPT,/, "", s)
                    sub(/,.*/, "", s)
                    if (s != "") { print s; exit }
                }
                found && /^[+ ]Boot[0-9]/ && $0 !~ pat { exit }
            ')
        fi
    fi

    # ── Step 2: Get root filesystem disks ────────────────────────────────────
    local root_disk_list=""
    root_disk_list=$(efi_root_disks "$root_type") || root_disk_list=""

    # ── Step 3: Build candidate_disks ────────────────────────────────────────
    local candidate_disks=""
    local _boot_disks=""

    if [ -n "$boot_partuuid" ]; then
        # Enumerate all disks and check gpart list rawuuid fields
        local all_disks
        all_disks=$(sysctl -n kern.disks 2>/dev/null | tr ' ' '\n') || all_disks=""

        local d
        for d in $all_disks; do
            [ -z "$d" ] && continue
            local glist_out
            glist_out=$(gpart list "$d" 2>/dev/null) || continue

            # Case-insensitive UUID comparison using awk tolower()
            local matched
            matched=$(printf '%s\n' "$glist_out" | awk -v uuid="$boot_partuuid" '
                tolower($0) ~ "rawuuid:" {
                    # $NF is the UUID value
                    if (tolower($NF) == tolower(uuid)) { print "yes"; exit }
                }
            ')
            if [ "$matched" = "yes" ]; then
                _boot_disks="${_boot_disks}${d}
"
            fi
        done

        # On some FreeBSD-CURRENT systems gpart list returns empty for short
        # disk names (nda0, ada0) but works with diskid provider names.
        # If the kern.disks scan found nothing, also try diskid entries.
        if [ -z "$_boot_disks" ] && [ -d "${_EFI_DISKID_DEV}" ]; then
            local _diskid_bases
            _diskid_bases=$(for _f in "${_EFI_DISKID_DEV}"/*; do
                [ -e "$_f" ] || continue
                printf '%s\n' "${_f#${_EFI_DISKID_DEV}/}" | sed 's/p[0-9][0-9]*$//'
            done | sort -u)
            local _dbase
            for _dbase in $_diskid_bases; do
                [ -z "$_dbase" ] && continue
                local glist_out matched
                glist_out=$(gpart list "diskid/${_dbase}" 2>/dev/null) || continue
                matched=$(printf '%s\n' "$glist_out" | awk -v uuid="$boot_partuuid" '
                    tolower($0) ~ "rawuuid:" {
                        if (tolower($NF) == tolower(uuid)) { print "yes"; exit }
                    }
                ')
                if [ "$matched" = "yes" ]; then
                    _boot_disks="${_boot_disks}diskid/${_dbase}
"
                fi
            done
        fi
    fi

    if [ -n "$_boot_disks" ]; then
        candidate_disks="$_boot_disks"

        # Check whether the identified boot disk(s) overlap with the root
        # filesystem disk(s).  No overlap means split-media or a dedicated
        # boot disk: the root disk(s) are not part of this system's boot
        # path.  In that case, restrict updates to the boot disk only —
        # adding root disks could update an ESP on shared media that belongs
        # to another system, not the one currently running.
        #
        # Overlap (the common case, including ZFS mirrors where the boot disk
        # is also a pool member): add all root disks so every mirror member's
        # ESP is kept in sync.
        local _overlap=0
        local _bd
        for _bd in $_boot_disks; do
            if printf '%s\n' "$root_disk_list" | grep -qx "$_bd"; then
                _overlap=1
                break
            fi
        done

        if [ "$_overlap" = "1" ]; then
            # Normal or mirror: boot disk is a root disk — include all root disks.
            if [ -n "$root_disk_list" ]; then
                candidate_disks="${candidate_disks}${root_disk_list}
"
            fi
        else
            # Split-media or dedicated boot disk: restrict to boot disk only.
            _efi_verb "Boot disk differs from root filesystem disk(s) — restricting ESP updates to boot disk"
        fi
    else
        # BootCurrent PARTUUID not matched — fall back to root disks only.
        if [ -n "$root_disk_list" ]; then
            candidate_disks="${root_disk_list}
"
        fi
    fi

    # ── Step 4: Deduplicate candidate_disks ──────────────────────────────────
    local deduped_disks
    deduped_disks=$(printf '%s' "$candidate_disks" | sort -u | grep -v '^$') || deduped_disks=""

    if [ -z "$deduped_disks" ]; then
        _efi_warn "efi_boot_esps: cannot determine boot/root disks"
        return 1
    fi

    # ── Step 5: Scan each candidate disk for ESP partitions ──────────────────
    local found=0
    local disk
    for disk in $deduped_disks; do
        [ -z "$disk" ] && continue
        local parts
        parts=$(_efi_gpart_show_norm "$disk" | \
            awk -v d="$disk" '
                /^"scheme":/ {
                    gsub(/^"scheme":"/, ""); gsub(/"$/, ""); scheme = $0
                }
                /^"index":/ {
                    gsub(/^"index":/, ""); idx = $0 + 0; type = ""
                }
                /^"type":/ {
                    gsub(/^"type":"/, ""); gsub(/"$/, ""); type = $0
                    if (idx > 0 &&
                        ((scheme == "GPT" && type == "efi") ||
                         (scheme == "MBR" && (type == "fat32lba" ||
                                              type == "fat32"    ||
                                              type == "efi"      ||
                                              type == "!12"      ||
                                              type == "!ef")))) {
                        print d, idx, scheme
                    }
                }
            ')

        if [ -n "$parts" ]; then
            printf '%s\n' "$parts"
            found=1
        fi
    done

    [ "$found" -eq 0 ] && return 1
    return 0
}

# Identify freebsd-boot partitions belonging to the current system only.
# Uses root filesystem disk(s) via efi_root_disks.
# Outputs one "disk part_index" tuple per line.
# Returns 1 if root disks cannot be determined or no freebsd-boot partitions found.
efi_boot_bios_parts() {
    local root_type
    root_type=$(efi_root_fs_type)

    local root_disks
    root_disks=$(efi_root_disks "$root_type") || {
        _efi_warn "efi_boot_bios_parts: cannot determine root filesystem disks"
        return 1
    }

    if [ -z "$root_disks" ]; then
        _efi_warn "efi_boot_bios_parts: root disk list is empty"
        return 1
    fi

    local found=0
    local disk
    for disk in $root_disks; do
        [ -z "$disk" ] && continue
        local parts
        parts=$(_efi_gpart_show_norm "$disk" | \
            awk -v d="$disk" '
                /^"index":/ {
                    gsub(/^"index":/, ""); idx = $0 + 0; type = ""
                }
                /^"type":/ {
                    gsub(/^"type":"/, ""); gsub(/"$/, ""); type = $0
                    if (idx > 0 && type == "freebsd-boot") { print d, idx }
                }
            ') || true
        if [ -n "$parts" ]; then
            printf '%s\n' "$parts"
            found=1
        fi
    done

    [ "$found" -eq 0 ] && return 1
    return 0
}

# ============================================================
# ESP MOUNTING
# ============================================================

# Module-level state for the current ESP mount operation.
_efi_esp_mp=""          # Current ESP mountpoint
_efi_esp_did_mount=0    # 1 if we mounted it (we must unmount)
_efi_esp_is_real=0      # 1 if esp_mp points to a real accessible ESP
                        # (pre-mounted or actually mounted); 0 in dry-run
                        # with an empty tmpdir
_efi_tmp_mounts=""      # All temp mounts we created (space-separated)

# Remove all temporary mounts created by this script.  Called from EXIT trap.
efi_cleanup_mounts() {
    local mp
    for mp in ${_efi_tmp_mounts}; do
        _efi_verb "Cleanup: unmounting ${mp}"
        umount "$mp" 2>/dev/null || true
        rmdir  "$mp" 2>/dev/null || true
    done
    _efi_tmp_mounts=""
}

# Return the current mountpoint for a device, or empty string if not mounted.
efi_esp_mountpoint() {
    local device="$1"
    case "$device" in /dev/*) ;; *) device="/dev/${device}" ;; esac

    local mount_json
    mount_json=$(mount --libxo json 2>/dev/null)

    # First: direct device path match (common case — GPT disks, any system
    # where mount reports the raw device node as special).
    local result
    result=$(printf '%s\n' "$mount_json" | tr '}' '\n' | awk -F'"' \
        -v dev="$device" '
        {
            special = ""; node = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "special") special = $(i+2)
                if ($i == "node") node = $(i+2)
            }
            if (special == dev && node != "") { print node; exit }
        }
    ')
    [ -n "$result" ] && { echo "$result"; return; }

    # Second: GEOM label resolution.  mount(8) may report the device under
    # a GEOM label path rather than the raw device node — for example,
    # /dev/msdosfs/EFI when a FAT ESP with volume label "EFI" is mounted.
    # Use glabel status to resolve each label to its backing component and
    # compare against the requested device.
    local dev_base="${device#/dev/}"
    local glabel_out
    glabel_out=$(glabel status 2>/dev/null)
    result=$(printf '%s\n' "$mount_json" | tr '}' '\n' | awk -F'"' '
        {
            special = ""; node = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "special") special = $(i+2)
                if ($i == "node") node = $(i+2)
            }
            if (special ~ "^/dev/" && node != "") print special " " node
        }
    ' | while read -r special node; do
        lbl="${special#/dev/}"
        component=$(printf '%s\n' "$glabel_out" | \
            awk -v l="$lbl" '$1 == l { print $NF; exit }')
        [ "$component" = "$dev_base" ] && { echo "$node"; break; }
    done)
    [ -n "$result" ] && echo "$result"
}

# Mount the EFI System Partition at a temporary directory.
# Sets _efi_esp_mp and _efi_esp_did_mount.
# Returns 0 on success, 1 on failure.
# $3: partition scheme — "GPT" (default, uses pN suffix) or "MBR" (uses sN suffix)
efi_mount_esp() {
    local disk="$1"
    local part_index="$2"
    local scheme="${3:-GPT}"
    local device
    case "$scheme" in
        MBR) device="/dev/${disk}s${part_index}" ;;
        *)   device="/dev/${disk}p${part_index}" ;;
    esac

    _efi_esp_mp=""
    _efi_esp_did_mount=0
    _efi_esp_is_real=0

    # Reuse an existing mount if the device is already mounted.
    local existing
    existing=$(efi_esp_mountpoint "$device")
    if [ -n "$existing" ]; then
        _efi_verb "ESP ${device} already mounted at ${existing}"
        _efi_esp_mp="$existing"
        _efi_esp_did_mount=0
        _efi_esp_is_real=1
        return 0
    fi

    local tmp_mp
    tmp_mp=$(mktemp -d 2>/dev/null) || {
        _efi_err "Cannot create temporary mount directory"
        return 1
    }

    if [ "${EFI_DRY_RUN}" = "1" ]; then
        _efi_info "[DRY RUN] Would mount ${device} at ${tmp_mp}"
        _efi_esp_mp="$tmp_mp"
        _efi_esp_did_mount=1
        _efi_esp_is_real=0
        _efi_tmp_mounts="${_efi_tmp_mounts} ${tmp_mp}"
        return 0
    fi

    if ! mount_msdosfs -o noexec -o nosuid "${device}" "${tmp_mp}" 2>/dev/null; then
        _efi_err "Failed to mount ESP ${device} at ${tmp_mp}"
        rmdir "$tmp_mp" 2>/dev/null
        return 1
    fi

    _efi_esp_mp="$tmp_mp"
    _efi_esp_did_mount=1
    _efi_esp_is_real=1
    _efi_tmp_mounts="${_efi_tmp_mounts} ${tmp_mp}"
    _efi_verb "Mounted ${device} at ${tmp_mp}"
    return 0
}

# Unmount the ESP if this script mounted it; clears state variables.
efi_unmount_esp() {
    if [ "${_efi_esp_did_mount}" = "1" ] && [ -n "${_efi_esp_mp}" ]; then
        if [ "${EFI_DRY_RUN}" != "1" ]; then
            _efi_verb "Unmounting ESP at ${_efi_esp_mp}"
            umount "${_efi_esp_mp}" 2>/dev/null || \
                _efi_warn "Failed to unmount ${_efi_esp_mp}"
            rmdir  "${_efi_esp_mp}" 2>/dev/null || true
        fi
        # Remove from cleanup list
        _efi_tmp_mounts=$(printf '%s\n' ${_efi_tmp_mounts} | \
            grep -Fxv "${_efi_esp_mp}" | tr '\n' ' ')
    fi
    _efi_esp_mp=""
    _efi_esp_did_mount=0
    _efi_esp_is_real=0
}

# ============================================================
# LOADER FINGERPRINTING
# ============================================================

# Returns 0 if the given file appears to be a FreeBSD EFI loader binary.
#
# Primary check: bootprog_info string embedded by newvers.sh in all FreeBSD
# loaders since FreeBSD 11 — "FreeBSD/<arch> EFI, Revision N.N".  This
# pattern is specific enough to eliminate false positives from other OSes.
#
# Fallback: multi-string heuristic requiring _EFI_FINGERPRINT_THRESHOLD of
# "FreeBSD", "loader.efi", "boot/lua" — covers older binaries that predate
# the bootprog_info format.
efi_is_freebsd_loader() {
    local file="$1"

    [ -f "$file" ] || return 1
    [ -s "$file" ] || return 1   # must be non-empty

    # Primary: match the bootprog_info pattern.
    if strings "$file" 2>/dev/null | grep -qE 'FreeBSD/[^ ]+ EFI,'; then
        _efi_verb "Fingerprint '${file}': bootprog_info match"
        return 0
    fi

    # Fallback: multi-string heuristic for binaries without bootprog_info.
    local matches=0 sig
    for sig in "FreeBSD" "loader.efi" "boot/lua"; do
        strings "$file" 2>/dev/null | grep -qF "$sig" && \
            matches=$((matches + 1))
    done

    _efi_verb "Fingerprint '${file}': ${matches}/${_EFI_FINGERPRINT_THRESHOLD} heuristic match(es)"
    [ "$matches" -ge "${_EFI_FINGERPRINT_THRESHOLD}" ]
}

# ============================================================
# SPACE CHECK
# ============================================================

# Returns 0 if the ESP has enough free space for at least 2 copies of
# loader.efi (current + new) plus a 64 KiB safety margin.
efi_check_space() {
    local esp_mount="$1"

    local src_size
    src_size=$(stat -f '%z' "${EFI_LOADER_SRC}" 2>/dev/null) || {
        _efi_err "Cannot stat ${EFI_LOADER_SRC}"
        return 1
    }

    if [ "${EFI_DRY_RUN}" = "1" ] && [ "${_efi_esp_is_real:-0}" != "1" ]; then
        _efi_verb "[DRY RUN] Space check skipped (ESP not mounted)"
        return 0
    fi

    local avail_kb
    avail_kb=$(df -k "$esp_mount" 2>/dev/null | awk 'NR==2 { print $4 }') || {
        _efi_err "Cannot determine free space on ${esp_mount}"
        return 1
    }

    local avail_bytes=$((avail_kb * 1024))
    # Allow 2× the loader size (temp file + final) plus 64 KiB overhead
    local required=$((src_size * 2 + 65536))

    if [ "$avail_bytes" -lt "$required" ]; then
        _efi_err "Insufficient space on ESP: ${avail_bytes} B available, ${required} B needed"
        _efi_err "Free space on the EFI System Partition and retry"
        return 1
    fi

    _efi_verb "ESP space OK: ${avail_bytes} B available, ${required} B needed"
    return 0
}

# ============================================================
# FILE OPERATIONS
# ============================================================

# Copy src to dst using a temp file + rename to minimise the corruption window
# on the non-journaled FAT32 filesystem.
efi_safe_copy() {
    local src="$1"
    local dst="$2"
    local tmp="${dst}.new"

    # _efi_copy_wrote: set to 1 if a write occurred, 0 if skipped (already
    # current) or dry-run.  Callers use this to count actual writes.
    _efi_copy_wrote=0

    if [ "${EFI_DRY_RUN}" = "1" ]; then
        _efi_info "[DRY RUN] Would update: ${dst}"
        return 0
    fi

    # Skip the copy if the destination already matches the source.
    # Avoids unnecessary FAT32 writes on repeated freebsd-update install runs.
    if [ -f "$dst" ] && cmp -s "$src" "$dst" 2>/dev/null; then
        _efi_verb "Already up to date: ${dst}"
        return 0
    fi

    cp -f "$src" "$tmp" 2>/dev/null || {
        _efi_err "Copy failed: ${src} → ${tmp}"
        rm -f "$tmp" 2>/dev/null
        return 1
    }
    sync 2>/dev/null || true

    mv -f "$tmp" "$dst" 2>/dev/null || {
        _efi_err "Rename failed: ${tmp} → ${dst}"
        rm -f "$tmp" 2>/dev/null
        return 1
    }
    sync 2>/dev/null || true

    _efi_copy_wrote=1
    _efi_info "Updated: ${dst}"
    return 0
}

# ============================================================
# EFI PATH MANAGEMENT
# ============================================================

# Ensure a FreeBSD NVRAM boot entry pointing to /EFI/FreeBSD/loader.efi exists.
# Non-fatal: many systems boot fine without an explicit NVRAM entry (fallback
# path covers them), efibootmgr may not be installed, or EFIRT (/dev/efi) may
# be unavailable (custom kernel without options EFIRT, or i386/armv7/riscv64).
efi_ensure_nvram_entry() {
    local esp_mount="$1"
    local freebsd_loader_abs="$2"  # absolute path on mounted ESP

    if [ "${EFI_NVRAM_UPDATE}" != "1" ]; then
        _efi_verb "EFI_NVRAM_UPDATE=0 — skipping NVRAM boot entry management"
        return 0
    fi

    command -v efibootmgr >/dev/null 2>&1 || {
        _efi_warn "efibootmgr not found — cannot verify NVRAM boot entry"
        _efi_warn "Ensure UEFI NVRAM has a FreeBSD entry pointing to the loader"
        return 0
    }
    [ -c "${_EFI_DEV_EFI}" ] || {
        _efi_verb "EFIRT (/dev/efi) unavailable — skipping NVRAM boot entry management"
        return 0
    }

    # Derive EFI-style path (relative to ESP root, backslashes)
    local rel_path="${freebsd_loader_abs#${esp_mount}}"
    local efi_path
    efi_path=$(echo "$rel_path" | tr '/' '\\')

    # Look for an existing FreeBSD entry that references /EFI/FreeBSD/loader.efi
    local existing
    existing=$(efibootmgr -v 2>/dev/null | \
        grep -i "FreeBSD" | grep -i "loader\.efi") || true

    if [ -n "$existing" ]; then
        _efi_verb "NVRAM FreeBSD entry already exists"
        return 0
    fi

    _efi_info "Adding NVRAM boot entry: FreeBSD → ${efi_path}"
    if [ "${EFI_DRY_RUN}" = "1" ]; then
        _efi_info "[DRY RUN] efibootmgr -a -c -l '${freebsd_loader_abs}' -L FreeBSD"
        return 0
    fi

    # FreeBSD efibootmgr -l expects a Unix path on the mounted ESP,
    # not an EFI backslash path.  It resolves the partition and EFI
    # device path itself.
    efibootmgr -a -c -l "$freebsd_loader_abs" -L "FreeBSD" >/dev/null 2>&1 || {
        _efi_warn "efibootmgr failed to create NVRAM entry"
        _efi_warn "Run as root: efibootmgr -a -c -l '${freebsd_loader_abs}' -L FreeBSD"
        return 0   # still non-fatal
    }
    _efi_info "NVRAM boot entry created"
}

# Update all FreeBSD EFI loaders on a mounted ESP, and create the
# OS-specific /EFI/FreeBSD/loader.efi path + NVRAM entry if absent.
efi_update_esp() {
    local esp_mount="$1"
    local fallback_binary="$2"   # e.g. "BOOTx64.efi"
    local disk="$3"
    local part_index="$4"
    local scheme="${5:-GPT}"
    local device
    case "$scheme" in
        MBR) device="/dev/${disk}s${part_index}" ;;
        *)   device="/dev/${disk}p${part_index}" ;;
    esac

    local updated=0 errors=0

    if [ "${EFI_DRY_RUN}" = "1" ] && [ "${_efi_esp_is_real:-0}" != "1" ]; then
        _efi_info "[DRY RUN] ESP not mounted — existing file/directory detection skipped; output reflects a blank ESP"
    fi

    # ── 1.  OS-specific path: /EFI/FreeBSD/loader.efi ─────────────────────────
    #
    # FAT32 is case-insensitive.  Use case-insensitive find so we handle ESPs
    # created by installers that chose a different capitalisation.

    local freebsd_dir freebsd_loader

    local found_dir
    found_dir=$(find "${esp_mount}" -maxdepth 3 -type d \
        -iname "FreeBSD" 2>/dev/null | head -1)

    if [ -n "$found_dir" ]; then
        freebsd_dir="$found_dir"
        freebsd_loader="${freebsd_dir}/loader.efi"
        efi_safe_copy "${EFI_LOADER_SRC}" "$freebsd_loader" || errors=$((errors + 1))
        [ "${_efi_copy_wrote:-0}" = "1" ] && updated=$((updated + 1))
    else
        # Directory does not exist — create it (the "promote" step)
        freebsd_dir="${esp_mount}/EFI/FreeBSD"
        freebsd_loader="${freebsd_dir}/loader.efi"
        _efi_info "Creating ${freebsd_dir}/ and installing loader"
        if [ "${EFI_DRY_RUN}" != "1" ]; then
            mkdir -p "$freebsd_dir" 2>/dev/null || {
                _efi_err "Cannot create directory: ${freebsd_dir}"
                errors=$((errors + 1))
            }
        fi
        if [ "$errors" -eq 0 ]; then
            efi_safe_copy "${EFI_LOADER_SRC}" "$freebsd_loader" || errors=$((errors + 1))
            [ "${_efi_copy_wrote:-0}" = "1" ] && updated=$((updated + 1))
        fi
    fi

    # ── 2.  Fallback path: /EFI/BOOT/<arch>.efi ───────────────────────────────
    #
    # Only update if the file already exists AND fingerprints as a FreeBSD loader.
    # This protects other OSes that may own this path on a shared ESP.

    local boot_dir fallback_file=""
    local found_boot
    found_boot=$(find "${esp_mount}/EFI" -maxdepth 1 -type d \
        -iname "BOOT" 2>/dev/null | head -1) || true

    if [ -n "$found_boot" ]; then
        boot_dir="$found_boot"
        fallback_file=$(find "$boot_dir" -maxdepth 1 -type f \
            -iname "$fallback_binary" 2>/dev/null | head -1) || true
    fi

    if [ -n "$fallback_file" ]; then
        if efi_is_freebsd_loader "$fallback_file"; then
            efi_safe_copy "${EFI_LOADER_SRC}" "$fallback_file" || errors=$((errors + 1))
            [ "${_efi_copy_wrote:-0}" = "1" ] && updated=$((updated + 1))
        else
            _efi_warn "$(basename "$fallback_file") at ${fallback_file} does not fingerprint as FreeBSD — skipping"
            _efi_warn "Another OS may own this path; FreeBSD will boot via /EFI/FreeBSD/"
        fi
    else
        # No fallback binary at all — create one (common on fresh or BIOS-migrated installs)
        if [ -z "$found_boot" ]; then
            boot_dir="${esp_mount}/EFI/BOOT"
        fi
        fallback_file="${boot_dir}/${fallback_binary}"
        _efi_info "Installing fallback loader: ${fallback_file}"
        if [ "${EFI_DRY_RUN}" != "1" ]; then
            mkdir -p "$boot_dir" 2>/dev/null || {
                _efi_err "Cannot create directory: ${boot_dir}"
                errors=$((errors + 1))
            }
        fi
        if [ "$errors" -eq 0 ]; then
            efi_safe_copy "${EFI_LOADER_SRC}" "$fallback_file" || errors=$((errors + 1))
            [ "${_efi_copy_wrote:-0}" = "1" ] && updated=$((updated + 1))
        fi
    fi

    # ── 3.  NVRAM entry ────────────────────────────────────────────────────────
    efi_ensure_nvram_entry "$esp_mount" "$freebsd_loader"

    # ── Summary ────────────────────────────────────────────────────────────────
    [ "$updated" -gt 0 ] && \
        _efi_info "Updated ${updated} EFI loader file(s) on ${device}"
    [ "$errors" -gt 0 ] && {
        _efi_warn "${errors} error(s) updating ESP on ${device}"
        return 1
    }
    return 0
}

# ============================================================
# BIOS BOOTCODE
# ============================================================

# Write BIOS-mode GPT bootcode to a freebsd-boot partition.
# Selects gptzfsboot or gptboot based on the root filesystem type.
efi_update_bios_bootcode() {
    local disk="$1"
    local part_index="$2"

    local root_fs bootprog
    root_fs=$(efi_root_fs_type)

    case "$root_fs" in
        zfs) bootprog="${EFI_BIOS_ZFS_BOOT}" ;;
        ufs) bootprog="${EFI_BIOS_UFS_BOOT}" ;;
        *)
            _efi_warn "Unknown root FS '${root_fs}' on ${disk} — skipping BIOS bootcode"
            return 0
            ;;
    esac

    for f in "${EFI_BIOS_PMBR}" "$bootprog"; do
        [ -f "$f" ] || {
            _efi_warn "BIOS boot file not found: ${f}"
            return 1
        }
    done

    _efi_info "Updating BIOS bootcode on ${disk}p${part_index} (${root_fs})"
    if [ "${EFI_DRY_RUN}" = "1" ]; then
        _efi_info "[DRY RUN] gpart bootcode -b ${EFI_BIOS_PMBR} -p ${bootprog} -i ${part_index} ${disk}"
        return 0
    fi

    gpart bootcode -b "${EFI_BIOS_PMBR}" \
                   -p "$bootprog" \
                   -i "$part_index" \
                   "$disk" 2>/dev/null || {
        _efi_err "gpart bootcode failed on ${disk}p${part_index}"
        return 1
    }

    _efi_info "BIOS bootcode updated on ${disk}p${part_index}"
}

# ============================================================
# MAIN ORCHESTRATION
# ============================================================

# Update all bootloaders on all boot disks.
# Returns 0 if all updates succeeded, 1 if any failed.
update_bootloaders() {
    local total_errors=0

    # ── Prerequisites ──────────────────────────────────────────────────────────
    local rc
    efi_check_prerequisites; rc=$?
    case $rc in
        0) ;;          # all good
        2) return 0 ;; # in jail — skip silently
        *) return 1 ;; # fatal
    esac

    # ── Boot method and architecture ───────────────────────────────────────────
    local boot_method fallback_binary=""
    boot_method=$(efi_boot_method)
    _efi_info "Boot method detected: ${boot_method}"

    if [ "$boot_method" = "UEFI" ]; then
        fallback_binary=$(efi_fallback_binary) || {
            _efi_warn "Cannot determine EFI binary name — EFI partition update skipped"
            # Continue: BIOS bootcode on freebsd-boot partitions can still be updated.
        }
    fi

    # Register cleanup so temp mounts are removed even on error or signal.
    trap 'efi_cleanup_mounts' EXIT INT TERM

    # ── EFI System Partitions — scoped to current system's boot/root disks ────
    if [ "$boot_method" = "UEFI" ] && [ -n "$fallback_binary" ]; then
        local esp_list
        esp_list=$(efi_boot_esps) || {
            _efi_warn "No EFI System Partitions found for this system's boot/root disks"
            _efi_warn "If using hardware RAID or an unusual topology, update the bootloader manually"
        }

        if [ -n "$esp_list" ]; then
            local esp_disk esp_pidx esp_scheme
            while IFS=' ' read -r esp_disk esp_pidx esp_scheme; do
                _efi_info "Processing EFI partition: ${esp_disk} partition ${esp_pidx} (${esp_scheme})"

                if ! efi_mount_esp "$esp_disk" "$esp_pidx" "$esp_scheme"; then
                    _efi_err "Skipping ${esp_disk} partition ${esp_pidx} — mount failed"
                    total_errors=$((total_errors + 1))
                    continue
                fi

                local esp_mp="${_efi_esp_mp}"

                if ! efi_check_space "$esp_mp"; then
                    total_errors=$((total_errors + 1))
                    efi_unmount_esp
                    continue
                fi

                efi_update_esp "$esp_mp" "$fallback_binary" "$esp_disk" "$esp_pidx" "$esp_scheme" || \
                    total_errors=$((total_errors + 1))

                efi_unmount_esp
            done <<_ESPS_
$esp_list
_ESPS_
        fi
    fi

    # ── BIOS freebsd-boot partitions — scoped to root filesystem disks ────────
    local bios_list
    bios_list=$(efi_boot_bios_parts) || true

    if [ -n "$bios_list" ]; then
        local bios_disk bios_pidx
        while IFS=' ' read -r bios_disk bios_pidx; do
            efi_update_bios_bootcode "$bios_disk" "$bios_pidx" || \
                total_errors=$((total_errors + 1))
        done <<_BIOS_
$bios_list
_BIOS_
    fi

    # ── Final status ───────────────────────────────────────────────────────────
    if [ "$total_errors" -gt 0 ]; then
        _efi_warn "Bootloader update finished with ${total_errors} error(s)"
        _efi_warn "Review the messages above and update any failed bootloaders manually"
        return 1
    fi

    if [ "${EFI_DRY_RUN}" = "1" ]; then
        _efi_info "[DRY RUN] Bootloader update complete (no changes made)"
    else
        _efi_info "Bootloader update complete"
    fi
    return 0
}

# ============================================================
# STANDALONE ENTRY POINT
# ============================================================

# When executed directly (not sourced), parse arguments and run.
_efi_script_name="${0##*/}"
if [ "${_efi_script_name}" = "efi_bootloader_update.sh" ]; then
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run|-n) EFI_DRY_RUN=1  ;;
            --verbose|-v) EFI_VERBOSE=1  ;;
            --help|-h)
                cat <<EOF
Usage: ${_efi_script_name} [OPTIONS]

Updates the FreeBSD EFI bootloader on the EFI System Partition(s) and the
BIOS bootcode on freebsd-boot partition(s) for all disks participating in
the root filesystem.

Options:
  -n, --dry-run   Show what would be done without making any changes
  -v, --verbose   Enable debug/verbose output
  -h, --help      Show this help message

Environment:
  EFI_LOADER_SRC      Source loader path (default: /boot/loader.efi)
  EFI_DRY_RUN         1 = dry-run mode
  EFI_VERBOSE         1 = verbose/debug mode
EOF
                exit 0
                ;;
            *)
                echo "${_efi_script_name}: unknown option: $1" >&2
                exit 1
                ;;
        esac
        shift
    done

    update_bootloaders
    exit $?
fi
