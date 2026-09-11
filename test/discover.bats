#!/usr/bin/env bats
# lib/discover.sh against the AGENTS.md contract, with synthetic DMI and lsblk fixtures.

load test_helper/common

setup() { t1r_env; }

@test "model_id: MacBookPro14,3 from dmi-14_3" {
  t1r_use_dmi 14_3; t1r_load discover; t1r_need model_id
  assert_eq "MacBookPro14,3" "$(model_id)"
}

@test "model_id: MacBookPro13,2 from dmi-13_2 and 'Not a Mac' from dmi-other" {
  t1r_use_dmi 13_2; t1r_load discover; t1r_need model_id
  assert_eq "MacBookPro13,2" "$(model_id)"
  t1r_use_dmi other
  assert_eq "Not a Mac" "$(model_id)"
}

@test "model_status: MacBookPro14,3 -> tested" {
  t1r_load discover; t1r_need model_status
  assert_eq tested "$(model_status MacBookPro14,3)"
}

@test "model_status: MacBookPro13,2 -> untested" {
  t1r_load discover; t1r_need model_status
  assert_eq untested "$(model_status MacBookPro13,2)"
}

@test "model_status: MacBookPro13,3 and MacBookPro14,2 -> untested" {
  t1r_load discover; t1r_need model_status
  assert_eq untested "$(model_status MacBookPro13,3)"
  assert_eq untested "$(model_status MacBookPro14,2)"
}

@test "model_status: MacBookPro15,1 (T2) -> unsupported" {
  t1r_load discover; t1r_need model_status
  assert_eq unsupported "$(model_status MacBookPro15,1)"
}

@test "model_status: 'Not a Mac' -> unsupported" {
  t1r_load discover; t1r_need model_status
  assert_eq unsupported "$(model_status "Not a Mac")"
}

@test "esp_candidates: one ESP -> one line with /dev/sdz1" {
  t1r_use_lsblk one-esp; t1r_load discover; t1r_need esp_candidates
  local out; out=$(esp_candidates)
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "line count"
  assert_contains "$out" "/dev/sdz1"
  refute_contains "$out" "/dev/sdz2"
}

@test "esp_candidates: two ESPs -> two lines, three columns each" {
  t1r_use_lsblk two-esp; t1r_load discover; t1r_need esp_candidates
  local out; out=$(esp_candidates)
  assert_eq 2 "$(printf '%s\n' "$out" | grep -c .)" "line count"
  assert_contains "$out" "/dev/sdz1"
  assert_contains "$out" "/dev/sdy1"
  while read -r dev mp has; do
    [[ -n $dev && -n $mp && -n $has ]] || { echo "bad line: '$dev $mp $has'" >&2; return 1; }
  done <<<"$out"
}

@test "esp_candidates: no ESP -> no output" {
  t1r_use_lsblk no-esp; t1r_load discover; t1r_need esp_candidates
  assert_eq "" "$(esp_candidates)"
}

@test "esp_select: one ESP -> selected" {
  t1r_use_lsblk one-esp; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 0
  [[ $output == /dev/sdz1\ * || $output == /dev/sdz1 ]] || { echo "got: $output" >&2; return 1; }
}

@test "esp_select: two ESPs, neither distinguished -> returns 1" {
  t1r_use_lsblk two-esp; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 1
}

@test "esp_select: two ESPs, one has EFI/APPLE -> that one" {
  t1r_load discover; t1r_need esp_select
  local mnt=$T1R_TMP/esp2
  mkdir -p "$mnt/EFI/APPLE"
  sed "s|@ESP_MNT@|$mnt|" "$T1R_FIXTURES/lsblk-two-esp-apple.json.tmpl" >"$T1R_TMP/lsblk.json"
  export T1R_LSBLK_JSON=$T1R_TMP/lsblk.json
  run esp_select
  assert_status 0
  assert_contains "$output" "/dev/sdy1"
}

@test "esp_select: two ESPs, one mounted at /boot -> that one" {
  t1r_use_lsblk two-esp-boot; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 0
  assert_contains "$output" "/dev/sdz1"
}

@test "esp_select: no ESP -> returns 1" {
  t1r_use_lsblk no-esp; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 1
}

@test "frst_method: empty (not an error) when there are no ACPI tables" {
  t1r_load discover; t1r_need frst_method
  run frst_method
  assert_eq "" "$output"
}

@test "sourcing lib/discover.sh has no side effects" {
  [[ -f $T1R_REPO/lib/discover.sh ]] || skip "lib/discover.sh not present"
  run bash -c 'source "$T1R_ROOT/lib/common.sh"; source "$T1R_ROOT/lib/discover.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}
