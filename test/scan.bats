#!/usr/bin/env bats
# tools/scan-identifiers.sh: self-test, a planted forbidden line, allowlist behaviour.

load test_helper/common

setup() {
  t1r_env
  SCAN=$T1R_REPO/tools/scan-identifiers.sh
  [[ -f $SCAN ]] || skip "tools/scan-identifiers.sh not present"
}

@test "scanner self-test passes" {
  run bash "$SCAN" --self-test
  assert_status 0
}

@test "a planted banned ACPI method name fails, even in a comment" {
  local d=$T1R_TMP/tree
  mkdir -p "$d"
  printf 'x=1  # do not call SO%s\n' CW >"$d/a.sh"
  printf 'clean\n' >"$d/b.txt"
  run bash "$SCAN" "$d"
  assert_status 1
  assert_contains "$output" "a.sh:1:"
  assert_contains "$output" "[banned]"
}

@test "a planted hex identifier fails; a clean tree passes" {
  local d=$T1R_TMP/tree h
  mkdir -p "$d"
  h=$(printf '%s%s' 0123456789 abcdef)
  printf 'ok line\n' >"$d/clean.md"
  run bash "$SCAN" "$d"
  assert_status 0
  printf 'ECID=%s\n' "$h" >"$d/leak.txt"
  run bash "$SCAN" "$d"
  assert_status 1
  assert_contains "$output" "leak.txt:1:"
}

@test "allowlist suppresses a matching line only in matching paths" {
  local d=$T1R_TMP/tree h sha
  mkdir -p "$d"
  h=$(printf '%s%s' 0123456789 abcdef)
  sha=$(printf '%s' "$h$h$h$h" | cut -c1-64)
  printf '%s  pkg.tar.xz\n' "$sha" >"$d/x.sha256"
  printf '%s\t%s\t%s\n' '*.sha256' '^[0-9a-f]{64}[ \t]' 'test' >"$T1R_TMP/allow"
  run bash "$SCAN" --allowlist "$T1R_TMP/allow" "$d"
  assert_status 0
  printf '%s  pkg.tar.xz\n' "$sha" >"$d/notes.txt"
  run bash "$SCAN" --allowlist "$T1R_TMP/allow" "$d"
  assert_status 1
  assert_contains "$output" "notes.txt:1:"
}

@test "the repository itself is clean" {
  run bash "$SCAN"
  assert_status 0
}

@test "--banned-only reports nothing on the repository" {
  run bash "$SCAN" --banned-only
  assert_status 0
}

# --- staged mode and the pre-commit hook ------------------------------------------------
# Both run in a throw-away git repository under $T1R_TMP; nothing is ever committed
# in the real work tree.
t1r_fake_repo() {   # t1r_fake_repo DIR: a git repo carrying a copy of the scanner and the hook
  local d=$1
  mkdir -p "$d/tools" "$d/.githooks"
  cp "$T1R_REPO/tools/scan-identifiers.sh" "$d/tools/"
  cp "$T1R_REPO/tools/scan-allowlist.txt" "$d/tools/"
  cp "$T1R_REPO/.githooks/pre-commit" "$d/.githooks/"
  git -C "$d" init -q
  git -C "$d" config user.email t1r@example.invalid
  git -C "$d" config user.name t1r
}

@test "--staged scans the index, not the work tree" {
  local d=$T1R_TMP/repo h
  t1r_fake_repo "$d"
  h=$(printf '%s%s' 0123456789 abcdef)
  printf 'clean\n' >"$d/note.txt"
  git -C "$d" add note.txt
  run bash -c "cd '$d' && bash tools/scan-identifiers.sh --staged"
  assert_status 0
  # dirty in the work tree but not staged: --staged stays quiet
  printf 'ECID=%s\n' "$h" >"$d/note.txt"
  run bash -c "cd '$d' && bash tools/scan-identifiers.sh --staged"
  assert_status 0
  # once staged, it is caught
  git -C "$d" add note.txt
  run bash -c "cd '$d' && bash tools/scan-identifiers.sh --staged"
  assert_status 1
  assert_contains "$output" "note.txt:1:"
}

@test "pre-commit hook refuses a staged identifier and a staged syntax error" {
  local d=$T1R_TMP/hookrepo h
  t1r_fake_repo "$d"
  printf 'echo ok\n' >"$d/good.sh"
  git -C "$d" add good.sh
  run bash -c "cd '$d' && bash .githooks/pre-commit"
  assert_status 0

  h=$(printf '%s%s' 0123456789 abcdef)
  printf 'ECID=%s\n' "$h" >"$d/leak.txt"
  git -C "$d" add leak.txt
  run bash -c "cd '$d' && bash .githooks/pre-commit"
  assert_status 1
  assert_contains "$output" "leak.txt:1:"
  git -C "$d" rm -q --cached leak.txt

  printf '#!/usr/bin/env bash\nif true; then\n' >"$d/broken.sh"
  git -C "$d" add broken.sh
  run bash -c "cd '$d' && bash .githooks/pre-commit"
  assert_status 1
  assert_contains "$output" "broken.sh"
}

@test "make hooks points core.hooksPath at .githooks" {
  local d=$T1R_TMP/hooksmake
  t1r_fake_repo "$d"
  cp "$T1R_REPO/Makefile" "$d/Makefile"
  run make -C "$d" hooks
  assert_status 0
  assert_eq ".githooks" "$(git -C "$d" config core.hooksPath)"
}

@test "pre-commit hook accepts a staged .bats file and rejects an unparsable one" {
  local d=$T1R_TMP/batsrepo
  t1r_fake_repo "$d"
  mkdir -p "$d/test/test_helper"
  printf '# helper\n' >"$d/test/test_helper/common.bash"
  printf 'load test_helper/common\n\n@test "x" {\n  true\n}\n' >"$d/test/a.bats"
  git -C "$d" add test
  run bash -c "cd '$d' && bash .githooks/pre-commit"
  assert_status 0

  printf 'load test_helper/common\n\n@test "y" {\n  if true; then\n}\n' >"$d/test/a.bats"
  git -C "$d" add test/a.bats
  run bash -c "cd '$d' && bash .githooks/pre-commit"
  if command -v bats >/dev/null 2>&1; then
    assert_status 1
  else
    skip "bats not installed: the hook skips the .bats parse check"
  fi
}
