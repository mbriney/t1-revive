#!/usr/bin/env bash
# lib/discover.sh - ESP, DMI model + allowlist, FRST ACPI path.
#
# Pure with respect to T1R_* variables: T1R_DMI, T1R_LSBLK_JSON, T1R_ACPI_TABLES, T1R_STATE.
# Nothing runs at source time. Requires lib/common.sh (note/warn/die/run_cmd).
#
# shellcheck shell=bash

T1R_ESP_PARTTYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
export T1R_ESP_PARTTYPE
# T1R_ESP_DEV: optional operator override (t1-revive.conf) for a machine with two ESPs.
: "${T1R_ESP_DEV:=}"
export T1R_ESP_DEV

# ----- model ---------------------------------------------------------------------------
model_id() {
  local m=
  [[ -r "$T1R_DMI/product_name" ]] && read -r m <"$T1R_DMI/product_name" 2>/dev/null
  printf '%s\n' "${m:-unknown}"
}

model_status() {
  case "${1:-}" in
    MacBookPro14,3) printf 'tested\n';;
    MacBookPro13,2|MacBookPro13,3|MacBookPro14,2) printf 'untested\n';;
    *) printf 'unsupported\n';;
  esac
}

# ----- ESP -----------------------------------------------------------------------------
# _esp_lsblk_json: the lsblk tree as JSON (from T1R_LSBLK_JSON when set).
_esp_lsblk_json() {
  if [[ -n "${T1R_LSBLK_JSON:-}" ]]; then
    [[ -r "$T1R_LSBLK_JSON" ]] || return 1
    cat "$T1R_LSBLK_JSON"
  else
    command -v lsblk >/dev/null 2>&1 || return 1
    lsblk -J -o NAME,PATH,PARTTYPE,MOUNTPOINT,FSTYPE,LABEL 2>/dev/null
  fi
}

# _esp_parse: JSON on stdin -> "PATH MOUNTPOINT" for every ESP partition (mountpoint "-" if none)
_esp_parse() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg t "$T1R_ESP_PARTTYPE" '
      [.. | objects | select(has("parttype")) | select(((.parttype // "") | ascii_downcase) == $t)]
      | .[] | "\(.path // ("/dev/" + .name)) \(.mountpoint // (.mountpoints // [null])[0] // "-")"' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
want = sys.argv[1]
def walk(n):
    if isinstance(n, dict):
        if str(n.get("parttype") or "").lower() == want:
            mp = n.get("mountpoint") or (n.get("mountpoints") or [None])[0] or "-"
            print("%s %s" % (n.get("path") or "/dev/" + str(n.get("name")), mp))
        for v in n.values(): walk(v)
    elif isinstance(n, list):
        for v in n: walk(v)
walk(json.load(sys.stdin))' "$T1R_ESP_PARTTYPE" 2>/dev/null
  else
    return 1
  fi
}

# esp_candidates: "DEVICE MOUNTPOINT HAS_APPLE" per ESP. HAS_APPLE is yes/no when mounted
# (EFI/APPLE present under the mountpoint), "?" when not mounted. Never mounts anything.
esp_candidates() {
  local dev mp has
  while read -r dev mp; do
    [[ -n "$dev" ]] || continue
    if [[ "$mp" = "-" ]] || [[ -z "$mp" ]]; then has='?'
    elif [[ -d "$mp/EFI/APPLE" ]]; then has=yes
    else has=no; fi
    printf '%s %s %s\n' "$dev" "${mp:--}" "$has"
  done < <(_esp_lsblk_json | _esp_parse)
  return 0
}

# esp_select: the one ESP to use, as "DEVICE MOUNTPOINT". Preference: the single ESP holding
# EFI/APPLE, else the one mounted at /boot, /efi or /boot/efi. Returns 1 if none or ambiguous.
esp_select() {
  local -a lines=()
  local l n dev mp has pick='' apple=0 std=0
  mapfile -t lines < <(esp_candidates)
  # An operator can pin the ESP in t1-revive.conf (T1R_ESP_DEV=/dev/...) when two look alike.
  if [[ -n "${T1R_ESP_DEV:-}" ]]; then
    for l in "${lines[@]}"; do
      read -r dev mp _ <<<"$l"
      [[ "$dev" = "$T1R_ESP_DEV" ]] && { printf '%s %s\n' "$dev" "$mp"; return 0; }
    done
    warn "T1R_ESP_DEV=$T1R_ESP_DEV is not an EFI system partition on this machine; ignoring it"
  fi
  n=${#lines[@]}
  [[ "$n" -gt 0 ]] || return 1
  if [[ "$n" = 1 ]]; then read -r dev mp _ <<<"${lines[0]}"; printf '%s %s\n' "$dev" "$mp"; return 0; fi
  for l in "${lines[@]}"; do
    read -r dev mp has <<<"$l"
    if [[ "$has" = yes ]]; then apple=$((apple + 1)); pick="$dev $mp"; fi
  done
  [[ "$apple" = 1 ]] && { printf '%s\n' "$pick"; return 0; }
  pick=
  for l in "${lines[@]}"; do
    read -r dev mp has <<<"$l"
    case "$mp" in /boot|/efi|/boot/efi) std=$((std + 1)); pick="$dev $mp";; *) ;; esac
  done
  [[ "$std" = 1 ]] && { printf '%s\n' "$pick"; return 0; }
  return 1
}

# esp_mount DEVICE: prints the mountpoint, mounting under $T1R_STATE/esp when needed.
esp_mount() {
  local dev=${1:?esp_mount DEVICE} mp='' l d m
  while read -r d m _; do [[ "$d" = "$dev" ]] && mp=$m; done < <(esp_candidates)
  if { [[ -z "$mp" ]] || [[ "$mp" = "-" ]]; } && command -v findmnt >/dev/null 2>&1; then
    mp=$(findmnt -rno TARGET "$dev" 2>/dev/null | head -1)
  fi
  if [[ -n "$mp" ]] && [[ "$mp" != "-" ]]; then printf '%s\n' "$mp"; return 0; fi
  mp=$T1R_STATE/esp
  if [[ "$T1R_DRY_RUN" = 1 ]]; then note "(dry-run) mount $dev $mp"; printf '%s\n' "$mp"; return 0; fi
  install -d -m 0700 "$mp" || return 1
  mount -t vfat "$dev" "$mp" || return 1
  l=$(findmnt -rno FSTYPE "$mp" 2>/dev/null); [[ "$l" = vfat ]] || { umount "$mp" 2>/dev/null; return 1; }
  printf '%s\n' "$mp"
}

# esp_is_writable MOUNTPOINT: rw vfat mount that root can write to.
esp_is_writable() {
  local mp=${1:?} opts
  opts=$(findmnt -rno FSTYPE,OPTIONS "$mp" 2>/dev/null) || return 1
  case "$opts" in vfat\ *rw*) ;; *) return 1;; esac
  [[ -w "$mp" ]]
}

# ----- FRST ACPI method ----------------------------------------------------------------
# frst_method: full path of the T1 reset method from the AML tables under $T1R_ACPI_TABLES.
# Empty when python3 or readable tables are missing. Never calls anything.
frst_method() {
  local walker=$T1R_ROOT/tools/acpi-method-path.py
  local -a tables=()
  local t out
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -r "$walker" ]] || return 0
  [[ -r "$T1R_ACPI_TABLES/DSDT" ]] && tables+=("$T1R_ACPI_TABLES/DSDT")
  while IFS= read -r t; do [[ -r "$t" ]] && tables+=("$t"); done < <(find "$T1R_ACPI_TABLES" -maxdepth 1 -name 'SSDT*' 2>/dev/null | sort -V)
  [[ "${#tables[@]}" -gt 0 ]] || return 0
  out=$(python3 "$walker" --method FRST "${tables[@]}" 2>/dev/null) || return 0
  # Prefer the one under the xHCI root hub (where the T1 hangs) if several tables define one.
  t=$(printf '%s\n' "$out" | grep -E 'XHC' | head -1)
  [[ -n "$t" ]] || t=$(printf '%s\n' "$out" | head -1)
  [[ -n "$t" ]] && printf '%s\n' "$t"
  return 0
}
