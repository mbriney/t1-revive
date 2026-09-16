#!/usr/bin/env bash
# tools/relocate-prefix.sh - make a copy of the built prefix run from somewhere else.
#
#   bash tools/relocate-prefix.sh PREFIX --to INSTALL_PREFIX [--from BUILD_PREFIX] [--origin] [--strip-dev]
#
# build.sh (libtool, really) bakes the build machine's absolute prefix into every binary and
# shared library (the ELF RUNPATH), into lib/pkgconfig/*.pc, into the udev rule under
# lib/udev/rules.d and into the libtool *.la files. A copy of that tree only runs from the
# path it was built at, and the identifier scan refuses to pack it (it carries a home
# directory). This script rewrites a copy in place:
#
#   *.la and *.a          deleted (build-time only; they carry the build path)
#   ELF files             stripped (--strip-unneeded): the DWARF line tables of an unstripped
#                         build spell the build tree's include directories out
#   ELF RUNPATH           INSTALL_PREFIX/lib (plus /lib64 when the tree has one); with --origin,
#                         $ORIGIN-relative instead, so the tree runs from wherever it is unpacked
#   *.pc, *.rules         BUILD_PREFIX replaced by INSTALL_PREFIX in the text
#   --strip-dev           also removes include/, share/man and lib/pkgconfig: nothing at run time
#                         reads them, and the toolkit does not need them
#
# --from defaults to the prefix found in the RUNPATH of the first binary under PREFIX/bin.
# The script refuses (exit 1) when any file under PREFIX still mentions BUILD_PREFIX afterwards.
# Used by packaging/arch/PKGBUILD (installed prefix) and tools/make-toolkit.sh (--origin).
set -euo pipefail

usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0" >&2; exit "${1:-2}"; }

PREFIX='' TO='' FROM='' ORIGIN=0 STRIP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TO=${2:?--to needs a path}; shift 2;;
    --to=*) TO=${1#--to=}; shift;;
    --from) FROM=${2:?--from needs a path}; shift 2;;
    --from=*) FROM=${1#--from=}; shift;;
    --origin) ORIGIN=1; shift;;
    --strip-dev) STRIP=1; shift;;
    -h|--help) usage 0;;
    -*) echo "unknown argument: $1" >&2; usage;;
    *) [[ -z "$PREFIX" ]] || { echo "one PREFIX only" >&2; usage; }; PREFIX=$1; shift;;
  esac
done
[[ -n "$PREFIX" ]] && [[ -n "$TO" ]] || usage
[[ -d "$PREFIX" ]] || { echo "not a directory: $PREFIX" >&2; exit 1; }
for t in patchelf strip; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
PREFIX=$(cd -- "$PREFIX" && pwd -P)
TO=${TO%/}

is_elf() { [[ "$(head -c 4 -- "$1" 2>/dev/null | tr -d '\0')" = $'\x7fELF' ]]; }

# the ELF files: executables and shared objects, by magic and not by name
mapfile -d '' ELFS < <(find "$PREFIX" -type f \( -perm -u+x -o -name '*.so*' \) -print0)
elfs=()
for f in "${ELFS[@]}"; do is_elf "$f" && elfs+=("$f"); done

# 1. the build prefix, unless given: what the first binary's RUNPATH says
if [[ -z "$FROM" ]]; then
  for f in "${elfs[@]}"; do
    case "$f" in "$PREFIX"/bin/*|"$PREFIX"/sbin/*) ;; *) continue;; esac
    rp=$(patchelf --print-rpath "$f" 2>/dev/null || true)
    rp=${rp%%:*}
    case "$rp" in */lib|*/lib64) FROM=${rp%/lib*}; break;; esac
  done
  [[ -n "$FROM" ]] || { echo "cannot tell the build prefix from the RUNPATH under $PREFIX/bin; pass --from" >&2; exit 1; }
fi
FROM=${FROM%/}

# 2. build-time leftovers
find "$PREFIX" -type f \( -name '*.la' -o -name '*.a' \) -delete
if [[ "$STRIP" = 1 ]]; then
  rm -rf -- "$PREFIX/include" "$PREFIX/share/man" "$PREFIX/lib/pkgconfig" "$PREFIX/lib64/pkgconfig"
  rmdir -- "$PREFIX/share" 2>/dev/null || true
fi

# 3. strip, then RUNPATH
if [[ "$ORIGIN" = 1 ]]; then
  # literal $ORIGIN: the dynamic loader expands it to the directory of the file being loaded
  # shellcheck disable=SC2016
  runpath='$ORIGIN/../lib:$ORIGIN'
  # shellcheck disable=SC2016
  [[ -d "$PREFIX/lib64" ]] && runpath="$runpath"':$ORIGIN/../lib64'
else
  runpath=$TO/lib
  [[ -d "$PREFIX/lib64" ]] && runpath="$runpath:$TO/lib64"
fi
n=0
for f in "${elfs[@]}"; do
  [[ -e "$f" ]] || continue   # a *.a that was deleted above
  strip --strip-unneeded "$f" || { echo "strip failed on $f" >&2; exit 1; }
  patchelf --set-rpath "$runpath" "$f" || { echo "patchelf failed on $f" >&2; exit 1; }
  n=$((n + 1))
done

# 4. text files that spell the prefix out
while IFS= read -r -d '' f; do
  sed -i "s|$FROM|$TO|g" "$f"
done < <(find "$PREFIX" -type f \( -name '*.pc' -o -name '*.rules' \) -print0)

# 5. nothing may still point into the build tree
leftover=$(grep -rlI --binary-files=text -- "$FROM" "$PREFIX" 2>/dev/null || true)
if [[ -n "$leftover" ]]; then
  echo "REFUSING: the build prefix is still spelled out under $PREFIX:" >&2
  printf '  %s\n' "$leftover" >&2
  exit 1
fi
echo "relocated $PREFIX: $n ELF files stripped, RUNPATH $runpath, text files point at $TO"
