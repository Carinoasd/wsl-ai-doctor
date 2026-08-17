# wsl-ai-doctor

**繁體中文** · [English](README.en.md)

> WSL 環境健康檢查工具 — 專為在 WSL 上使用 AI coding agent CLI 的開發者而生
>
> A health-check tool for WSL environments running AI coding agent CLIs.

[![CI](https://github.com/Carinoasd/wsl-ai-doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/Carinoasd/wsl-ai-doctor/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)](wsl-ai-doctor.sh)

在 WSL 上安裝 Claude Code、Codex CLI 這類工具時,最惱人的往往不是工具本身,而是環境:
`npm install -g` 明明成功了,指令卻 `command not found`;或者用的其實是 Windows 版的
Node.js,結果路徑一路對不上。這些問題的錯誤訊息通常都指不到真正的原因。

`wsl-ai-doctor` 是一支零相依的 bash 腳本,一次跑完六類常見的環境問題檢查,**每個問題都直接給出可複製貼上的修復指令**,而不是只告訴你「有問題」。

---

## 檢查項目 / What it checks

| 檢查項目 | 抓得出什麼問題 |
| --- | --- |
| **Node.js 版本** | 版本低於 AI CLI 需求;誤用 Windows 版 node.exe;node 與 npm 分屬 WSL / Windows 兩側 |
| **PATH 設定** | Windows interop 失效導致無法呼叫 `cmd.exe`;`node`/`npm`/`git` 被 Windows 版本蓋過;PATH 含空值(等同當前目錄,有安全風險)、重複項與失效目錄 |
| **npm 全域安裝** | 全域前綴落在 Windows 端;全域 bin 目錄不在 PATH(「裝好了卻找不到指令」);已安裝的執行檔被同名指令蓋掉;前綴目錄不可寫而被迫 `sudo` |
| **對外網路連線** | 連不到 `api.anthropic.com` / `api.openai.com`;並區分是 DNS 解析失敗還是 TLS 連線被擋,再給出 resolv.conf、VPN MTU、企業憑證的對應處理 |
| **WSL 版本與設定** | 仍在 WSL1;systemd 未啟用 |
| **.wslconfig 資源配置** | 記憶體配得太低(agent 跑到一半被 OOM killer 砍掉);配得太高排擠 Windows;`processors` 超過實體核心數或設定值寫錯格式 |

檢查結果分三級:

- `PASS` — 沒問題
- `WARN` — 影響效能或穩定性,但工具還能運作
- `FAIL` — 會直接導致 AI CLI 無法正常運作,需優先處理

---

## 安裝 / Installation

### 直接下載執行

```bash
curl -fsSL https://raw.githubusercontent.com/Carinoasd/wsl-ai-doctor/main/wsl-ai-doctor.sh -o wsl-ai-doctor.sh
chmod +x wsl-ai-doctor.sh
./wsl-ai-doctor.sh
```

### 或 clone 整個專案

```bash
git clone https://github.com/Carinoasd/wsl-ai-doctor.git
cd wsl-ai-doctor
./wsl-ai-doctor.sh
```

### 需求

- WSL2(WSL1 也能執行,會直接提示你升級)
- Bash 4.4+(Ubuntu / Debian / Fedora 等主流發行版預設皆符合)
- `curl`(僅網路檢查需要;沒有時可用 `--skip-network` 略過)

不需要 root 權限,腳本**只讀取不修改**任何設定。

---

## 使用範例 / Usage

```bash
./wsl-ai-doctor.sh
```

輸出範例:

```
wsl-ai-doctor v0.2.1 — WSL AI coding agent 環境健檢
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

### 選項

| 選項 | 說明 |
| --- | --- |
| `-h, --help` | 顯示說明 |
| `-v, --version` | 顯示版本 |
| `--no-color` | 停用彩色輸出 |
| `--color` | 強制彩色輸出(即使不是終端機) |
| `--json` | 輸出機器可讀的 JSON(自動停用顏色) |
| `--lang <代碼>` | 診斷訊息語言:`zh-TW`(預設)或 `en` |
| `--skip-network` | 略過對外連線檢查(離線環境使用) |
| `--allow-non-wsl` | 非 WSL 環境也執行,WSL 相關檢查標記為 SKIP(CI 用) |

輸出到檔案或管線時會自動停用顏色,也支援 [`NO_COLOR`](https://no-color.org/) 慣例:

```bash
./wsl-ai-doctor.sh > health-report.txt
```

### JSON 輸出

`--json` 讓結果可以被其他工具消費。每筆檢查都有**穩定的 `id`**,是串接時可靠的錨點——訊息文字會隨版本或語言改變,`id` 不會:

```bash
./wsl-ai-doctor.sh --json
```

```json
{
  "tool": "wsl-ai-doctor",
  "version": "0.2.1",
  "generated_at": "2026-08-17T12:47:35+0800",
  "lang": "zh-TW",
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
      "message": "npm 全域安裝路徑位於 Windows 端:C:\\Users\\you\\AppData\\Roaming\\npm",
      "hints": ["這正是「明明 npm install -g 裝好了,指令卻找不到」最常見的原因:"],
      "commands": ["curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"]
    }
  ]
}
```

`summary.health` 有四種值:`healthy`、`usable`、`needs_fix`、`not_applicable`(非 WSL 環境)。

搭配 `jq` 取出所有需要處理的項目:

```bash
./wsl-ai-doctor.sh --json | jq -r '.checks[] | select(.status=="fail") | .id'
```

### 語言切換

診斷訊息預設為繁體中文,可切換為英文:

```bash
./wsl-ai-doctor.sh --lang en
```

也可用環境變數設為預設,寫進 `~/.bashrc` 即可:

```bash
export WSL_AI_DOCTOR_LANG=en
```

`--lang` 同時影響檢查訊息、章節標題、總結與 `--help`。修復指令本身不翻譯,因為 shell 指令沒有語言之分。

### 離開代碼 / Exit codes

| 代碼 | 意義 |
| --- | --- |
| `0` | 全部通過 |
| `1` | 有 WARN,無 FAIL |
| `2` | 有 FAIL |
| `3` | 不在 WSL 環境中,未執行任何檢查 |
| `64` | 選項用法錯誤 |

在非 WSL 環境(原生 Linux、容器、CI runner)執行時,本工具**預設拒絕執行並回報 `3`**。因為所有檢查的前提都是 WSL,硬跑只會產生誤導性建議(例如叫你去修改一台根本沒有 `/etc/wsl.conf` 的機器)。若確實需要在這類環境執行,加上 `--allow-non-wsl`,WSL 專屬的檢查會標記為 `SKIP`。

適合放進 devcontainer 或環境初始化腳本裡當作前置檢查:

```bash
./wsl-ai-doctor.sh --skip-network || echo "環境有待處理的問題"
```

### 環境變數

各項門檻皆可覆寫,適用於團隊有自訂標準的情況:

| 變數 | 預設值 | 說明 |
| --- | --- | --- |
| `WSL_AI_DOCTOR_LANG` | `zh-TW` | 預設語言(`zh-TW` 或 `en`) |
| `WSL_AI_DOCTOR_NODE_MIN` | `18` | Node.js 最低版本,低於此值判為 FAIL |
| `WSL_AI_DOCTOR_NODE_RECOMMENDED` | `20` | Node.js 建議版本,低於此值判為 WARN |
| `WSL_AI_DOCTOR_NET_TIMEOUT` | `8` | 網路檢查逾時秒數 |
| `WSL_AI_DOCTOR_MEM_MIN_GB` | `4` | `.wslconfig` 記憶體下限(GB) |
| `WSL_AI_DOCTOR_MEM_MAX_PCT` | `80` | `.wslconfig` 記憶體佔主機比例上限(%) |
| `WSL_AI_DOCTOR_PATH_WIN_WARN` | `25` | PATH 中 Windows 路徑數量警戒值 |
| `WSL_AI_DOCTOR_WSLCONFIG` | 自動偵測 | 指定 `.wslconfig` 路徑 |

```bash
WSL_AI_DOCTOR_NODE_MIN=20 ./wsl-ai-doctor.sh
```

---

## 為什麼需要這個工具 / Why

WSL 是一個「兩個作業系統共用一份 PATH」的環境,大部分疑難雜症都源自這個特性:

- Windows 的 PATH 預設會併入 WSL,所以 `npm` 可能解析到 `/mnt/c/Program Files/nodejs/npm`
  ——指令能跑,但它是 Windows 程式,拿到 `/home/you/project` 這種路徑就失效了。
- `npm install -g` 會把套件裝進 Windows 的 `%APPDATA%\npm`,產生的 `.cmd` 包裝檔在 bash 裡叫不動。
- 錯誤訊息通常只有 `command not found` 或某個 npm 內部堆疊,完全指不到真正的原因。

這些問題單獨看都不難修,難的是**知道要往哪裡看**。這支腳本的目的就是把「往哪裡看」這件事自動化。

---

## Roadmap

已完成:

- [x] `--json` 輸出,方便串接其他工具(v0.2.0)
- [x] 英文輸出(`--lang en`)(v0.2.0)
- [x] 非 WSL 環境防護與 CI(v0.2.0)

規劃中:

- [ ] `--fix` 自動修復模式
- [ ] 互動式選單,逐項確認要修的問題
- [ ] 更多檢查:git 設定、SSH agent、Docker Desktop 整合、專案是否放在 `/mnt/c`(跨檔案系統的效能陷阱)
- [ ] 更多語言(訊息目錄已備妥,新增語言只需補一份對照表)

完整的版本紀錄見 [CHANGELOG.md](CHANGELOG.md)。

---

## Contributing

歡迎回報你遇過的 WSL 環境地雷 —— 尤其是那種「錯誤訊息完全誤導人」的案例,那正是這個工具最該涵蓋的部分。

送 PR 前請確認:

```bash
bash -n wsl-ai-doctor.sh          # 語法檢查
shellcheck -S warning wsl-ai-doctor.sh   # 靜態檢查
```

CI 會在每次 push 與 PR 跑上述兩項加上冒煙測試。由於 GitHub runner 不是 WSL,冒煙測試透過 `--allow-non-wsl` 讓檢查真的執行,而不是只用 `--help` 應付。

新增訊息時必須**同時**加進腳本裡的 `MSG_ZH` 與 `MSG_EN`。英文輸出若殘留未翻譯的文字或 `<missing:...>` 鍵,CI 會直接失敗。

---

## License

[MIT](LICENSE)
