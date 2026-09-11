# Changelog

Dates are the days the work was proven on hardware, taken from the maintainer's private
engineering notebook. Everything before the first public version happened on one
MacBookPro14,3.

## Unreleased

Initial public version, derived from the private notebook scripts (`one-shot.sh`,
`pass-a.sh`, `pass-b.sh`, `phase14.sh`, `stage-esp.sh`, `frst-test.sh`, `regen-preflight.sh`,
the toolkit and install-stick builders) with a clean history:

- step gates match the proven run by default (artefacts present; `8600` after the boot step's watch);
  `--strict` adds idevicerestore exit-status and full 30 s stability requirements
- one entry point `t1-revive` with `preflight`, `backup`, `regenerate [--from STEP]`,
  `stage`, `handover`, `status`, `report`, `version`, and the global `--no-confirm`,
  `--demo`, `--dry-run`; the regeneration steps are `provision`, `reset-1`, `personalize`,
  `reset-2`, `boot`, `stage`, `handover`;
- model allowlist from DMI (`MacBookPro13,2`, `13,3`, `14,2`, `14,3`; `14,3` tested, the
  others warn and continue, anything else refused);
- the T1 reset method discovered from the ACPI tables instead of assumed;
- ESP discovery by partition type, refusing when ambiguous;
- a recommended backup step before any device-touching step: `regenerate` warns and asks
  for confirmation when no off-disk copy was taken, and `stage` keeps an on-disk copy of any
  existing `EMBEDDEDOS` files under the state directory before overwriting them;
- firmware package fetched from Apple's CDN at run time and verified against a pinned
  checksum; nothing from Apple in the repository;
- state under `/var/lib/t1-revive` (0700), redacted logs under `/var/log/t1-revive`, cache
  under `/var/cache/t1-revive`; no `$HOME`, no fixed user;
- redaction at the source, structured identifier-free diagnostics, a `report` bundle for
  testers;
- documented exit codes; resume at every step;
- the patched libimobiledevice stack as pinned forks built by `build.sh`; AUR recipe;
- the install stick (stock Omarchy ISO plus a `TOOLKIT` partition) and the BCM43602 Wi-Fi
  fixer under `contrib/stick/`;
- tests: shellcheck, bats against synthetic fixtures, the identifier scan and the forbidden-method
  grep in CI;
- documentation: README, how it works, threat model, troubleshooting, FAQ, hardware
  validation, the Omarchy page for t1bridge (firewall rule, PAM lines, known quirks),
  install stick, a tester agent skill;
- t1bridge is installed from its own README, which ships signed packages for Arch and
  Omarchy; t1-revive stops at the handover and does not wrap anyone else's installer.

## Milestones before the public version

- 2026-09-03: first regeneration from Linux on a MacBookPro14,3 whose `EFI/APPLE` had been
  wiped: pass A and pass B, phase 14 boots the T1 (`05ac:8600` stable, full personality,
  bar lit), the three files staged on the ESP and verified. Power cycles between steps.
- 2026-09-06: Touch ID enrolled on the regenerated data with t1bridge 0.1.2, after a fix to
  its property-list decoder (3-byte offset width). sudo, polkit and lock screen by touch;
  persists across reboot.
- 2026-09-07: `FRST`, the T1-only ACPI reset, proven safe (T1 back in recovery in 2.4 s, no
  host side effects). Zero-reboot handover to t1bridge by USB re-enumeration. Full
  regeneration from a wiped state in one shot: 4 min 56 s, no reboot. Wiped machine to sudo
  by touch, t1-revive then t1bridge, about 10 min with zero restarts.
- 2026-09-09: the whole path on camera from a fresh Omarchy install: stock installer wipes
  the T1, regeneration from the install stick, t1bridge, Touch ID, no reboot. The t1bridge
  decoder fix is merged upstream and ships in 0.1.6.
- 2026-09-10: decision to publish as an open-source tool, `t1-revive`, MIT, bash, with a
  tested table, a recommended backup and a model allowlist.
