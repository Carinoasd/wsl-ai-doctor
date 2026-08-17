# wsl-ai-doctor

**English** · [繁體中文](README.md)

> A health-check tool for WSL environments running AI coding agent CLIs.

[![CI](https://github.com/Carinoasd/wsl-ai-doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/Carinoasd/wsl-ai-doctor/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)](wsl-ai-doctor.sh)

When you install tools like Claude Code or Codex CLI on WSL, the tool itself is rarely
the problem — the environment is. `npm install -g` reports success, yet the command comes
back `command not found`. Or you are unknowingly running the Windows build of Node.js, and
every path you hand it turns out to be wrong. The error messages almost never point at the
actual cause.

`wsl-ai-doctor` is a dependency-free bash script that runs six classes of environment
checks in one pass. **Every problem it finds comes with a copy-pasteable fix**, not just a
notice that something is wrong.

---

## What it checks

| Check | What it catches |
| --- | --- |
| **Node.js version** | Version below what AI CLIs require; accidentally using the Windows `node.exe`; `node` and `npm` coming from opposite sides of the WSL/Windows boundary |
| **PATH setup** | Windows interop disabled, so `cmd.exe` can't be invoked; `node`/`npm`/`git` shadowed by their Windows counterparts; empty PATH entries (equivalent to the current directory — a security risk), duplicates, and dead directories |
| **npm global installs** | Global prefix landing on the Windows side; global bin directory missing from PATH (the classic "installed but command not found"); installed executables shadowed by same-named commands; prefix directory not writable, forcing `sudo` |
| **Outbound connectivity** | Can't reach `api.anthropic.com` / `api.openai.com` — and distinguishes DNS resolution failure from a blocked TLS connection, then points at resolv.conf, VPN MTU, or corporate certificates accordingly |
| **WSL version & config** | Still running WSL1; systemd not enabled |
| **.wslconfig resources** | Memory set too low (agents get killed mid-run by the OOM killer); set too high, starving Windows itself; `processors` exceeding physical core count, or values written in an invalid format |

Results come in three levels:

- `PASS` — no problem
- `WARN` — affects performance or stability, but the tool still works
- `FAIL` — will actively prevent AI CLIs from working; fix these first

---

## Installation

### One-liner (fastest)

```bash
curl -fsSL https://raw.githubusercontent.com/Carinoasd/wsl-ai-doctor/main/wsl-ai-doctor.sh | bash
```

Leaves nothing behind — ideal when you just want to see the result once. Pass options through
`bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/Carinoasd/wsl-ai-doctor/main/wsl-ai-doctor.sh | bash -s -- --lang en
```

> This script **only reads** — it never modifies your configuration — so running it this way
> carries less risk than a typical installer. Piping anything from the network into `bash` still
> means trusting the source, though; use the method below if you would rather read it first.

### Download, then run (lets you inspect it first)

```bash
curl -fsSL https://raw.githubusercontent.com/Carinoasd/wsl-ai-doctor/main/wsl-ai-doctor.sh -o wsl-ai-doctor.sh
chmod +x wsl-ai-doctor.sh
./wsl-ai-doctor.sh
```

Keeping the file around also lets you re-run it later and compare before and after a fix.

### Or clone the repository

```bash
git clone https://github.com/Carinoasd/wsl-ai-doctor.git
cd wsl-ai-doctor
./wsl-ai-doctor.sh
```

### Requirements

- WSL2 (WSL1 also runs, but the script will tell you to upgrade)
- Bash 4.4+ (default on Ubuntu, Debian, Fedora, and other mainstream distributions)
- `curl` (only for the connectivity check — use `--skip-network` if you don't have it)

No root required. The script **only reads** — it never modifies your configuration.

---

## Usage

```bash
./wsl-ai-doctor.sh
```

Diagnostics default to Traditional Chinese; pass `--lang en` for English:

```bash
./wsl-ai-doctor.sh --lang en
```

Sample output, from a machine where Node.js was only installed on the Windows side:

```
wsl-ai-doctor v0.3.0 — WSL AI coding agent environment health check
Checked at: 2026-08-17 12:48:55

▸ WSL version and configuration
  [PASS] WSL2 (kernel 6.18.33.2-microsoft-standard-WSL2)
  [INFO] Distribution: Ubuntu
  [PASS] systemd is enabled (PID 1 = systemd)

▸ Node.js version
  [FAIL] node command not found
         ↳ Do not use the Windows build of Node.js as your WSL node; the two are not interchangeable.
         ↳ Claude Code, Codex CLI and similar tools all run on Node.js. Install it inside WSL with nvm:
           $ curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
           $ exec $SHELL -l
           $ nvm install --lts

▸ npm global installs and PATH
  [FAIL] The npm global prefix is on the Windows side: C:\Users\you\AppData\Roaming\npm
         ↳ This is the number one cause of "npm install -g succeeded but the command is not found":
         ↳   * packages land in Windows %APPDATA%\npm as .cmd / .ps1 wrappers
         ↳   * those wrappers are not executable Linux binaries under WSL bash
         ↳   * even when they run, the Linux paths you pass them are meaningless on the Windows side

▸ Outbound connectivity
  [PASS] api.anthropic.com is reachable (HTTP 404)
  [PASS] api.openai.com is reachable (HTTP 421)

════════════════════════════════════════════
 Summary (12 checks)

   ● PASS    7
   ● WARN    2
   ● FAIL    3

 Status: needs fixing — 3 items will actively prevent AI CLI tools from working.
════════════════════════════════════════════
```

### Options

| Option | Description |
| --- | --- |
| `-h, --help` | Show help |
| `-v, --version` | Show version |
| `--no-color` | Disable colored output |
| `--color` | Force colored output, even when not a terminal |
| `--json` | Machine-readable JSON output (implies `--no-color`) |
| `--lang <code>` | Diagnostic language: `zh-TW` (default) or `en` |
| `--skip-network` | Skip the connectivity check (for offline environments) |
| `--allow-non-wsl` | Run outside WSL too; WSL checks are marked SKIP (for CI) |

Color is disabled automatically when output is redirected to a file or a pipe, and the
[`NO_COLOR`](https://no-color.org/) convention is respected:

```bash
./wsl-ai-doctor.sh > health-report.txt
```

### JSON output

`--json` makes the results consumable by other tools. Every check carries a **stable `id`** —
message text changes with versions and languages, the `id` does not, so that is what you
should key on:

```bash
./wsl-ai-doctor.sh --json --lang en
```

```json
{
  "tool": "wsl-ai-doctor",
  "version": "0.3.0",
  "generated_at": "2026-08-17T12:47:35+0800",
  "lang": "en",
  "environment": {
    "is_wsl": true,
    "wsl_version": 2,
    "kernel": "6.18.33.2-microsoft-standard-WSL2",
    "distro": "Ubuntu",
    "systemd": true
  },
  "summary": {
    "pass": 12, "warn": 2, "fail": 0, "skip": 0,
    "total": 14, "health": "usable"
  },
  "exit_code": 1,
  "checks": [
    {
      "id": "npm.prefix_location",
      "section": "npm",
      "status": "fail",
      "message": "The npm global prefix is on the Windows side: C:\\Users\\you\\AppData\\Roaming\\npm",
      "hints": ["This is the number one cause of \"npm install -g succeeded but the command is not found\":"],
      "commands": ["curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"]
    }
  ]
}
```

`summary.health` is one of `healthy`, `usable`, `needs_fix`, or `not_applicable` (outside WSL).

Pull out everything that needs attention with `jq`:

```bash
./wsl-ai-doctor.sh --json | jq -r '.checks[] | select(.status=="fail") | .id'
```

### Hand the diagnosis to an AI agent

When the run produces any WARN or FAIL and `claude` is installed locally, the summary is
followed by a copy-pasteable command:

```
🤖 Let an AI agent fix this
   claude is installed on this machine, so you can hand the diagnosis straight to it:
   $ claude "Run /path/to/wsl-ai-doctor.sh --json to get the environment diagnosis for this
     WSL machine. For every check whose status is fail or warn, explain the cause and help me
     fix it. Before touching any of my configuration files, tell me which file and which line
     you intend to change and wait for my confirmation."
```

It points the agent at `--json` rather than the text output, because the JSON carries stable
check `id`s and the agent never has to parse human-facing formatting. The prompt also requires
the agent to **name the file and line and wait for your confirmation** before editing anything,
so it cannot quietly rewrite your environment.

This block appears in text mode only — `--json` output has to stay clean or downstream parsers
break — and never when everything passes, since there is nothing to fix. With `--lang en` the
suggested prompt is in English.

### Language

Set English as the default by exporting an environment variable, for example in `~/.bashrc`:

```bash
export WSL_AI_DOCTOR_LANG=en
```

`--lang` applies to check messages, section titles, the summary and `--help`. Suggested
commands are never translated, since shell commands have no language.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Everything passed |
| `1` | Warnings, no failures |
| `2` | At least one failure |
| `3` | Not running inside WSL; no checks were run |
| `64` | Invalid command-line usage |

Outside WSL — native Linux, a container, a CI runner — the tool **refuses to run and reports
`3`** by default. Every check assumes WSL, so running anyway would only produce misleading
advice, such as telling you to edit an `/etc/wsl.conf` that does not exist. If you do need to
run it there, pass `--allow-non-wsl` and the WSL-specific checks are marked `SKIP`.

This makes it usable as a preflight check in a devcontainer or environment bootstrap script:

```bash
./wsl-ai-doctor.sh --skip-network || echo "Environment has unresolved issues"
```

### Environment variables

Every threshold can be overridden, which is useful when your team has its own standards:

| Variable | Default | Description |
| --- | --- | --- |
| `WSL_AI_DOCTOR_LANG` | `zh-TW` | Default language (`zh-TW` or `en`) |
| `WSL_AI_DOCTOR_NODE_MIN` | `18` | Minimum Node.js version; below this is a FAIL |
| `WSL_AI_DOCTOR_NODE_RECOMMENDED` | `20` | Recommended Node.js version; below this is a WARN |
| `WSL_AI_DOCTOR_NET_TIMEOUT` | `8` | Connectivity check timeout, in seconds |
| `WSL_AI_DOCTOR_MEM_MIN_GB` | `4` | `.wslconfig` memory floor, in GB |
| `WSL_AI_DOCTOR_MEM_MAX_PCT` | `80` | `.wslconfig` memory ceiling, as a percentage of host RAM |
| `WSL_AI_DOCTOR_PATH_WIN_WARN` | `25` | Threshold for the number of Windows entries in PATH |
| `WSL_AI_DOCTOR_WSLCONFIG` | auto-detected | Explicit path to `.wslconfig` |

```bash
WSL_AI_DOCTOR_NODE_MIN=20 ./wsl-ai-doctor.sh
```

---

## Why this exists

WSL is an environment where two operating systems share a single PATH, and most of its
mysterious failures trace back to exactly that:

- Windows' PATH is appended to WSL's by default, so `npm` may resolve to
  `/mnt/c/Program Files/nodejs/npm` — the command runs, but it is a Windows program, and it
  falls apart the moment you hand it a path like `/home/you/project`.
- `npm install -g` writes packages into Windows' `%APPDATA%\npm`, producing `.cmd` wrappers
  that bash simply cannot execute.
- What you actually see is `command not found`, or some npm internal stack trace. Neither
  points anywhere near the real cause.

None of these are hard to fix individually. The hard part is **knowing where to look**.
Automating that is the entire point of this script.

---

## Roadmap

Done:

- [x] `--json` output for piping into other tools (v0.2.0)
- [x] English output (`--lang en`) (v0.2.0)
- [x] Non-WSL guard and CI (v0.2.0)

Planned:

- [ ] `--fix` mode for automatic remediation
- [ ] Interactive menu to confirm fixes one by one
- [ ] More languages (the message catalog is in place; a new language is one more table)
- [ ] More checks: git configuration, SSH agent, Docker Desktop integration, and projects
      stored under `/mnt/c` (a cross-filesystem performance trap)

See [CHANGELOG.md](CHANGELOG.md) for the full release history.

---

## Contributing

Reports of WSL environment traps you have hit are very welcome — especially the ones where
the error message actively misleads you. Those are exactly what this tool should cover.

Before opening a PR:

```bash
bash -n wsl-ai-doctor.sh                 # syntax check
shellcheck -S warning wsl-ai-doctor.sh   # static analysis
```

CI runs both of the above plus a smoke test on every push and pull request. Since GitHub
runners are not WSL, the smoke job exercises the script through `--allow-non-wsl`, so the
checks really do run rather than merely being invoked with `--help`.

Adding a message means adding it to **both** `MSG_ZH` and `MSG_EN` in the script. CI fails
if the English output still contains untranslated text or a `<missing:...>` key.

### Release process

Pushing a tag publishes the release; nothing has to be done through the web UI:

```bash
# 1. Bump VERSION in wsl-ai-doctor.sh and add the matching section to CHANGELOG.md
# 2. Push an annotated tag — its first line becomes the release title
git tag -a v0.4.0 -m "v0.4.0 — what this release is about"
git push origin v0.4.0
```

`.github/workflows/release.yml` takes it from there: it runs lint and a smoke test, checks
that the tag matches `VERSION` in the script, then extracts that version's section from
`CHANGELOG.md` and publishes it as the release body.

- **A version containing `-`** (for example `v0.4.0-rc1`) is marked as a pre-release and does
  not take over the Latest badge
- **A tag that disagrees with `VERSION`** aborts the run, so a release can never ship a file
  whose version does not match its tag
- **A missing CHANGELOG section** also aborts, which forces every release to be documented
- Re-running for the same tag updates the existing release rather than creating a duplicate

For a tag that was pushed before this workflow existed, open the **Release** workflow in the
Actions tab and use **Run workflow** to publish it by name.

---

## License

[MIT](LICENSE)
