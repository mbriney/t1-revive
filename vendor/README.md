# vendor/ — the patched libimobiledevice stack

t1-revive drives Apple's EmbeddedOS restore protocol with the
[libimobiledevice](https://libimobiledevice.org) tools. Upstream has no notion of the
T1 / `iBridge1,1` (x619ap) part: `libirecovery` does not know the device, the T1 in
recovery misses libusb's fixed 1 s string-descriptor timeout, `usbmuxd` filters the
hotplug events it needs, and `idevicerestore` rejects Apple's firmware *bundle* (it is
not an IPSW), insists on a root filesystem, and cannot round-trip the FDR memory store
or replay a captured memboot image. Three small patches add exactly that, opt-in, behind
`IDEVICERESTORE_T1_*` environment variables. Nothing here is installed system-wide: the
whole stack is built into a private prefix (`$T1R_PREFIX`, default `<repo>/prefix`)
and only the tool's own subprocesses use it.

## What is here

| path | purpose |
| --- | --- |
| `refs.env` | one block per component, in build order: `_UPSTREAM_URL`, `_BASE_COMMIT`, `_VERSION` (`git describe`), `_PATCH`, `_LICENSE`, `_TARBALL_SHA256` (for the Arch package) and, for patched components, `_FORK_URL` / `_FORK_BRANCH` |
| `patches/*.patch` | the T1 patches: header comment (project, base commit, licence, what it adds) followed by a plain `git diff` against the base commit |
| `SOURCES.template` | the corresponding-source statement shipped in release tarballs (filled in by `tools/make-toolkit.sh`) |
| `src/` (gitignored) | per-component source checkouts created by `build.sh` |
| `build/` (gitignored) | per-component build logs |
| `../build.sh` | the build driver (repo root) |

Components, in build order: libplist, libimobiledevice-glue, libtatsu, libirecovery
(patched), libusbmuxd, libimobiledevice, usbmuxd (patched), idevicerestore (patched).

## Building

```
bash build.sh                          # clone each base commit into vendor/src, patch, build into ./prefix
bash build.sh --prefix /some/dir       # any prefix; nothing outside the repo and that prefix is written
bash build.sh --offline                # no network: vendor/src/<name> must already exist
bash build.sh --from-forks             # clone the patched components from the maintainer's t1 branches instead
bash build.sh --only idevicerestore    # rebuild one component (its dependencies must be in the prefix)
```

`build.sh` mirrors the proven build exactly: same environment (`PATH`, `PKG_CONFIG_PATH`,
`LD_LIBRARY_PATH` pointed at the prefix), same configure flags
(`libplist --without-cython`; `libirecovery --with-udevrulesdir=<prefix>/lib/udev/rules.d`;
`libimobiledevice --without-cython --enable-debug-code`;
`usbmuxd --without-systemd --with-udevrulesdir=<prefix>/lib/udev/rules.d`), same order.
`RELEASE_VERSION` is passed to each `autogen.sh` so every binary reports the same
`--version` string as the reference build regardless of whether the tree is a git checkout
or an unpacked tarball. Patch application is idempotent (checked first, verified after);
a second run only re-runs `make`. Requires the autotools, pkgconf, a C compiler, git,
patch, and the headers of libzip, libusb-1.0, openssl, curl, zlib and readline; the
script names the missing package before doing anything.

The binaries link against the private `lib/` through an ELF RUNPATH set by libtool
to the build prefix. Moving a prefix therefore needs `LD_LIBRARY_PATH=<prefix>/lib`
(the dispatcher exports it) or a RUNPATH rewrite (the Arch package uses `patchelf`).

## Two equivalent source routes

`refs.env` records, for each patched component, both the upstream base commit + patch
and the maintainer's fork branch (`*_FORK_URL`, branch `t1`). They are meant to be the
same tree: the fork branch is the base commit with the patch committed on top. `build.sh
--from-forks` enforces this — it requires the base commit to be an ancestor of the branch
and then runs the same idempotent patch step, which must report "already applied";
anything else (branch drifted, patch not regenerated) fails loudly.

## Refreshing

1. Pick the new upstream commit: `git ls-remote https://github.com/libimobiledevice/<name>`.
2. `git -C vendor/src/<name> fetch origin && git checkout --detach <sha>`, then
   `git apply vendor/patches/<name>.patch` (or `git apply -3` and resolve).
3. Build (`bash build.sh --only <name>`), run the restore rehearsal
   (`t1-revive regenerate --dry-run`, then the bats suite, then real hardware).
4. Regenerate the patch **with its header kept**: copy the header lines of the old
   file, then append `git -C vendor/src/<name> -c diff.mnemonicPrefix=false diff HEAD`.
   Keep the base-commit line in the header in sync.
5. Update `refs.env`: `_BASE_COMMIT` (full sha), `_VERSION` (`git describe --tags` of the
   new base commit) and `_TARBALL_SHA256`
   (`curl -sL <url>/archive/<sha>.tar.gz | sha256sum`, which the Arch package verifies), and
   push the same tree to the fork's `t1` branch if you maintain one.
6. Run `tools/scan-identifiers.sh` — patches must stay free of identifiers.

Pitfall worth knowing: never run `git apply` in a directory that is *not* a git
checkout but sits inside one (for example an unpacked tarball under `vendor/src/`
inside this repo). git then resolves paths against the outer repository and reports
success while changing nothing. `build.sh` uses `git apply` only inside a real
per-component checkout and GNU `patch -p1` otherwise, and verifies the result either way.

## Licences

| component | licence (verified from `COPYING*` and source headers) | patched |
| --- | --- | --- |
| libplist | LGPL-2.1-or-later (`COPYING` is the GPL-2.0 text the LGPL refers to; `COPYING.LESSER` is the LGPL) | no |
| libimobiledevice-glue | LGPL-2.1-or-later | no |
| libtatsu | LGPL-2.1-or-later | no |
| libirecovery | LGPL-2.1-only (headers say "version 2.1", no "or later") | yes |
| libusbmuxd | LGPL-2.1-or-later | no |
| libimobiledevice | LGPL-2.1-or-later, except `tools/idevicesetlocation.c` (GPL-2.0-or-later) | no |
| usbmuxd | GPL-2.0-only OR GPL-3.0-only (source headers: "either version 2 or version 3"; both texts ship in the tree) | yes |
| idevicerestore | LGPL-2.1-or-later per every source header; the repository's `COPYING` and README carry the LGPL-3.0 text | yes |

The patches are contributed under the licence of the files they modify. Everything
t1-revive itself authors (including `build.sh`) is MIT. Full texts and copyright/author
lists: `THIRD_PARTY_NOTICES.md` at the repo root.

## Source availability (LGPL / GPL compliance)

The patched sources are exactly: the base commits listed in `refs.env`, plus the patch
files in `vendor/patches/`. Anyone can reproduce the shipped binaries with
`git clone <upstream> && git checkout <commit> && git apply <patch>` followed by
`build.sh`'s configure flags. Release tarballs and the Arch package ship a `SOURCES`
file (from `SOURCES.template`) listing component, URL, commit and patch sha256, the
patch files themselves, and the licence texts. No Apple code and no device data is part
of any of this: firmware is downloaded from Apple at run time and everything
identity-bearing stays under `/var/lib/t1-revive`.

Credits: the libimobiledevice project (Nikias Bassen, Martin Szulecki and contributors)
for the stack; Andrew Boyd’s
[t1bridge](https://github.com/standardagents/t1bridge) (MIT), which takes over the T1
once it boots.
