# Changelog

本專案的所有重要變更都記錄於此。
格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/),版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

---

## [0.2.1] - 2026-08-17

### Fixed

- **PATH 檢查對套件管理器的前瞻性目錄誤判。** Ubuntu 預設把 `/snap/bin` 寫進 `/etc/environment`,但在還沒安裝任何 snap 套件之前該目錄並不存在,先前會被判為「移除工具後沒清理的殘留」而發出 WARN,並建議使用者去清理一個其實正常的設定。現在若對應的套件管理器已安裝(`/snap/bin` 對應 `snap`),改以 INFO 說明「由套件管理器負責建立」,不列入警告。真正失效的目錄仍照常警告。
  *PATH check no longer flags directories that an installed package manager creates on demand. `/snap/bin` on a system with snapd but no snaps installed was previously reported as a leftover, which sent users to clean up a perfectly correct configuration.*

---

## [0.2.0] - 2026-08-17

這一版的重點是把工具從「一支腳本」變成「可以被信任、可以被串接的工具」:輸出可被機器消費、訊息可切換語言、行為由 CI 保護。

This release turns the tool from a script into something dependable and composable:
machine-readable output, switchable languages, and CI protecting the behaviour.

### Added

- **`--json`** — 輸出機器可讀的 JSON,包含 `environment`、`summary`、`exit_code` 與 `checks` 陣列。每筆檢查帶有**穩定的 `id`**(例如 `npm.prefix_location`),訊息文字會隨版本與語言改變,`id` 不會,因此串接時應以 `id` 為錨點。
  *Machine-readable JSON output. Every check carries a stable `id` to key on.*
- **`--lang en` 與 `WSL_AI_DOCTOR_LANG`** — 診斷訊息、章節標題、總結與 `--help` 皆可切換為英文。修復指令本身不翻譯,因為 shell 指令沒有語言之分。
  *English diagnostics via flag or environment variable.*
- **`--allow-non-wsl`** — 在非 WSL 環境仍執行檢查,WSL 專屬項目標記為新的 `SKIP` 狀態。主要供 CI 使用。
  *Run outside WSL with WSL-specific checks marked SKIP; intended for CI.*
- **`SKIP` 狀態** — 單獨計數,不影響健康判定與離開代碼,用於區分「刻意跳過」與「沒跑到」。
  *A SKIP status, counted separately and excluded from the health verdict.*
- **離開代碼 `3`** — 不在 WSL 環境中、未執行任何檢查。不能用 `0`(會謊稱健康)也不能用 `2`(那代表發現問題)。
  *Exit code 3 for "not a WSL environment, nothing was checked".*
- **GitHub Actions CI** — `bash -n`、`shellcheck -S warning`,以及在 ubuntu runner 上實際執行腳本的冒煙測試(涵蓋離開代碼、JSON 結構、英文完整性、顏色控制、參數順序)。
  *CI with lint and a real smoke test on every push and pull request.*

### Changed

- **架構重構(內部)** — 檢查邏輯、結果集合、輸出格式三者分離。檢查函式不再直接 `printf`,改為呼叫 `record()` 存入結果集合,跑完後由 `render_text` 或 `render_json` 決定呈現方式;所有人類可讀字串經由訊息目錄取得。此前每個檢查邊執行邊輸出,新增任何輸出形式都得把每條訊息重寫一遍。
  *Internal three-layer refactor: checks → result store → renderers, with a message catalog.*
- **非 WSL 環境的行為** — 先前偵測到非 WSL 只會標記一項 FAIL 後**繼續執行**,產生誤導性結果(例如建議修改一台沒有 `/etc/wsl.conf` 的機器,或把原生 Linux 的 node 描述為「WSL 端安裝」),最後以 `2` 結束。現在預設不執行任何檢查,清楚說明後以 `3` 結束。
  *Outside WSL the tool now refuses to run instead of emitting misleading advice.*
- 文字輸出格式與既有離開代碼(`0`/`1`/`2`/`64`)維持不變,v0.1.0 的使用方式完全相容。
  *Text output and existing exit codes are unchanged; v0.1.0 usage still works.*

### Fixed

- `--help --lang en` 會印出中文說明。`--help` 原本在參數迴圈中立即結束,後面的 `--lang` 根本沒被讀到;改為解析完所有參數再輸出。
  *`--help --lang en` printed the wrong language because `--help` exited before `--lang` was parsed.*
- 以 `-` 開頭的訊息會整句消失(例如英文的 `--skip-network given, ...`),因為 `printf` 把它當成選項。改用 `printf --`。
  *Messages starting with `-` vanished because printf treated them as options.*
- 非 WSL 環境中 `check_wsl()` 的 `return 1` 只跳出函式、未中止腳本,導致後續檢查照常輸出。
  *The non-WSL guard only returned from its function instead of stopping the run.*

### Notes

- 需要 bash 4.0 以上(使用 associative array 實作訊息目錄),啟動時會檢查並給出明確訊息。
  *Requires bash 4.0+; the script checks and reports this explicitly.*

---

## [0.1.0] - 2026-08-17

首次發布。針對在 WSL 上使用 AI coding agent CLI 的使用者,一次跑完六類環境檢查。

Initial release: six classes of environment checks for developers running AI coding agent CLIs on WSL.

### Added

- **Node.js 版本檢查** — 版本是否符合 AI CLI 需求;是否誤用 Windows 版 `node.exe`;`node` 與 `npm` 是否分屬 WSL / Windows 兩側。
  *Node.js version, accidental use of the Windows build, and node/npm coming from opposite sides.*
- **PATH 檢查** — Windows interop 是否生效;`node`/`npm`/`git` 等是否被 Windows 版本蓋過;PATH 中的空值(等同當前目錄,有安全風險)、重複項與失效目錄。
  *PATH correctness: interop, shadowing, empty entries, duplicates, dead directories.*
- **npm 全域安裝檢查** — 全域前綴是否落在 Windows 端;全域 bin 是否在 PATH 中;逐一比對已安裝的執行檔是否真的叫得出來(抓「明明裝了但指令找不到」);前綴目錄是否可寫。
  *npm global installs, including the classic "installed but command not found".*
- **對外網路連線檢查** — `api.anthropic.com` 與 `api.openai.com` 是否可達,並區分 DNS 解析失敗與 TLS 連線受阻,再給出 resolv.conf、VPN MTU、企業憑證的對應處理。
  *Connectivity to the AI API endpoints, distinguishing DNS failure from blocked TLS.*
- **WSL 版本與設定檢查** — 是否為 WSL2;systemd 是否啟用。
  *WSL2 versus WSL1, and whether systemd is enabled.*
- **`.wslconfig` 資源配置檢查** — 記憶體是否過低(會被 OOM killer 砍掉)或過高(排擠 Windows);`processors` 是否超過實體核心數或格式錯誤。配置合理與否是對照 Windows 主機的實際資源判斷,而非寫死門檻。
  *.wslconfig memory and CPU sanity, compared against the actual host resources.*
- 每項檢查以 `PASS` / `WARN` / `FAIL` 分級,`WARN` 與 `FAIL` 一律附上可直接複製貼上的修復指令。
  *Every WARN and FAIL comes with copy-pasteable fix commands.*
- 彩色總結;輸出到檔案或管線時自動停用顏色,並支援 `NO_COLOR`。
  *Colored summary, auto-disabled for files and pipes, honouring NO_COLOR.*
- 離開代碼 `0`(全過)/ `1`(有 WARN)/ `2`(有 FAIL)/ `64`(用法錯誤)。
  *Exit codes for scripting.*
- 所有門檻皆可用環境變數覆寫。
  *All thresholds overridable via environment variables.*

[0.2.1]: https://github.com/Carinoasd/wsl-ai-doctor/releases/tag/v0.2.1
[0.2.0]: https://github.com/Carinoasd/wsl-ai-doctor/releases/tag/v0.2.0
[0.1.0]: https://github.com/Carinoasd/wsl-ai-doctor/releases/tag/v0.1.0
