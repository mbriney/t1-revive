#!/usr/bin/env bats
# lib/firmware.sh and tools/firmware-manifest.sha256.
#
# Nothing here reaches Apple's CDN: the only paths exercised are the ones that refuse a package
# ($T1R_CACHE is a temp dir, the "package" is a small synthetic file with the wrong checksum) and
# the dry run that prints the download instead of making it. The bundle verifier is checked
# against a synthetic manifest of synthetic files by overriding the manifest path.

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/firmware.sh ]] || skip "lib/firmware.sh not present"
  unset T1R_FIRMWARE
  MANIFEST=$T1R_REPO/tools/firmware-manifest.sha256
}

fw_load() {
  t1r_load firmware
  t1r_need firmware_ensure firmware_bundle_dir firmware_verify_pkg firmware_verify_bundle
}

# --- a package that is not the pinned one ----------------------------------------------------
@test "firmware_ensure: --firmware with the wrong sha256 exits 6 and says what is expected" {
  fw_load
  local bad=$T1R_TMP/not-the-package.pkg
  printf 'this is not a firmware package\n' >"$bad"
  run firmware_ensure --firmware "$bad"
  assert_status 6
  assert_contains "$output" "not the pinned"
  assert_contains "$output" "expected sha256 $T1R_FIRMWARE_SHA256"
  assert_contains "$output" "$T1R_FIRMWARE_SIZE bytes"
  assert_contains "$output" "Only that exact package has been proven on hardware"
  # the refused file must not be copied into the cache
  assert_eq "" "$(find "$T1R_CACHE" -type f 2>/dev/null || true)"
}

@test "firmware_ensure: --firmware pointing at nothing exits 6" {
  fw_load
  run firmware_ensure --firmware "$T1R_TMP/absent.pkg"
  assert_status 6
  assert_contains "$output" "no such file"
}

@test "firmware_ensure: --firmware without a value exits 2" {
  fw_load
  run firmware_ensure --firmware
  assert_status 2
}

@test "firmware_verify_pkg: refuses a file of the wrong size and a missing file" {
  fw_load
  local f=$T1R_TMP/pkg
  printf 'synthetic\n' >"$f"
  run firmware_verify_pkg "$f"
  assert_status 1
  run firmware_verify_pkg "$T1R_TMP/absent"
  assert_status 1
}

# --- the dry run ------------------------------------------------------------------------------
@test "firmware_ensure: a dry run with an empty cache prints the download and writes nothing" {
  fw_load
  export T1R_DRY_RUN=1
  run firmware_ensure
  assert_status 0
  assert_contains "$output" "dry run: would download"
  assert_contains "$output" "$T1R_FIRMWARE_URL"
  assert_contains "$output" "$T1R_FIRMWARE_SHA256"
  assert_eq "" "$(find "$T1R_CACHE" -type f 2>/dev/null || true)" "a dry run must create no files"
  assert_contains "$(t1r_diag_lines)" "step=firmware result=skipped reason=dry-run"
}

# --- an empty cache -----------------------------------------------------------------------------
@test "firmware_bundle_dir: prints nothing and returns 1 when the cache is empty" {
  fw_load
  run firmware_bundle_dir
  assert_status 1
  assert_eq "" "$output"
}

@test "firmware_verify_bundle: returns 1 when the bundle directory is not there" {
  fw_load
  run firmware_verify_bundle "$T1R_TMP/no-such-bundle"
  assert_status 1
}

# --- the manifest -------------------------------------------------------------------------------
@test "firmware-manifest.sha256: exactly 31 entries" {
  [[ -f $MANIFEST ]] || skip "tools/firmware-manifest.sha256 not present"
  assert_eq 31 "$(grep -cvE '^[[:space:]]*(#|$)' "$MANIFEST")"
}

@test "firmware-manifest.sha256: every entry is sha256, size and a relative path" {
  [[ -f $MANIFEST ]] || skip "tools/firmware-manifest.sha256 not present"
  local sum size path n=0 rc=0
  while read -r sum size path; do
    case "$sum" in ''|'#'*) continue;; *) ;; esac
    n=$((n + 1))
    [[ $sum =~ ^[0-9a-f]{64}$ ]]   || { echo "not a sha256: $sum" >&2; rc=1; }
    [[ $size =~ ^[0-9]+$ ]]        || { echo "not a size: $size ($path)" >&2; rc=1; }
    [[ -n $path ]]                 || { echo "empty path" >&2; rc=1; }
    [[ $path != /* ]]              || { echo "absolute path: $path" >&2; rc=1; }
    [[ $path != *..* ]]            || { echo "path escapes the bundle: $path" >&2; rc=1; }
    [[ $path == Contents/* ]]      || { echo "not under the bundle: $path" >&2; rc=1; }
  done <"$MANIFEST"
  assert_eq 31 "$n" "entries read"
  return $rc
}

@test "firmware-manifest.sha256: names the file the restore steps look for" {
  [[ -f $MANIFEST ]] || skip "tools/firmware-manifest.sha256 not present"
  grep -q ' Contents/Resources/BuildManifest.plist$' "$MANIFEST" || {
    echo "the manifest does not list Contents/Resources/BuildManifest.plist" >&2; return 1; }
}

# --- the verifier, against a synthetic bundle ------------------------------------------------
@test "firmware_verify_bundle: accepts a matching tree and rejects each way of differing" {
  fw_load
  local dir=$T1R_TMP/bundle
  mkdir -p "$dir/Contents/Resources"
  printf 'synthetic build manifest\n' >"$dir/Contents/Resources/BuildManifest.plist"
  printf 'synthetic info\n' >"$dir/Contents/Info.plist"
  # the manifest is generated from the synthetic tree, so no checksum is ever written down here
  _fw_manifest() { printf '%s' "$T1R_TMP/manifest"; }
  firmware_manifest_print "$dir" >"$T1R_TMP/manifest"
  assert_eq 2 "$(grep -cvE '^[[:space:]]*(#|$)' "$T1R_TMP/manifest")"

  run firmware_verify_bundle "$dir"
  assert_status 0

  printf 'synthetic info, edited\n' >"$dir/Contents/Info.plist"
  run firmware_verify_bundle "$dir"
  assert_status 1
  assert_contains "$output" "wrong size: Contents/Info.plist"

  printf 'synthetic inf0\n' >"$dir/Contents/Info.plist"     # same size, different bytes
  run firmware_verify_bundle "$dir"
  assert_status 1
  assert_contains "$output" "wrong checksum: Contents/Info.plist"

  rm -f "$dir/Contents/Info.plist"
  run firmware_verify_bundle "$dir"
  assert_status 1
  assert_contains "$output" "missing: Contents/Info.plist"
}

@test "firmware_bundle_dir: prints the Resources directory of a verified bundle" {
  fw_load
  local root; root=$(_fw_bundle_root)
  mkdir -p "$root/Contents/Resources"
  printf 'synthetic build manifest\n' >"$root/Contents/Resources/BuildManifest.plist"
  _fw_manifest() { printf '%s' "$T1R_TMP/manifest"; }
  firmware_manifest_print "$root" >"$T1R_TMP/manifest"
  run firmware_bundle_dir
  assert_status 0
  assert_eq "$root/Contents/Resources" "$output"
}

@test "sourcing lib/firmware.sh has no side effects" {
  run bash -c '. "$T1R_ROOT/lib/common.sh"; . "$T1R_ROOT/lib/firmware.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}
