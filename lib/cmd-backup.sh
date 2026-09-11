#!/usr/bin/env bash
# lib/cmd-backup.sh - cmd_backup [--to DIR]
#
# Saves the ESP's EFI/APPLE tree (FDRData, EmbeddedOS image, version.plist) as a root-only tar
# under $T1R_STATE, optionally copied to DIR (a USB stick). Every dangerous command requires
# this first: regenerate checks that a backup tar exists or that EFI/APPLE is absent.
# Nothing from inside the files is ever printed; only names, sizes and checksums.
#
# shellcheck shell=bash

cmd_backup() {
  local to='' esp dev mp stamp tar sum short n copy
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to) [[ $# -ge 2 ]] || { echo "usage: t1-revive backup [--to DIR]" >&2; return 2; }; to=$2; shift;;
      --to=*) to=${1#--to=};;
      -h|--help) echo "usage: t1-revive backup [--to DIR]"; return 0;;
      *) echo "backup: unknown flag $1" >&2; return 2;;
    esac
    shift
  done
  require_root
  ensure_dirs || die 1 "cannot create $T1R_STATE / $T1R_LOG / $T1R_CACHE"
  open_log backup || true
  lock_acquire
  say "backup of the Apple EFI data"
  show "Saving this Mac's Apple firmware files (if any)"

  esp=$(esp_select) || die 4 "no single EFI system partition found (t1-revive preflight lists the candidates)"
  read -r dev mp <<<"$esp"
  mp=$(esp_mount "$dev") || die 1 "cannot mount the ESP $dev"
  note "ESP: $dev at $mp"

  if [[ ! -d "$mp/EFI/APPLE" ]]; then
    note "no EFI/APPLE on the ESP: nothing to back up (a wiped ESP)"
    show "  no Apple firmware files on this disk: nothing to back up"
    diag step=backup result=ok apple=absent
    return 0
  fi

  n=$(find "$mp/EFI/APPLE" -type f 2>/dev/null | wc -l)
  note "EFI/APPLE holds $n files"
  [[ -d "$mp/EFI/APPLE/EMBEDDEDOS" ]] && note "EMBEDDEDOS: $(dir_names "$mp/EFI/APPLE/EMBEDDEDOS")"
  stamp=$(date +%Y%m%d-%H%M%S)
  tar=$T1R_STATE/efi-backup-$stamp.tar
  if [[ "$T1R_DRY_RUN" = 1 ]]; then
    note "(dry-run) tar -C $mp -cf $tar EFI/APPLE"
    [[ -n "$to" ]] && note "(dry-run) copy to $to/"
    diag step=backup result=ok dry_run=1
    return 0
  fi
  ( umask 077; tar -C "$mp" -cf "$tar" EFI/APPLE ) || { rm -f "$tar"; die 1 "tar failed"; }
  chmod 0600 "$tar"
  sum=$(sha256sum "$tar" | awk '{print $1}')
  printf '%s  %s\n' "$sum" "${tar##*/}" >"$tar.sha256"; chmod 0600 "$tar.sha256"
  ln -sfn "${tar##*/}" "$T1R_STATE/efi-backup-latest.tar"
  short=${sum:0:12}
  note "saved $tar ($(stat -c %s "$tar") bytes, mode 0600)"
  # The redaction filter turns any 16+ hex run into <hex>, so the full sum is only useful in
  # the sidecar file; the first 12 characters survive and are enough to compare by eye.
  note "sha256 $sum"
  note "sha256 starts $short - the full value is in ${tar##*/}.sha256"
  if tar -tf "$tar" | grep -q 'EMBEDDEDOS/FDRData$'; then note "contains FDRData: yes"; else warn "contains FDRData: no (the tar has the rest of EFI/APPLE)"; fi

  if [[ -n "$to" ]]; then
    install -d -m 0700 "$to" || die 1 "cannot create $to"
    copy=$to/${tar##*/}
    { cp -f "$tar" "$copy" && cp -f "$tar.sha256" "$copy.sha256" && sync -f "$copy"; } || die 1 "copy to $to failed"
    chmod 0600 "$copy" "$copy.sha256" 2>/dev/null || true
    cmp -s "$tar" "$copy" || die 1 "the copy at $copy does not match the original"
    if tar -tf "$copy" | grep -q 'EMBEDDEDOS/FDRData$'; then note "copy verified at $copy (FDRData listed)"
    else note "copy verified at $copy (no FDRData inside; see above)"; fi
    show "  copy written to $to"
  fi
  show "  backup saved (sha256 starts $short; full value in ${tar##*/}.sha256)"
  note "keep a copy OFF this disk before any reinstall: this is the only key to this Mac's Touch ID"
  diag step=backup result=ok apple=present files="$n"
  return 0
}
