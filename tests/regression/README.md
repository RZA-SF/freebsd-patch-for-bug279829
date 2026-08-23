# Regression Index

Each entry here records a confirmed bug found on real hardware, the fix, and
the test(s) that prevent it from regressing.  Tests live in their natural
home (`tests/unit/`, `tests/integration/`, `tests/error_conditions/`) — this
file is the human-readable index.

---

## R-01 — `mount_msdosfs` rejects comma-separated `-o` flags

**Found on:** FreeBSD 14.0-RELEASE-p11, amd64, NVMe (live run, 2026-08-17)
**Symptom:** `mount_msdosfs -o noexec,nosuid` → "mount option \<noexec,nosuid\>
is unknown: Invalid argument". ESP mount failed silently; no loader update occurred.
**Root cause:** `mount_msdosfs` does not accept comma-separated options;
`mount -t msdosfs` does. The two binaries are not equivalent in this regard.
**Fix:** Pass `-o noexec -o nosuid` as separate flags in `efi_mount_esp`.
**Tests:** `tests/unit/test_08_esp_mountpoint.sh` — test 5
("mount_msdosfs: -o noexec and -o nosuid as separate flags")

---

## R-02 — `efibootmgr -l` requires a Unix path, not an EFI backslash path

**Found on:** FreeBSD 14.0-RELEASE-p11, amd64, NVMe (live run, 2026-08-17)
**Symptom:** `efibootmgr -a -c -l '\EFI\FreeBSD\loader.efi'` → "Cannot
translate unix loader path: No such file or directory".
**Root cause:** `efibootmgr` resolves the EFI device path itself from a Unix
filesystem path; it does not accept pre-formatted EFI backslash paths.
**Fix:** Pass the full Unix path to the mounted ESP file
(e.g. `/tmp/tmp.XXXX/EFI/FreeBSD/loader.efi`) to `efibootmgr -l`.
**Tests:** `tests/unit/test_13_nvram_entry.sh` — test 6
("efibootmgr -l receives Unix path to mounted ESP file")

---

## R-03 — `machdep.bootmethod` absent on aarch64 causes silent no-op

**Found on:** aarch64 Windows Dev Kit 2023, FreeBSD + UFS (reported by
markmi, D58990 review, 2026-08-20)
**Symptom:** `sysctl -n machdep.bootmethod` exits non-zero (OID absent).
Old code returned `"unknown"` → `update_bootloaders` skipped the entire EFI
update path. Script exited 0 with "Bootloader update complete" but made no
changes.
**Root cause:** `machdep.bootmethod` is an x86-specific OID. It does not
exist on arm64, armv7, or riscv64. Those platforms are exclusively UEFI —
there is no BIOS boot option.
**Fix:** In `efi_boot_method`, fall back to `"UEFI"` (with a verbose message)
when the sysctl exits non-zero or returns an empty string.
**Commit:** `7cb6971`
**Tests:** `tests/unit/test_02_boot_method.sh` — test 3
("sysctl fails (OID absent) → returns UEFI") and test 4
("sysctl returns empty string → returns UEFI")

---

## R-05 — `mount --libxo json` "special" field used as "from" (never existed)

**Found on:** All real FreeBSD hardware in debug traces (reported by markmi and user, 2026-08-20)
**Symptom:** `efi_root_disks` always returned empty, causing "cannot determine boot/root disks"
warning on every system. BIOS bootcode update also failed. Both `efi_boot_esps` and
`efi_boot_bios_parts` fell back to "no ESPs found" and emitted the manual-update warning.
**Root cause:** `mount --libxo json` has used `"special"` as the field name for the source
device since libxo support was added to `mount(8)` in FreeBSD 13.1 (Sept 2021). The code
used `"from"` — a field that has never existed in any FreeBSD version. This was invented
during development without verification against real output. The test fixtures also used
`"from"`, so all unit tests passed while the code was broken on every real system.
**Fix:** Changed all awk parsers in `efi_root_disks` (ZFS and UFS paths) and
`efi_esp_mountpoint` to match `$i == "special"`. Renamed awk variable `from` → `special`
for consistency. Updated all test fixtures and inline mocks to use real `"special"` format.
**Commit:** `5d2173a`
**Tests:** `tests/unit/test_14_root_disks.sh` — tests 15–17 (ZFS "special", UFS "special");
`tests/unit/test_08_esp_mountpoint.sh` — tests 8–9 (ESP mountpoint detection with "special")

---

## R-06 — `efibootmgr -v` device path on `dp:` sub-line not parsed

**Found on:** amd64 system with multi-line efibootmgr output (reported by markmi, 2026-08-20)
**Symptom:** `boot_partuuid` always empty on systems where `efibootmgr -v` emits the EFI
device path on a `dp:` sub-line below the boot entry description, rather than inline.
BootCurrent PARTUUID extraction silently fell through to the root-disk fallback.
**Root cause:** `grep "Boot${current_num}[* ]" | sed 's/.*HD(...)...'` only processed the
matched line itself. When the HD() device path appeared on the immediately following `dp:`
line, the grep returned only the description line (no HD()) and sed extracted nothing.
**Fix:** Replaced `grep | sed` with awk that sets a flag on the `Boot<XXXX>` entry line and
scans forward for `HD([0-9]*,GPT,...)`, stopping at the next boot entry. Works for both
inline and `dp:`-line formats.
**Commit:** `eab6ffd`
**Tests:** `tests/unit/test_15_boot_esps.sh` — test 22
("dp:-line format: PARTUUID extracted from sub-line; nda0 1 GPT found")

---

## R-08 — GEOM label paths are device nodes, not symlinks, on newer kernels

**Found on:** markmi's Windows Dev Kit 2023 (aarch64, FreeBSD UFS, post-5d2173a debug trace, 2026-08-21)
**Symptom:** `efi_root_disks ufs` returned `gpt/PBaseUFS` unchanged; `gpart show
gpt/PBaseUFS` returned empty; ESP discovery failed entirely with "No EFI System
Partitions found for this system's boot/root disks".  The system had no NVRAM
BootCurrent entry with an HD() device path, so the UUID fallback was also
unavailable.  The script exited 0 with "dry run complete" but no update occurred.
**Root cause:** `mount --libxo json` reports the UFS root device as `/dev/gpt/PBaseUFS`
(a GPT GEOM label).  The code used `realpath(1)` to resolve this to the underlying
physical device.  On older FreeBSD, `/dev/gpt/X` was a devfs symlink and `realpath`
followed it (e.g. → `/dev/mmcsd0p2`).  On newer kernels, the GEOM label path is a
character device node directly; `realpath` returns the path unchanged.  The same
bug exists in the ZFS vdev `gpt/` arm added in R-07.
**Fix:** After `realpath` succeeds but returns a path still in `gpt/`, `diskid/`, or
`gptid/` form, fall back to `glabel status` to find the backing partition
(`glabel status | awk '$1 == label { print $NF }'`).  Applied to both the UFS root
device path and the ZFS vdev resolution loop.
**Tests:** `tests/unit/test_14_root_disks.sh` — test 21
("UFS gpt/PBaseUFS: realpath unchanged, glabel resolves to mmcsd0") and test 23
("ZFS gpt/OptBzfs: realpath unchanged, glabel resolves to nda2")

---

## R-07 — ZFS `gpt/LABEL` vdev not recognised by leaf-device awk filter

**Found on:** markmi's amd64 system, pool `zoptb` with sole vdev `gpt/OptBzfs` (debug trace post-5d2173a, 2026-08-20)
**Symptom:** `efi_root_disks zfs` always returned empty on systems where the ZFS
pool's vdev is referenced by a GPT label (e.g. `gpt/OptBzfs`) rather than a raw
partition name (e.g. `nda2p3`). `efi_boot_bios_parts` emitted
`WARN: efi_boot_bios_parts: root disk list is empty` on every run. The EFI update
still succeeded via the BootCurrent UUID path on this particular system, but the
warning was spurious and the BIOS code-update path was broken for any system
relying on root-disk detection.
**Root cause:** The awk vdev filter used `$1 ~ /[0-9]/` to exclude pool-level
metadata lines (e.g. `state: ONLINE`). `gpt/OptBzfs` contains no digit and was
silently skipped. Additionally, the `diskid/*|gptid/*` alias arm in the case
statement did not include `gpt/*`, so even if matched, GPT labels would not have
been resolved via `realpath`.
**Fix:** Replaced `$1 ~ /[0-9]/` with `in_config` flag (only process lines after
`config:` section header) plus `$1 != pool` (skip pool-name line). Added `gpt/*`
to the `realpath` alias resolution arm in the `while` loop.
**Tests:** `tests/unit/test_14_root_disks.sh` — test 21
("ZFS gpt/OptBzfs vdev: realpath resolves to nda2")

---

## R-14 — Root-disk fallback may update an ESP that belongs to another system

**Identified by:** markmi (D58990 review, hardware discussion, 2026-08-22)
**Symptom:** On a system with multiple disks and ESPs, when BootCurrent correctly
identifies the boot disk (nda0) but that disk has no overlap with the ZFS root
pool (ada0), the original code appended root-pool disks unconditionally to the
candidate list.  This meant a shared portable ESP on the root disk — one used
by multiple machines — could be updated without being the ESP that actually
booted the current system.  Observed in a historical Rock64 configuration:
loader and kernel on SD card (BootCurrent disk), root filesystem on a USB3
device shared with other aarch64 systems that had their own ESP on it.
**Root cause:** `efi_boot_esps` Step 3 always formed the union of the
BootCurrent disk and all root filesystem disks, regardless of whether the
BootCurrent disk was a root disk member.  No overlap check existed.
**Fix (R-14):** After populating `_boot_disks` from BootCurrent PARTUUID
matching, compute the intersection with `root_disk_list`.  If at least one
boot disk is also a root disk member (the common case: normal single-disk or
ZFS mirror), include all root disks so every mirror member's ESP is synced.
If there is no overlap (boot disk is not a root disk member — split-media or
dedicated boot disk), restrict candidates to the BootCurrent disk only.  When
BootCurrent is unavailable, the behavior is unchanged (root disks only).
**Tests:** `tests/unit/test_15_boot_esps.sh` — test 24
("Split-media: only boot disk nda0 ESP found"),
test 25 ("Split-media: root disk ada0 ESP NOT included"),
test 26 ("Mirror+overlap: nda0 1 GPT found"),
test 27 ("Mirror+overlap: nda1 1 GPT also found");
`tests/integration/test_i12_split_media_guard.sh` — full end-to-end
verification that only the boot disk ESP is updated.

---

## R-04 — `gpart show` fixture `=>` rendered as HTML entity `&gt;`

**Found during:** test development (2026-08-20)
**Symptom:** Fixture files written via Write tool contained `&gt;` instead
of `=>` in the gpart header line. The `awk` scheme-detection (`$5`) parsed
`&gt;` as the scheme, returning no match, causing all ESP discovery tests to
fail.
**Root cause:** Write tool HTML-escaped `>` in heredoc content.
**Fix:** All `gpart_show_*.txt` fixtures corrected with `sed -i 's/=&gt;/=>/g'`.
**Tests:** All of `tests/unit/test_05_esp_discovery.sh`,
`tests/unit/test_06_bios_discovery.sh`, `tests/unit/test_07_partition_discovery.sh`
— every test that calls `efi_discover_all_esps` or `efi_discover_all_bios_parts`
with a fixture.
