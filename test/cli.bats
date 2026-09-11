#!/usr/bin/env bats
# bin/t1-revive dispatcher: help, version, usage errors. Nothing here needs root or a device.

load test_helper/common

setup() {
  t1r_env
  CLI=$T1R_REPO/bin/t1-revive
  [[ -f $CLI ]] || skip "bin/t1-revive not present"
}

@test "help: exit 0 and mentions every subcommand" {
  run bash "$CLI" help
  assert_status 0
  local sub
  for sub in preflight backup status regenerate stage handover report version help; do
    assert_contains "$output" "$sub"
  done
}

@test "help: --help and no arguments also print usage" {
  run bash "$CLI" --help
  assert_status 0
  assert_contains "$output" regenerate
  run bash "$CLI"
  assert_contains "$output" regenerate
  [[ $status -eq 0 || $status -eq 2 ]] || { echo "exit $status" >&2; return 1; }
}

@test "unknown subcommand: exit 2" {
  run bash "$CLI" frobnicate
  assert_status 2
}

@test "version: prints the VERSION file content" {
  run bash "$CLI" version
  assert_status 0
  assert_eq "$(tr -d '\n' <"$T1R_REPO/VERSION")" "$output"
}

@test "dispatcher is executable and has a bash shebang" {
  [[ -x $CLI ]] || { echo "bin/t1-revive is not executable" >&2; return 1; }
  head -1 "$CLI" | grep -q bash
}

@test "help lists every cmd_* subcommand that lib/ actually implements" {
  local subs sub missing=''
  subs=$(grep -rhoE '^[[:space:]]*(function[[:space:]]+)?cmd_[a-z0-9_]+[[:space:]]*\(\)' \
    "$T1R_REPO"/lib 2>/dev/null | grep -oE 'cmd_[a-z0-9_]+' | sed 's/^cmd_//;s/_/-/g' | sort -u)
  [[ -n $subs ]] || skip "no cmd_* functions in lib/ yet"
  run bash "$CLI" help
  assert_status 0
  for sub in $subs; do
    [[ $output == *"$sub"* ]] || missing+=" $sub"
  done
  [[ -z $missing ]] || { echo "help does not mention:$missing" >&2; echo "--- help ---"; echo "$output" >&2; return 1; }
}

@test "every subcommand in help has a cmd_* implementation" {
  local sub missing=''
  run bash "$CLI" help
  assert_status 0
  for sub in preflight backup status regenerate stage handover report; do
    grep -rqE "(function[[:space:]]+)?cmd_${sub//-/_}[[:space:]]*\(\)" "$T1R_REPO"/lib || missing+=" $sub"
  done
  [[ -z $missing ]] || { echo "help offers subcommands with no cmd_* function:$missing" >&2; return 1; }
}
