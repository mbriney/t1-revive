#!/usr/bin/env bats
# Repository hygiene: syntax, side-effect-free libraries, executable bits.

load test_helper/common

setup() { t1r_env; }

@test "bash -n passes on every shell file" {
  local rc=0 f
  while IFS= read -r f; do
    bash -n "$f" || { echo "syntax error: $f" >&2; rc=1; }
  done < <(cd "$T1R_REPO" && { ls bin/t1-revive build.sh .githooks/pre-commit 2>/dev/null; find lib tools contrib test -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null; })
  return $rc
}

@test "every lib/**/*.sh sources without output or exit" {
  [[ -f $T1R_REPO/lib/common.sh ]] || skip "lib/common.sh not present"
  local rc=0 f out
  while IFS= read -r f; do
    out=$(cd "$T1R_REPO" && bash -c 'source lib/common.sh; source lib/discover.sh 2>/dev/null; source "$1" && echo __ok__' _ "$f" 2>&1)
    [[ $out == "__ok__" ]] || { printf 'side effect or failure sourcing %s:\n%s\n' "$f" "$out" >&2; rc=1; }
  done < <(cd "$T1R_REPO" && find lib -type f -name '*.sh' | sort)
  return $rc
}

@test "no file in the tree uses the banned ACPI method name (AGENTS.md exempt)" {
  run bash "$T1R_REPO/tools/scan-identifiers.sh" --banned-only
  assert_status 0
}

@test "scripts in bin/ and tools/ are executable" {
  local rc=0 f
  for f in "$T1R_REPO"/bin/* "$T1R_REPO"/tools/*.sh "$T1R_REPO"/tools/*.py; do
    [[ -e $f ]] || continue
    [[ -x $f ]] || { echo "not executable: ${f#"$T1R_REPO"/}" >&2; rc=1; }
  done
  return $rc
}
