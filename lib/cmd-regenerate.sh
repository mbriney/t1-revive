# lib/cmd-regenerate.sh - cmd_regenerate: the whole T1 regeneration with no
# reboot between steps. Port of one-shot.sh.
#
#   t1-revive regenerate                 pass-a -> frst-a -> pass-b -> frst-b -> phase14 -> stage -> handover
#   t1-revive regenerate --from STEP     resume at pass-a | frst-a | pass-b | frst-b | phase14 | stage | handover
#   t1-revive regenerate --force         proceed without an ESP backup (warns); passed on to stage
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
for _t1r_f in steps/pass-a steps/pass-b steps/phase14 steps/frst cmd-stage cmd-handover; do
  # shellcheck disable=SC1090
  . "$_t1r_lib/$_t1r_f.sh"
done
unset _t1r_f

_regen_steps="pass-a frst-a pass-b frst-b phase14 stage handover"

_regen_index() {
  case "$1" in
    pass-a) echo 1;; frst-a) echo 2;; pass-b) echo 3;; frst-b) echo 4;;
    phase14) echo 5;; stage) echo 6;; handover) echo 7;; *) echo 0;;
  esac
}

# _regen_fail STEP MSG: die 5 with the fallback for resuming at STEP.
_regen_fail() { die 5 "$2. $(fallback_text "$1")"; }

# _regen_ensure_recovery STEP: one-shot's `[ "$(t1)" = 1281 ] || frst` guard.
_regen_ensure_recovery() {
  [ "$(t1_state)" = recovery ] && return 0
  note "T1 is not in recovery; resetting it first"
  ( step_frst ) || _regen_fail "$1" "T1 reset before $1 failed"
}

cmd_regenerate() {
  local from=pass-a force=0 start priv fw esp_mnt model status n
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
  fw=$(firmware_dir) || exit 1
  bundle_ok "$fw"
  note "firmware bundle OK"

  prefix_env
  for n in "$T1R_IDR" "$T1R_MUX" "$T1R_PLISTUTIL"; do
    [ -x "$n" ] || die 3 "patched tool missing: $n (build the prefix or install the package)"
  done
  note "patched tools OK"
  no_system_usbmuxd 3
  if command -v t1bridge >/dev/null 2>&1 || modinfo -n t1_cfgsel >/dev/null 2>&1; then
    note "t1bridge is installed; its modules get reloaded by the kernel when 8600 appears; phase 14 handles that"
  fi

  # The backup rule: an existing EFI/APPLE/EMBEDDEDOS is never overwritten
  # before `t1-revive backup` saved it.
  read -r _ esp_mnt < <(esp_resolve)
  if [ -n "$esp_mnt" ] && [ -d "$esp_mnt/EFI/APPLE/EMBEDDEDOS" ]; then
    if [ -z "$(backup_latest)" ]; then
      if [ "$force" = 1 ]; then
        warn "the ESP already holds EFI/APPLE/EMBEDDEDOS and no backup exists; --force given, continuing"
      else
        die 4 "the ESP already holds EFI/APPLE/EMBEDDEDOS and no backup exists under $T1R_STATE. Run: t1-revive backup   first"
      fi
    else
      note "existing EFI/APPLE/EMBEDDEDOS on the ESP; a backup exists"
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

  confirm "This talks to the T1 and is not reversible. It runs the restore protocol against Apple's servers, resets the T1 twice, boots it, and writes EFI/APPLE/EMBEDDEDOS on the ESP. Start at: $from"
  T1R_NO_CONFIRM=1; export T1R_NO_CONFIRM   # confirmed once; the steps do not ask again
  diag step=chain result=start from="$from"

  # -------------------------------------------------------------- chain ----
  if [ "$start" -le 1 ]; then
    step_banner "Step 1 of 4: the T1 asks Apple for its own data" "step 1/7 · pass A (FDR creation)"
    _regen_ensure_recovery pass-a
    run_step pass-a step_pass_a "talking to Apple's servers" || _regen_fail pass-a "pass A failed (see the log)"
    expect_file "$priv/FDRData" 5 "pass A finished but no FDRData. $(fallback_text pass-a)"
    note "FDRData: $(file_size "$priv/FDRData") bytes"
  fi
  if [ "$start" -le 2 ]; then
    run_step frst-a step_frst "resetting the T1" || _regen_fail frst-a "T1 reset after pass A failed"
  fi
  if [ "$start" -le 3 ]; then
    step_banner "Step 2 of 4: personalising the T1's boot image" "step 3/7 · pass B (memboot + ticket capture)"
    _regen_ensure_recovery pass-b
    run_step pass-b step_pass_b "talking to Apple's servers" || _regen_fail pass-b "pass B failed (see the log)"
    expect_file "$priv/combined.preflight.memboot" 5 "pass B finished but the image is missing. $(fallback_text pass-b)"
    expect_file "$priv/preflight.apticket" 5 "pass B finished but the ticket is missing. $(fallback_text pass-b)"
    note "image: $(file_size "$priv/combined.preflight.memboot") bytes, ticket: $(file_size "$priv/preflight.apticket") bytes"
  fi
  if [ "$start" -le 4 ]; then
    run_step frst-b step_frst "resetting the T1" || _regen_fail frst-b "T1 reset after pass B failed"
  fi
  if [ "$start" -le 5 ]; then
    step_banner "Step 3 of 4: booting the T1" "step 5/7 · phase 14 (boot the T1 with the captured image)"
    _regen_ensure_recovery phase14
    for n in t1_cfgsel appletbdrm apple_t1_ncm; do dry_q modprobe -r "$n" || true; done
    run_step phase14 step_phase14 "watch the Touch Bar" || _regen_fail phase14 "phase 14 did not reach a stable 05ac:8600 (see the log)"
    dry_wait booted 5 || _regen_fail phase14 "T1 not at 8600 after phase 14"
  fi
  if [ "$start" -le 6 ]; then
    step_banner "Step 4 of 4: making it permanent" "step 6/7 · stage the ESP"
    t1_require booted 5 "T1 must be alive at 8600 to stage. $(fallback_text phase14)"
    local -a stage_args=(); [ "$force" = 1 ] && stage_args=(--force)
    ( cmd_stage --dry-run "${stage_args[@]}" ) || die 4 "stage dry run refused (see above)"
    run_step stage cmd_stage "writing the boot files" "${stage_args[@]}" || _regen_fail stage "staging the ESP failed"
    # shellcheck disable=SC2012
    [ "${T1R_DEMO:-0}" = 1 ] || { [ -n "$esp_mnt" ] && ls -la "$esp_mnt/EFI/APPLE/EMBEDDEDOS" 2>/dev/null | sed 's/^/   /'; }
  fi
  if [ "$start" -le 7 ]; then
    say "step 7/7 · handover"
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
