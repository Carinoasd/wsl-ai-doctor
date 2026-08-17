# wsl-ai-doctor

**English** · [繁體中文](README.md)

> A health-check tool for WSL environments running AI coding agent CLIs.

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

### Download and run

```bash
curl -fsSL https://raw.githubusercontent.com/Carinoasd/wsl-ai-doctor/main/wsl-ai-doctor.sh -o wsl-ai-doctor.sh
chmod +x wsl-ai-doctor.sh
./wsl-ai-doctor.sh
```

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

Sample output (from a real machine before it was fixed):

```
wsl-ai-doctor v0.1.0 — WSL AI coding agent 環境健檢
檢查時間:2026-08-17 04:36:06

▸ WSL 版本與設定
  [PASS] WSL2(kernel 6.18.33.2-microsoft-standard-WSL2)
  [INFO] 發行版:Ubuntu
  [PASS] systemd 已啟用(PID 1 = systemd)

▸ Node.js 版本
  [FAIL] 找不到 node 指令
         ↳ Claude Code、Codex CLI 等工具都以 Node.js 執行。建議用 nvm 在 WSL 內安裝:
           $ curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
           $ exec $SHELL -l
           $ nvm install --lts

▸ npm 全域安裝與 PATH
  [FAIL] npm 全域安裝路徑位於 Windows 端:C:\Users\you\AppData\Roaming\npm
         ↳ 這正是「明明 npm install -g 裝好了,指令卻找不到」最常見的原因:
         ↳   • 套件被裝進 Windows 的 %APPDATA%\npm,產生的是 .cmd / .ps1 包裝檔
         ↳   • 這些包裝檔在 WSL 的 bash 裡不是可執行的 Linux 執行檔
         ↳   • 即使能執行,傳進去的 Linux 路徑 Windows 端也解讀不了

▸ 對外網路連線
  [PASS] api.anthropic.com 可連線(HTTP 404)
  [PASS] api.openai.com 可連線(HTTP 421)

════════════════════════════════════════════
 健檢總結(共 12 項)

   ● PASS    7
   ● WARN    2
   ● FAIL    3

 環境狀態:需要修復 — 有 3 項會直接導致 AI CLI 工具無法正常運作。
════════════════════════════════════════════
```

> **Note on language:** v0.1.0 emits its diagnostics in Traditional Chinese. Status keywords
> (`PASS` / `WARN` / `FAIL`) and every suggested command are language-neutral, so the output
> is still actionable if you don't read Chinese. English output (`--lang en`) is on the
> roadmap below — contributions welcome.

### Options

| Option | Description |
| --- | --- |
| `-h, --help` | Show help |
| `-v, --version` | Show version |
| `--no-color` | Disable colored output |
| `--color` | Force colored output, even when not a terminal |
| `--skip-network` | Skip the connectivity check (for offline environments) |

Color is disabled automatically when output is redirected to a file or a pipe, and the
[`NO_COLOR`](https://no-color.org/) convention is respected:

```bash
./wsl-ai-doctor.sh > health-report.txt
```

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Everything passed |
| `1` | Warnings, no failures |
| `2` | At least one failure |
| `64` | Invalid command-line usage |

This makes it usable as a preflight check in a devcontainer or environment bootstrap script:

```bash
./wsl-ai-doctor.sh --skip-network || echo "Environment has unresolved issues"
```

### Environment variables

Every threshold can be overridden, which is useful when your team has its own standards:

| Variable | Default | Description |
| --- | --- | --- |
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

v1 focuses on getting the checks right. Planned next:

- [ ] `--fix` mode for automatic remediation
- [ ] Interactive menu to confirm fixes one by one
- [ ] `--json` output for piping into other tools
- [ ] English output (`--lang en`)
- [ ] More checks: git configuration, SSH agent, Docker Desktop integration, and projects
      stored under `/mnt/c` (a cross-filesystem performance trap)

---

## Contributing

Reports of WSL environment traps you've hit are very welcome — especially the ones where
the error message actively misleads you. Those are exactly what this tool should cover.

Before opening a PR:

```bash
bash -n wsl-ai-doctor.sh                 # syntax check
shellcheck -S warning wsl-ai-doctor.sh   # static analysis (optional)
```

---

## License

[MIT](LICENSE)
