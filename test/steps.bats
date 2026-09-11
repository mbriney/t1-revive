#!/usr/bin/env bats
# lib/steps/reset.sh and the step bookkeeping in lib/steps/common-steps.sh.
#
# step_reset is the only function in the tree that writes to /proc/acpi/call. Every test here
# runs it with T1R_DRY_RUN=1, and the tests assert that the path is only ever printed, never
# opened. frst_method is stubbed AFTER sourcing so no ACPI table is read either.
#
# Note: lib/steps/common-steps.sh defines a function called `run`, which shadows bats' own
# `run` helper; the suite keeps a copy of it as t1r_run (see test/test_helper/common.bash).

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/steps/reset.sh ]] || skip "lib/steps/reset.sh not present"
  t1r_use_sysfs recovery
}

steps_load() {
  t1r_load discover steps/common-steps steps/reset
  t1r_need step_reset run_step step_done step_marker_dir timing_summary
}

T1R_TEST_FRST='\_SB.PCI0.XHC1.RHUB.ASOC.FRST'

# --- step_reset: the method path gate ------------------------------------------------------
@test "step_reset: refuses a method path that does not end in .FRST" {
  steps_load
  frst_method() { printf '%s\n' '\_SB.PCI0.XHC1.RHUB.ASOC.RSET'; }
  t1r_run step_reset
  assert_status 4
  assert_contains "$output" "unexpected reset method name"
  refute_contains "$output" "(dry) printf"
}

@test "step_reset: refuses an empty method rather than guessing" {
  steps_load
  frst_method() { printf '\n'; }
  t1r_run step_reset
  assert_status 4
  assert_contains "$output" "refusing to guess"
}

@test "step_reset: refuses a bare method name with no ACPI path" {
  steps_load
  frst_method() { printf '%s\n' 'FRSTISH'; }
  t1r_run step_reset
  assert_status 4
  assert_contains "$output" "unexpected reset method name"
}

# --- step_reset: the dry run ---------------------------------------------------------------
@test "step_reset: a dry run prints the /proc/acpi/call write and opens nothing" {
  steps_load
  frst_method() { printf '%s\n' "$T1R_TEST_FRST"; }
  t1r_run step_reset
  assert_status 0
  assert_contains "$output" "(dry) printf '%s' $T1R_TEST_FRST > /proc/acpi/call"
  # the read-back and the settle only happen in a real run
  refute_contains "$output" "FRST returned"
  assert_contains "$output" "(dry) read the result back from /proc/acpi/call"
  assert_contains "$output" "(dry) sleep 12"
  # every mention of the acpi_call interface must be inside a "(dry)" trace line
  local line
  while IFS= read -r line; do
    [[ $line == *"/proc/acpi/call"* ]] || continue
    [[ $line == *"(dry)"* ]] || { echo "not a dry-run line: $line" >&2; return 1; }
  done <<<"$output"
}

@test "step_reset: a dry run touches neither usbmuxd nor acpi_call for real" {
  steps_load
  frst_method() { printf '%s\n' "$T1R_TEST_FRST"; }
  t1r_run step_reset
  assert_status 0
  assert_contains "$output" "(dry) systemctl stop t1-usbmuxd.service"
  assert_contains "$output" "(dry) modprobe acpi_call"
  assert_contains "$output" "(dry) wait up to 60 s for T1 state recovery"
}

# --- run_step: markers, diagnostics, timing ------------------------------------------------
@test "run_step: a successful step records its marker and diag result=ok" {
  export T1R_DRY_RUN=0
  steps_load
  t1r_step_ok() { note "the step ran"; return 0; }
  t1r_run run_step demo-ok t1r_step_ok "doing the thing"
  assert_status 0
  assert_contains "$output" "doing the thing"
  [[ -f $T1R_STATE/private/steps/demo-ok.done ]] || {
    echo "no marker at $T1R_STATE/private/steps/demo-ok.done" >&2; return 1; }
  local diag; diag=$(t1r_diag_lines)
  assert_contains "$diag" "step=demo-ok result=start"
  assert_contains "$diag" "step=demo-ok result=ok"
}

@test "run_step: a failing step records no marker and diags result=error with the code" {
  export T1R_DRY_RUN=0
  steps_load
  t1r_step_bad() { note "the step failed"; return 3; }
  t1r_run run_step demo-bad t1r_step_bad "doing the thing"
  assert_status 3
  [[ ! -e $T1R_STATE/private/steps/demo-bad.done ]] || {
    echo "a failing step left a marker behind" >&2; return 1; }
  local diag; diag=$(t1r_diag_lines)
  assert_contains "$diag" "step=demo-bad result=error"
  assert_contains "$diag" "code=3"
  assert_contains "$diag" "t1=recovery"
}

@test "run_step: a dry run records no marker at all" {
  steps_load
  t1r_step_ok() { return 0; }
  t1r_run run_step demo-dry t1r_step_ok
  assert_status 0
  assert_contains "$output" "(dry) would record step marker demo-dry.done"
  t1r_no_step_markers
}

@test "step_done: false before the step, true after it" {
  export T1R_DRY_RUN=0
  steps_load
  t1r_run step_done demo-two
  assert_status 1
  t1r_step_ok() { return 0; }
  run_step demo-two t1r_step_ok >/dev/null 2>&1
  t1r_run step_done demo-two
  assert_status 0
}

@test "step_marker_dir: is private/steps under the state directory" {
  steps_load
  assert_eq "$T1R_STATE/private/steps" "$(step_marker_dir)"
}

@test "timing_summary: one line per step plus a total, and nothing when no step ran" {
  export T1R_DRY_RUN=0
  steps_load
  t1r_run timing_summary
  assert_status 0
  assert_eq "" "$output" "no steps ran yet"
  t1r_step_ok() { return 0; }
  t1r_step_bad() { return 1; }
  run_step first t1r_step_ok >/dev/null 2>&1
  run_step second t1r_step_bad >/dev/null 2>&1 || true
  t1r_run timing_summary
  assert_status 0
  local n
  n=$(printf '%s\n' "$output" | grep -cE '^ +(first|second|total) +[0-9]+ s')
  assert_eq 3 "$n" "one line per step plus the total"
  assert_contains "$output" "min"
}

@test "sourcing lib/steps/*.sh has no side effects" {
  local f rc=0 out
  for f in "$T1R_REPO"/lib/steps/*.sh; do
    out=$(bash -c '. "$T1R_ROOT/lib/common.sh"; . "$T1R_ROOT/lib/discover.sh"
                   . "$T1R_ROOT/lib/steps/common-steps.sh"; . "$1" && echo __ok__' _ "$f" 2>&1)
    [[ $out == "__ok__" ]] || { printf 'side effect sourcing %s:\n%s\n' "$f" "$out" >&2; rc=1; }
  done
  return $rc
}
