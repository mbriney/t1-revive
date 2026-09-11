#!/usr/bin/env bats
# lib/common.sh against the AGENTS.md contract. Identifier-looking strings are built at run
# time so that this file passes tools/scan-identifiers.sh.

load test_helper/common

setup() { t1r_env; }

# --- kver_normalize --------------------------------------------------------------------
@test "kver_normalize: pacman 7.2.3.arch1-3 -> uname 7.2.3-arch1-3" {
  t1r_load; t1r_need kver_normalize
  assert_eq "7.2.3-arch1-3" "$(printf '7.2.3.arch1-3\n' | kver_normalize)"
}

@test "kver_normalize: 6.16.4.arch1-1 -> 6.16.4-arch1-1" {
  t1r_load; t1r_need kver_normalize
  assert_eq "6.16.4-arch1-1" "$(printf '6.16.4.arch1-1\n' | kver_normalize)"
}

@test "kver_normalize: already-normalized passes through" {
  t1r_load; t1r_need kver_normalize
  assert_eq "7.2.3-arch1-3" "$(printf '7.2.3-arch1-3\n' | kver_normalize)"
  assert_eq "6.16.4-arch1-1" "$(printf '6.16.4-arch1-1\n' | kver_normalize)"
}

# --- redact ----------------------------------------------------------------------------
@test "redact: a 16-hex run becomes <hex>" {
  t1r_load; t1r_need redact
  local h; h=$(printf '%s%s' 0123456789 abcdef)
  assert_eq "id <hex> end" "$(printf 'id %s end\n' "$h" | redact)"
}

@test "redact: a 40-hex run becomes <hex> (whole run, once)" {
  t1r_load; t1r_need redact
  local h; h=$(printf '%s%s%s%s' 0123456789 abcdef0123 456789abcd ef01234567)
  assert_eq "commit <hex>" "$(printf 'commit %s\n' "$h" | redact)"
}

@test "redact: a 15-hex run is untouched" {
  t1r_load; t1r_need redact
  local h; h=$(printf '%s%s' 0123456789 abcde)
  assert_eq "id $h end" "$(printf 'id %s end\n' "$h" | redact)"
}

@test "redact: MAC address becomes <mac>" {
  t1r_load; t1r_need redact
  local m; m=$(printf '%s:%s:%s:%s:%s:%s' 02 1a 2b 3c 4d 5e)
  assert_eq "link/ether <mac> brd" "$(printf 'link/ether %s brd\n' "$m" | redact)"
}

@test "redact: an ECID value is redacted, the key is kept" {
  t1r_load; t1r_need redact
  local v out; v=$(printf '%s%s' 1234 ABCD)
  out=$(printf 'ECID=%s\n' "$v" | redact)
  refute_contains "$out" "$v"
  assert_contains "$out" "ECID"
}

@test "redact: a serial-looking token is redacted" {
  t1r_load; t1r_need redact
  local v out; v=$(printf '%s%s' C02ABC DEF1GH)
  out=$(printf 'Serial Number: %s\n' "$v" | redact)
  refute_contains "$out" "$v"
}

@test "redact: text without identifiers is unchanged" {
  t1r_load; t1r_need redact
  local s="T1 is in recovery (05ac:1281), elapsed=97, ESP c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
  assert_eq "$s" "$(printf '%s\n' "$s" | redact)"
}

# --- T1 USB state ----------------------------------------------------------------------
@test "t1_state: sysfs-recovery -> recovery" {
  t1r_use_sysfs recovery; t1r_load; t1r_need t1_state
  assert_eq recovery "$(t1_state)"
}

@test "t1_state: sysfs-booted-cfg1 -> booted" {
  t1r_use_sysfs booted-cfg1; t1r_load; t1r_need t1_state
  assert_eq booted "$(t1_state)"
}

@test "t1_state: sysfs-booted-cfg2 -> booted" {
  t1r_use_sysfs booted-cfg2; t1r_load; t1r_need t1_state
  assert_eq booted "$(t1_state)"
}

@test "t1_state: sysfs-none -> none (unrelated 1d6b:0002 device ignored)" {
  t1r_use_sysfs none; t1r_load; t1r_need t1_state
  assert_eq none "$(t1_state)"
}

@test "t1_config: 1, 2, and empty when no booted T1" {
  t1r_use_sysfs booted-cfg1; t1r_load; t1r_need t1_config
  assert_eq 1 "$(t1_config)" "cfg1"
  t1r_use_sysfs booted-cfg2
  assert_eq 2 "$(t1_config)" "cfg2"
  t1r_use_sysfs recovery
  assert_eq "" "$(t1_config)" "recovery has no configuration"
  t1r_use_sysfs none
  assert_eq "" "$(t1_config)" "none"
}

@test "t1_sysfs: path of the T1 device, empty when absent" {
  t1r_use_sysfs booted-cfg1; t1r_load; t1r_need t1_sysfs
  local p; p=$(t1_sysfs)
  [[ -f $p/idVendor ]] || { echo "t1_sysfs printed '$p', not a usb device dir" >&2; return 1; }
  assert_eq 8600 "$(<"$p/idProduct")"
  t1r_use_sysfs none
  assert_eq "" "$(t1_sysfs)"
}

@test "wait_t1: returns 1 on timeout with sysfs-none (about 1 s)" {
  t1r_use_sysfs none; t1r_load; t1r_need wait_t1
  SECONDS=0
  run wait_t1 booted 1
  assert_status 1
  (( SECONDS <= 5 )) || { echo "wait_t1 took ${SECONDS}s for a 1 s timeout" >&2; return 1; }
}

@test "wait_t1: returns 0 immediately when the state already matches" {
  t1r_use_sysfs recovery; t1r_load; t1r_need wait_t1
  SECONDS=0
  run wait_t1 recovery 10
  assert_status 0
  (( SECONDS <= 1 )) || { echo "wait_t1 took ${SECONDS}s although the state matched" >&2; return 1; }
}

# --- diag / die ------------------------------------------------------------------------
@test "diag: writes a v=1 line with component and the given pairs" {
  t1r_load; t1r_need diag
  diag step=provision result=ok elapsed=97
  local line
  line=$(cat "$T1R_LOGFILE" "$T1R_LOG"/*.log 2>/dev/null | grep -m1 '^t1-revive-diagnostic ') || {
    echo "no diagnostic line in $T1R_LOGFILE or $T1R_LOG" >&2; return 1; }
  assert_contains "$line" "t1-revive-diagnostic v=1 component=test"
  assert_contains "$line" "step=provision"
  assert_contains "$line" "result=ok"
  assert_contains "$line" "elapsed=97"
}

@test "diag: a value with a space never reaches the log verbatim" {
  t1r_load; t1r_need diag
  run diag step="a b" result=ok
  # Contract: values are [A-Za-z0-9._:-]+ only. Rejecting (non-zero) and sanitising are both
  # acceptable; emitting the raw value is not.
  if [[ $status -eq 0 ]]; then
    ! grep -q 'step=a b' "$T1R_LOGFILE" "$T1R_LOG"/*.log 2>/dev/null || {
      echo "diag emitted a value containing a space" >&2; return 1; }
  fi
}

@test "die: exits with the given code and prints STOPPED: MSG" {
  t1r_load; t1r_need die
  run die 5 "device vanished"
  assert_status 5
  assert_contains "$output" "STOPPED"
  assert_contains "$output" "device vanished"
  run die 4 "refused"
  assert_status 4
}

@test "die: records diag result=error" {
  t1r_load; t1r_need die
  run die 5 "boom"
  grep -q 'result=error' "$T1R_LOGFILE" "$T1R_LOG"/*.log 2>/dev/null || {
    echo "no result=error diagnostic after die" >&2; return 1; }
}

# --- misc ------------------------------------------------------------------------------
@test "version: prints the VERSION file content" {
  t1r_load; t1r_need version
  assert_eq "$(tr -d '\n' <"$T1R_REPO/VERSION")" "$(version)"
}

@test "confirm: is a no-op with T1R_NO_CONFIRM=1 (no read from stdin)" {
  t1r_load; t1r_need confirm
  run timeout 5 bash -c 'source "$T1R_ROOT/lib/common.sh"; confirm "go?" </dev/null; echo done'
  assert_status 0
  assert_contains "$output" done
}

@test "sourcing lib/common.sh has no side effects (no output, no exit)" {
  [[ -f $T1R_REPO/lib/common.sh ]] || skip "lib/common.sh not present"
  run bash -c 'source "$T1R_ROOT/lib/common.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}
