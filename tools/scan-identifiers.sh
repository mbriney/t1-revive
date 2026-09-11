#!/usr/bin/env bash
# scan-identifiers.sh — refuse identifiers and private names in the t1-revive tree.
#
# Usage:
#   tools/scan-identifiers.sh                 scan the whole working tree (git ls-files + untracked)
#   tools/scan-identifiers.sh PATH...         scan the given files/directories
#   tools/scan-identifiers.sh --staged        scan the staged content of the index (pre-commit hook)
#   tools/scan-identifiers.sh --banned-only ... only the forbidden-ACPI-method check
#   tools/scan-identifiers.sh --self-test     run the built-in positive/negative cases
#
# Output: one line per hit, "FILE:LINE:MATCH<TAB>[rule]". Exit 1 on any hit, 0 when clean,
# 2 on usage error. Runs with bash, grep, awk (gawk preferred, mawk/busybox work), git.
#
# Rules (AGENTS.md rule 1 and 2):
#   hex16    a run of >= 16 hex digits (serials, ECIDs, nonces, hashes, keybags)
#   mac      six colon-separated hex pairs
#   serial   "serial" followed by a 10-12 char uppercase alphanumeric token with a digit
#   ecid     ECID/UDID/nonce/ticket/IMEI/snum-looking KEY=VALUE with a >= 8 char value
#   home     /home/<name>          (a literal "/home/<user>" placeholder is fine)
#   user     the maintainer's login followed by "@"
#   host     the maintainer's hostname
#   tailnet  the maintainer's tailnet name, and any tailscale dot-ts-dot-net name
#   banned   the forbidden ACPI method name (AGENTS.md rule 1), uppercase, anywhere, comments
#            included. tools/scan-allowlist.txt never applies to it. The only exemptions are the
#            four documents that exist to say the method is never called: AGENTS.md (and its
#            CLAUDE.md symlink), README.md and docs/how-it-works.md (see BANNED_EXEMPT).
#
# The rule patterns below spell the forbidden strings with character classes so that this
# file does not itself contain them.
#
# Exceptions live in tools/scan-allowlist.txt: "path-glob<TAB>line-regex<TAB>reason".
# A hit is suppressed when the file path matches the glob AND the whole line matches the regex.
# The banned rule ignores the allowlist.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ALLOWLIST_DEFAULT="$SCRIPT_DIR/scan-allowlist.txt"

# name<TAB>regex, one per line. The banned-method rule is separate (see below).
RULES=$(cat <<'RULES_EOF'
hex16	(^|[^0-9A-Za-z])[0-9A-Fa-f]{16,}([^0-9A-Za-z]|$)
mac	(^|[^0-9A-Za-z])([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}([^0-9A-Za-z]|$)
serial	[Ss][Ee][Rr][Ii][Aa][Ll][A-Za-z_ .-]{0,12}[=:"'[:space:]]+[A-Z0-9]{10,12}([^A-Za-z0-9]|$)
ecid	([Ee][Cc][Ii][Dd]|[Uu][Dd][Ii][Dd]|[Nn][Oo][Nn][Cc][Ee]|[Tt][Ii][Cc][Kk][Ee][Tt]|UniqueChipID|IMEI|[Ss][Nn][Uu][Mm])[A-Za-z_-]*[[:space:]]*[=:][[:space:]]*["']?(0x)?[A-Za-z0-9+/]{8,}
home	/hom[e]/[A-Za-z0-9._-]+
user	(^|[^A-Za-z0-9])n[n]@
host	(^|[^A-Za-z])[Oo][Mm][Aa][Cc]([^A-Za-z]|$)
tailnet	[Tt]ailfa7da[7]|\.ts\.ne[t]([^A-Za-z]|$)
RULES_EOF
)
# Rules whose match must contain a digit to count (filters "serial: PLACEHOLDER", "nonce=none").
DIGIT_RULES='serial ecid'
BANNED_RE='S[O]CW'
# Files allowed to spell the forbidden method name, because their whole point is to say it is
# never called. Exact repo-relative paths, one per line; nothing else is ever exempt.
BANNED_EXEMPT=$(cat <<'EXEMPT_EOF'
AGENTS.md
CLAUDE.md
README.md
docs/how-it-works.md
EXEMPT_EOF
)

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

AWK='awk'
command -v gawk >/dev/null 2>&1 && AWK=gawk

repo_root() {
  git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname -- "$SCRIPT_DIR"
}

# rel_label ROOT PATH -> the path as it is written in the repo (so the banned-method exemption
# and the allowlist globs work the same for `scan .`, `scan /abs/path` and a bare `scan`).
rel_label() {
  local root=$1 p=$2 abs
  abs=$(cd -- "$(dirname -- "$p")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename -- "$p")") || abs=$p
  [[ $abs == "$root"/* ]] && { printf '%s\n' "${abs#"$root"/}"; return; }
  p=${p#./}
  printf '%s\n' "$p"
}

# scan_file FILE LABEL ALLOWLIST BANNED_ONLY -> prints hits, returns 1 if any
scan_file() {
  local file=$1 label=$2 allowlist=$3 banned_only=$4 allow_res='' glob re
  [[ -f $file ]] || return 0
  grep -Iq '' -- "$file" 2>/dev/null || return 0   # binary or empty
  if [[ -n $allowlist && -f $allowlist ]]; then
    while IFS=$'\t' read -r glob re _; do   # field 3 is the human-readable reason
      [[ -z $glob || $glob == \#* ]] && continue
      # shellcheck disable=SC2053  # glob is meant to be a pattern
      if [[ $label == $glob ]]; then allow_res+="$re"$'\n'; fi
    done < "$allowlist"
  fi
  local banned_exempt=0 e
  while IFS= read -r e; do
    [[ -n $e && $label == "$e" ]] && { banned_exempt=1; break; }
  done <<<"$BANNED_EXEMPT"
  # shellcheck disable=SC2016  # the awk program is single-quoted on purpose
  T1R_SCAN_RULES=$RULES T1R_SCAN_ALLOW=$allow_res T1R_SCAN_DIGIT=$DIGIT_RULES \
  T1R_SCAN_BANNED=$BANNED_RE \
  "$AWK" -v file="$label" -v banned_only="$banned_only" -v banned_exempt="$banned_exempt" '
    BEGIN {
      nr = split(ENVIRON["T1R_SCAN_RULES"], R, "\n")
      for (i = 1; i <= nr; i++) { split(R[i], kv, "\t"); name[i] = kv[1]; re[i] = kv[2] }
      na = split(ENVIRON["T1R_SCAN_ALLOW"], A, "\n")
      nd = split(ENVIRON["T1R_SCAN_DIGIT"], D, " ")
      for (i = 1; i <= nd; i++) digit[D[i]] = 1
      banned = ENVIRON["T1R_SCAN_BANNED"]
      hits = 0
    }
    {
      line = $0
      if (!banned_exempt && match(line, banned)) {
        printf "%s:%d:%s\t[banned]\n", file, NR, substr(line, RSTART, RLENGTH); hits++
      }
      if (banned_only) next
      for (i = 1; i <= nr; i++) {
        if (name[i] == "" || !match(line, re[i])) continue
        m = substr(line, RSTART, RLENGTH)
        if ((name[i] in digit) && m !~ /[0-9]/) continue
        skip = 0
        for (j = 1; j <= na; j++) if (A[j] != "" && line ~ A[j]) { skip = 1; break }
        if (skip) continue
        gsub(/^[ \t"'"'"'=:,;()]+|[ \t"'"'"'=:,;()]+$/, "", m)
        printf "%s:%d:%s\t[%s]\n", file, NR, m, name[i]; hits++
      }
    }
    END { exit hits ? 1 : 0 }
  ' "$file"
}

# list_tree ROOT -> NUL-separated relative paths (tracked + untracked, ignored excluded)
list_tree() {
  local root=$1
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" ls-files -z --cached --others --exclude-standard
  else
    (cd "$root" && find . -type f -not -path './.git/*' -print0 | sed -z 's|^\./||')
  fi
}

self_test() {
  local tmp rc=0 failed=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/t1r-scan-selftest.XXXXXX") || exit 1
  trap 'rm -rf "${tmp:-}"' RETURN
  mkdir -p "$tmp/pos" "$tmp/neg"
  # Positive cases are built by concatenation so this file stays clean.
  local hex mac
  hex=$(printf '%s%s' 0123456789 abcdef0123)
  mac=$(printf '%s:%s:%s:%s:%s:%s' 02 1a 2b 3c 4d 5e)
  printf 'sha=%s\n' "$hex" > "$tmp/pos/hex16"
  printf 'link/ether %s brd\n' "$mac" > "$tmp/pos/mac"
  printf 'Serial Number: %s%s\n' C02ABC DEF1GH > "$tmp/pos/serial"
  printf 'ECID=%s\n' "$hex" > "$tmp/pos/ecid"
  printf 'ApNonce: %s\n' "$hex" > "$tmp/pos/ecid-nonce"
  printf 'cd /ho%s/someone/Work\n' me > "$tmp/pos/home"
  printf 'ssh n%s@host\n' n > "$tmp/pos/user"
  printf 'host: om%s-3\n' ac > "$tmp/pos/host"
  printf 'https://host.tailfa7d%s.ts.n%s/\n' a7 et > "$tmp/pos/tailnet"
  printf 'https://foo.ts.n%s/\n' et > "$tmp/pos/tsnet"
  printf '# never call SO%s here\n' CW > "$tmp/pos/banned-comment"
  printf 'acpi_call \\_SB.PCI0.XHC1.RHUB.ASOC.SO%s\n' CW > "$tmp/pos/banned-path"
  # An allowlisted sha256 line must still be caught when the allowlist is not used.
  local sha
  sha=$(printf '%s' "$hex$hex$hex$hex" | cut -c1-64)
  printf '%s  file.tar.xz\n' "$sha" > "$tmp/pos/x.sha256"
  {
    echo 'PARTTYPE c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
    printf 'short hex %s%s ok\n' 0123456789 abcde
    echo '2026-09-10T12:34:56 elapsed=97 12:34:56:78'
    echo 'paths are discovered, not /home/<user>'
    echo 'serial number is 12 characters, e.g. serial: PLACEHOLDER'
    echo 'nonce=none ticket=missing ECID=redacted'
    echo 'ACPI FRST is the only reset; the other method is banned'
    echo 'plugin stomach idVendor=05ac idProduct=8600 variable banned_only=1'
    echo 'https://example.ts.network/x'
    echo 'export T1R_STATE=/var/lib/t1-revive'
  } > "$tmp/neg/clean"
  printf '%s  file.tar.xz\n' "$sha" > "$tmp/neg/allowed.sha256"
  printf '%s\t%s\t%s\n' '*.sha256' '^[0-9a-f]{64}[ \t]' 'self-test checksum file' > "$tmp/allow"

  local f out
  for f in "$tmp"/pos/*; do
    out=$(scan_file "$f" "${f#"$tmp"/}" "" 0)
    if [[ -z $out ]]; then echo "self-test FAIL: expected a hit in ${f#"$tmp"/}"; failed=1; fi
  done
  for f in "$tmp"/neg/*; do
    out=$(scan_file "$f" "${f#"$tmp"/}" "$tmp/allow" 0)
    if [[ -n $out ]]; then echo "self-test FAIL: unexpected hit in ${f#"$tmp"/}: $out"; failed=1; fi
  done
  # the banned rule ignores the allowlist
  printf '%s\t%s\t%s\n' 'pos/banned-comment' '.*' 'must not work' > "$tmp/allow2"
  out=$(scan_file "$tmp/pos/banned-comment" pos/banned-comment "$tmp/allow2" 0)
  [[ -n $out ]] || { echo "self-test FAIL: banned method name was allowlisted"; failed=1; }
  # AGENTS.md is exempt from the banned rule only
  cp "$tmp/pos/banned-comment" "$tmp/AGENTS.md"
  out=$(scan_file "$tmp/AGENTS.md" AGENTS.md "" 0)
  [[ -z $out ]] || { echo "self-test FAIL: AGENTS.md exemption: $out"; failed=1; }
  # so are README.md and docs/how-it-works.md, by exact path and by exact path only
  for f in README.md docs/how-it-works.md; do
    out=$(scan_file "$tmp/pos/banned-comment" "$f" "" 0)
    [[ -z $out ]] || { echo "self-test FAIL: $f should be exempt from the banned rule: $out"; failed=1; }
  done
  for f in vendor/README.md docs/README.md docs/how-it-works.md.bak; do
    out=$(scan_file "$tmp/pos/banned-comment" "$f" "" 0)
    [[ -n $out ]] || { echo "self-test FAIL: $f must not inherit the banned-rule exemption"; failed=1; }
  done
  printf 'ECID=%s\n' "$hex" >> "$tmp/AGENTS.md"
  out=$(scan_file "$tmp/AGENTS.md" AGENTS.md "" 0)
  [[ -n $out ]] || { echo "self-test FAIL: AGENTS.md must still be scanned for identifiers"; failed=1; }
  # --banned-only reports nothing else
  out=$(scan_file "$tmp/pos/ecid" pos/ecid "" 1)
  [[ -z $out ]] || { echo "self-test FAIL: --banned-only reported $out"; failed=1; }
  out=$(scan_file "$tmp/pos/banned-path" pos/banned-path "" 1)
  [[ -n $out ]] || { echo "self-test FAIL: --banned-only missed the method path"; failed=1; }
  if (( failed )); then echo "self-test: FAILED"; rc=1; else echo "self-test: ok"; fi
  return $rc
}

main() {
  local staged=0 banned_only=0 allowlist=$ALLOWLIST_DEFAULT quiet=0 paths=() root hits=0 rc
  while (( $# )); do
    case $1 in
      --staged) staged=1 ;;
      --banned-only) banned_only=1 ;;
      --self-test) self_test; exit $? ;;
      --allowlist) [[ $# -ge 2 ]] || usage; allowlist=$2; shift ;;
      --no-allowlist) allowlist='' ;;
      -q|--quiet) quiet=1 ;;
      -h|--help) usage ;;
      --) shift; paths+=("$@"); break ;;
      -*) echo "unknown option: $1" >&2; usage ;;
      *) paths+=("$1") ;;
    esac
    shift
  done
  root=$(repo_root)

  if (( staged )); then
    local f tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/t1r-scan.XXXXXX") || exit 1
    trap 'rm -rf "${tmp:-}"' EXIT
    while IFS= read -r -d '' f; do
      git -C "$root" show ":$f" > "$tmp/blob" 2>/dev/null || continue
      scan_file "$tmp/blob" "$f" "$allowlist" "$banned_only" || hits=1
    done < <(git -C "$root" diff --cached --name-only --diff-filter=ACMR -z)
  elif (( ${#paths[@]} )); then
    local p f
    for p in "${paths[@]}"; do
      if [[ -d $p ]]; then
        while IFS= read -r -d '' f; do
          [[ -L $f ]] && continue
          scan_file "$f" "$(rel_label "$root" "$f")" "$allowlist" "$banned_only" || hits=1
        done < <(find "$p" -type f -not -path '*/.git/*' -print0)
      else
        scan_file "$p" "$(rel_label "$root" "$p")" "$allowlist" "$banned_only" || hits=1
      fi
    done
  else
    local f
    while IFS= read -r -d '' f; do
      [[ -L $root/$f ]] && continue
      scan_file "$root/$f" "$f" "$allowlist" "$banned_only" || hits=1
    done < <(list_tree "$root")
  fi

  if (( hits )); then
    (( quiet )) || echo "scan-identifiers: FAILED (see AGENTS.md rules 1 and 2; exceptions go in tools/scan-allowlist.txt with a reason)" >&2
    rc=1
  else
    (( quiet )) || echo "scan-identifiers: clean" >&2
    rc=0
  fi
  return $rc
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
