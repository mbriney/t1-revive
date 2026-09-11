# Synthetic fixtures

Everything here is fake: `/dev/sdz`-style devices, USB device names, DMI strings. No file was
copied from a real machine. `sysfs-*` mimic `/sys/bus/usb/devices` (one unrelated root hub
`usb1` = 1d6b:0002 plus, except in `sysfs-none`, a T1 at `1-3`), `dmi-*` mimic
`/sys/class/dmi/id`, `lsblk-*.json` mimic `lsblk -J -o NAME,PATH,PARTTYPE,MOUNTPOINT,FSTYPE,LABEL`.
`lsblk-two-esp-apple.json.tmpl` is instantiated by the tests with a temporary mountpoint that
contains `EFI/APPLE`.
`os-release-*` mimic `/etc/os-release` (`T1R_OS_RELEASE`) so the distro checks do not depend on
the machine the suite runs on. `lsblk-one-esp-mounted.json.tmpl` is the single-ESP counterpart of
`lsblk-two-esp-apple.json.tmpl`: the tests instantiate it with a temporary mountpoint that stands
in for a mounted ESP.
