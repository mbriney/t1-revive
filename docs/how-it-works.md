# How it works

This document describes what `t1-revive regenerate` does, step by step: what each step sends,
what it receives, what it writes, what "success" means at that step, and how long it took in
the rehearsal. Names only; no identifiers, no file contents.

## Background

The T1 does not keep its operating system. At every boot the Mac's firmware reads
`EFI/APPLE/EMBEDDEDOS/combined.memboot` from the EFI System Partition and loads it into the
chip, together with `FDRData`, a factory data record personalised to this chip and this
fingerprint sensor and signed by Apple, and `version.plist`. A Linux installer that recreates
the ESP deletes that folder. From then on the T1 boots its immutable ROM recovery and shows
on USB as `05ac:1281`. A healthy T1 shows as `05ac:8600`.

The restore protocol the T1 speaks is the one iPhones speak, and the open-source
libimobiledevice tools already implement it. What they lacked was the T1's habit of keeping
its factory data on the host, and the T1-specific restore options. The patched
idevicerestore, libirecovery and usbmuxd under `vendor/` add exactly that. The inputs are
Apple's public `EmbeddedOSFirmware.pkg` (the `iBridge1,1` customer bundle, `Customer Boot`
variant) and Apple's servers.

The sequence is pass A, reset, pass B, reset, phase 14, stage, handover. It runs as one
command with no reboot at any point. Every step checks the T1's USB state before touching
it and stops on the first failure.

## Step 1: pass A, FDR creation

The T1 must be at `05ac:1281`. A private usbmuxd is started; a system usbmuxd is refused.

- Sends: the restore ramdisk and its components from the firmware bundle, with the restore
  boot arguments the recipe prescribes; the chip's identity and nonces to Apple's TSS at
  `gs.apple.com`, which returns signed tickets; the FDR conversation with Apple's FDR
  service, carried inside the restore protocol.
- Receives: the signed restore images and the chip's factory data record, produced by
  Apple's servers for this chip.
- Writes: `private/FDRData` in the state directory, mode 0600. Nothing on the ESP.

Success: idevicerestore exits 0, its log says `Restore Finished`, and `FDRData` is
non-empty and parses as a property list. After pass A the T1 sits at `05ac:8600` in a
degraded restore personality (one vendor interface, no HID). That is not a booted
EmbeddedOS; it is the restore leaving the chip where it left it. Rehearsal: 2 min 15 s.

## Step 2: FRST, the T1-only reset

The T1 has to be back in recovery for pass B. The tool writes the ACPI method path
discovered from this machine's ACPI tables (on the tested model it ends in `ASOC.FRST`) to
`/proc/acpi/call`, provided by `acpi_call`. It refuses to run if the method is not found in
the tables; the path is never assumed.

- Sends: one ACPI method call. No network.
- Receives: the method's return value; `0x0` in every run so far.
- Writes: nothing.

Success: the T1 leaves the USB bus and reappears as `05ac:1281` within 60 s. Measured:
gone at 0.7 s, back at 2.4 s. The tool then waits 12 s for recovery mode to settle (the
recipe says at least 10 s). No freeze, no host side effects, uptime unchanged.

### Why FRST and never SOCW

Two ACPI methods can affect the T1. `SOCW` is the power method the stock firmware-bar driver
called at probe, suspend and resume. Calling it while the T1 is at `05ac:8600` hard-freezes
the whole machine; the recipe's author saw it, and the maintainer's notes list it as the one
hazard whose outcome is unknown. `FRST` resets only the T1 and has behaved the same way every
time. So the rule is absolute: `FRST` is the only reset, `SOCW` is never called, the word is
grepped for in CI, and the runtime refuses a method path that contains it.

## Step 3: pass B, replay and capture

Same restore as pass A, with two differences: the FDR store from pass A is replayed as input
instead of being created, and the personalised preflight boot image and its AP ticket are
captured from the same transaction.

- Sends: the same restore, the same conversations with TSS and the FDR service, plus the
  pass A FDR store as the answer to the FDR requests.
- Receives: signed images, the replayed FDR store, and the pair that phase 14 needs.
- Writes: `private/combined.preflight.memboot`, `private/preflight.apticket`,
  `private/FDRData.replayed`, all 0600. Nothing on the ESP.

Success: exit 0, `Restore Finished`, all three files non-empty, and the replayed store
byte-identical to the pass A store. The image and the ticket must come from one and the same
pass B run; a ticket requested separately after a reset produced images that looked right
and sent the T1 back to recovery every time. Rehearsal: 1 min 22 s.

## Step 4: FRST again

Identical to step 2. The T1 is back at `05ac:1281` and settled.

## Step 5: phase 14, boot the T1 with the captured pair

No restore, no new ticket, no network. Over libusb to recovery mode, in the recipe's order:
set auto-boot off and save the environment, send the saved AP ticket, upload the saved boot
image, set the boot arguments to `rd=md0`, then issue the blind memboot command.

- Sends: the pass B ticket and image, and four recovery commands.
- Receives: nothing but USB enumeration events.
- Writes: nothing on disk.

The dispatch exit code proves only that the transaction was sent. Success is defined on the
bus: the tool watches USB for 30 s and passes when `05ac:8600` appears, stays, and never
falls back to `05ac:1281`. Measured: `8600` at 7 to 8 s, stable through the window. By default the
gate after the watch is the one the proven run used: the T1 answers as `05ac:8600` within 5 s.
With `--strict` the full verdict is required (at least 60 of 120 samples at `8600`, none at `1281`,
`8600` last). Likewise pass A and pass B gate on their artefacts by default and on
idevicerestore's exit status only with `--strict`. The tool
then selects USB configuration 1 host-side so the firmware personality enumerates fully: two
UVC interfaces (the camera), two HID interfaces, and the virtual Touch Bar and sensor
devices. On a machine with no bar driver the Touch Bar stays dark at this point by design;
the verdict line is the proof. With the stock firmware-bar driver present the bar lit here.

Failure shapes, from the notes: `8600` appears and falls back to `1281` within seconds means
iBoot rejected the image or the ticket (pair mismatch, wrong boot arguments); the fix is to
rerun pass B, never to request a new ticket alone. `8600` stays but exposes no HID after
configuration 1 means the degraded personality, not a booted OS. Stays at `1281` means the
memboot was not accepted; power cycle and retry once before changing anything.

## Step 6: stage the ESP

Precondition: the T1 is alive at `05ac:8600` right now, with HID devices present. The tool
refuses otherwise; staging an image that has not booted is how a machine ends up looping in
recovery at every boot.

- Reads: `private/combined.preflight.memboot`, `private/FDRData`, and `version.plist` from
  the firmware bundle.
- Writes: `EFI/APPLE/EMBEDDEDOS/combined.memboot`, `FDRData`, `version.plist` on the ESP.

The ESP is discovered by partition type, mounted if needed, and must be a writable vfat. If
the folder already holds any of the three files they are copied to
`efi-backup-<stamp>/` in the state directory first. Each file is written under a temporary
name on the same filesystem, synced, then renamed over the final name; then the filesystem
is synced and each file is compared byte for byte with its source.

### Why atomic

The firmware reads this folder at every boot with no host involved. A rename on the same
filesystem is a single directory operation, so at no instant does the folder hold a
half-written `combined.memboot` under its final name. If power failed mid-way, the folder
would hold either the old file, the new file, or a temporary name the firmware ignores. A
corrupt or partial file would not damage anything (the ROM validates what it loads and falls
back to recovery), but it would cost a power cycle and a resume. The `cmp` after the sync is
what lets the tool print "staged" and mean it.

Success: three `verified` lines. From here on the T1 lights at every cold boot with nothing
running. Rehearsal: seconds. Wall clock from the start of pass A to the verified ESP:
4 min 56 s.

## Step 7: handover

The T1 is at `05ac:8600` in the firmware personality, configuration 1. If t1bridge is
installed, the tool loads its configuration selector, de-authorizes the USB device, unloads
the firmware-bar drivers, and re-authorizes it. The selector picks configuration 2 and
t1bridge's device-driven units come up on their own: USB configuration, display, private
network, xART storage, keybag, broker, Touch Bar. A keybag saved earlier is restored from
disk; no re-enrollment. Measured: about 60 s, uptime unchanged.

If t1bridge is not installed, the tool says so. Install it, then do one full power cycle; the
firmware loads the staged files and t1bridge takes the T1 at boot.

Success: `sudo t1bridge status` rows ready, or a dark bar and the instruction to power cycle.

## The whole thing, timed

| Step | Measured |
| --- | --- |
| pass A | 2 min 15 s |
| FRST | 2.4 s to recovery, plus 12 s settle |
| pass B | 1 min 22 s |
| FRST | as above |
| phase 14 | 8600 at 7 s, watched 30 s |
| stage | seconds |
| handover | about 60 s |
| wiped machine to verified ESP | 4 min 56 s |
| wiped machine to sudo by touch, with omarchy-t1 | about 10 min, zero restarts |

Measured on one MacBookPro14,3 on 2026-09-07, and again from a fresh Omarchy install on
2026-09-09.

## What "regenerated" means

The data macOS writes on a first boot comes from the same online repair, against the same
Apple servers, bound to the same chip. Ours came from that same transaction with Linux at the
keyboard. In both cases the record is Apple-signed and verified by the Secure Enclave before
it enrolls anything. We say "equivalent in kind". We do not say "byte-identical", because we
cannot compare against a file that no longer exists, and we do not say "Apple approved".
