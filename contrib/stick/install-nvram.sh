#!/usr/bin/env bash
# Fix for BCM43602 (14e4:43ba) missing/incomplete NVRAM calibration data.
# Installs a community-verified nvram file for this exact chip, with this
# machine's real Wi-Fi MAC address and regulatory country filled in.
set -euo pipefail
cd "$(dirname "$0")"
[[ "$EUID" -eq 0 ]] || { echo "Run: sudo bash $0 <2-letter-country-code, e.g. US>" >&2; exit 1; }

CCODE="${1:-}"
if [[ -z "$CCODE" ]]; then
  echo "Usage: sudo bash install-nvram.sh <2-letter-country-code>" >&2
  echo "Example: sudo bash install-nvram.sh US" >&2
  exit 1
fi

IFACE=""
for _if in /sys/class/net/wl*; do [[ -e "$_if" ]] || continue; IFACE=$(basename -- "$_if"); break; done
[[ -n "$IFACE" ]] || { echo "No wlan interface found (wl*). Is the card up?"; exit 1; }
MAC=$(cat "/sys/class/net/$IFACE/address")
echo "Interface: $IFACE   MAC: $MAC   Country: $CCODE"

DEST=/lib/firmware/brcm/brcmfmac43602-pcie.txt
[[ -f "$DEST" ]] && cp "$DEST" "$DEST.bak.$(date +%s)" && echo "Backed up existing $DEST"

sed -e "s/^macaddr=.*/macaddr=$MAC/" \
    -e "s/^ccode=.*/ccode=$CCODE/" \
    brcmfmac43602-pcie.txt > "$DEST"

echo "Installed $DEST"
echo "==> Reloading driver"
modprobe -r brcmfmac_wcc 2>/dev/null || true
modprobe -r brcmfmac 2>/dev/null || true
modprobe brcmfmac
sleep 3

echo
echo "==> Regulatory domain now:"
iw reg get | grep -m1 country || true
echo "==> brcmfmac log:"
dmesg | grep -i brcmfmac | tail -15
echo
echo "Now try connecting. To revert:"
echo "  sudo mv $DEST.bak.<timestamp> $DEST   # or: sudo rm $DEST"
echo "  sudo modprobe -r brcmfmac; sudo modprobe brcmfmac"
