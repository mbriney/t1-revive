#!/usr/bin/env bats
# lib/cmd-regenerate.sh: argument handling, the model and FRST gates, the firmware gate, the
# backup gate and a complete dry run.
#
# Nothing here touches a T1, /proc/acpi/call, a real ESP or the network: T1R_* point at
# test/fixtures and $T1R_TMP, the patched stack is a directory of stub executables that only
# record their argv, and the three functions that need root or hardware (require_root,
# frst_method, firmware_ensure, no_system_usbmuxd) are redefined AFTER the libraries are
# sourced. The chain only ever runs with T1R_DRY_RUN=1.

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/cmd-regenerate.sh ]] || skip "lib/cmd-regenerate.sh not present"
  t1r_use_sysfs recovery
  t1r_use_dmi 14_3
  t1r_use_osrelease arch
  t1r_stub_prefix
  mkdir -p "$T1R_TMP/fw"
}

# regen_load: sources everything cmd_regenerate needs and installs the stubs.
regen_load() {
  t1r_load discover distro cmd-regenerate
  t1r_need cmd_regenerate run_step fallback_text
  require_root() { :; }
  frst_method() { printf '%s\n' '\_SB.PCI0.XHC1.RHUB.ASOC.FRST'; }
  firmware_ensure() { printf '%s\n' "$T1R_TMP/fw"; }
  no_system_usbmuxd() { :; }
}

# --- argument handling -------------------------------------------------------------------
@test "regenerate: --from with an unknown step exits 2 and names the steps" {
  regen_load
  t1r_run cmd_regenerate --from bogus
  assert_status 2
  assert_contains "$output" "provision"
  assert_contains "$output" "handover"
  assert_eq "" "$(t1r_calls)" "nothing may run before the usage check"
}

@test "regenerate: --from without a value exits 2" {
  regen_load
  t1r_run cmd_regenerate --from
  assert_status 2
}

@test "regenerate: an unknown flag exits 2" {
  regen_load
  t1r_run cmd_regenerate --frobnicate
  assert_status 2
}

@test "regenerate: --strict is a global flag the dispatcher accepts" {
  local cli=$T1R_REPO/bin/t1-revive
  [[ -f $cli ]] || skip "bin/t1-revive not present"
  # --from bogus stops in the argument check, before require_root: what is under test here is
  # only that --strict itself is not rejected as an unknown flag.
  t1r_run bash "$cli" --strict --dry-run regenerate --from bogus
  assert_status 2
  refute_contains "$output" "unknown flag"
}

# --- the model gate ----------------------------------------------------------------------
@test "regenerate: an unsupported model exits 4 before any device command" {
  t1r_use_dmi other; regen_load
  t1r_run cmd_regenerate
  assert_status 4
  assert_contains "$output" "not a supported T1 MacBook Pro"
  assert_eq "" "$(t1r_calls)" "no patched-stack binary may run for an unsupported model"
  t1r_no_step_markers
}

@test "regenerate: an untested model warns and continues in a dry run" {
  t1r_use_dmi 13_2; t1r_fake_esp; regen_load
  # 13,2 is a tested model since issue #9; the fixture stands in for the next new one
  T1R_TESTED_MODELS="MacBookPro14,3" T1R_UNTESTED_MODELS="MacBookPro13,2"
  t1r_run cmd_regenerate
  assert_status 0
  assert_contains "$output" "warning:"
  assert_contains "$output" "MacBookPro13,2"
  assert_contains "$output" "continue at your own risk"
}

# --- the FRST gate -----------------------------------------------------------------------
@test "regenerate: an empty frst_method exits 4" {
  regen_load
  frst_method() { printf '\n'; }
  t1r_run cmd_regenerate
  assert_status 4
  assert_contains "$output" "FRST"
  assert_eq "" "$(t1r_calls)"
}

# --- the firmware gate -------------------------------------------------------------------
@test "regenerate: no firmware module at all exits 1" {
  regen_load
  unset -f firmware_ensure
  t1r_run cmd_regenerate
  assert_status 1
  assert_contains "$output" "firmware module missing"
}

@test "regenerate: an unavailable firmware bundle exits 6 (network/Apple failure)" {
  regen_load
  firmware_ensure() { return 1; }
  t1r_run cmd_regenerate
  # AGENTS.md and docs/firmware.md: a firmware bundle that cannot be obtained is exit code 6.
  assert_status 6
  assert_contains "$output" "firmware bundle not available"
}

# --- the backup gate ---------------------------------------------------------------------
@test "regenerate: existing EMBEDDEDOS and no backup asks, and a declined answer exits 4" {
  t1r_fake_esp; t1r_esp_apple_data; t1r_esp_snapshot; regen_load
  # setsid: no controlling terminal, so confirm's read from /dev/tty fails instead of blocking.
  t1r_run timeout 30 setsid --wait bash -c '
    . "$T1R_ROOT/lib/common.sh"; . "$T1R_ROOT/lib/discover.sh"; . "$T1R_ROOT/lib/distro.sh"
    . "$T1R_ROOT/lib/cmd-regenerate.sh"
    require_root() { :; }
    frst_method() { printf "%s\n" "\_SB.PCI0.XHC1.RHUB.ASOC.FRST"; }
    firmware_ensure() { printf "%s\n" "$T1R_TMP/fw"; }
    no_system_usbmuxd() { :; }
    T1R_NO_CONFIRM=0 cmd_regenerate' </dev/null
  assert_status 4
  assert_contains "$output" "no off-disk backup"
  assert_contains "$output" "replacing the existing files"
  assert_contains "$output" "? start the regeneration at 'provision' and replace the existing Apple data"
  assert_contains "$output" "Press Enter to continue, or Ctrl-C to stop."
  t1r_esp_unchanged
  t1r_no_step_markers
}

@test "regenerate: existing EMBEDDEDOS and no backup proceeds with T1R_NO_CONFIRM=1" {
  t1r_fake_esp; t1r_esp_apple_data; t1r_esp_snapshot; regen_load
  t1r_run cmd_regenerate
  assert_status 0
  assert_contains "$output" "no off-disk backup"
  assert_contains "$(t1r_diag_lines)" "step=gate backup=none existing_data=yes"
  t1r_esp_unchanged
}

@test "regenerate: an efi-backup tar in the state dir silences the backup warning" {
  t1r_fake_esp; t1r_esp_apple_data; regen_load
  : >"$T1R_STATE/efi-backup-19700101-000000.tar"
  t1r_run cmd_regenerate
  assert_status 0
  refute_contains "$output" "no off-disk backup"
  assert_contains "$output" "an off-disk backup exists"
}

# --- the complete dry run ------------------------------------------------------------------
@test "regenerate: a full dry run exits 0 and writes no markers and no ESP files" {
  t1r_fake_esp; t1r_esp_snapshot; regen_load
  t1r_run cmd_regenerate
  assert_status 0
  local step
  for step in provision reset-1 personalize reset-2 boot stage handover; do
    assert_contains "$output" "$step"
  done
  assert_contains "$output" "*** DRY RUN"
  assert_contains "$output" "(dry) would record step marker"
  t1r_no_step_markers
  t1r_esp_unchanged
}

@test "regenerate: a full dry run never opens /proc/acpi/call and prints the FRST write" {
  t1r_fake_esp; regen_load
  t1r_run cmd_regenerate
  assert_status 0
  assert_contains "$output" "(dry) printf '%s' \\_SB.PCI0.XHC1.RHUB.ASOC.FRST > /proc/acpi/call"
  refute_contains "$output" "FRST returned"
}

@test "regenerate: a full dry run runs no patched-stack binary except the version probes" {
  t1r_fake_esp; regen_load
  t1r_run cmd_regenerate
  assert_status 0
  # check_idevicerestore runs `idevicerestore --version`; nothing else may reach the stack.
  local line
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    [[ $line == "idevicerestore --version" ]] || {
      echo "unexpected call to the patched stack: $line" >&2; return 1; }
  done <<<"$(t1r_calls)"
}

@test "regenerate: a full dry run labels all seven steps, resets once per reset step, previews stage once" {
  regen_load
  t1r_run cmd_regenerate
  assert_status 0
  assert_contains "$output" "==== plan"
  assert_contains "$output" "regenerate will:"
  for s in "step 1/7" "step 2/7 · reset" "step 3/7" "step 4/7 · reset" "step 5/7" "step 6/7" "step 7/7"; do
    assert_contains "$output" "$s"
  done
  # the dry T1 never leaves 'booted': the guard must not print a second reset before each step
  assert_eq 2 "$(grep -c '^==== reset: ' <<<"$output")"
  assert_eq 1 "$(grep -c '^==== stage: staging' <<<"$output")"
}

@test "regenerate: --from stage skips the earlier steps" {
  t1r_fake_esp; t1r_step_marker boot; regen_load
  t1r_run cmd_regenerate --from stage
  assert_status 0
  assert_contains "$(t1r_diag_lines)" "step=chain result=start from=stage"
  refute_contains "$output" "step 1/7"
  assert_contains "$output" "step 6/7"
}

@test "regenerate: the timing summary prints one line per step plus a total" {
  t1r_fake_esp; regen_load
  t1r_run cmd_regenerate
  assert_status 0
  local step
  for step in provision reset-1 personalize reset-2 boot stage handover total; do
    printf '%s\n' "$output" | grep -qE "^ +$step +[0-9]+ s" || {
      echo "no timing line for $step" >&2; printf '%s\n' "$output" | tail -20 >&2; return 1; }
  done
}

# --- the fallback text ---------------------------------------------------------------------
@test "fallback_text: names the resume command for the step" {
  regen_load
  assert_eq "Fallback: full shutdown, wait 20 s, power on, then: t1-revive regenerate --from boot" \
    "$(fallback_text boot)"
  assert_contains "$(fallback_text reset-2)" "t1-revive regenerate --from reset-2"
}

@test "_regen_fail: dies 5 and spells out the resume command" {
  regen_load
  t1r_need _regen_fail
  t1r_run _regen_fail personalize "personalize failed (see the log)"
  assert_status 5
  assert_contains "$output" "STOPPED"
  assert_contains "$output" "personalize failed"
  assert_contains "$output" "t1-revive regenerate --from personalize"
}

@test "sourcing lib/cmd-regenerate.sh has no side effects" {
  t1r_run bash -c '. "$T1R_ROOT/lib/common.sh"; . "$T1R_ROOT/lib/discover.sh"
               . "$T1R_ROOT/lib/cmd-regenerate.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}
