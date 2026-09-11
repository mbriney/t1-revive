# lib/steps/pass-b.sh - step_pass_b: replay the pass-A FDR store, capture the
# personalised preflight memboot image and its AP ticket. Port of pass-b.sh.
#
# THIS TALKS TO THE T1 AND IS NOT REVERSIBLE. Same EmbeddedOS restore as
# pass A, with the FDR store replayed as input and the preflight image + ticket
# saved; phase 14 replays exactly that pair. No ESP or Linux-install writes;
# no FRST. Identity-bearing data stays 0600 under $T1R_STATE/private.
# shellcheck shell=bash

step_pass_b() {
  local priv fw rc boot_args f ok
  prefix_env
  fw=$(firmware_dir) || exit 1
  boot_args='rd=md0 -restore IOUSBDeviceController-configuration=standardMuxOnly'
  priv="${T1R_STATE:?}/private"

  say "pass B: preflight checks"
  # 1. The T1 must be in recovery. If it is already 8600 we must not touch it.
  t1_forbid booted 5 "a device is already at 05ac:8600 - the T1 is alive, do NOT run pass B"
  t1_require recovery 5 "no 05ac:1281 device found"
  note "T1 in recovery"
  # 2. Binaries must be the patched ones.
  [ -x "$T1R_MUX" ] || die 3 "patched usbmuxd not built at $T1R_MUX"
  check_idevicerestore "T1: EmbeddedOS restore options applied"
  note "patched binaries OK"
  # 2b. Pass A's FDR store must exist - it is the whole point of pass B.
  expect_file "$priv/FDRData" 4 "no FDRData from pass A (run: t1-revive regenerate --from pass-a)"
  if ! is_dry; then
    LD_LIBRARY_PATH="$T1R_LIBS" "$T1R_PLISTUTIL" -i "$priv/FDRData" -o /dev/null 2>/dev/null \
      || die 4 "the pass-A FDRData does not parse as a plist"
  fi
  note "pass A FDRData present ($(file_size "$priv/FDRData") bytes)"
  # 3. Firmware bundle.
  bundle_ok "$fw"
  note "firmware bundle OK"
  # 4. No system usbmuxd competing.
  no_system_usbmuxd 3
  note "no competing usbmuxd"

  priv=$(priv_dir) || exit 1

  say "pass B: starting private usbmuxd"
  start_usbmuxd "$priv"

  say "pass B: EmbeddedOS restore with FDR INPUT replayed + preflight capture"
  note "(this takes a few minutes; do not unplug or sleep the machine)"
  install -m 600 /dev/null "$priv/phase11.private.log"
  install -m 600 /dev/null "$priv/phase11-runner.private.log"

  dry env \
    -u IDEVICERESTORE_T1_PHASE14 \
    -u IDEVICERESTORE_T1_APTICKET_FILE \
    -u IDEVICERESTORE_MEMBOOT_FILE \
    -u IDEVICERESTORE_MEMBOOT_EXACT \
    -u IDEVICERESTORE_MEMBOOT_SAVE \
    -u IDEVICERESTORE_MEMBOOT_2GMI \
    -u IDEVICERESTORE_OSRAMDISK \
    -u IDEVICERESTORE_OSRAMDISK_SEPARATE \
    LD_LIBRARY_PATH="$T1R_LIBS" \
    IDEVICERESTORE_T1_EMBEDDEDOS=1 \
    IDEVICERESTORE_T1_FDR_INPUT="$priv/FDRData" \
    IDEVICERESTORE_T1_FDR_OUTPUT="$priv/FDRData.replayed" \
    IDEVICERESTORE_T1_PREFLIGHT_MEMBOOT_SAVE="$priv/combined.preflight.memboot" \
    IDEVICERESTORE_T1_PREFLIGHT_TICKET_SAVE="$priv/preflight.apticket" \
    IDEVICERESTORE_RESTORE_BOOT_ARGS="$boot_args" \
    "$T1R_IDR" -y --variant 'Customer Boot' \
    --logfile="$priv/phase11.private.log" \
    "$fw" \
    2>&1 | tee "$priv/phase11-runner.private.log" \
         | redact_restore
  rc=${PIPESTATUS[0]}
  chmod 600 "$priv"/*.log 2>/dev/null

  say "pass B: result"
  restore_report "$priv/phase11-runner.private.log" "$rc"
  ok=1
  for f in combined.preflight.memboot preflight.apticket FDRData.replayed; do
    if [ -s "$priv/$f" ]; then
      chmod 600 "$priv/$f"
      note "$f: $(stat -c '%s bytes mode %a' "$priv/$f")"
    else
      note "$f: MISSING OR EMPTY"; ok=0
    fi
  done
  if [ -s "$priv/FDRData.replayed" ]; then
    if cmp -s "$priv/FDRData" "$priv/FDRData.replayed"; then
      note "FDR replay matches pass A store byte-for-byte: yes"
    else
      note "FDR replay matches pass A store byte-for-byte: NO (sizes: $(file_size "$priv/FDRData") vs $(file_size "$priv/FDRData.replayed"))"
    fi
  fi
  if [ "$ok" = 1 ] && [ "$rc" = 0 ]; then
    note "PASS B: all artefacts captured."
  else
    note "PASS B: incomplete - do NOT run phase 14 with these artefacts."
  fi

  say "pass B: T1 USB state now"
  usb_report

  note "stopping private usbmuxd"
  stop_usbmuxd
  note "pass B finished. NOTHING has been written to the ESP."
  sleep 0.5
  [ "$rc" = 0 ]
}
