#!/usr/bin/env bash
# lib/firmware.sh - fetch, verify and extract Apple's EmbeddedOSFirmware.pkg into $T1R_CACHE.
#
# The T1 restore needs the generic iBridge1_1Customer.bundle that Apple ships inside a macOS
# security update. Nothing from Apple is stored in this repository: this file pins the CDN URL,
# the package checksum and the per-file manifest of the extracted bundle
# (tools/firmware-manifest.sha256); the package itself is downloaded at run time.
#
# Public functions (sourceable without side effects; they rely on lib/common.sh being sourced):
#   firmware_ensure [--firmware FILE]   make the bundle available; prints the Resources directory
#   firmware_bundle_dir                 prints the Resources directory if present and verified, else nothing
#   firmware_verify_pkg FILE            0 if FILE has the pinned sha256, 1 otherwise
#   firmware_verify_bundle [DIR]        0 if the extracted bundle matches the manifest, 1 otherwise
#   firmware_manifest_print DIR         print a manifest for a bundle dir (maintainer use, see docs/firmware.md)
#
# Layout under $T1R_CACHE (default /var/cache/t1-revive, mode 0755, no device data ever):
#   EmbeddedOSFirmware.pkg              the verified package (download in progress: .part)
#   firmware/                           the package payload as extracted (usr/standalone/firmware/...)
#   firmware/<bundle>/Contents/Resources  what this file prints; the restore steps read from here
set -uo pipefail

# ---- pinned values (see docs/firmware.md for how these were established and how to re-pin) ----
: "${T1R_FIRMWARE_URL:=https://swcdn.apple.com/content/downloads/22/59/001-72525-A_7H83CSQW4K/p9dd3a0vdtdssud9qlxd4i73pn389rxugu/EmbeddedOSFirmware.pkg}"
T1R_FIRMWARE_SHA256_PINNED=0c97ab746ec635b34b1bdea4e4722cd0173443e2ba6ede54cc6af3b5e220d230
: "${T1R_FIRMWARE_SHA256:=$T1R_FIRMWARE_SHA256_PINNED}"
: "${T1R_FIRMWARE_SIZE:=59314427}"
: "${T1R_FIRMWARE_PKG_NAME:=EmbeddedOSFirmware.pkg}"
: "${T1R_FIRMWARE_BUNDLE_REL:=usr/standalone/firmware/iBridge1_1Customer.bundle}"
# Optional: a pre-downloaded package (same as --firmware FILE); may also come from t1-revive.conf.
: "${T1R_FIRMWARE:=}"

_fw_root() { printf '%s' "${T1R_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"; }
_fw_cache() { printf '%s' "${T1R_CACHE:-/var/cache/t1-revive}"; }
_fw_pkg_path() { printf '%s/%s' "$(_fw_cache)" "$T1R_FIRMWARE_PKG_NAME"; }
_fw_bundle_root() { printf '%s/firmware/%s' "$(_fw_cache)" "$T1R_FIRMWARE_BUNDLE_REL"; }
_fw_manifest() { printf '%s/tools/firmware-manifest.sha256' "$(_fw_root)"; }
_fw_sha256() { sha256sum -- "$1" | cut -d' ' -f1; }

_fw_moved_hint() {
  cat <<EOF
  Apple may have moved or withdrawn the package (the URL is a content-addressed CDN path from a
  macOS security update). Options:
    1. Obtain the exact package elsewhere (a Mac's software update cache, the Apple sucatalog, a
       colleague's copy) and point the tool at it:
         sudo t1-revive --firmware /path/to/EmbeddedOSFirmware.pkg <command>
       (or put T1R_FIRMWARE=... in ${T1R_CONF:-/etc/t1-revive}/t1-revive.conf). It is accepted only if its
       sha256 is $T1R_FIRMWARE_SHA256
    2. Check docs/firmware.md ("When the URL changes") and open an issue so the URL can be re-pinned.
EOF
}

# firmware_verify_pkg FILE -> 0 if FILE is the pinned package
firmware_verify_pkg() {
  local f=$1 sum
  [[ -f "$f" ]] || return 1
  [[ "$(stat -c %s -- "$f")" = "$T1R_FIRMWARE_SIZE" ]] || return 1
  sum=$(_fw_sha256 "$f") || return 1
  [[ "$sum" = "$T1R_FIRMWARE_SHA256" ]]
}

# firmware_verify_bundle [BUNDLE_DIR] -> 0 if every manifest entry is present with the right size and hash
firmware_verify_bundle() {
  local dir=${1:-$(_fw_bundle_root)} manifest sum size path bad=0 n=0
  manifest=$(_fw_manifest)
  [[ -d "$dir" ]] || return 1
  [[ -r "$manifest" ]] || { warn "firmware manifest missing: $manifest"; return 1; }
  while read -r sum size path; do
    case "$sum" in ''|'#'*) continue;; *) ;; esac
    n=$((n + 1))
    if [[ ! -f "$dir/$path" ]]; then
      note "missing: $path"; bad=$((bad + 1)); continue
    fi
    if [[ "$(stat -c %s -- "$dir/$path")" != "$size" ]]; then
      note "wrong size: $path"; bad=$((bad + 1)); continue
    fi
    if [[ "$(_fw_sha256 "$dir/$path")" != "$sum" ]]; then
      note "wrong checksum: $path"; bad=$((bad + 1)); continue
    fi
  done < "$manifest"
  [[ "$n" -gt 0 ]] && [[ "$bad" -eq 0 ]]
}

# firmware_manifest_print BUNDLE_DIR -> manifest lines for every file under BUNDLE_DIR (maintainer use)
firmware_manifest_print() {
  local dir=$1 p
  [[ -d "$dir" ]] || { warn "not a directory: $dir"; return 1; }
  printf '# t1-revive firmware manifest: contents of %s\n' "$(basename -- "$dir")"
  printf '# Fields: sha256 size path (path relative to the bundle directory).\n'
  (cd -- "$dir" && find . -type f -printf '%P\n' | LC_ALL=C sort) | while read -r p; do
    printf '%s %s %s\n' "$(_fw_sha256 "$dir/$p")" "$(stat -c %s -- "$dir/$p")" "$p"
  done
}

# firmware_bundle_dir -> prints the verified Resources directory, or nothing (return 1)
firmware_bundle_dir() {
  local root
  root=$(_fw_bundle_root)
  [[ -f "$root/Contents/Resources/BuildManifest.plist" ]] || return 1
  firmware_verify_bundle "$root" >/dev/null 2>&1 || return 1
  printf '%s\n' "$root/Contents/Resources"
}

# _fw_download DEST -> curl with resume into DEST.part, then rename; returns curl's status
_fw_download() {
  local dest=$1 rc opts=(-fL --retry 3 --retry-delay 5 -C -)
  if [[ -t 2 ]]; then opts+=(--progress-bar); else opts+=(-sS); fi
  note "downloading $T1R_FIRMWARE_PKG_NAME from Apple's software update CDN (about $((T1R_FIRMWARE_SIZE / 1048576)) MB)"
  curl "${opts[@]}" -o "$dest.part" -- "$T1R_FIRMWARE_URL"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # a stale .part that can no longer be resumed (HTTP 416) must not poison the next attempt
    [[ "$rc" = 33 ]] || [[ "$rc" = 22 ]] && rm -f -- "$dest.part"
    return "$rc"
  fi
  mv -f -- "$dest.part" "$dest"
}

# _fw_extract PKG -> unpack the Payload into $T1R_CACHE/firmware (atomic replace)
_fw_extract() {
  local pkg=$1 cache root tmp tools
  cache=$(_fw_cache); tools=$(_fw_root)/tools
  command -v python3 >/dev/null 2>&1 || die 1 "python3 is required to extract the firmware package"
  [[ -r "$tools/xar-extract.py" ]] && [[ -r "$tools/pbzx.py" ]] || die 1 "extractors missing under $tools"
  tmp=$(mktemp -d -- "$cache/firmware.tmp.XXXXXX") || die 1 "cannot create a temporary directory in $cache"
  chmod 0755 -- "$tmp"
  note "extracting the firmware bundle (xar -> Payload -> pbzx -> cpio)"
  if ! python3 "$tools/xar-extract.py" --member Payload --output - -- "$pkg" \
       | python3 "$tools/pbzx.py" -C "$tmp" - 2>/dev/null; then
    rm -rf -- "$tmp"
    die 1 "extracting $T1R_FIRMWARE_PKG_NAME failed (the package is verified, so this is a local problem: disk space, python3, permissions on $cache)"
  fi
  root=$cache/firmware
  rm -rf -- "$root.old"
  [[ -e "$root" ]] && mv -- "$root" "$root.old"
  mv -- "$tmp" "$root" || die 1 "cannot move the extracted bundle into place"
  rm -rf -- "$root.old"
}

# firmware_ensure [--firmware FILE]
# Makes the verified bundle available under $T1R_CACHE and prints its Resources directory.
# Exit 6 (die) on download failure or checksum mismatch.
firmware_ensure() {
  local given="$T1R_FIRMWARE" cache pkg dir src="cache"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --firmware) [[ $# -ge 2 ]] || die 2 "--firmware needs a file"; given=$2; shift 2;;
      --firmware=*) given=${1#--firmware=}; shift;;
      *) die 2 "firmware_ensure: unknown argument $1";;
    esac
  done
  cache=$(_fw_cache); pkg=$(_fw_pkg_path)
  mkdir -p -- "$cache" || die 1 "cannot create $cache"

  # 1. already extracted and verified: nothing to do
  if dir=$(firmware_bundle_dir); then
    note "firmware bundle present and verified"
    diag step=firmware result=ok source=extracted
    printf '%s\n' "$dir"
    return 0
  fi

  # 2. obtain the package: --firmware FILE, the cached copy, or a download
  if [[ -n "$given" ]]; then
    [[ -f "$given" ]] || die 6 "--firmware: no such file: $given"
    note "using the supplied package"
    if ! firmware_verify_pkg "$given"; then
      diag step=firmware result=error code=6 reason=bad-checksum source=file
      die 6 "the supplied package is not the pinned $T1R_FIRMWARE_PKG_NAME (expected sha256 $T1R_FIRMWARE_SHA256, $T1R_FIRMWARE_SIZE bytes). Only that exact package has been proven on hardware."
    fi
    if [[ "$(readlink -f -- "$given")" != "$(readlink -f -- "$pkg" 2>/dev/null)" ]]; then
      if ! cp -f -- "$given" "$pkg.part"; then die 1 "cannot copy the package into $cache"; fi
      if ! mv -f -- "$pkg.part" "$pkg"; then die 1 "cannot copy the package into $cache"; fi
    fi
    src="file"
  elif firmware_verify_pkg "$pkg"; then
    note "using the cached package"
  else
    [[ -f "$pkg" ]] && { warn "cached package fails verification; downloading again"; rm -f -- "$pkg"; }
    if [[ "${T1R_DRY_RUN:-0}" = 1 ]]; then
      note "dry run: would download $T1R_FIRMWARE_URL"
      note "dry run: to $pkg, then verify sha256 $T1R_FIRMWARE_SHA256 and extract into $cache/firmware"
      diag step=firmware result=skipped reason=dry-run
      return 0
    fi
    command -v curl >/dev/null 2>&1 || die 1 "curl is required to download the firmware package"
    if ! _fw_download "$pkg"; then
      diag step=firmware result=error code=6 reason=download
      die 6 "could not download $T1R_FIRMWARE_PKG_NAME from Apple.
$(_fw_moved_hint)"
    fi
    if ! firmware_verify_pkg "$pkg"; then
      rm -f -- "$pkg"
      diag step=firmware result=error code=6 reason=bad-checksum source=download
      die 6 "the downloaded package does not match the pinned sha256 $T1R_FIRMWARE_SHA256 (it was deleted).
$(_fw_moved_hint)"
    fi
    src="download"
  fi

  # 3. extract and verify the bundle against the manifest
  _fw_extract "$pkg"
  if ! firmware_verify_bundle; then
    diag step=firmware result=error code=6 reason=bundle-mismatch source="$src"
    die 6 "the extracted bundle does not match tools/firmware-manifest.sha256 (see the lines above). The package verified, so this points at the extractor or the disk; please open an issue with 't1-revive report'."
  fi
  dir=$(_fw_bundle_root)/Contents/Resources
  note "firmware bundle verified: $(grep -c -v '^#' "$(_fw_manifest)") files"
  diag step=firmware result=ok source="$src"
  printf '%s\n' "$dir"
}
