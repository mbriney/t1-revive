#!/usr/bin/env bats
# lib/cmd-preflight.sh: the ok/NO lines, the summary and the exit codes.
#
# Always with --local, so no name resolution and no TCP connection is attempted. The model,
# sysfs, ESP and os-release all come from test/fixtures; the patched stack is a directory of
# stub executables. distro_kernel_matches and distro_install are redefined after sourcing:
# the first because its answer would otherwise depend on the machine running the suite, the
# second because it is the one function here that would change the system.

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/cmd-preflight.sh ]] || skip "lib/cmd-preflight.sh not present"
  t1r_use_sysfs recovery
  t1r_use_dmi 14_3
  t1r_use_lsblk one-esp
  t1r_use_osrelease arch
  t1r_stub_prefix
}

pf_load() {
  t1r_load discover distro firmware cmd-preflight
  t1r_need cmd_preflight
  # the installed kernel matching the running one is a property of the machine, not of the code
  distro_kernel_matches() { return 0; }
  # nothing in this suite may install a package
  T1R_TEST_INSTALLS=$T1R_TMP/installs.log
  : >"$T1R_TEST_INSTALLS"
  distro_install() { printf '%s\n' "$*" >>"$T1R_TEST_INSTALLS"; return 0; }
}

# --- the normal run ---------------------------------------------------------------------------
@test "preflight --local: prints ok and NO lines and a summary, and exits 3" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  printf '%s\n' "$output" | grep -q '^  ok  ' || { echo "no ok lines" >&2; return 1; }
  printf '%s\n' "$output" | grep -q '^  NO  ' || { echo "no NO lines" >&2; return 1; }
  printf '%s\n' "$output" | grep -qE '^[0-9]+ ok, [0-9]+ problems$' || {
    echo "no summary line" >&2; return 1; }
  assert_contains "$output" "Fix the NO lines first."
  assert_contains "$(t1r_diag_lines)" "step=preflight result=error code=3"
}

@test "preflight --local: skips the network checks entirely" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "network checks skipped (--local)"
  refute_contains "$output" "gs.apple.com"
  refute_contains "$output" "swcdn.apple.com"
}

@test "preflight --local: reports the fixture model, T1 state and ESP" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "model MacBookPro14,3 (the proven machine)"
  assert_contains "$output" "T1 in recovery (05ac:1281)"
  assert_contains "$output" "/dev/sdz1"
}

@test "preflight --local: an untested model is an ok line with a warning" {
  t1r_use_dmi 13_2; pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "model MacBookPro13,2 (a T1 Mac"
  assert_contains "$output" "warning: untested model"
}

@test "preflight --local: sees the stub toolchain and its T1 marker" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "ok  bin/idevicerestore runs"
  assert_contains "$output" "ok  sbin/usbmuxd runs"
  assert_contains "$output" "idevicerestore carries the T1 patches"
}

@test "preflight --local: an empty prefix is reported as missing binaries" {
  rm -rf "${T1R_PREFIX:?}/bin" "${T1R_PREFIX:?}/sbin"
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "NO  bin/idevicerestore missing"
  assert_contains "$output" "NO  sbin/usbmuxd missing"
}

@test "preflight --local: an uncached firmware bundle is a NO line with --local" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "firmware bundle not in the cache and --local given"
}

# --- the refusals and the other exit codes --------------------------------------------------
@test "preflight: an unsupported model exits 4 and stops at the model check" {
  t1r_use_dmi other; pf_load
  run cmd_preflight --local
  assert_status 4
  assert_contains "$output" "is not a T1 MacBook Pro; refusing"
  assert_contains "$output" "This machine is not a T1 MacBook Pro"
  # nothing after the model section may run
  refute_contains "$output" "restore toolchain"
  refute_contains "$output" "EFI system partition"
  assert_contains "$(t1r_diag_lines)" "step=preflight result=refused model_status=unsupported"
}

@test "preflight: exits 7 when the running kernel is not the installed one" {
  pf_load
  distro_kernel_matches() { return 1; }
  run cmd_preflight --local
  assert_status 7
  assert_contains "$output" "reboot, then run this again"
  assert_contains "$output" "Reboot, then run 't1-revive preflight' again."
  assert_contains "$(t1r_diag_lines)" "step=preflight result=reboot"
}

@test "preflight: an unknown flag exits 2 and --help exits 0" {
  pf_load
  run cmd_preflight --frobnicate
  assert_status 2
  assert_contains "$output" "unknown flag"
  run cmd_preflight --help
  assert_status 0
  assert_contains "$output" "usage: t1-revive preflight"
}

# --- --install ------------------------------------------------------------------------------
@test "preflight --local --install: the flag is accepted and installs nothing without root" {
  [[ ${EUID:-$(id -u)} -ne 0 ]] || skip "this test describes what a normal user gets"
  pf_load
  run cmd_preflight --local --install
  # accepted: not a usage error, and the run reaches the summary
  [[ $status -eq 3 || $status -eq 7 ]] || { echo "unexpected exit $status" >&2; return 1; }
  printf '%s\n' "$output" | grep -qE '^[0-9]+ ok, [0-9]+ problems$' || {
    echo "no summary line" >&2; return 1; }
  assert_contains "$output" "not running as root"
  assert_eq "" "$(cat "$T1R_TEST_INSTALLS")" "--install must not install anything without root"
}

@test "preflight: non-Arch systems say so instead of guessing" {
  t1r_use_osrelease other; pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "package checks are implemented for Arch-based systems only"
  assert_contains "$output" "packages and kernel (nonesuch)"
}

@test "sourcing lib/cmd-preflight.sh has no side effects" {
  run bash -c '. "$T1R_ROOT/lib/common.sh"; . "$T1R_ROOT/lib/discover.sh"
               . "$T1R_ROOT/lib/distro.sh"; . "$T1R_ROOT/lib/cmd-preflight.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}
