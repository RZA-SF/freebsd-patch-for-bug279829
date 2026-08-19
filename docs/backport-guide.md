# Backport Guide: efi_bootloader_update.sh

**Bug reference:** FreeBSD PR 279829
**Primary submission:** FreeBSD 15-CURRENT
**Related work:** D45890 (Warner Losh — Lua loader version warning)

---

## 1. Why Backports Are Needed

### 1.1 The freebsd-update Upgrade Sequence

When `freebsd-update upgrade` is run to move from, say, FreeBSD 14.1 to 15.0,
it downloads the new distribution and installs it.  Crucially, the
**post-install hook scripts** that run at the end of this process are the
**source system's** scripts — the ones from the version being upgraded *to*,
extracted from the downloaded distribution set.

This means:

- A user on FreeBSD 14.1 who upgrades to 15.0 will have
  `efi_bootloader_update.sh` from the 15.0 distribution run on their system.
- If 15.0 ships the script, the ESP is updated automatically during the
  upgrade.

However, users who **stay on a stable branch** (e.g. 14-STABLE tracking minor
releases within 14.x) upgrade using the same `freebsd-update` mechanism but
within the same major version.  For them:

- A user on 14.0 upgrading to 14.1 needs the 14.1 distribution to include
  the script.
- A user on 14.1 upgrading to 14.2 needs the 14.2 distribution.

Therefore, the script must be backported to every active stable branch so that
users who never cross a major version boundary also receive the fix.

### 1.2 The Bootstrapping Problem

There is a subtle bootstrapping concern: the first upgrade on any branch that
*includes* this script will run it.  For upgrades *prior* to its inclusion,
the old (missing) behaviour applies.  Once the script is in the distribution,
all subsequent upgrades on that branch will update the ESP correctly.

This means backporting to older branches only helps users who have not yet
upgraded past the patch point.  It is still worth doing to minimise the window
of exposure.

---

## 2. Backport Targets

### 2.1 FreeBSD 15-CURRENT — Primary Submission Target

**Priority: Required (this is the primary development target)**

All changes originate on `main` (15-CURRENT).  The Phabricator review
(Differential) should target `main`.  Once accepted and committed to `main`,
the MFC (Merge From Current) process handles propagation to stable branches.

FreeBSD 15.0-RELEASE will be the first release to ship the script.

### 2.2 FreeBSD 14-STABLE — High Priority

**Priority: High**

Rationale:
- FreeBSD 14.x is the current production-supported major version as of
  mid-2025.
- Users upgrading 14.0 → 14.1 → 14.2 (etc.) within the 14.x series will
  not cross a major version boundary and will only benefit from backports.
- The Lua crash (bug 279829) was first widely reported on 14.1, making this
  the most important branch for the fix.
- 14-STABLE receives MFC commits from `main`; a formal MFC request should
  follow the `main` commit.

MFC window: 2 weeks after the `main` commit (standard FreeBSD policy for
`usr.sbin/freebsd-update`).

### 2.3 FreeBSD 13-STABLE — Medium Priority

**Priority: Medium**

Rationale:
- FreeBSD 13.x is currently in extended security support.
- Users who have not yet migrated from 13.x to 14.x are at risk when they
  eventually do upgrade (the major-version crossing scenario).
- The MFC to 13-STABLE may require minor adaptation because `usr.sbin/freebsd-update`
  differs between 13.x and 14.x in the hook invocation mechanism.  Verify
  that the hook point exists in 13-STABLE before submitting.

### 2.4 FreeBSD 12-STABLE — Skip (EOL)

**Priority: Skip**

FreeBSD 12.x reached end-of-life in December 2023.  No further commits are
accepted to `stable/12`.  Users still running 12.x should upgrade to a
supported branch first; the bootloader issue will then be addressed by the
backport to the target branch.

---

## 3. Submission Process

### 3.1 Phabricator Review

FreeBSD uses Phabricator for code review.  The review portal is at:
<https://reviews.freebsd.org/>

Steps:

1. Create an account at <https://reviews.freebsd.org/> linked to your
   FreeBSD Bugzilla account if you have one.
2. Install `arc` (the Arcanist CLI for Phabricator):
   ```sh
   pkg install arcanist
   ```
3. Configure `arc` for the FreeBSD repository:
   ```sh
   cd /usr/src
   arc set-config default https://reviews.freebsd.org/
   ```
4. Create the differential:
   ```sh
   arc diff HEAD~1
   ```
   This opens an editor for the commit message / review description.
5. In the review description:
   - Reference bug 279829: `Fixes: https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279829`
   - Mention D45890 as complementary: see section 3.2.
   - Summarise the change clearly: one paragraph on the problem, one on the
     solution.
6. Add reviewers: at minimum `Warner Losh <imp@FreeBSD.org>` and
   `freebsd-update maintainers`.

### 3.2 Relationship to D45890 (Warner Losh's Work)

Warner Losh's D45890 adds a version-compatibility warning inside the Lua
boot loader itself.  When the loader detects that it is too old for the kernel
it is about to boot, it prints a warning and (optionally) halts.

These two changes are **complementary, not competing**:

- D45890 makes the failure mode visible to the operator: "your loader is too
  old."
- This script fixes the failure mode proactively: update the loader so it is
  never too old.

The ideal final state is that both ship together.  In the commit message for
this script, reference D45890:

```
See also: D45890 (loader version warning in Lua — complementary fix)
```

Do not create a hard dependency between the two changes.  Either is useful
independently.

### 3.3 Mailing Lists

CC the following mailing lists in the Phabricator review (or send an
announcement after the `main` commit):

| List | Address | Why |
|---|---|---|
| freebsd-current | current@FreeBSD.org | 15-CURRENT development list |
| freebsd-stable | stable@FreeBSD.org | Stable branch users and maintainers |
| freebsd-update | (via freebsd-stable) | freebsd-update user base |
| freebsd-announce | announce@FreeBSD.org | Only for release notes; not required for in-progress work |

A brief announcement email to `freebsd-stable` is appropriate after the MFC
to 14-STABLE, notifying users that the next `freebsd-update fetch && freebsd-update install`
within the 14.x series will fix the ESP.

### 3.4 Bugzilla

Update bug 279829 at each milestone:

- When the Phabricator review is created: add a comment with the review URL.
- When committed to `main`: add a comment with the commit hash.
- When MFC'd to 14-STABLE: add a comment.
- When the fix first appears in a release (e.g. 14.3-RELEASE): set the
  bug status to RESOLVED / FIXED.

---

## 4. How to Create the Patch for Each Branch

### 4.1 General Approach

The script lives at `usr.sbin/freebsd-update/efi_bootloader_update.sh`
(proposed location; exact path to be confirmed with the freebsd-update
maintainers).  The corresponding hook invocation lives in
`usr.sbin/freebsd-update/freebsd-update.sh`.

```sh
# Clone the FreeBSD source tree if you do not have it
git clone --depth=1 https://git.FreeBSD.org/src.git freebsd-src
cd freebsd-src
```

### 4.2 Patch for 15-CURRENT (main)

```sh
git checkout main
git checkout -b add-efi-bootloader-update
# Copy the script into the tree
cp /path/to/efi_bootloader_update.sh usr.sbin/freebsd-update/
# Add the hook invocation to freebsd-update.sh (see integration notes below)
# Stage changes
git add usr.sbin/freebsd-update/efi_bootloader_update.sh
git add usr.sbin/freebsd-update/freebsd-update.sh
git commit -m "freebsd-update: update EFI/BIOS bootloaders during upgrade

Addresses PR 279829: freebsd-update upgrade does not update the EFI
System Partition, which can cause boot failures after major version
upgrades due to loader/kernel version mismatches.

The new efi_bootloader_update.sh script is sourced by freebsd-update
and invoked via update_bootloaders() after the base system is installed.
It updates /EFI/FreeBSD/loader.efi and, where safe, the fallback binary,
for all disks participating in the root filesystem.

PR:		279829
See also:	D45890"
arc diff HEAD~1
```

### 4.3 Patch for 14-STABLE

After the `main` commit:

```sh
git checkout stable/14
git cherry-pick <commit-hash-from-main>
# Resolve any conflicts (freebsd-update.sh may differ between branches)
# Verify the hook integration still applies cleanly
# Submit MFC request via Phabricator:
arc diff stable/14..HEAD --message "MFC from main: efi_bootloader_update.sh

MFC r<svn-revision> / git <hash>: update EFI/BIOS bootloaders during upgrade"
```

### 4.4 Patch for 13-STABLE

```sh
git checkout stable/13
git cherry-pick <commit-hash-from-main>
# Verify: check that freebsd-update.sh on 13-STABLE has a compatible hook point
# The install phase hook may be named differently; adapt as needed
# Test on a 13.x system (see section 5)
arc diff stable/13..HEAD --message "MFC from main: efi_bootloader_update.sh (13-STABLE)"
```

### 4.5 freebsd-update.sh Integration Point

The hook in `freebsd-update.sh` should be added near the end of the
`install_files()` function (or whichever function finalises the upgrade
before reboot).  The relevant addition is:

```sh
# Update EFI/BIOS bootloaders
if [ -f "${WORKDIR}/efi_bootloader_update.sh" ]; then
    . "${WORKDIR}/efi_bootloader_update.sh"
    update_bootloaders || warn "Bootloader update encountered errors — check messages above"
fi
```

The exact integration point depends on the version of `freebsd-update.sh` on
each branch.  Review the function structure of the target branch before
applying the change.

---

## 5. Testing Requirements Before Submission

All of the following must pass before submitting a Phabricator review:

### 5.1 Automated Test Suite

```sh
# Run full suite from the project root
sh tests/run_tests.sh

# Confirm zero failures
```

All unit tests, integration tests, and error-condition tests must pass.
On Linux (development hosts), tests that depend on FreeBSD-specific tools
(`mount_msdosfs`, `gpart`, `efibootmgr`) are exercised via mocks.

### 5.2 Manual FreeBSD Validation

On a FreeBSD test system (virtual machine or spare hardware):

- [ ] Single disk, EFI + BIOS, ZFS root — update runs and ESP is updated
- [ ] Two-disk mirror — both ESPs updated
- [ ] Shared ESP with Linux — Linux fallback binary not overwritten
- [ ] arm64 (if hardware available) — BOOTaa64.efi used
- [ ] Dry-run mode — `EFI_DRY_RUN=1 sh efi_bootloader_update.sh` produces
      `[DRY RUN]` output and makes no changes
- [ ] Repeated run — second invocation produces no errors and leaves files
      identical (idempotency)
- [ ] Full upgrade simulation — `freebsd-update upgrade` on a 14.x VM to a
      newer 14.x release; confirm ESP updated automatically

### 5.3 Code Review Checklist

Before submitting the review, self-check:

- [ ] No bash-specific syntax (`[[`, `$(< file)`, `local` with assignment
      in the same statement, etc.) — must be pure POSIX sh
- [ ] All variables unset or reset between test runs to avoid cross-test
      pollution
- [ ] `shellcheck -s sh` reports no warnings on the main script and all test
      files (adjust with `# shellcheck disable=...` only where necessary and
      with justification)
- [ ] Copyright header present with current year
- [ ] SPDX identifier present: `BSD-2-Clause`
- [ ] Man page or `--help` output updated to reflect any new options
