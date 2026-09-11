# lib/cmd-handover.sh - cmd_handover: hand a T1 that is already booted
# (05ac:8600) to t1bridge without a restart. Port of one-shot.sh step 5 and
# the no-reboot handover proven 2026-09-07 (re-enumerating the USB
# device makes t1bridge's configuration selector pick configuration 2; udev
# then starts the t1bridge stack on its own).
#
# Without t1bridge's selector module there is nothing to hand the T1 to: the
# command then says what to install and leaves the T1 running as it is.
# shellcheck shell=bash

# The dispatcher sources only lib/cmd-<sub>.sh; pull in the shared step code.
_t1r_lib=${T1R_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/lib
# shellcheck source=steps/common-steps.sh
declare -F run_step >/dev/null 2>&1 || . "$_t1r_lib/steps/common-steps.sh"

cmd_handover() {
  local dev cfg m sock=/run/t1bridge/touchbar.sock
  [ $# -eq 0 ] || die 2 "usage: t1-revive handover"
  require_root
  open_log_once handover
  lock_once

  say "handover: giving the booted T1 to t1bridge"
  t1_require booted 5 "the T1 is not at 05ac:8600; handover needs a booted T1 (power cycle, then: t1-revive handover)"
  dev=$(t1_sysfs)
  if [ -z "$dev" ]; then
    is_dry && dev="${T1R_SYSFS:-/sys}/bus/usb/devices/T1"
    [ -n "$dev" ] || die 5 "cannot find the T1's sysfs node"
  fi

  if ! modinfo -n t1_cfgsel >/dev/null 2>&1 && ! command -v t1bridge >/dev/null 2>&1; then
    note "t1bridge is not installed on this machine, so nothing takes the T1 yet."
    note "The T1 keeps running the regenerated image; once the ESP is staged it boots from it on its own."
    note "Next: install t1bridge (https://github.com/standardagents/t1bridge; on Omarchy see docs/omarchy.md),"
    note "then run: t1-revive handover   (or simply power cycle once)."
    diag step=handover result=skipped reason=no-t1bridge
    return 0
  fi

  note "t1bridge is installed: re-enumerating the T1 so its configuration selector takes it (no reboot)"
  [ "${T1R_DEMO:-0}" = 1 ] && show "  Handing the Touch Bar to its driver"
  dry_q modprobe t1_cfgsel || true
  confirm "re-enumerate the T1 (${dev##*/})"
  dry_write "$dev/authorized" '%s\n' 0; dry_sleep 2
  for m in apple_touchbar apple_ibridge; do
    if dry_q modprobe -r "$m"; then note "unloaded firmware-bar driver $m"; fi
  done
  dry_write "$dev/authorized" '%s\n' 1; dry_sleep 4

  if is_dry; then
    note "(dry) read bConfigurationValue (2 = t1bridge owns it)"
  else
    cfg=$(t1_config)
    if [ "$cfg" != 2 ]; then                      # give udev/t1_cfgsel a few more seconds
      for _ in $(seq 1 12); do sleep 0.5; cfg=$(t1_config); [ "$cfg" = 2 ] && break; done
    fi
    note "T1 configuration now: ${cfg:-unset} (2 = t1bridge owns it)"
    [ "$cfg" = 2 ] || warn "t1bridge's selector did not take the T1 (configuration ${cfg:-unset}); a full power cycle will"
    diag step=handover result=enumerated config="${cfg:-none}"
  fi

  if command -v t1bridge >/dev/null 2>&1; then
    if ! is_dry; then
      for _ in $(seq 1 30); do [ -S "$sock" ] && break; sleep 0.5; done
      if [ -S "$sock" ]; then note "t1bridge hardware socket is up"; else warn "t1bridge hardware socket did not appear within 15 s"; fi
      sleep 3
      t1bridge status 2>/dev/null | sed 's/^/   /' || true
    else
      note "(dry) wait up to 15 s for $sock, then: t1bridge status"
    fi
    note "If the Touch Bar is not drawn by t1bridge within ~10 s: full power cycle (the ESP is staged, it comes back)."
    note "Touch ID needs t1bridge's import and enrolment (see its README; on Omarchy also docs/omarchy.md)."
  else
    note "t1bridge's selector module is present but the t1bridge CLI is not; install the t1bridge packages, then check: t1bridge status"
  fi
  return 0
}
