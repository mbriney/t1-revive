# Security policy

Report suspected vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/niconistal/t1-revive/security/advisories/new),
not a public issue. Include the tool version, the impact, and redacted reproduction steps.
Fixes target the latest release.

Do not include serial numbers, ECIDs, nonces, tickets, MAC addresses, keybags, biometric
state, the contents of anything under `EFI/APPLE`, or files from `/var/lib/t1-revive/private/`
in a report, an issue, or a test fixture.

## What counts

- An identifier reaching a redacted log, the report bundle, a diagnostic line, the screen in
  `--demo` mode, or the repository.
- A path by which the tool touches the T1, the ESP, or the network without the confirmation
  the contract requires, or in `--dry-run`.
- A write to the ESP outside `EFI/APPLE/EMBEDDEDOS`, or a non-atomic write there.
- Any way to make the tool call an ACPI method other than the discovered `FRST`.
- A weakness in how the firmware package is fetched and verified (checksum pinning, TLS), or
  in how the vendored forks are pinned and built.
- State directory or log permissions looser than documented (0700, files 0600).

## What does not belong here

- Bugs in t1bridge: report them to
  [t1bridge](https://github.com/standardagents/t1bridge/security/advisories/new).
- The behaviour of Apple's servers, including a future refusal to sign.
- A regeneration that failed on your machine without a security angle: that is an ordinary
  issue with the report bundle.

Every privileged operation in this tool has to justify itself in
[docs/threat-model.md](docs/threat-model.md). Something that cannot be justified there does
not ship.
