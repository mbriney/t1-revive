# t1-revive tester skill

A skill for the coding agent you already use (Claude Code, Codex, or anything that reads
`SKILL.md` packages). Installed on your machine, running under your login, it turns your
agent into the guide for t1-revive: it reads `t1-revive status` and `t1-revive report`,
walks you through the documented next step, and files an identifier-free report to
[niconistal/t1-revive](https://github.com/niconistal/t1-revive) with your GitHub account
once you have read the report and said yes. Nobody on the project side connects to your
Mac; that is the point.

## Install

With the [skills CLI](https://github.com/vercel-labs/skills), which discovers skills
under `skills/<name>/SKILL.md` in a repository:

```bash
npx skills add niconistal/t1-revive@t1-revive-tester            # this skill only
npx skills add niconistal/t1-revive --skill t1-revive-tester -g # same, into your user directory
```

Add `-a claude-code` or `-a codex` to target one agent. If the `@t1-revive-tester` form does not
resolve on your version of the CLI, the `--skill t1-revive-tester` form does.

Manually, for Claude Code:

```bash
git clone https://github.com/niconistal/t1-revive
mkdir -p ~/.claude/skills
cp -r t1-revive/skills/t1-revive-tester ~/.claude/skills/t1-revive-tester
```

For Codex, copy the same directory to `~/.codex/skills/t1-revive-tester` (user-wide) or
`.agents/skills/t1-revive-tester` inside the directory you open the agent in. Then start
a session and say what you see (for example "my Touch Bar is dark and lsusb shows
05ac:1281"), or invoke `/t1-revive-tester` where slash commands exist.

## What it will and will not do

It will read the machine with read-only commands, explain the state in plain words, name
the documented next step, prepare the report bundle, show it to you, and file or reply to
an issue only after you have read the text and agreed. It will not run `t1-revive
regenerate`, `stage`, `handover`, or `backup` for you: you type those in your own terminal
after reading the caution, and the tool's own confirmations stay on. It never uses
`--no-confirm` or `--force`, never touches ACPI directly, never opens `FDRData` or anything
under `EFI/APPLE`, and never changes PAM or your login. If your agent proposes any of that,
it is not following this skill; stop it and say so in the issue.
