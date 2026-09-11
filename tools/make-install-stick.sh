#!/usr/bin/env bash
# tools/make-install-stick.sh - write a stock installer ISO to a USB stick and add a third partition
# (label TOOLKIT) that carries the t1-revive toolkit, so the stick that installs Linux also brings
# the regeneration tool to the fresh system. The ISO and its EFI partition are untouched.
#
#   sudo bash tools/make-install-stick.sh ISO /dev/sdX [--toolkit FILE.tar.zst]
#                                         [--partition-only] [--i-copied-the-backup]
#
#   ISO                     the installer image (a .sha256 file next to it is checked when present)
#   /dev/sdX                the whole stick (not a partition). Everything on it is erased.
#   --toolkit FILE          the tarball from tools/make-toolkit.sh (default: newest next to the repo)
#   --partition-only        the ISO is already on the stick; only add/refresh the TOOLKIT partition
#   --i-copied-the-backup   allow a stick whose label looks like a backup (BAK/BACKUP)
# Safety: refuses internal disks (nvme, mmcblk, anything holding a mounted system directory),
# refuses backup-labelled sticks unless overridden, checks the size, asks for a typed YES.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
STICK=$ROOT/contrib/stick
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit "${1:-2}"; }
[[ $# -ge 2 ]] || usage
ISO=$1; DEV=$2; shift 2
KIT=""; FORCE_BACKUP=0; PART_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolkit) KIT=${2:?--toolkit needs a file}; shift 2;;
    --toolkit=*) KIT=${1#--toolkit=}; shift;;
    --partition-only) PART_ONLY=1; shift;;
    --i-copied-the-backup) FORCE_BACKUP=1; shift;;
    -h|--help) usage 0;;
    *) echo "unknown argument: $1" >&2; usage;;
  esac
done
[[ "$(id -u)" = 0 ]] || { echo "run with sudo"; exit 1; }
[[ -f "$ISO" ]] || { echo "no such ISO: $ISO"; exit 1; }
[[ -n "$KIT" ]] || KIT=$(find "$(dirname -- "$ROOT")" -maxdepth 1 -name 't1-revive-toolkit-*.tar.zst' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
[[ -n "$KIT" ]] && [[ -f "$KIT" ]] || { echo "no toolkit tarball found; build one with tools/make-toolkit.sh or pass --toolkit FILE"; exit 1; }
[[ -f "$KIT.sha256" ]] || { echo "missing $KIT.sha256 (make-toolkit.sh writes it)"; exit 1; }
for f in go.sh README.txt install-nvram.sh brcmfmac43602-pcie.txt; do
  [[ -f "$STICK/$f" ]] || { echo "missing $STICK/$f"; exit 1; }
done
for t in lsblk blockdev mkfs.vfat partprobe udevadm dd; do command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 1; }; done

# ---- safety checks on the target ----
[[ -b "$DEV" ]] || { echo "$DEV is not a block device"; exit 1; }
case "$DEV" in
  /dev/nvme*|/dev/mmcblk*) echo "refusing: $DEV looks like an internal disk"; exit 1;;
  *[0-9]) case "$DEV" in /dev/sd*|/dev/vd*) echo "refusing: $DEV is a partition; give the whole device"; exit 1;; *) ;; esac;;
  *) ;;
esac
[[ "$(lsblk -dno TYPE -- "$DEV")" = disk ]] || { echo "refusing: $DEV is not a whole disk"; exit 1; }
mounted=$(lsblk -nro MOUNTPOINTS -- "$DEV" 2>/dev/null | tr ' ' '\n' | grep -E '^/(boot|efi|home|usr|var)?$' || true)
[[ -z "$mounted" ]] || { echo "refusing: $DEV holds a mounted system directory ($(echo "$mounted" | tr '\n' ' '))"; exit 1; }
if lsblk -nro LABEL,PARTLABEL -- "$DEV" 2>/dev/null | grep -qiE 'bak|backup'; then
  [[ "$FORCE_BACKUP" = 1 ]] || { echo "refusing: $DEV carries a backup-looking label (pass --i-copied-the-backup if it is safely copied elsewhere)"; exit 1; }
  echo "NOTE: erasing a backup-labelled stick on your say-so (copied elsewhere)."
fi
size=$(blockdev --getsize64 "$DEV"); iso=$(stat -c %s -- "$ISO"); kit=$(stat -c %s -- "$KIT")
need=$((iso + kit + 64*1024*1024))
[[ "$size" -gt "$need" ]] || { echo "stick too small: $((size/1000000)) MB for a $((iso/1000000)) MB ISO plus a $((kit/1000000)) MB toolkit"; exit 1; }
echo "stick:   $DEV ($(lsblk -dno MODEL,SIZE -- "$DEV" | tr -s ' '))"
echo "iso:     $ISO"
echo "toolkit: $KIT"
if [[ -f "$ISO.sha256" ]]; then
  echo "checksum of the ISO:"; (cd -- "$(dirname -- "$ISO")" && sha256sum -c "$(basename -- "$ISO").sha256")
else
  echo "note: no $ISO.sha256 next to the ISO; its checksum is not verified"
fi
echo "checksum of the toolkit:"; (cd -- "$(dirname -- "$KIT")" && sha256sum -c "$(basename -- "$KIT").sha256")

# ---- write ----
if [[ "$PART_ONLY" = 0 ]]; then
  read -r -p ">> ERASE $DEV and write the install stick? Type YES: " a; [[ "$a" = YES ]] || exit 1
  for p in "$DEV"?*; do umount "$p" 2>/dev/null || true; done
  echo "== writing the ISO"; dd if="$ISO" of="$DEV" bs=4M status=progress oflag=direct conv=fsync
  sync; partprobe "$DEV" 2>/dev/null || true; sleep 2
else
  read -r -p ">> Replace the TOOLKIT partition on $DEV (ISO kept)? Type YES: " a; [[ "$a" = YES ]] || exit 1
  echo "== --partition-only: ISO assumed already written"; for p in "$DEV"?*; do umount "$p" 2>/dev/null || true; done
fi
echo "== adding the TOOLKIT partition in the free space after the ISO"
pt=$(lsblk -dno PTTYPE -- "$DEV")
if [[ "$pt" = dos ]]; then
  # isohybrid MBR: partition 1 = the ISO, 2 = its EFI image. Append 3 = FAT32 in the remaining space.
  if [[ "$PART_ONLY" = 1 ]] && [[ "$(lsblk -nro NAME -- "$DEV" | wc -l)" -ge 4 ]]; then
    echo "   (partition 3 already exists; reformatting it)"
  else
    command -v sfdisk >/dev/null || { echo "missing tool: sfdisk"; exit 1; }
    printf '%s\n' ',,0c' | sfdisk --append --no-reread "$DEV" >/dev/null
  fi
else
  command -v sgdisk >/dev/null || { echo "missing tool: sgdisk (package gptfdisk)"; exit 1; }
  if [[ "$PART_ONLY" = 1 ]] && sgdisk -p "$DEV" 2>/dev/null | grep -q '^ *3 '; then
    echo "   (partition 3 already exists; reformatting it)"
  else
    sgdisk -e "$DEV" >/dev/null; sgdisk -n 3:0:0 -t 3:0700 -c 3:TOOLKIT "$DEV" >/dev/null
  fi
fi
partprobe "$DEV"; sleep 2; udevadm settle
P3="${DEV}3"; [[ -b "$P3" ]] || P3=$(lsblk -nrpo NAME -- "$DEV" | tail -1)
mkfs.vfat -F 32 -n TOOLKIT "$P3" >/dev/null
M=$(mktemp -d); mount "$P3" "$M"
cp -- "$KIT" "$KIT.sha256" "$M/"
# go.sh is the one-command runner; install-nvram.sh + the nvram template fix Wi-Fi on the BCM43602
# (the template carries a zero MAC and ccode=XX; install-nvram.sh fills in this machine's values).
cp -- "$STICK/go.sh" "$STICK/README.txt" "$STICK/install-nvram.sh" "$STICK/brcmfmac43602-pcie.txt" "$M/"
ls -la "$M"; sync; umount "$M"; rmdir "$M"
echo "== result"; lsblk -o NAME,SIZE,FSTYPE,LABEL -- "$DEV"
echo "done. Boot the Mac holding Option and pick the orange EFI Boot entry."
