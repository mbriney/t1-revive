# lib/steps/phase14.sh - step_phase14: replay the pass-B preflight image + AP
# ticket and watch USB. Port of the proven phase14.sh.
#
# THIS TALKS TO THE T1. It runs no restore, requests no new ticket, and does
# not touch the ESP. Sequence (inside the patched idevicerestore, phase-14
# mode): auto-boot=false + saveenv, send the SAVED AP ticket, upload the SAVED
# combined memboot, setenv boot-args rd=md0, blind memboot (bRequest=1). Then
# USB is watched for 30 s: success is a 05ac:8600 that stays and does not fall
# back to 05ac:1281.
# shellcheck shell=bash

step_phase14() {
  local priv fw image ticket rc sysfs
  local s8600=0 s1281=0 snone=0 last="" i s d n hid drv cfg
  prefix_env
  fw=$(firmware_dir) || exit 1
  priv="${T1R_STATE:?}/private"
  image="$priv/combined.preflight.memboot"
  ticket="$priv/preflight.apticket"
  sysfs="${T1R_SYSFS:-/sys}"

  say "phase 14: preflight checks"
  t1_forbid booted 5 "a device is already at 05ac:8600 - the T1 is alive, do NOT run phase 14"
  t1_require recovery 5 "no 05ac:1281 device found (the T1 must be in recovery)"
  note "T1 in recovery"
  note "uptime: $(uptime -p 2>/dev/null)"

  check_idevicerestore "T1: phase 14 mode"
  note "patched binary OK"

  expect_file "$image" 4 "missing preflight image (run pass B first)"
  expect_file "$ticket" 4 "missing preflight ticket (run pass B first)"
  note "image:  $(file_size "$image") bytes"
  note "ticket: $(file_size "$ticket") bytes"
  if [ "$(file_size "$image")" = 30667180 ]; then
    note "image size matches the reference build: yes"
  else
    note "image size differs from the reference (30667180) - continuing anyway"
  fi
  bundle_ok "$fw"

  # Phase 14 talks to recovery over libusb only; no usbmuxd must be running.
  if systemctl is-active --quiet "$T1R_MUX_UNIT.service"; then note "stopping private usbmuxd"; stop_usbmuxd; fi
  no_system_usbmuxd 3
  note "no usbmuxd running"

  # Have the Touch Bar driver registered BEFORE the device enumerates, so it
  # wins the HID match against the mainline hid_appletb_kbd. Harmless if no
  # device appears; apple_ibridge (ACPI platform driver) is normally already up.
  dry_q modprobe apple_ibridge || true
  if dry_q modprobe apple_touchbar; then note "apple_touchbar loaded"; else note "apple_touchbar NOT loaded (modprobe failed)"; fi
  lsmod 2>/dev/null | awk '$1=="apple_ibridge"||$1=="apple_touchbar"{printf "   module %s loaded\n",$1}'

  install -m 600 /dev/null "$priv/phase14.private.log"
  install -m 600 /dev/null "$priv/phase14-runner.private.log"

  say "phase 14: replaying preflight image + ticket"
  dry env \
    -u IDEVICERESTORE_T1_EMBEDDEDOS \
    -u IDEVICERESTORE_T1_FDR_INPUT \
    -u IDEVICERESTORE_T1_FDR_OUTPUT \
    -u IDEVICERESTORE_T1_PREFLIGHT_MEMBOOT_SAVE \
    -u IDEVICERESTORE_T1_PREFLIGHT_TICKET_SAVE \
    -u IDEVICERESTORE_MEMBOOT_EXACT \
    -u IDEVICERESTORE_MEMBOOT_SAVE \
    -u IDEVICERESTORE_MEMBOOT_2GMI \
    -u IDEVICERESTORE_OSRAMDISK_SEPARATE \
    -u IDEVICERESTORE_IBOOT_LOG \
    LD_LIBRARY_PATH="$T1R_LIBS" \
    IDEVICERESTORE_OSRAMDISK=1 \
    IDEVICERESTORE_MEMBOOT_OS_IMAGE=1 \
    IDEVICERESTORE_T1_PHASE14=1 \
    IDEVICERESTORE_MEMBOOT_FILE="$image" \
    IDEVICERESTORE_T1_APTICKET_FILE="$ticket" \
    IDEVICERESTORE_RESTORE_BOOT_ARGS='rd=md0' \
    "$T1R_IDR" -y --variant 'Customer Boot' \
    --logfile="$priv/phase14.private.log" \
    "$fw" \
    2>&1 | tee "$priv/phase14-runner.private.log" \
         | redact_restore
  rc=${PIPESTATUS[0]}
  chmod 600 "$priv"/*.log 2>/dev/null
  note "phase-14 dispatch exit: $rc   (0 only proves the transaction was sent)"

  say "phase 14: watching USB for 30 s (120 samples)"
  if is_dry; then
    note "(dry) 120 samples of the T1 USB state at 0.25 s; success = 05ac:8600 in >= 60 samples, 05ac:1281 in none, 8600 last"
    note "(dry) then: force bConfigurationValue 1, power/control on, sleep 3, hid-sensor-hub unbind, sleep 2, 1D6B:0301 probe, sleep 1"
    note "phase 14: (dry) verdict skipped"
    return 0
  fi
  for i in $(seq 1 120); do
    s=$(t1_product)
    case "$s" in 8600) s8600=$((s8600+1));; 1281) s1281=$((s1281+1));; *) snone=$((snone+1));; esac
    if [ "$s" != "$last" ]; then note "t=$((i/4))s: $s"; last=$s; fi
    sleep 0.25
  done
  note "samples: iBridge(8600)=$s8600 recovery(1281)=$s1281 absent=$snone"

  # On these machines the iBridge enumerates UNCONFIGURED (bConfigurationValue
  # empty). Forcing configuration 1 host-side exposes the Touch Bar HID
  # interfaces and the webcam, so the verdict reflects a real EmbeddedOS boot.
  if [ "$s8600" -gt 0 ]; then
    for d in "$sysfs"/bus/usb/devices/*/; do
      [ "$(cat "$d/idVendor" 2>/dev/null)" = "05ac" ] || continue
      [ "$(cat "$d/idProduct" 2>/dev/null)" = "8600" ] || continue
      cfg=$(cat "$d/bConfigurationValue" 2>/dev/null)
      note "$(basename "$d") bConfigurationValue='${cfg}' before"
      if [ "$cfg" != "1" ]; then
        if dry_write "$d/bConfigurationValue" '%s\n' 1 2>/dev/null; then note "forced USB configuration 1"; else note "could not set configuration 1"; fi
      fi
      dry_write "$d/power/control" '%s\n' on 2>/dev/null && note "USB autosuspend disabled for the iBridge"
    done
    sleep 3
    # Since kernel 6.3 the generic hid-sensor-hub can grab one physical iBridge
    # interface before apple-ibridge. Unbind it and let the HID core re-probe,
    # then make sure the virtual 1D6B:0301 device is bound to apple-touchbar.
    for hid in "$sysfs"/bus/hid/devices/*05AC:8600*; do
      [ -e "$hid" ] || continue
      drv=$(basename "$(readlink -f "$hid/driver" 2>/dev/null)" 2>/dev/null)
      if [ "$drv" = "hid-sensor-hub" ]; then
        note "$(basename "$hid") was grabbed by hid-sensor-hub, unbinding"
        dry_write "$sysfs/bus/hid/drivers/hid-sensor-hub/unbind" '%s\n' "$(basename "$hid")" 2>/dev/null
        dry_write "$sysfs/bus/hid/drivers_probe" '%s\n' "$(basename "$hid")" 2>/dev/null
      fi
    done
    sleep 2
    for hid in "$sysfs"/bus/hid/devices/*1D6B:0301*; do
      [ -e "$hid" ] || continue
      [ -L "$hid/driver" ] || { note "$(basename "$hid") unbound, probing"; dry_write "$sysfs/bus/hid/drivers_probe" '%s\n' "$(basename "$hid")" 2>/dev/null; }
    done
    sleep 1
  fi

  say "phase 14: iBridge USB interfaces now"
  for d in "$sysfs"/bus/usb/devices/*/; do
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "05ac" ] || continue
    [ "$(cat "$d/idProduct" 2>/dev/null)" = "8600" ] || continue
    n=$(basename "$d")
    note "$n: product='$(cat "$d/product" 2>/dev/null)' config=$(cat "$d/bConfigurationValue" 2>/dev/null) numcfg=$(cat "$d/bNumConfigurations" 2>/dev/null) speed=$(cat "$d/speed" 2>/dev/null)"
    for i in "$d"/"$n":*; do
      [ -d "$i" ] || continue
      drv=$(basename "$(readlink "$i/driver" 2>/dev/null)" 2>/dev/null)
      note "  $(basename "$i") class=$(cat "$i/bInterfaceClass" 2>/dev/null) sub=$(cat "$i/bInterfaceSubClass" 2>/dev/null) proto=$(cat "$i/bInterfaceProtocol" 2>/dev/null) driver=${drv:-unbound}"
    done
  done

  say "phase 14: HID devices"
  for hid in "$sysfs"/bus/hid/devices/*05AC:8600* "$sysfs"/bus/hid/devices/*05AC:8302* "$sysfs"/bus/hid/devices/*05AC:8102* "$sysfs"/bus/hid/devices/*1D6B:0301*; do
    [ -e "$hid" ] || continue
    drv=unbound; [ -L "$hid/driver" ] && drv=$(basename "$(readlink -f "$hid/driver")")
    note "$(basename "$hid") -> $drv"
  done
  grep -iE 'iBridge|Touch Bar' /proc/bus/input/devices 2>/dev/null | sed 's/^/   input: /' || note "no iBridge/Touch Bar input devices"

  say "phase 14: kernel messages (usb/ibridge/touchbar)"
  d=$(t1_sysfs); n=${d##*/}
  dmesg --time-format reltime 2>/dev/null | tail -n 200 | grep -iE "usb ${n:-[0-9]+-[0-9]+}|ibridge|touchbar|appletb|hid" | tail -n 40 | sed 's/^/   /'

  say "phase 14: verdict"
  if [ "$s8600" -ge 60 ] && [ "$s1281" -eq 0 ] && [ "$last" = 8600 ]; then
    note "PHASE 14: 05ac:8600 stable for 30 s and no fallback to recovery."
    note "Look at the Touch Bar now. NOTHING has been written to the ESP yet."
    sleep 0.5
    return 0
  fi
  note "PHASE 14: NOT stable (see samples above). Do not stage anything on the ESP."
  sleep 0.5
  return 1
}
