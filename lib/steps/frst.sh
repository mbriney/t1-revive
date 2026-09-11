# lib/steps/frst.sh - step_frst: the T1-only ACPI reset. Port of one-shot.sh's
# frst() (timings from frst-test.sh, proven 2026-09-07: T1 leaves the bus
# within a second and is back as 05ac:1281 a few seconds later).
#
# The method path comes from frst_method (lib/discover.sh), discovered from
# this machine's ACPI tables; nothing else is ever written to /proc/acpi/call.
# shellcheck shell=bash

step_frst() {
  local method res
  method=$(frst_method) || method=""
  [ -n "$method" ] || die 4 "no T1 reset method found in the ACPI tables; refusing to guess"
  case "$method" in *.FRST) ;; *) die 4 "unexpected reset method name; refusing";; esac

  # Inside run_step the spinner already names the step on screen (demo mode).
  if [ "${T1R_IN_STEP:-0}" = 1 ]; then say "FRST: T1-only reset"
  else step_banner "  Resetting the T1" "FRST: T1-only reset"; fi
  dry_q systemctl stop "${T1R_MUX_UNIT:-t1-usbmuxd}.service" || true
  dry_q modprobe acpi_call
  if ! is_dry; then [ -w /proc/acpi/call ] || die 3 "acpi_call unavailable (modprobe acpi_call failed or /proc/acpi/call not writable)"; fi
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
