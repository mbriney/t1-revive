#!/usr/bin/env bats
# tools/relocate-prefix.sh: a copy of the built prefix runs from somewhere else and carries
# no build path (issue #1). The synthetic tree tests need patchelf but no ELF file; the last
# two use the real prefix/ when build.sh has produced one, and are skipped otherwise.

load test_helper/common

setup() {
  t1r_env
  REL=$T1R_REPO/tools/relocate-prefix.sh
  [[ -f $REL ]] || skip "tools/relocate-prefix.sh not present"
  command -v patchelf >/dev/null || skip "patchelf not installed"
  BUILD=/tmp/synthetic-build-tree/prefix
}

# a prefix as libtool leaves it, minus the binaries: text files that spell the build path out
synthetic_prefix() {
  local p=$T1R_TMP/prefix
  mkdir -p "$p/bin" "$p/lib/pkgconfig" "$p/lib/udev/rules.d" "$p/include/x" "$p/share/man/man1"
  printf 'prefix=%s\nlibdir=${prefix}/lib\n' "$BUILD" >"$p/lib/pkgconfig/libx.pc"
  printf 'RUN+="%s/sbin/usbmuxd -x"\n' "$BUILD" >"$p/lib/udev/rules.d/39-usbmuxd.rules"
  printf "libdir='%s/lib'\n" "$BUILD" >"$p/lib/libx.la"
  printf 'not really an archive\n' >"$p/lib/libx.a"
  printf 'int x;\n' >"$p/include/x/x.h"
  printf '.TH X 1\n' >"$p/share/man/man1/x.1"
  printf '%s' "$p"
}

@test "relocate: rewrites the text files, deletes *.la and *.a, and leaves no build path" {
  local p; p=$(synthetic_prefix)
  run bash "$REL" "$p" --from "$BUILD" --to /usr/lib/t1-revive/prefix
  assert_status 0
  assert_contains "$(cat "$p/lib/pkgconfig/libx.pc")" "prefix=/usr/lib/t1-revive/prefix"
  assert_contains "$(cat "$p/lib/udev/rules.d/39-usbmuxd.rules")" "/usr/lib/t1-revive/prefix/sbin/usbmuxd"
  [[ ! -e $p/lib/libx.la ]] && [[ ! -e $p/lib/libx.a ]]
  [[ -e $p/include/x/x.h ]] && [[ -e $p/share/man/man1/x.1 ]]   # kept without --strip-dev
  assert_eq "" "$(grep -rl "$BUILD" "$p" || true)" "build path left behind"
}

@test "relocate: --strip-dev drops headers, man pages and pkg-config" {
  local p; p=$(synthetic_prefix)
  run bash "$REL" "$p" --from "$BUILD" --to /usr/local/lib/t1-revive/prefix --origin --strip-dev
  assert_status 0
  [[ ! -e $p/include ]] && [[ ! -e $p/share/man ]] && [[ ! -e $p/lib/pkgconfig ]]
  assert_contains "$(cat "$p/lib/udev/rules.d/39-usbmuxd.rules")" "/usr/local/lib/t1-revive/prefix/sbin/usbmuxd"
}

@test "relocate: refuses when a file still spells the build path out" {
  local p; p=$(synthetic_prefix)
  printf 'built at %s\n' "$BUILD" >"$p/bin/NOTES.txt"
  run bash "$REL" "$p" --from "$BUILD" --to /usr/lib/t1-revive/prefix
  assert_status 1
  assert_contains "$output" "REFUSING"
  assert_contains "$output" "NOTES.txt"
}

@test "relocate: needs a PREFIX and --to; --from is required when no binary tells the build path" {
  local p; p=$(synthetic_prefix)
  run bash "$REL" "$p"
  assert_status 2
  run bash "$REL" --to /x
  assert_status 2
  run bash "$REL" "$p" --to /usr/lib/t1-revive/prefix
  assert_status 1
  assert_contains "$output" "pass --from"
}

# --- the real prefix, when built --------------------------------------------------------------
real_prefix_copy() {
  [[ -x $T1R_REPO/prefix/bin/irecovery ]] || skip "prefix/ not built (run build.sh)"
  # not $T1R_TMP/prefix: t1r_env already created that one (the stub toolchain directory)
  cp -a -- "$T1R_REPO/prefix" "$T1R_TMP/relocated"
  printf '%s' "$T1R_TMP/relocated"
}

@test "relocate: --origin makes the real binaries run from a copy with no LD_LIBRARY_PATH" {
  local p; p=$(real_prefix_copy)
  run bash "$REL" "$p" --to /usr/local/lib/t1-revive/prefix --origin --strip-dev
  assert_status 0
  assert_contains "$output" 'RUNPATH $ORIGIN/../lib:$ORIGIN'
  assert_eq "" "$(grep -rlI --binary-files=text "$T1R_REPO/prefix" "$p" || true)" "build path left behind"
  # the copy, from its own directory, without the build tree's libraries
  run env -u LD_LIBRARY_PATH "$p/bin/irecovery" --version
  assert_status 0
  run env -u LD_LIBRARY_PATH "$p/bin/idevicerestore" --version
  assert_status 0
  run env -u LD_LIBRARY_PATH "$p/sbin/usbmuxd" --version
  assert_status 0
}

@test "relocate: the build prefix is read from the RUNPATH when --from is not given" {
  local p; p=$(real_prefix_copy)
  run bash "$REL" "$p" --to /usr/lib/t1-revive/prefix
  assert_status 0
  assert_eq "/usr/lib/t1-revive/prefix/lib" "$(patchelf --print-rpath "$p/bin/irecovery")"
  assert_eq "" "$(grep -rlI --binary-files=text "$T1R_REPO/prefix" "$p" || true)" "build path left behind"
}
