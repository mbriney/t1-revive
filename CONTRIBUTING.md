# Contributing

Use [issues](https://github.com/niconistal/t1-revive/issues) for bugs, tester reports and
feature requests, and [private reporting](SECURITY.md) for anything security-relevant.

## Reporting a run

Whether it worked or not, a run on real hardware is the most useful contribution there is.
Fill in the checklist in [docs/hardware-validation.md](docs/hardware-validation.md), attach
the output of `sudo t1-revive report`, and use the issue templates in
`.github/ISSUE_TEMPLATE/`. State the model identifier, the distribution and kernel, the
t1-revive and t1bridge versions, what you expected, and what happened.

Never attach serial numbers, ECIDs, nonces, tickets, MAC addresses, hostnames, keybags,
biometric data, restore logs from `/var/lib/t1-revive/private/`, the contents of anything
under `EFI/APPLE`, or Apple binaries. The report bundle is redacted for exactly this reason;
if you see something in it that looks like an identifier, that is a bug to report privately.

## Changing code

Read [AGENTS.md](AGENTS.md) before touching anything. It is canonical for the rules that
never bend, the layout, the paths, the exit codes and the library API. In short:

- The restore sequence is proven and is not to be changed. Refactor layout and naming; keep
  the commands, order, flags, environment and timings sent to the device exactly as they are.
- The name of the forbidden ACPI power method (the one that is not `FRST`) may not appear in code. CI greps for it.
- No identifiers anywhere, including fixtures and commit messages. `tools/scan-identifiers.sh`
  runs in CI and as a pre-commit hook; run it before you push.
- No Apple binaries or device data in the repository. Firmware is fetched at run time.
- No `$HOME`, no fixed user, no fixed device paths. Everything is discovered or configured.
- bash, `set -uo pipefail`, shellcheck-clean, functions sourceable without side effects.
  Python only for parsers and extractors under `tools/`.
- Logs are redacted at the source. Diagnostics are structured, identifier-free lines.

Keep pull requests focused and say how the change was tested. `make quality` is the full
gate: shellcheck, `bash -n`, the identifier scan, the forbidden-method grep, and the bats tests against
`test/fixtures`. Documentation-only changes need link and command-syntax checks, not a
rebuild. A change to a device-touching step needs a run on real hardware and its
[validation](docs/hardware-validation.md) table in the pull request.

## Patches to the libimobiledevice forks

The patches under `vendor/` apply to pinned upstream refs of idevicerestore, libirecovery
and usbmuxd and stay under those projects' licences. Changes there go with a rebuild through
`build.sh` and a note in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) if a base ref moves.
The long-term goal is to offer the T1 support upstream.

## Documentation

Short sentences, no hype, no emoji. Every claim traceable to a run or to upstream. Say
"equivalent in kind", never "byte-identical"; "regenerated", never "bypassed"; "one model
tested", never "works on all T1 Macs". Credit t1bridge where the work rests on
theirs.

## Conduct

Be precise and kind. Testers are lending us their machines.
