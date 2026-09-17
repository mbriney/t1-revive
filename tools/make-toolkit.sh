#!/usr/bin/env bash
# tools/make-toolkit.sh - pack what a fresh machine needs to run t1-revive offline from a USB stick.
#
#   bash tools/make-toolkit.sh [--out DIR|FILE.tar.zst]
#
# Allowlist only: bin/ lib/ tools/ contrib/ docs/ skills/ VERSION LICENSE README.md AGENTS.md
# THIRD_PARTY_NOTICES.md, and the built prefix/ (patched libimobiledevice stack) if present.
# Never: logs, post/, test/, vendor sources, Apple firmware, device data.
# Output: t1-revive-toolkit-<date>.tar.zst plus a .sha256 sidecar, next to the repository unless --out.
# The tarball unpacks to t1-revive-toolkit/{t1-revive/,MANIFEST.txt}; contrib/stick/go.sh
# installs it. No network is used.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
OUT=""
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit "${1:-2}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT=${2:?--out needs a path}; shift 2;;
    --out=*) OUT=${1#--out=}; shift;;
    -h|--help) usage 0;;
    *) echo "unknown argument: $1" >&2; usage;;
  esac
done
for t in tar zstd sha256sum; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
[[ -d "$ROOT/prefix/bin" ]] && ! command -v patchelf >/dev/null && { echo "missing tool: patchelf (needed to relocate prefix/)" >&2; exit 1; }
if [[ ! -f "$ROOT/VERSION" || ! -d "$ROOT/lib" ]]; then echo "not a t1-revive checkout: $ROOT" >&2; exit 1; fi

STAMP=$(date +%Y%m%d)
case "$OUT" in
  '') OUT=$(dirname -- "$ROOT")/t1-revive-toolkit-$STAMP.tar.zst;;
  *.tar.zst) ;;
  *) mkdir -p -- "$OUT"; OUT=$OUT/t1-revive-toolkit-$STAMP.tar.zst;;
esac
OUT=$(readlink -f -- "$(dirname -- "$OUT")")/$(basename -- "$OUT")

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
T=$STAGE/t1-revive-toolkit; R=$T/t1-revive; mkdir -p "$R"

# 1. the tool itself (allowlist)
for item in bin lib tools contrib docs skills VERSION LICENSE README.md AGENTS.md THIRD_PARTY_NOTICES.md; do
  [[ -e "$ROOT/$item" ]] || continue
  cp -a -- "$ROOT/$item" "$R/$item"
done
find "$R" \( -name __pycache__ -o -name '*.pyc' -o -name '*.log' -o -name .git \) -prune -exec rm -rf {} + 2>/dev/null || true
# 2. the built binaries, when present (no sources; a SOURCES file states where they came from)
# 3. relocated: the build machine's prefix is baked into every binary's RUNPATH and into a few
#    text files, so a verbatim copy only runs from the path it was built at and carries a home
#    directory the identifier scan refuses. $ORIGIN-relative RUNPATHs let the tree run from
#    wherever the stick or go.sh puts it; the text files point at go.sh's install location.
if [[ -d "$ROOT/prefix/bin" ]]; then
  cp -a -- "$ROOT/prefix" "$R/prefix"
  bash "$ROOT/tools/relocate-prefix.sh" "$R/prefix" --to /usr/local/lib/t1-revive/prefix --origin --strip-dev \
    || { echo "REFUSING: prefix/ could not be relocated (see above)"; exit 1; }
  if [[ -f "$ROOT/vendor/SOURCES.template" ]]; then
    # the same corresponding-source statement the package installs, placeholders filled
    sed -e "s|@VERSION@|$(tr -d '[:space:]' < "$ROOT/VERSION")|g" \
        -e "s|@SHA256_LIBIRECOVERY_PATCH@|$(sha256sum "$ROOT/vendor/patches/libirecovery.patch" | cut -d' ' -f1)|" \
        -e "s|@SHA256_USBMUXD_PATCH@|$(sha256sum "$ROOT/vendor/patches/usbmuxd.patch" | cut -d' ' -f1)|" \
        -e "s|@SHA256_IDEVICERESTORE_PATCH@|$(sha256sum "$ROOT/vendor/patches/idevicerestore.patch" | cut -d' ' -f1)|" \
        "$ROOT/vendor/SOURCES.template" > "$R/prefix/SOURCES"
  else printf 'Built by build.sh from the pinned upstreams and patches under vendor/ (see the repository).\n' > "$R/prefix/SOURCES"; fi
  HAVE_PREFIX=yes
else
  HAVE_PREFIX=no
fi
find "$T" -type f -name '*.sh' -exec chmod 0755 {} +
[[ -f "$R/bin/t1-revive" ]] && chmod 0755 "$R/bin/t1-revive"

# 4. refuse anything that looks like device data or firmware
bad=$(find "$T" -type f \( -iname 'FDRData*' -o -iname '*.memboot' -o -iname '*apticket*' -o -iname '*.shsh*' \
      -o -path '*/private/*' -o -iname 'keybag*' -o -iname '*.im4p' -o -iname '*.im4m' -o -iname '*.dmg' \
      -o -iname '*.pkg' -o -iname 'BuildManifest.plist' -o -path '*/EMBEDDEDOS/*' -o -iname 'ecid*' \) | head)
[[ -z "$bad" ]] || { echo "REFUSING: device data or firmware in the toolkit:"; echo "$bad"; exit 1; }
if [[ -f "$R/tools/scan-identifiers.sh" ]]; then
  # Same scanner as CI, but run from the staged copy against the staged copy: the scanner labels
  # every file relative to its own parent directory, and both the allowlist (tools/scan-allowlist.txt)
  # and the banned-method exemptions are repo-relative paths, so they only apply when the labels come
  # out as they do in the repository. GIT_CEILING_DIRECTORIES keeps it from finding an enclosing
  # checkout if $TMPDIR happens to live inside one. Exceptions belong in the allowlist, not here.
  GIT_CEILING_DIRECTORIES=$STAGE bash "$R/tools/scan-identifiers.sh" "$R" \
    || { echo "REFUSING: tools/scan-identifiers.sh found identifiers in the staged toolkit (hits above)"; exit 1; }
fi

# 5. manifest
{
  echo "t1-revive toolkit, built $(date -u +%Y-%m-%dT%H:%M:%SZ), tool version $(tr -d '[:space:]' < "$ROOT/VERSION")"
  echo "Layout: t1-revive/ (the tool; install with contrib/stick/go.sh or copy to /usr/local/lib/t1-revive),"
  echo "        prefix built binaries: $HAVE_PREFIX"
  echo "Contains NO Apple firmware (downloaded from Apple at run time and checksum-verified) and"
  echo "NO data from any specific Mac: no EFI/APPLE folder, no FDRData, no tickets, no memboot, no logs."
  echo; echo "sha256 of every file (this manifest excepted; verify it with the .sha256 of the tarball):"
  (cd "$T" && find . -type f ! -name MANIFEST.txt -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
} > "$T/MANIFEST.txt"

# 6. pack and hash
mkdir -p -- "$(dirname -- "$OUT")"
tar -C "$STAGE" -cf - t1-revive-toolkit | zstd -T0 -3 -q --force -o "$OUT"
(cd -- "$(dirname -- "$OUT")" && sha256sum "$(basename -- "$OUT")" > "$(basename -- "$OUT").sha256")
echo "toolkit: $OUT ($(du -h -- "$OUT" | cut -f1), $(find "$T" -type f | wc -l) files, prefix=$HAVE_PREFIX)"
echo "sha256:  $(cut -d' ' -f1 "$OUT.sha256")"
echo "proof (must be 'none'): $(tar --zstd -tf "$OUT" | grep -E '(^|/)FDRData|\.memboot$|apticket|/private/|EMBEDDEDOS/|\.im4p$|\.dmg$' || echo none)"
