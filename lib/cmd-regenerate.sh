# lib/cmd-regenerate.sh - cmd_regenerate: the whole T1 regeneration with no
# reboot between steps. Port of one-shot.sh.
#
#   t1-revive regenerate                 provision -> reset-1 -> personalize -> reset-2 -> boot -> stage -> handover
#   t1-revive regenerate --from STEP     resume at provision | reset-1 | personalize | reset-2 | boot | stage | handover
#   t1-revive regenerate --force         passed on to stage (write even without a boot marker)
#
# Confirmations: the plan is printed and confirmed once before anything runs, and the ESP write
# is confirmed once more after its preview. --confirm-each asks before every device-touching
# step as well; --no-confirm and --demo ask nothing.
#
# Every step checks the T1's USB state before touching it and the chain stops
# on the first failure with the fallback spelled out (full power cycle, then
# --from STEP). Proven on a MacBookPro14,3 from nothing to a staged ESP in
# under five minutes, zero reboots.
# shellcheck shell=bash

# The dispatcher sources only lib/cmd-<sub>.sh; pull in the shared step code.
_t1r_lib=${T1R_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/lib
# shellcheck source=steps/common-steps.sh
declare -F run_step >/dev/null 2>&1 || . "$_t1r_lib/steps/common-steps.sh"
for _t1r_f in steps/provision steps/personalize steps/boot steps/reset cmd-stage cmd-handover; do
  # shellcheck disable=SC1090
  . "$_t1r_lib/$_t1r_f.sh"
done
unset _t1r_f

_regen_steps="provision reset-1 personalize reset-2 boot stage handover"

_regen_index() {
  case "$1" in
    provision) echo 1;; reset-1) echo 2;; personalize) echo 3;; reset-2) echo 4;;
    boot) echo 5;; stage) echo 6;; handover) echo 7;; *) echo 0;;
  esac
}

# _regen_fail STEP MSG: die 5 with the fallback for resuming at STEP.
# _regen_fail STEP MSG: keep the step's own contract exit code (2..7) when it had one; anything
# else is a device-state failure (5). $? must be read before any other command runs.
_regen_fail() {
  local rc=$?
  case "$rc" in [2-7]) ;; *) rc=5;; esac
  die "$rc" "$2. $(fallback_text "$1")"
}

# _regen_ensure_recovery STEP: one-shot's `[ "$(t1)" = 1281 ] || frst` guard. In a dry run the
# T1 never changes state, so once a (dry) reset has been printed the guard takes it as done
# instead of printing the same reset a second time before every step.
_regen_reset_seen=0
_regen_ensure_recovery() {
  [ "$(t1_state)" = recovery ] && return 0
  if is_dry && [ "$_regen_reset_seen" = 1 ]; then
    note "(dry) T1 taken as in recovery after the reset above"
    return 0
  fi
  note "T1 is not in recovery; resetting it first"
  ( step_reset ) || _regen_fail "$1" "T1 reset before $1 failed"
  _regen_reset_seen=1
}

# _regen_stage_dry: the dry-run stand-in for the real write; the preview already printed everything.
_regen_stage_dry() {
  note "(dry) the write itself is skipped; a real run repeats the preview above for real and verifies it"
  return 0
}

# _regen_plan START ESP_HAS_DATA: the lines printed before the one start confirmation.
_regen_plan() {
  local start=$1 has_data=$2
  note "regenerate will:"
  [ "$start" -le 2 ] && note "  1. reset the T1 into recovery and run provision (the T1 asks Apple for its own data)"
  [ "$start" -le 4 ] && note "  2. reset it and run personalize (captures the boot image and ticket for this T1)"
  [ "$start" -le 5 ] && note "  3. reset it and boot it from the captured image (watch the Touch Bar)"
  if [ "$start" -le 6 ]; then
    if [ "$has_data" = 1 ]; then
      note "  4. write EFI/APPLE/EMBEDDEDOS on the ESP, replacing the existing files (old copies kept under private/esp-backup-<stamp>/)"
    else
      note "  4. write EFI/APPLE/EMBEDDEDOS on the ESP"
    fi
    note "     (it asks once more before writing)"
  fi
  if command -v t1bridge >/dev/null 2>&1 || modinfo -n t1_cfgsel >/dev/null 2>&1; then
    note "  5. hand the booted T1 to t1bridge by re-enumerating it (no reboot)"
  else
    note "  5. handover: t1bridge is not installed, so nothing takes the T1 yet"
  fi
  note "The T1 steps talk to Apple's servers and are not undone by Ctrl-C: if a step fails, the"
  note "fallback is a full power cycle, then: t1-revive regenerate --from STEP"
  return 0
}

cmd_regenerate() {
  local from=provision force=0 start priv fw esp_mnt model status n
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] || die 2 "--from needs a step"; from=$2; shift;;
      --from=*) from=${1#--from=};;
      --force) force=1;;
      --no-confirm) T1R_NO_CONFIRM=1; export T1R_NO_CONFIRM;;
      --demo) T1R_DEMO=1; T1R_NO_CONFIRM=1; export T1R_DEMO T1R_NO_CONFIRM;;
      --dry-run) T1R_DRY_RUN=1; export T1R_DRY_RUN;;
      *) die 2 "usage: t1-revive regenerate [--from STEP] [--force]   (STEP: $_regen_steps)";;
    esac
    shift
  done
  start=$(_regen_index "$from")
  [ "$start" != 0 ] || die 2 "unknown --from step '$from' (one of: $_regen_steps)"

  # ---------------------------------------------------------- preflight ----
  require_root
  ensure_dirs || die 1 "cannot create $T1R_STATE / $T1R_LOG / $T1R_CACHE"
  lock_once
  open_log_once regenerate
  say "preflight"
  is_dry && note "*** DRY RUN: nothing talks to the T1, the ESP or the network ***"

  model=$(model_id); status=$(model_status "$model")
  case "$status" in
    tested) note "model: $model (tested)";;
    untested) warn "model $model is a T1 machine this tool has not been run on yet; the procedure is the same, continue at your own risk and please report";;
    *) die 4 "this is not a supported T1 MacBook Pro ($model)";;
  esac

  [ -n "$(frst_method)" ] || die 4 "no T1 reset method (FRST) found in the ACPI tables; the no-reboot chain cannot run here"
  fw=$(firmware_dir) || exit "$?"
  bundle_ok "$fw"
  note "firmware bundle OK"

  prefix_env
  for n in "$T1R_IDR" "$T1R_MUX" "$T1R_PLISTUTIL"; do
    [ -x "$n" ] || die 3 "patched tool missing: $n (build the prefix or install the package)"
  done
  note "patched tools OK"
  no_system_usbmuxd 3
  if command -v t1bridge >/dev/null 2>&1 || modinfo -n t1_cfgsel >/dev/null 2>&1; then
    note "t1bridge is installed; its modules get reloaded by the kernel when 8600 appears; the boot step handles that"
  fi

  # Existing EFI/APPLE/EMBEDDEDOS is replaced by the regenerated set. An off-disk backup is
  # optional: the data can be regenerated again as long as Apple signs it, and cmd_stage keeps an
  # on-disk copy of the old files under private/esp-backup-<stamp>/ before writing. We warn here
  # and the start confirmation below covers it (the plan names the replacement explicitly).
  local has_data=0
  esp_resolve_or_die; esp_mnt=$ESP_MNT
  if [ -n "$esp_mnt" ] && [ -d "$esp_mnt/EFI/APPLE/EMBEDDEDOS" ]; then
    has_data=1
    if [ -z "$(backup_latest)" ]; then
      warn "the ESP already holds EFI/APPLE/EMBEDDEDOS and no off-disk backup was made with: t1-revive backup --to PATH"
      note "the old files are kept on this disk under $T1R_STATE/private/esp-backup-<stamp>/ when staging;"
      note "an off-disk copy only matters if Apple ever stops signing this data (then it cannot be regenerated)."
      diag step=gate backup=none existing_data=yes
    else
      note "existing EFI/APPLE/EMBEDDEDOS on the ESP; an off-disk backup exists"
    fi
  else
    note "no EFI/APPLE/EMBEDDEDOS on the ESP"
  fi
  note "T1 now: $(t1_product)   start: $from"
  priv="${T1R_STATE:?}/private"

  if [ "${T1R_DEMO:-0}" = 1 ]; then
    show "Before we start:"
    if [ -n "$esp_mnt" ] && [ -d "$esp_mnt/EFI/APPLE/EMBEDDEDOS" ]; then show "  ✗ this disk already has Apple firmware files"; else show "  ✓ no Apple firmware folder on this disk"; fi
    if [ -d "$priv" ]; then show "  ✗ saved device data present"; else show "  ✓ no saved device data on this machine"; fi
    n=$(find / -xdev \( -iname 'FDRData*' -o -iname '*.memboot' \) -type f 2>/dev/null | wc -l)
    if [ "$n" = 0 ]; then show "  ✓ no firmware files anywhere on the disk"; else show "  ✗ $n firmware files found on the disk"; fi
    if [ "$(t1_state)" = recovery ]; then show "  ✓ T1 state: recovery mode (nothing loaded)"; else show "  ✓ T1 state: $(t1_product)"; fi
    show "  Only inputs: Apple's public firmware package and Apple's servers."
  fi

  [ "${T1R_DEMO:-0}" = 1 ] || { say "plan"; _regen_plan "$start" "$has_data"; }
  if [ "$has_data" = 1 ]; then confirm "start the regeneration at '$from' and replace the existing Apple data with regenerated data"
  else confirm "start the regeneration at '$from'"; fi
  diag step=chain result=start from="$from"

  # -------------------------------------------------------------- chain ----
  if [ "$start" -le 1 ]; then
    step_banner "Step 1 of 4: the T1 asks Apple for its own data" "step 1/7 · provision (FDR provisioning)"
    _regen_ensure_recovery provision
    confirm_each "run provision (the T1 talks to Apple and receives its FDR data)"
    run_step provision step_provision "talking to Apple's servers" || _regen_fail provision "provision failed (see the log)"
    expect_file "$priv/FDRData" 5 "provision finished but no FDRData. $(fallback_text provision)"
    note "FDRData: $(file_size "$priv/FDRData") bytes"
  fi
  if [ "$start" -le 2 ]; then
    [ "${T1R_DEMO:-0}" = 1 ] || say "step 2/7 · reset (back to recovery for personalize)"
    confirm_each "reset the T1 (FRST) after provision"
    run_step reset-1 step_reset "resetting the T1" || _regen_fail reset-1 "T1 reset after provision failed"
    _regen_reset_seen=1
  fi
  if [ "$start" -le 3 ]; then
    step_banner "Step 2 of 4: personalising the T1's boot image" "step 3/7 · personalize (memboot + ticket capture)"
    _regen_ensure_recovery personalize
    confirm_each "run personalize (captures the boot image and ticket for this T1)"
    run_step personalize step_personalize "talking to Apple's servers" || _regen_fail personalize "personalize failed (see the log)"
    expect_file "$priv/combined.preflight.memboot" 5 "personalize finished but the image is missing. $(fallback_text personalize)"
    expect_file "$priv/preflight.apticket" 5 "personalize finished but the ticket is missing. $(fallback_text personalize)"
    note "image: $(file_size "$priv/combined.preflight.memboot") bytes, ticket: $(file_size "$priv/preflight.apticket") bytes"
  fi
  if [ "$start" -le 4 ]; then
    [ "${T1R_DEMO:-0}" = 1 ] || say "step 4/7 · reset (back to recovery for boot)"
    confirm_each "reset the T1 (FRST) after personalize"
    run_step reset-2 step_reset "resetting the T1" || _regen_fail reset-2 "T1 reset after personalize failed"
    _regen_reset_seen=1
  fi
  if [ "$start" -le 5 ]; then
    step_banner "Step 3 of 4: booting the T1" "step 5/7 · boot (boot the T1 from the captured image)"
    _regen_ensure_recovery boot
    confirm_each "boot the T1 from the captured image (watch the Touch Bar)"
    for n in t1_cfgsel appletbdrm apple_t1_ncm; do dry_q modprobe -r "$n" || true; done
    run_step boot step_boot "watch the Touch Bar" || _regen_fail boot "boot did not reach a stable 05ac:8600 (see the log)"
    dry_wait booted 5 || _regen_fail boot "T1 not at 8600 after the boot step"
  fi
  if [ "$start" -le 6 ]; then
    step_banner "Step 4 of 4: making it permanent" "step 6/7 · stage the ESP"
    t1_require booted 5 "T1 must be alive at 8600 to stage. $(fallback_text boot)"
    local -a stage_args=(); [ "$force" = 1 ] && stage_args=(--force)
    ( cmd_stage --dry-run "${stage_args[@]}" ) || die 4 "stage dry run refused (see above)"
    confirm "write to the ESP (the preview above is exactly what gets written)"
    if is_dry; then
      run_step stage _regen_stage_dry "writing the boot files" || _regen_fail stage "staging the ESP failed"
    else
      # cmd_stage lists the verified folder itself
      run_step stage cmd_stage "writing the boot files" "${stage_args[@]}" || _regen_fail stage "staging the ESP failed"
    fi
  fi
  if [ "$start" -le 7 ]; then
    [ "${T1R_DEMO:-0}" = 1 ] || say "step 7/7 · handover"
    run_step handover cmd_handover "handing the Touch Bar to its driver" || _regen_fail handover "handover failed"
  fi

  # ------------------------------------------------------------ summary ----
  diag step=chain result=ok
  if [ "${T1R_DEMO:-0}" = 1 ]; then
    show ""; show "Done. The T1 is back."; show "  Created just now:"
    # shellcheck disable=SC2012
    [ -n "$esp_mnt" ] && ls -l --time-style='+%H:%M:%S' "$esp_mnt/EFI/APPLE/EMBEDDEDOS" 2>/dev/null | awk 'NR>1{printf "    %s  %s\n", $6, $7}' | while IFS= read -r n; do show "$n"; done
  else
    say "regenerate complete. T1: $(t1_product)"
  fi
  say "timing"
  timing_summary
  return 0
}
