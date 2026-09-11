t1-revive toolkit. After a fresh Linux install on a 2016/2017 Touch Bar MacBook Pro, with this
stick plugged in. Run everything as your normal user; sudo is asked for once.

If the stick is not mounted: it is the third partition, label TOOLKIT (lsblk shows it), e.g.
    udisksctl mount -b /dev/disk/by-label/TOOLKIT
It then appears under /run/media/<your user>/TOOLKIT.

1. Wi-Fi first, if there is no network.
   This model's BCM43602 has NO NVRAM calibration in linux-firmware, so a fresh install can
   come up with no wireless. Everything in step 2 needs the network (packages, then Apple's
   servers), so fix it first:

       sudo bash /run/media/<you>/TOOLKIT/install-nvram.sh CA     (2-letter country code)

   The script reloads brcmfmac itself, so no reboot is normally needed -- just connect to
   Wi-Fi afterwards. It prints the regulatory domain and the brcmfmac log when it finishes:
   if the country shows your code and there are no nvram/firmware errors, it worked. Reboot
   only if the country still reads 00 or 99, or if 'lsmod | grep brcmfmac' shows the module
   never actually unloaded. go.sh also stops with this instruction if it finds no default route.

2. Then ONE command:

       bash /run/media/<you>/TOOLKIT/go.sh

   It installs the toolkit to /usr/local/lib/t1-revive (t1-revive on the PATH via /usr/local/bin;
   --dest DIR to put it elsewhere), checks the machine (sudo t1-revive preflight --install),
   and regenerates the T1's firmware data from Apple (sudo t1-revive regenerate --demo; the
   firmware package is downloaded from Apple's CDN and checksum-verified). It then points you
   at t1bridge for the Touch Bar and Touch ID; it does not install t1bridge for you. No reboot.
   Sudo asked once.

   If EFI/APPLE still exists on this machine, copying it off the disk first is recommended:
       sudo t1-revive backup --to PATH
   Any destination that is not this disk works: another machine over scp, a phone, a cloud
   folder. It is not required. Without it, regenerate warns and asks you to confirm.

   On a fresh install expect TWO runs: the first one syncs the package lists and does the full
   system update (the ISO's kernel is usually behind the repos, and every kernel module built in
   this run must match the running kernel), then stops with "reboot needed". Reboot, run the same
   command again, and it goes all the way. On an up-to-date machine the update is a no-op.

3. Touch Bar and Touch ID: install t1bridge from its own README.

       https://github.com/standardagents/t1bridge

   It ships signed packages for Arch and Omarchy, and its README covers install, import and
   enrolling a finger. On Omarchy also read docs/omarchy.md in the installed toolkit
   (/usr/local/lib/t1-revive/docs/omarchy.md): the ufw rule for the T1 link, the PAM lines for
   sudo, polkit and the lock screen, and the known quirks with their fixes. Afterwards:

       sudo t1-revive handover

   hands the booted T1 to t1bridge with no restart. A full power cycle does the same.

   If go.sh stops during the regeneration, the reason is on screen and in
   /var/log/t1-revive/latest.log (redacted; safe to paste). Pass A's data survives, so after a
   full power cycle resume with:
       sudo t1-revive regenerate --from pass-b

   The Touch Bar renderer needs the t1bridge group, which this login session predates, so the
   bar may only light for you at the next login. Touch ID works either way.

   Something to report?  sudo t1-revive report   prints a redacted bundle to paste into an issue.

This partition holds only these files: the toolkit tarball and its checksum, go.sh, this README,
install-nvram.sh and the nvram template (zero MAC, ccode=XX). No EFI folder, no Apple firmware,
no device data.
