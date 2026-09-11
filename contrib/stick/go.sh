#!/usr/bin/env bash
# go.sh - the whole thing, from a fresh Linux install with a dead T1 to Touch ID, in one command:
#
#     bash /run/media/$USER/TOOLKIT/go.sh          [--dest DIR]
#
# 1. installs the toolkit from this stick (default /usr/local/lib/t1-revive)   2. checks the machine (no T1 contact)
# 3. regenerates the T1's firmware data from Apple                              4. installs the Touch Bar + Touch ID stack
# Stops at the first failure and says which step. Sudo is asked for once at the start.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
KIT=""
for _k in "$HERE"/t1-revive-toolkit-*.tar.zst; do [[ -f "$_k" ]] && { KIT=$_k; break; }; done
DEST=/usr/local/lib/t1-revive
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST=${2:?--dest needs a directory}; shift 2;;
    --dest=*) DEST=${1#--dest=}; shift;;
    -h|--help) awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0;;
    *) echo "unknown argument: $1"; exit 2;;
  esac
done
say() { printf '\n\e[1;32m%s\e[0m\n' "$*"; }
stop() { printf '\n\e[31mStopped at: %s\e[0m\n%s\n' "$1" "${2:-}"; exit 1; }
t1() { local r=none d; for d in /sys/bus/usb/devices/*; do [[ "$(cat "$d/idVendor" 2>/dev/null)" = 05ac ]] || continue; case "$(cat "$d/idProduct" 2>/dev/null)" in 8600) r=8600;; 1281) r=1281;; *) ;; esac; done; echo "$r"; }
bcm43602() { local d; for d in /sys/bus/pci/devices/*; do [[ "$(cat "$d/vendor" 2>/dev/null)" = 0x14e4 ]] && [[ "$(cat "$d/device" 2>/dev/null)" = 0x43ba ]] && return 0; done; return 1; }
# a mounted EFI System Partition that already carries Apple's EmbeddedOS folder (discovered, never a fixed path)
embeddedos_present() {
  local mp pt
  while read -r _ mp pt; do
    [[ "$pt" = c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] && [[ -n "$mp" ]] && sudo test -d "$mp/EFI/APPLE/EMBEDDEDOS" && return 0
  done < <(lsblk -nro PATH,MOUNTPOINT,PARTTYPE 2>/dev/null)
  return 1
}

[[ "$(id -u)" != 0 ]] || stop "user check" "run this as your normal user (it uses sudo where needed)"
[[ -n "$KIT" ]] || stop "toolkit" "no t1-revive-toolkit-*.tar.zst next to this script"
sudo -v || stop "sudo" "sudo is needed"
# keep that one sudo alive for the whole run (the update, the regeneration and the enrollment together
# outlast sudo's timestamp), and stop refreshing the moment this script is gone
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &

# Everything below needs the network: pacman in step 2, then Apple's servers in step 3. On this
# model the Wi-Fi is a BCM43602, for which linux-firmware ships no NVRAM calibration at all, so a
# fresh install can come up with no wireless until install-nvram.sh writes one.
if ! ip route 2>/dev/null | grep -q '^default'; then
  if bcm43602 && [[ ! -f /lib/firmware/brcm/brcmfmac43602-pcie.txt ]]; then
    stop "network" "No network, and this Mac's BCM43602 Wi-Fi has no NVRAM calibration yet.
  Fix Wi-Fi first:  sudo bash $HERE/install-nvram.sh CA     (2-letter country code)
  Then reconnect (a reboot is the surest way) and run this again."
  fi
  stop "network" "No default route. Connect to the network and run this again."
fi

say "1/4  Installing the toolkit"
TMP=$(mktemp -d) || stop "toolkit" "cannot create a temporary directory"
trap 'rm -rf "$TMP"' EXIT
if ! cp "$KIT" "$KIT.sha256" "$TMP/" || ! (cd "$TMP" && sha256sum -c "$(basename "$KIT").sha256" >/dev/null); then
  stop "toolkit checksum" "the toolkit on the stick does not match its checksum"
fi
tar --zstd -xf "$TMP/$(basename "$KIT")" -C "$TMP" || stop "toolkit extract"
[[ -f "$TMP/t1-revive-toolkit/t1-revive/bin/t1-revive" ]] || stop "toolkit layout" "no t1-revive/bin/t1-revive inside the tarball"
if ! { sudo rm -rf "$DEST.new" \
       && sudo mkdir -p "$DEST.new" \
       && sudo cp -a "$TMP/t1-revive-toolkit/t1-revive/." "$DEST.new/" \
       && sudo cp "$TMP/t1-revive-toolkit/MANIFEST.txt" "$DEST.new/MANIFEST.txt"; }; then
  stop "toolkit install" "could not copy the toolkit to $DEST"
fi
if [[ -d "$TMP/t1-revive-toolkit/omarchy-t1" ]]; then
  sudo cp -a "$TMP/t1-revive-toolkit/omarchy-t1" "$DEST.new/omarchy-t1" || stop "toolkit install" "could not copy omarchy-t1 to $DEST"
fi
if ! { sudo chown -R root:root "$DEST.new" \
       && sudo rm -rf "$DEST.old" \
       && { [[ ! -e "$DEST" ]] || sudo mv "$DEST" "$DEST.old"; } \
       && sudo mv "$DEST.new" "$DEST" \
       && sudo rm -rf "$DEST.old"; }; then
  stop "toolkit install" "could not move the toolkit into $DEST"
fi
if ! { sudo install -d /usr/local/bin && sudo ln -sfn "$DEST/bin/t1-revive" /usr/local/bin/t1-revive; }; then
  stop "toolkit install" "could not link /usr/local/bin/t1-revive"
fi
sudo t1-revive version >/dev/null 2>&1 || stop "toolkit install" "'sudo t1-revive version' does not run; is /usr/local/bin in sudo's secure_path?"
echo "  installed to $DEST ($(sudo t1-revive version 2>/dev/null | head -1))"

say "2/4  Checking the machine"
# Every kernel module this run builds (acpi_call now, t1bridge in step 4) must be built for the kernel
# that is running, and step 4 does a full system upgrade anyway. A fresh Omarchy install has only the
# ISO's offline package DB (no acpi_call-dkms) and an ISO kernel that is usually behind the repos, so:
# sync + full upgrade first, and if the kernel changed, one reboot -- then run this again, it continues.
# On an up-to-date machine this is a no-op.
if command -v pacman >/dev/null; then
  kver() { sed 's/\.arch/-arch/'; }   # pacman 7.2.3.arch1-3 -> uname 7.2.3-arch1-3
  repo_linux=$(pacman -Si linux 2>/dev/null | awk '/^Version/{print $3}' | kver)
  if ! pacman -Si acpi_call-dkms >/dev/null 2>&1 || [[ "$repo_linux" != "$(pacman -Q linux | awk '{print $2}' | kver)" ]]; then
    echo "  updating the system first (fresh install, or a pending kernel update); this takes a few minutes"
    sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Sy --noconfirm archlinux-keyring >/dev/null || stop "system update" "could not refresh the package keyring"
    sudo env LC_ALL=C OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu --noconfirm --overwrite '/usr/share/omarchy/*' >/dev/null || stop "system update" "pacman -Syu failed (its error is above). Fix it or run 'omarchy-update', then run this again."
  fi
  installed_linux=$(pacman -Q linux | awk '{print $2}' | kver)
  [[ "$installed_linux" = "$(uname -r)" ]] || stop "reboot needed" "the kernel was updated ($(uname -r) -> $installed_linux).
  Reboot, then run this same command again: it picks up from here."
fi
# preflight --install: packages (linux-headers, acpi_call-dkms, ...), the T1 reset module, the ESP, the model;
# it prints the NO lines when something is missing and exits 3; exit 7 means a reboot is needed.
pf=$(sudo t1-revive preflight --install 2>&1); pfrc=$?
printf '%s\n' "$pf" | grep -E 'NO|ok, [0-9]+ problems|Ready|STOPPED' || true
case $pfrc in
  0) ;;
  7) stop "reboot needed" "the kernel changed. Reboot, then run this same command again: it picks up from here.";;
  *) stop "preflight" "fix the NO lines above, then run this again (full output: sudo t1-revive preflight).
  If an earlier run already did pass A, resume instead:   sudo t1-revive regenerate --from pass-b";;
esac
SKIP_REGEN=0
case "$(t1)" in
  1281) echo "  T1 in recovery mode: nothing loaded. Regeneration needed.";;
  8600) if embeddedos_present; then echo "  T1 already running and firmware files present: skipping regeneration"; SKIP_REGEN=1
        else echo "  T1 running but no firmware files on the EFI partition (survived a warm reboot); regeneration will reset it first"; fi;;
  *) stop "T1 check" "no T1 on the USB bus";;
esac

if [[ "$SKIP_REGEN" = 0 ]]; then
  say "3/4  Regenerating the T1's firmware data"
  sudo t1-revive regenerate --demo || stop "regeneration" "see /var/log/t1-revive/latest.log; a full power cycle then 'sudo t1-revive regenerate --from <step>' resumes"
else
  say "3/4  Regeneration not needed"
fi

say "4/4  Touch Bar and Touch ID"
if [[ -f "$DEST/omarchy-t1/install.sh" ]]; then
  bash "$DEST/omarchy-t1/install.sh" --no-reboot --quiet || stop "Touch ID setup" "see ~/.local/state/omarchy-t1/install.log; rerun: bash $DEST/omarchy-t1/install.sh"
else
  echo "  This toolkit was built without the omarchy-t1 plugin. Install t1bridge by hand:"
  echo "    git clone https://github.com/standardagents/t1bridge && cd t1bridge"
  echo "    follow its README (install, then enrol a finger); it takes over the booted T1 from here."
  say "Regeneration done; Touch Bar/Touch ID stack left to you."
  exit 0
fi

say "All done."
echo "  Try it:   sudo -k; sudo true      (touch the sensor)"
echo "  Lock:     Super+Ctrl+L, then touch"
# This session's user manager started before t1bridge existed, so the enabled renderer unit is
# refused at session-admission. install.sh bootstraps one renderer with the group via newgrp, in
# its own scope, to cover this session; the user unit takes over from the next login. Touch ID is
# unaffected either way -- PAM does not use the renderer socket.
if systemctl --user is-active --quiet t1-touchbar-session.scope; then
  echo "  Touch Bar: live now (bootstrapped for this session; the user unit takes over next login)"
elif ! id -nG | grep -qw t1bridge; then
  echo "  Touch Bar: log out and back in to light it up (this session predates the t1bridge group)"
fi
