# lib/steps/reset.sh - step_reset: the T1-only ACPI reset (the FRST method).
# ported from frst-test.sh / one-shot.sh's frst() (proven 2026-09-07: T1 leaves
# the bus within a second and is back as 05ac:1281 a few seconds later).
#
# The method path comes from frst_method (lib/discover.sh), discovered from
# this machine's ACPI tables; nothing else is ever written to /proc/acpi/call.
# shellcheck shell=bash

step_reset() {
  local method res
  method=$(frst_method) || method=""
  [ -n "$method" ] || die 4 "no T1 reset method found in the ACPI tables; refusing to guess"
  case "$method" in *.FRST) ;; *) die 4 "unexpected reset method name; refusing";; esac

  # Inside run_step the spinner already names the step on screen (demo mode).
  if [ "${T1R_IN_STEP:-0}" = 1 ]; then say "reset: T1-only ACPI reset (FRST)"
  else step_banner "  Resetting the T1" "reset: T1-only ACPI reset (FRST)"; fi
  dry_q systemctl stop "${T1R_MUX_UNIT:-t1-usbmuxd}.service" || true
  dry_q modprobe acpi_call
  # Seen on a 13,3 (issue #4): the chain stopped here twice with code 3 and elapsed=0. The
  # message names the running kernel because a DKMS module built for another one is the
  # usual reason modprobe fails after preflight had passed.
  if ! is_dry; then [ -w /proc/acpi/call ] || die 3 "acpi_call is not loaded: /proc/acpi/call is not writable (modprobe acpi_call failed; is the module built for the running kernel $(uname -r)? 'sudo dkms status' lists the builds, 'sudo t1-revive preflight' loads it, '--install' rebuilds it)"; fi
  dry_write /proc/acpi/call '%s' "$method" || die 5 "FRST write failed"
  if is_dry; then
    note "(dry) read the result back from /proc/acpi/call"
  else
    res=$(tr -cd '[:print:]' < /proc/acpi/call)
    note "FRST returned '$res'"
  fi
  dry_wait recovery 60 || die 5 "T1 did not return to recovery (05ac:1281) within 60 s after FRST"
  if [ "${T1R_DEMO:-0}" = 1 ] && [ "${T1R_IN_STEP:-0}" != 1 ]; then show "  ✓ T1 reset"; else note "T1 in recovery. Settling 12 s."; fi
  dry_sleep 12
}
