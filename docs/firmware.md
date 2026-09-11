# The Apple firmware package

t1-revive restores the T1 with Apple's own EmbeddedOS restore protocol, which needs the
generic (non-personalised) iBridge firmware bundle that Apple ships to every 2016/2017 Touch
Bar MacBook Pro. This page says where that bundle comes from, why the tool downloads it at
run time instead of shipping it, exactly which copy is pinned, and what to do when Apple's
CDN no longer serves it.

## Where it comes from

Apple distributes the T1 firmware as a small standalone installer package,
`EmbeddedOSFirmware.pkg` (identifier `com.apple.pkg.EmbeddedOSFirmware`), as part of macOS
security updates delivered through Software Update. The copy t1-revive pins carries the
package version `10.13.6.1.1.1604106639` (built 2020-10-31) and bundle version 901 of
`iBridge1_1Customer.bundle`, i.e. the EmbeddedOS firmware component of the macOS High Sierra
10.13.6 security update train released in November 2020 (product `001-72525`; the package's
own version string is the authoritative statement of which update it belongs to). It is the
package that every successful regeneration so far was run with.

The package is served by Apple's software update CDN at a content-addressed path:

```
https://swcdn.apple.com/content/downloads/22/59/001-72525-A_7H83CSQW4K/p9dd3a0vdtdssud9qlxd4i73pn389rxugu/EmbeddedOSFirmware.pkg
```

| | |
| --- | --- |
| size | 59314427 bytes |
| sha256 | `0c97ab746ec635b34b1bdea4e4722cd0173443e2ba6ede54cc6af3b5e220d230` |
| xar members | `Payload` (59305812 bytes, stored), `PackageInfo`, `Bom` |
| bundle | `usr/standalone/firmware/iBridge1_1Customer.bundle` (31 files), `CFBundleVersion` 901 |
| product | `ProductType` `Watch2,5`, `ProductBuildVersion` `14Y901`, platform `t8002`, boards `x619ap` (BDID 18) and `x619dev` (BDID 19) |

Both values are pinned in `lib/firmware.sh` (`T1R_FIRMWARE_URL`, `T1R_FIRMWARE_SHA256`); the
per-file checksums of the extracted bundle are in `tools/firmware-manifest.sha256`.

Other EmbeddedOSFirmware packages exist. The ones inside the Catalina security updates
2021-008 and 2026-001, for instance, are byte-identical to each other but carry bundle version
908 with different restore images (`048-94560-005.dmg`, `048-94563-005.dmg`) and different
`all_flash` payloads; extracting either produces a bundle that differs from the pinned one in
every file. They are not accepted: only the package above has been proven end to end on
hardware, and the tool refuses anything whose checksum differs.

## Why it is fetched at run time and never redistributed

The package is Apple's copyrighted firmware. t1-revive does not ship it, does not embed any
part of it, and does not put it in the toolkit tarball or on the install stick. The repository
holds only the URL, the checksums, the sizes and the file names. Every user's machine downloads
the package from Apple directly, verifies it against the pinned sha256, extracts it locally and
verifies every file of the bundle against the manifest. This is the same thing a Mac does when
it installs the update; t1-revive only performs the restore that macOS would perform.

## What the tool does

`firmware_ensure` in `lib/firmware.sh`, called by `preflight`/`regenerate`:

1. If `$T1R_CACHE/firmware/` already holds a bundle that matches the manifest, use it.
2. Otherwise obtain the package: the one named by `T1R_FIRMWARE` / `--firmware FILE` if given, else the cached
   `$T1R_CACHE/EmbeddedOSFirmware.pkg` if it verifies, else download it with `curl` (resumable,
   three retries) into `$T1R_CACHE` (`/var/cache/t1-revive` by default).
3. Verify size and sha256. A mismatch or a failed download stops with exit code 6.
4. Extract with the two stdlib-only helpers, reproducing `pbzx Payload | cpio -idm`:
   `tools/xar-extract.py --member Payload` (verifies the xar checksums) piped into
   `tools/pbzx.py -C DIR` (xz chunks to cpio, cpio to files). The result replaces
   `$T1R_CACHE/firmware/` atomically.
5. Verify every file of the bundle (size and sha256) against `tools/firmware-manifest.sha256`
   and print the Resources directory. `firmware_bundle_dir` prints it later without touching the
   network.

With `T1R_DRY_RUN=1` nothing is downloaded; the tool prints what it would fetch and where.

Both helpers have `--help` and work on their own, e.g. `python3 tools/xar-extract.py --list
EmbeddedOSFirmware.pkg`.

## Supplying the package by hand

If the machine has no route to Apple's CDN, or the URL has gone away, point the tool at a copy
of the exact same package:

```
sudo t1-revive --firmware /path/to/EmbeddedOSFirmware.pkg regenerate
```

The same thing can be set as the environment variable `T1R_FIRMWARE`, or permanently as
`T1R_FIRMWARE=/path/to/EmbeddedOSFirmware.pkg` in `/etc/t1-revive/t1-revive.conf`.

The file is accepted only if its sha256 is the pinned one; it is then copied into the cache and
treated exactly like a download. A package with a different checksum is refused with exit code 6
even when supplied by hand, because nothing but the proven package has been tested against real
T1s.

## When the URL changes

Apple's CDN paths are stable for years but not forever. If the download fails or the checksum
no longer matches:

* **As a user**: obtain the pinned package from another source (a Mac that installed the update
  keeps it in its software update cache, or a fellow tester) and use `--firmware`. Open an issue
  so the maintainers know the URL moved. Do not attach the package to the issue.
* **As a maintainer**, re-pin it:
  1. Look the package up in Apple's software update catalog (`sucatalog`). The catalogs are
     plists at `https://swscan.apple.com/content/catalogs/others/index-<...>.merged-1.sucatalog`;
     search them for `EmbeddedOSFirmware.pkg` and pick the product whose package sha256 is the
     pinned one (the catalog lists each package URL and size; download candidates and compare).
  2. If the identical package is served from a new path, change `T1R_FIRMWARE_URL` in
     `lib/firmware.sh` and this page. Nothing else changes.
  3. If only a different EmbeddedOSFirmware package is available, do **not** re-pin without a
     full hardware validation of the new bundle (provision, personalize, boot, staging, cold boot on a
     supported model). After validation, regenerate the manifest from the verified extraction
     (`firmware_manifest_print DIR > tools/firmware-manifest.sha256`, then add the header
     comments) and update the sha256, size and this page in the same commit.

## Bundle contents

Everything under `iBridge1_1Customer.bundle/` (paths relative to the bundle; every file's size
and sha256 is in `tools/firmware-manifest.sha256`):

```
Contents/Info.plist
Contents/version.plist
Contents/_CodeSignature/{CodeDirectory,CodeRequirements,CodeResources,CodeSignature}
Contents/Resources/BuildManifest.plist              restore manifest (what the T1 is asked to accept)
Contents/Resources/Restore.plist
Contents/Resources/048-71103-002.dmg                OSRamdisk (the EmbeddedOS system image)
Contents/Resources/048-71112-002.dmg                RestoreRamDisk (booted to perform the restore)
Contents/Resources/kernelcache.release.x619
Contents/Resources/Firmware/dfu/iBSS.x619.RELEASE.im4p
Contents/Resources/Firmware/dfu/iBEC.x619.RELEASE.im4p
Contents/Resources/Firmware/all_flash/all_flash.x619ap.production/
    DeviceTree.x619ap.im4p (+ .plist), LLB.x619.RELEASE.im4p (+ .plist),
    iBoot.x619.RELEASE.im4p (+ .plist), sep-firmware.x619.RELEASE.im4p (+ .plist), manifest
Contents/Resources/Firmware/all_flash/all_flash.x619dev.production/   (development-board variant; unused)
Contents/Resources/Firmware/usr/local/standalone/                    (empty directories)
```

The restore steps point idevicerestore at `Contents/Resources` (the directory `firmware_ensure`
prints); the T1 of a MacBook Pro is the `x619ap` board.
