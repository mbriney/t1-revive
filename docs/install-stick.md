# The install stick: the offline path

This page is for one case only: a fresh install that comes up with no network at all. On
the 2017 15-inch that is common, because `linux-firmware` carries no calibration file for
its Wi-Fi chip. If your machine has network after the install, ignore this page entirely and
use the AUR package or the source build in the README.

The tool needs the network twice: for packages, then for Apple. The install stick solves
that. It is the
stock Omarchy ISO with one extra partition, labelled `TOOLKIT`, that carries the tool, the
patched restore binaries, Apple's public firmware bundle, and a Wi-Fi fixer. The ISO and its
EFI partition are untouched; the installer stays stock.

The partition holds no EFI folder and no device data. The toolkit builder refuses to pack
anything that looks like `FDRData`, a boot image, a ticket, a keybag or a private directory,
and writes a manifest with the hash of every file it does pack.

## Make the stick

On a machine that has the repository and network:

```sh
bash tools/make-toolkit.sh                      # builds the toolkit tarball and its checksum
sudo bash tools/make-install-stick.sh /dev/sdX  # writes the ISO, adds the TOOLKIT partition
```

The toolkit carries the patched restore binaries from `prefix/` relocated so that they run
from wherever the tree is unpacked: their RUNPATH is `$ORIGIN`-relative, the build-time files
(`*.la`, `*.a`, headers, man pages, pkg-config) are dropped, and the udev rule points at
go.sh's install location. `tools/relocate-prefix.sh` does that, and the identifier scan runs
over the staged tree afterwards; a toolkit that still carried the build machine's path would
be refused (issue #1). `patchelf` is needed on the machine that builds it.

`make-install-stick.sh` refuses internal disks, verifies the ISO's checksum, writes the ISO,
then adds a FAT partition in the free space with the tarball, its checksum, the files from
`contrib/stick/` and a `README.txt`. Pass `--partition-only` to add the partition to a stick
that already carries the ISO. The stick needs the ISO's size plus a few hundred megabytes.

## Use the stick

1. Install Omarchy from the stick as usual. On a Touch Bar Mac that takes the whole disk,
   this is the step that erases `EFI/APPLE`; the Touch Bar is dark on first boot and
   `lsusb` shows the T1 in recovery mode. If you still have a copy of `EFI/APPLE`, you do
   not need regeneration at all.
2. After first login, plug the same stick back in. Omarchy mounts its `TOOLKIT` partition
   under `/run/media/`. If it does not, `udisksctl mount -b /dev/sdX3`.
3. Read `README.txt` on the partition. It is the copy of `contrib/stick/README.txt` that
   matches the toolkit on that stick and is authoritative for the exact commands.

## Wi-Fi first, if there is no network

The 2017 15-inch has a Broadcom BCM43602 for which `linux-firmware` ships no NVRAM
calibration file, so a fresh install can show no wireless networks at all. Everything else
needs the network, so fix it first:

```sh
sudo bash /run/media/$USER/TOOLKIT/install-nvram.sh CC     # CC = your two-letter country code
```

`contrib/stick/install-nvram.sh` writes `/lib/firmware/brcm/brcmfmac43602-pcie.txt` from a
community-verified template for this exact chip, filling in your card's own MAC address and
the country code, backs up any existing file, and reloads `brcmfmac`. It prints the
regulatory domain and the driver log when it finishes: if the country shows your code and
there are no nvram or firmware errors, it worked. Connect to Wi-Fi. Reboot only if the
country still reads `00` or `99`, or if the module never actually unloaded. The template in
`contrib/stick/` carries a zero MAC address; the script fills in yours locally and nothing
leaves the machine.

`preflight` stops with this instruction when it finds no default route and detects the chip
without a calibration file.

## Expect two runs on a fresh install

The fresh system has only the ISO's offline package database (no `acpi_call-dkms`) and the
ISO's kernel, which is usually behind the repositories. Every kernel module built during the
run (`acpi_call` now, t1bridge's modules later) must match the kernel that is running. So the
first `preflight` syncs the database and runs the full system upgrade; if the kernel changed,
it stops with exit code 7 and says "reboot needed". Reboot, run the same command again, and
it goes all the way. On an up-to-date machine the update is a no-op and there is one run.

## Then the flow

Install the toolkit from the partition as its `README.txt` says, then:

```sh
sudo t1-revive preflight
sudo t1-revive backup --to PATH        # recommended if EFI/APPLE still exists
sudo t1-revive regenerate
```

followed by t1bridge, installed from its own README; on Omarchy read
[omarchy.md](omarchy.md) alongside it. The backup is recommended, not required: if you skip
it, `regenerate` warns and asks you to confirm. If the stick's `README.txt` offers a single
wrapper command that runs those in order, it does exactly that and stops at the first
failing step with the step's name; the individual commands above are the same thing broken
out.

Sudo is asked once at the start and kept alive for the run. No reboot is needed between
regeneration and Touch ID; the Touch Bar renderer needs the `t1bridge` group, which your
first login session predates, so the bar may only light for your user at the next login.
Touch ID works either way.

## If it stops

The reason is on screen and in `/var/log/t1-revive/latest.log`. The provisioned data
survives, so resume with `sudo t1-revive regenerate --from personalize` (or the step named),
after a full power cycle. Then t1bridge by hand. See [troubleshooting.md](troubleshooting.md).
