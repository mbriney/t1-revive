# t1-revive

`t1-revive` regenerates the Apple T1 firmware data of a 2016 or 2017 Touch Bar MacBook Pro
from Linux alone. It is for the machine whose Linux installer recreated the EFI System
Partition and erased `EFI/APPLE/EMBEDDEDOS`, which leaves the T1 in USB recovery mode with a
dark Touch Bar, no camera and no Touch ID. The tool drives Apple's own EmbeddedOS restore
protocol with patched libimobiledevice tools, lets the chip fetch its own Apple-signed factory
data and a personalised boot image from Apple's servers, boots the T1 with them, and stages
the three resulting files on the ESP so the Mac's firmware loads them at every boot. No macOS
install is needed and no file from another Mac is used. Afterwards,
[t1bridge](https://github.com/standardagents/t1bridge) provides the Touch Bar, the camera and
Touch ID.

> **CAUTION. Read this before running anything.**
>
> - This tool talks to the T1 over Apple's restore protocol and writes new factory data into
>   the chip. That is a firmware recovery operation, not a driver install. Once a
>   regeneration has run, the chip carries the new data; there is no "undo" other than
>   restoring a previous copy of `EFI/APPLE` if you have one.
> - It depends on Apple's servers. The T1 authenticates to Apple's signing service and
>   fetches its factory data from Apple's FDR service. If Apple stops signing this firmware,
>   regeneration stops working for everyone, macOS reinstalls included. That is why the
>   backup step comes first and is not optional.
> - Never run it unattended. Every device-touching step asks before it proceeds. Stay at
>   the keyboard, on mains power, and do not let the machine sleep.
> - Run it only on `MacBookPro13,2`, `13,3`, `14,2` or `14,3`. Anything else is refused.
>   Only the `14,3` has been tested. On the other three models the tool warns and continues;
>   you are the first, so read [docs/hardware-validation.md](docs/hardware-validation.md) and
>   report.
> - One machine so far. Everything below was proven on one MacBookPro14,3, several times,
>   including from a fresh install. That is evidence, not coverage.
> - The tool never calls the ACPI method `SOCW`. The only T1 reset it uses is `FRST`.

## Tested

| Model | Date | Restore | Touch ID | Tester |
| --- | --- | --- | --- | --- |
| MacBookPro14,3 | 2026-09-03 restore, 2026-09-06 Touch ID, 2026-09-07 rehearsals, 2026-09-09 fresh install | yes | yes, persists across reboot | @niconistal (maintainer) |
| MacBookPro14,2 | | untested | untested | your report here |
| MacBookPro13,3 | | untested | untested | your report here |
| MacBookPro13,2 | | untested | untested | your report here |

A confirmed run on any model becomes a row here with your
handle if you want it there. See [Testing and reporting](#testing-and-reporting).

## Requirements

- A T1 MacBook Pro from the list above, with the T1 in recovery mode: `lsusb` shows
  `05ac:1281 Apple, Inc. Mobile Device (Recovery Mode)` instead of `05ac:8600`.
- An Arch-based x86_64 Linux. Tested on Omarchy 4.0.2 with kernel 7.1.9. Other
  distributions fail clearly at preflight; the restore itself is distribution-neutral and
  packaging help is welcome.
- Root through `sudo`, mains power, and a network path to Apple: `gs.apple.com` and
  `swcdn.apple.com` over HTTPS. A fresh Omarchy on a 14,3 may have no Wi-Fi at all; see
  [docs/install-stick.md](docs/install-stick.md) for the fix.
- A USB stick or another machine for the backup. The tool refuses to regenerate until you
  have confirmed a backup off this disk.
- Kernel headers for the running kernel and `acpi_call-dkms`. Preflight installs them and
  tells you to reboot if the kernel changed (exit code 7).
- No system `usbmuxd` running. Preflight checks.

## Install

From the AUR, once published:

```sh
yay -S t1-revive
```

From source:

```sh
git clone https://github.com/niconistal/t1-revive && cd t1-revive
bash build.sh          # builds the pinned libimobiledevice forks into prefix/
sudo bin/t1-revive version
```

Nothing from Apple is in the repository or the package. The firmware package
`EmbeddedOSFirmware.pkg` is downloaded from Apple's CDN at run time and checked against a
pinned checksum. For a machine with no network after a fresh install, the install stick
carries the tool and the Wi-Fi fix: [docs/install-stick.md](docs/install-stick.md).

## The flow

```sh
sudo t1-revive preflight                    # read-only checks; installs the few packages
sudo t1-revive backup --to /path/to/usb     # copies EFI/APPLE off this disk if any of it exists
sudo t1-revive regenerate                   # pass A, reset, pass B, reset, phase 14, stage, handover
```

Then install t1bridge. On Omarchy, [omarchy-t1](https://github.com/niconistal/omarchy-t1)
does that in one command; elsewhere follow t1bridge's own README. If t1bridge is already
installed when `regenerate` finishes, the last step hands the booted T1 to it without a
reboot. If it is not, install it and do one full power cycle; the firmware loads the staged
files on its own.

`regenerate` asks before every step that touches the device. Pass `--no-confirm` to skip the
questions, `--dry-run` to print what would happen without touching the device, the ESP or
the network, and `--demo` for generic on-screen lines with details in the log. The other
subcommands are `stage` and `handover` (the last two steps on their own), `status`, `report`
and `version`. Timings from the rehearsal: about five minutes from a wiped machine to a
verified ESP, with zero reboots. [docs/how-it-works.md](docs/how-it-works.md) has the steps.

### If it stops

The tool stops at the first failure, names the step, and prints the fallback. The fallback is
always the same: full shutdown, wait 20 seconds, power on, then resume with
`sudo t1-revive regenerate --from STEP` where STEP is one of `pass-a`, `pass-b`, `phase14`,
`stage`, `handover`. Pass A's data survives in the state directory, so a failure in pass B or
later does not repeat the first pass. The T1 cannot end up worse than recovery mode, which is
where it started. [docs/troubleshooting.md](docs/troubleshooting.md) is organised by symptom
and exit code.

## What talks to Apple, and what is stored where

Network:

| Endpoint | When | What for |
| --- | --- | --- |
| `swcdn.apple.com` | before pass A | download of Apple's public `EmbeddedOSFirmware.pkg` |
| `gs.apple.com` | pass A and pass B | TSS, the signing service: the chip's identity and nonces go up, signed tickets come back |
| Apple's FDR service, reached through the restore protocol | pass A and pass B | the chip's factory data record, signed for this chip |

Phase 14, staging and handover use no network. What Apple's servers see is what any T1 or
iPhone restore sends: the chip's identity and nonces. Nothing about your files or your
fingerprints. Fingerprints never leave the Secure Enclave.

On disk:

| Path | Mode | Contents |
| --- | --- | --- |
| `/var/lib/t1-revive/private/` | 0700, files 0600 | the FDR store, the personalised boot image, the AP ticket, unredacted restore logs |
| `/var/lib/t1-revive/efi-backup-<stamp>/` | 0700 | any `EFI/APPLE` files that existed before staging |
| `/var/log/t1-revive/` | 0700 | redacted logs, one per command, `latest.log` symlink |
| `/var/cache/t1-revive/` | 0755 | the firmware package and its extracted bundle; no device data |
| ESP `EFI/APPLE/EMBEDDEDOS/` | | `combined.memboot`, `FDRData`, `version.plist`: what the firmware loads at boot |

Nothing identity-bearing is ever printed. Logs are redacted at the source.
[docs/threat-model.md](docs/threat-model.md) covers what the host sees, what it never sees,
and what someone with the state directory could do.

After it works, copy the new `EFI/APPLE` folder off this disk, encrypted, and keep it. A
reinstall is exactly the event that destroys it.

## After it works

- [t1bridge](https://github.com/standardagents/t1bridge) by Andrew Boyd: Touch Bar, camera,
  Touch ID, with the Secure Enclave doing the matching. Touch ID enrolls on regenerated data
  and persists across reboot; t1bridge 0.1.6 or later reads the T1's FDRData directly.
- [omarchy-t1](https://github.com/niconistal/omarchy-t1): the Omarchy installer for t1bridge
  (packages, firewall rule on the T1 link, import, enrollment, PAM for sudo, polkit and the
  lock screen, with password fallback).

Known gaps, ours and upstream's: system suspend and resume do not work with the T1 stack;
the ambient light sensor is not available under t1bridge; the camera under t1bridge has not
been tested by us; one machine.

## Testing and reporting

Read [TESTING.md](TESTING.md) and the checklist in
[docs/hardware-validation.md](docs/hardware-validation.md). If you work with an agent,
point it at [skills/tester/SKILL.md](skills/tester/SKILL.md); it guides a run without
skipping the confirmations. When something fails, or works on a new model, open an issue with
the output of:

```sh
sudo t1-revive report
```

That bundle is redacted and structured: model status, kernel, distro, t1bridge version, T1
state, ESP findings, the last diagnostic lines, package versions. It is the only thing we ask
you to paste. Never paste serial numbers, ECIDs, nonces, tickets, MAC addresses, restore logs
from the private directory, or the contents of anything under `EFI/APPLE`.

## Credits

- Andrew Boyd, for [t1bridge](https://github.com/standardagents/t1bridge) and for saying
  early and loudly "back up your EFI partition". This tool exists to produce the file his
  stack requires.
- The [libimobiledevice](https://libimobiledevice.org/) project, for idevicerestore,
  libirecovery and usbmuxd, which speak the restore protocol.

Maintained by @niconistal. Contributions: [CONTRIBUTING.md](CONTRIBUTING.md). Security
reports: [SECURITY.md](SECURITY.md). Changes: [CHANGELOG.md](CHANGELOG.md).

## Licence

MIT for everything authored in this repository. The patches and build recipes under
`vendor/` apply to idevicerestore and libirecovery (LGPL-2.1) and usbmuxd (GPL) and stay under
those licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
