#!/usr/bin/env bash
#
# wsl-ai-doctor — WSL 環境健康檢查工具
#
# 針對在 WSL 上使用 AI coding agent CLI(Claude Code / Codex CLI 等)的使用者,
# 快速找出「裝好了卻跑不動」的環境問題,並給出可直接複製貼上的修復指令。
#
# 用法: ./wsl-ai-doctor.sh [選項]
# 授權: MIT
#
# 架構(v0.2.0 起分為三層,便於新增輸出格式與語言):
#
#   檢查層  →  結果集合  →  輸出層(text / json)
#                             ↑
#                         訊息目錄(zh-TW / en)
#
#   * 檢查函式不直接印出任何東西,一律呼叫 record() 存入結果集合
#   * 全部檢查跑完後,由 render_text 或 render_json 決定如何呈現
#   * 所有人類可讀的字串都經過 t() 從訊息目錄取得,支援多語系
#
# 注意:本腳本刻意不使用 `set -e`。每一項檢查失敗都是預期中的結果,
#       不應該中斷整份健檢流程。

set -uo pipefail

VERSION="0.3.0"

# 依賴 associative array(declare -A),需要 bash 4.0 以上
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  printf 'ERROR: wsl-ai-doctor 需要 bash 4.0 以上,目前為 %s\n' "${BASH_VERSION:-未知}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 可調參數(皆可用環境變數覆寫)
# ---------------------------------------------------------------------------

# AI CLI 工具常見的 Node.js 需求:多數要求 18+,較新的版本要求 20+。
NODE_MIN_REQUIRED="${WSL_AI_DOCTOR_NODE_MIN:-18}"
NODE_MIN_RECOMMENDED="${WSL_AI_DOCTOR_NODE_RECOMMENDED:-20}"

# 網路檢查
NET_TIMEOUT="${WSL_AI_DOCTOR_NET_TIMEOUT:-8}"
NET_ENDPOINTS=(
  "https://api.anthropic.com"
  "https://api.openai.com"
)

# .wslconfig 合理範圍
WSLCONF_MEM_MIN_GB="${WSL_AI_DOCTOR_MEM_MIN_GB:-4}"     # 低於此值容易在跑 node/agent 時卡頓
WSLCONF_MEM_MAX_PCT="${WSL_AI_DOCTOR_MEM_MAX_PCT:-80}"  # 高於主機記憶體此比例會排擠 Windows

# PATH 中 Windows 路徑數量的警戒值(過多會拖慢每次指令查找與 tab 補全)
PATH_WIN_ENTRY_WARN="${WSL_AI_DOCTOR_PATH_WIN_WARN:-25}"

# nvm 安裝指令(多處引用,集中一處便於更新版本)
NVM_INSTALL_CMD="curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"

# 本工具自身的下載位址。以管線方式執行(curl ... | bash)時,腳本並不存在於
# 檔案系統上,提示中的「請再執行一次」就得改用這個網址,否則會印出
# `bash --allow-non-wsl` 這種根本不存在的指令。
SELF_RAW_URL="https://raw.githubusercontent.com/Carinoasd/wsl-ai-doctor/main/wsl-ai-doctor.sh"

# ---------------------------------------------------------------------------
# 執行期狀態
# ---------------------------------------------------------------------------

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

USE_COLOR=auto
SKIP_NETWORK=0
ALLOW_NON_WSL=0                            # --allow-non-wsl:非 WSL 環境也繼續執行
NON_WSL=0                                  # 執行期判定:1 代表目前不在 WSL 中
OUTPUT_FORMAT=text                         # text | json
LANG_CODE="${WSL_AI_DOCTOR_LANG:-zh-TW}"   # zh-TW | en

# 環境資訊(供 JSON 輸出與部分檢查使用)
ENV_KERNEL=""
ENV_DISTRO=""
ENV_WSL_VERSION=""
ENV_SYSTEMD=""

# 結果集合。以平行陣列儲存,hints/cmds 內部用 US(0x1f)分隔多筆。
R_ID=(); R_SECTION=(); R_STATUS=(); R_MSG=(); R_HINTS=(); R_CMDS=()
CURRENT_SECTION=""
US=$'\x1f'

# ---------------------------------------------------------------------------
# 訊息目錄
# ---------------------------------------------------------------------------
#
# 值會經過 printf 處理,因此:
#   * 佔位符用 %s
#   * 字面上的 % 要寫成 %%
#   * 字面上的反斜線要寫成 \\
#
# 不含自然語言的純指令字串不放在這裡(shell 指令沒有語言之分),
# 只有夾帶說明性註解的指令才需要翻譯。

declare -A MSG_ZH=(
  [app.tagline]='WSL AI coding agent 環境健檢'
  [app.time]='檢查時間:%s'

  [sec.wsl]='WSL 版本與設定'
  [sec.node]='Node.js 版本'
  [sec.path]='PATH 設定'
  [sec.npm]='npm 全域安裝與 PATH'
  [sec.net]='對外網路連線'
  [sec.wslconf]='.wslconfig 資源配置'

  [gate.not_wsl]='目前不在 WSL 環境中(kernel: %s)'
  [gate.h1]='本工具專為 WSL 設計,在原生 Linux 或容器中執行只會得到誤導性結果,'
  [gate.h2]='因此不進行任何檢查。請在 WSL 發行版的終端機內執行。'
  [gate.h3]='若你確定要在此環境執行(例如 CI 冒煙測試),可加上:'
  [gate.h4]='與 WSL 相關的檢查會標記為 SKIP,其餘檢查照常執行。'
  [gate.forced]='⚠ 非 WSL 環境,以 --allow-non-wsl 繼續執行;WSL 相關檢查將標記為 SKIP。'

  [wsl.skip]='非 WSL 環境,略過 WSL 版本與設定檢查(kernel: %s)'
  [wsl.v2]='WSL2(kernel %s)'
  [wsl.v1]='偵測到 WSL1(kernel %s)'
  [wsl.v1.h1]='WSL1 沒有完整 Linux kernel,檔案 I/O 與網路行為和原生 Linux 差異大,'
  [wsl.v1.h2]='跑 node 生態系與 AI CLI 工具容易出現難以診斷的問題。請升級到 WSL2:'
  [wsl.v1.c1]='wsl --set-version %s 2   # 在 Windows PowerShell 執行'
  [wsl.distro]='發行版:%s'
  [wsl.systemd_on]='systemd 已啟用(PID 1 = systemd)'
  [wsl.systemd_off]='systemd 未啟用(PID 1 = %s)'
  [wsl.systemd.h1]='沒有 systemd 時,以 service/systemctl 管理的元件(docker、ssh-agent、'
  [wsl.systemd.h2]='自訂背景服務)無法正常啟動,部分開發工具的背景常駐程序也會受影響。'
  [wsl.systemd.h3]='在 /etc/wsl.conf 加入以下設定後,於 PowerShell 執行 wsl --shutdown 重啟:'
  [wsl.shutdown_cmd]='wsl --shutdown   # 在 Windows PowerShell 執行,再重開 WSL'
  [wsl.unknown]='未知'
  [wsl.conf_exists]='/etc/wsl.conf 存在'
  [wsl.conf_append_false]='已設定 appendWindowsPath=false(Windows PATH 不會併入 WSL,屬刻意設定)'
  [wsl.conf_missing]='/etc/wsl.conf 不存在(使用預設設定)'

  [node.missing]='找不到 node 指令'
  [node.missing.h1]='Claude Code、Codex CLI 等工具都以 Node.js 執行。建議用 nvm 在 WSL 內安裝:'
  [node.missing.h2]='請勿把 Windows 版 Node.js 當成 WSL 的 node 使用,兩者無法互通。'
  [node.no_version]='node 指令存在(%s),但無法取得版本(node -v 執行失敗)'
  [node.no_version.h1]='多半是 node 指到已損毀的安裝,或指向一個目前無法從 WSL 存取的 Windows 執行檔。'
  [node.unparsable]='無法解析 Node.js 版本字串:%s'
  [node.too_old]='Node.js v%s 過舊(AI CLI 工具普遍要求 v%s 以上)'
  [node.too_old.h1]='多數 AI CLI 在舊版 Node 上會直接安裝失敗,或啟動時報語法錯誤。請升級:'
  [node.below_rec]='Node.js v%s 可用,但建議升級到 v%s 以上'
  [node.below_rec.h1]='較新版本的 AI CLI 工具已陸續把最低需求拉高到 v%s。'
  [node.ok]='Node.js v%s(>= v%s)'
  [node.win]='node 指向 Windows 安裝:%s'
  [node.win.h1]='這是 WSL 上最常見的地雷。Windows 版 node.exe 從 WSL 呼叫時:'
  [node.win.h2]='  • 認得的是 Windows 路徑(C:\\...),拿到 Linux 路徑(/home/...)會找不到檔案'
  [node.win.h3]='  • 透過 /mnt 跨檔案系統存取,npm install 會慢上數倍'
  [node.win.h4]='  • 原生模組(node-gyp)編出來的是 Windows 二進位檔,在 WSL 內無法載入'
  [node.win.h5]='請在 WSL 內另外安裝一份 Linux 版 Node.js:'
  [node.native]='node 為原生 Linux 安裝:%s'
  [node.wsl]='node 為 WSL 端安裝:%s'
  [npm.missing]='找不到 npm 指令'
  [npm.missing.h1]='Node.js 安裝通常會一併帶上 npm;若只缺 npm,多半是安裝不完整。'
  [npm.missing.c1]='nvm install --lts   # 重新安裝一份完整的 Node.js'
  [npm.mixed]='node 在 WSL 端,npm 卻指向 Windows 端:%s'
  [npm.mixed.h1]='兩者混用時,npm 會把套件裝到 Windows 的目錄,而 WSL 的 node 找不到它們。'
  [npm.mixed.h2]='請確認 PATH 中 WSL 的 node 目錄排在 Windows 路徑之前,或重裝 nvm。'
  [npm.native]='npm 為原生 Linux 安裝:%s(%s)'
  [npm.wsl]='npm 為 WSL 端安裝:%s(%s)'
  [npm.win]='npm 指向 Windows 安裝:%s'
  [npm.win.h1]='與上一項為同一個根因,修好 node 之後這項通常會一起解決。'

  [path.count]='PATH 共 %s 個項目'
  [path.count_split]='PATH 共 %s 個項目(WSL 端 %s、Windows 端 %s)'
  [path.skip_interop]='非 WSL 環境,略過 Windows interop 與跨側指令解析檢查'
  [path.no_win]='PATH 中沒有任何 Windows 路徑,無法從 WSL 呼叫 Windows 指令'
  [path.no_win.h1]='AI CLI 的登入流程常需要呼叫 Windows 開啟瀏覽器;關掉 interop 後 OAuth 會卡住。'
  [path.no_win.h2]='若 /etc/wsl.conf 裡設了 appendWindowsPath=false,請改為 true 或移除該行:'
  [path.no_win.c2]='wsl --shutdown   # 在 Windows PowerShell 執行後重開'
  [path.too_many_win]='PATH 中有 %s 個 Windows 路徑,數量偏多(建議 <= %s)'
  [path.too_many_win.h1]='每個 Windows 路徑都跨 9p 檔案系統查找,會拖慢每次指令解析與 tab 補全。'
  [path.too_many_win.h2]='可改為只保留必要的 Windows 路徑:在 /etc/wsl.conf 設 appendWindowsPath=false,'
  [path.too_many_win.h3]='再於 ~/.bashrc 手動補上真正需要的幾個(例如 cmd.exe、powershell.exe 所在目錄)。'
  [path.interop_ok]='Windows interop 路徑正常(%s 個)'
  [path.wintools_ok]='可從 WSL 呼叫 Windows 指令(cmd.exe / powershell.exe)'
  [path.wintools_missing]='以下 Windows 指令無法從 WSL 呼叫:%s'
  [path.wintools_missing.h1]='OAuth 登入、開啟瀏覽器、讀取 .wslconfig 等功能會受影響。'
  [path.wintools_missing.h2]='請確認 /etc/wsl.conf 中 [interop] enabled 未被設為 false。'
  [path.shadow_ok]='常用開發指令都解析到 WSL 端版本'
  [path.shadowed]='以下指令解析到 Windows 端版本,而非 WSL 端:'
  [path.shadowed.h1]='跨側執行會導致路徑轉換錯誤、權限問題與效能損失。請在 WSL 內安裝對應工具,'
  [path.shadowed.h2]='並確認 ~/.bashrc 中 WSL 路徑排在 Windows 路徑之前:'
  [path.shadowed.c2]='command -v -a node   # 確認所有候選路徑與優先順序'
  [path.empty]='PATH 中含有 %s 個空值項目'
  [path.empty.h1]='空值等同於「當前目錄」,會讓 shell 執行到工作目錄下的同名檔案,有安全風險。'
  [path.empty.h2]='通常來自 ~/.bashrc 裡寫成 PATH="$PATH:" 或 PATH=":$PATH" 的多餘冒號。'
  [path.dup]='PATH 中有 %s 個重複項目:%s'
  [path.dup.h1]='多半是 ~/.bashrc 或 ~/.profile 被重複載入(例如 export PATH 寫在會重跑的區塊)。'
  [path.dup.h2]='不影響正確性,但會拖慢指令查找,也讓排查 PATH 問題變得困難。'
  [path.missing_dirs]='PATH 中有 %s 個不存在的目錄:%s'
  [path.missing_dirs.h1]='通常是移除工具後、rc 檔沒有跟著清理。清掉可減少每次指令查找的無效 stat。'
  [path.provisioned]='PATH 中有尚未建立的目錄:%s(由已安裝的套件管理器負責建立,不視為問題)'
  [path.clean]='PATH 內容乾淨(無空值、重複或失效目錄)'

  [npmg.no_npm]='找不到 npm,略過全域套件檢查'
  [npmg.no_npm.h1]='請先解決上面的 Node.js 問題,再重新執行本工具。'
  [npmg.no_prefix]='無法取得 npm 全域安裝路徑(npm config get prefix 沒有回應)'
  [npmg.win_prefix]='npm 全域安裝路徑位於 Windows 端:%s'
  [npmg.win_prefix.h1]='這正是「明明 npm install -g 裝好了,指令卻找不到」最常見的原因:'
  [npmg.win_prefix.h2]='  • 套件被裝進 Windows 的 %%APPDATA%%\\npm,產生的是 .cmd / .ps1 包裝檔'
  [npmg.win_prefix.h3]='  • 這些包裝檔在 WSL 的 bash 裡不是可執行的 Linux 執行檔'
  [npmg.win_prefix.h4]='  • 即使能執行,傳進去的 Linux 路徑 Windows 端也解讀不了'
  [npmg.win_prefix.h5]='請在 WSL 內安裝 Linux 版 Node.js,讓全域前綴落在 $HOME 底下:'
  [npmg.win_prefix.c3]='npm config get prefix   # 應顯示 /home/... 開頭的路徑'
  [npmg.prefix]='npm 全域前綴:%s'
  [npmg.bin_missing]='全域執行檔目錄不存在:%s'
  [npmg.bin_missing.h1]='尚未安裝任何全域套件時屬正常;若已安裝過,代表 prefix 設定有誤。'
  [npmg.bin_in_path]='全域執行檔目錄已在 PATH 中:%s'
  [npmg.bin_not_in_path]='全域執行檔目錄不在 PATH 中:%s'
  [npmg.bin_not_in_path.h1]='npm install -g 會成功,但裝好的指令一律「command not found」。加入 PATH:'
  [npmg.writable]='全域前綴目錄可寫入,不需要 sudo 安裝'
  [npmg.not_writable]='全域前綴目錄不可寫入:%s'
  [npmg.not_writable.h1]='會逼你用 sudo npm install -g,而 sudo 裝出來的檔案屬 root,'
  [npmg.not_writable.h2]='之後 npm update / 移除都可能因權限失敗。建議改用使用者層級的前綴:'
  [npmg.none]='尚未安裝任何全域執行檔'
  [npmg.all_ok]='全部 %s 個全域執行檔都能正常解析'
  [npmg.not_found]='以下全域執行檔已安裝,但在目前 shell 中找不到:%s'
  [npmg.not_found.h1]='典型的「裝了但指令不存在」。%s 沒有生效於當前 PATH:'
  [npmg.not_found.c2]='hash -r   # 清掉 shell 快取的舊指令位置'
  [npmg.shadowed]='以下全域執行檔被其他路徑的同名指令蓋過:'
  [npmg.shadowed.h1]='你執行到的不是 npm 剛裝的那一份,版本可能不一致。確認優先順序:'
  [npmg.shadowed.c1]='command -v -a <指令名稱>'

  [net.skipped]='已指定 --skip-network,略過網路檢查'
  [net.no_curl]='找不到 curl,無法檢查網路連線'
  [net.proxy]='偵測到 proxy 設定:%s'
  [net.ok]='%s 可連線(HTTP %s)'
  [net.dns_fail]='%s DNS 解析失敗'
  [net.tls_fail]='%s DNS 正常,但 HTTPS 連線失敗(逾時 %ss)'
  [net.diag]='WSL 網路異常常見的幾個原因與對應處理:'
  [net.diag.dns]='  目前 DNS 伺服器:%s'
  [net.diag.dns_none]='(未設定)'
  [net.diag.no_resolv]='  /etc/resolv.conf 不存在,DNS 完全無法運作。'
  [net.diag.gen1]='  1) resolv.conf 由 WSL 自動產生。若公司 VPN 或防火牆干擾了 DNS,'
  [net.diag.gen2]='     可改為自行指定(先關掉自動產生,再寫入固定 DNS):'
  [net.diag.gen_c2]='wsl --shutdown   # PowerShell 執行後重開,再設定 /etc/resolv.conf'
  [net.diag.mtu]='  2) 使用 VPN 時,WSL 的 MTU 常大於 VPN 介面,造成 TLS 交握卡死:'
  [net.diag.cert]='  3) 企業防火牆做 TLS 攔截時,需要把公司根憑證加入 WSL 的信任清單:'
  [net.diag.global]='  4) 先確認是否為全域斷網(而非只有 API 網域被擋):'

  [wc.skip]='非 WSL 環境,沒有 .wslconfig 可檢查'
  [wc.no_winhome]='無法定位 Windows 使用者家目錄,略過 .wslconfig 檢查'
  [wc.no_winhome.h1]='通常代表 Windows interop 被關閉,或 C: 未掛載到 /mnt/c。'
  [wc.host]='Windows 主機:%s GB RAM / %s 邏輯核心'
  [wc.current]='WSL 目前可用:%s GB RAM / %s 核心'
  [wc.missing_small]='找不到 .wslconfig,且主機記憶體偏小(%s GB)'
  [wc.missing_small.h1]='WSL2 預設最多用一半實體記憶體,在小記憶體機器上跑 node + AI agent 容易 OOM。'
  [wc.missing_small.h2]='建議建立 %s 明確配置(記憶體回收由 WSL 自動處理,設高不代表一直佔用):'
  [wc.missing_ok]='未設定 .wslconfig,採用 WSL2 預設值(記憶體上限約為實體記憶體一半)'
  [wc.missing_ok.info]='預設值對多數機器已足夠;需要精細控制時可建立:%s'
  [wc.path]='.wslconfig 位置:%s'
  [wc.mem_default]='未指定 memory,採用預設值(實體記憶體的一半)'
  [wc.mem_unparsable]='memory 值無法解析:%s'
  [wc.mem_unparsable.h1]='格式應為 memory=8GB 或 memory=8192MB。寫錯時 WSL 會忽略整行,靜默套用預設值。'
  [wc.mem_low]='memory=%s 偏低(建議至少 %sGB)'
  [wc.mem_low.h1]='Node.js 加上 AI agent 的檔案索引與語言伺服器很吃記憶體,配得太低會頻繁觸發'
  [wc.mem_low.h2]='OOM killer,症狀是 agent 跑到一半無預警被砍掉。建議調整:'
  [wc.mem_low.c1]='# 編輯 %s,將 memory 改為 %sGB 以上,再執行 wsl --shutdown'
  [wc.mem_high]='memory=%s 佔主機記憶體 %s%%(建議不超過 %s%%)'
  [wc.mem_high.h1]='留給 Windows 的記憶體不足時,整台機器會開始頻繁換頁,反而讓 WSL 也一起變慢。'
  [wc.mem_high.h2]='建議上限:%sGB'
  [wc.mem_ok]='memory=%s(%sGB)配置合理'
  [wc.cpu_default]='未指定 processors,採用預設值(全部邏輯核心)'
  [wc.cpu_unparsable]='processors 值無法解析:%s'
  [wc.cpu_unparsable.h1]='應為正整數,例如 processors=8。'
  [wc.cpu_low]='processors=%s 過低'
  [wc.cpu_low.h1]='npm install 與 AI agent 的平行檔案掃描在單核心下會明顯變慢。建議至少 2 核心。'
  [wc.cpu_over]='processors=%s 超過主機邏輯核心數(%s)'
  [wc.cpu_over.h1]='超出的部分不會生效,WSL 會直接以主機核心數為上限。'
  [wc.cpu_full]='processors=%s 已用滿全部核心;若編譯時 Windows 端會卡頓,可保留 1-2 核給主機。'
  [wc.cpu_ok]='processors=%s 配置合理'
  [wc.swap_zero]='swap=0(已停用)。記憶體吃緊時會直接觸發 OOM killer,而非降速。'
  [wc.swap]='swap=%s'
  [wc.restart]='提醒:修改 .wslconfig 後需要重啟 WSL 才會生效。'
  [wc.restart.c1]='wsl --shutdown   # 在 Windows PowerShell 執行'

  [sum.title]=' 健檢總結(共 %s 項)'
  [sum.skip_note]='(此環境不適用)'
  [sum.fail]='環境狀態:需要修復'
  [sum.fail.detail]=' — 有 %s 項會直接導致 AI CLI 工具無法正常運作。'
  [sum.fail.action]=' 請依上方 [FAIL] 項目的建議指令處理,修復後重新執行本工具確認。'
  [sum.warn]='環境狀態:堪用'
  [sum.warn.detail]=' — 沒有致命問題,但有 %s 項建議調整。'
  [sum.warn.action]=' 這些多半影響效能或穩定性,不會立刻讓工具失效。'
  [sum.ok]='環境狀態:健康'
  [sum.ok.detail]=' — 所有檢查項目都通過。'

  [ai.title]='🤖 AI 修復建議'
  [ai.desc]='偵測到本機已安裝 claude,可以把診斷結果直接交給 AI 逐項處理:'
  [ai.prompt]='請執行 %s --json 取得這台 WSL 的環境診斷,針對 status 為 fail 與 warn 的每一項,說明問題成因並協助我修復;動到我的設定檔之前,先告訴我要改哪個檔案的哪一行,經我確認後再修改。'

  [err.unknown_option]='ERROR: 未知的選項 %s'
  [err.unknown_lang]='ERROR: 不支援的語言 %s(可用:zh-TW、en)'
  [err.lang_missing]='ERROR: --lang 需要指定語言(zh-TW 或 en)'
)

declare -A MSG_EN=(
  [app.tagline]='WSL AI coding agent environment health check'
  [app.time]='Checked at: %s'

  [sec.wsl]='WSL version and configuration'
  [sec.node]='Node.js version'
  [sec.path]='PATH configuration'
  [sec.npm]='npm global installs and PATH'
  [sec.net]='Outbound connectivity'
  [sec.wslconf]='.wslconfig resource allocation'

  [gate.not_wsl]='Not running inside WSL (kernel: %s)'
  [gate.h1]='This tool is built for WSL. Running it on native Linux or in a container'
  [gate.h2]='only produces misleading results, so no checks were run. Please run it inside a WSL distribution.'
  [gate.h3]='If you intentionally want to run here (for example a CI smoke test), add:'
  [gate.h4]='WSL-specific checks are marked SKIP; everything else runs normally.'
  [gate.forced]='⚠ Not a WSL environment. Continuing with --allow-non-wsl; WSL-specific checks will be marked SKIP.'

  [wsl.skip]='Not a WSL environment, skipping WSL version and configuration checks (kernel: %s)'
  [wsl.v2]='WSL2 (kernel %s)'
  [wsl.v1]='WSL1 detected (kernel %s)'
  [wsl.v1.h1]='WSL1 has no real Linux kernel; its file I/O and networking differ substantially from'
  [wsl.v1.h2]='native Linux, which makes the node ecosystem and AI CLIs fail in hard-to-diagnose ways. Upgrade to WSL2:'
  [wsl.v1.c1]='wsl --set-version %s 2   # run in Windows PowerShell'
  [wsl.distro]='Distribution: %s'
  [wsl.systemd_on]='systemd is enabled (PID 1 = systemd)'
  [wsl.systemd_off]='systemd is not enabled (PID 1 = %s)'
  [wsl.systemd.h1]='Without systemd, anything managed by service/systemctl (docker, ssh-agent,'
  [wsl.systemd.h2]='your own background services) will not start, and some dev tools lose their daemons.'
  [wsl.systemd.h3]='Add the following to /etc/wsl.conf, then restart with wsl --shutdown from PowerShell:'
  [wsl.shutdown_cmd]='wsl --shutdown   # run in Windows PowerShell, then reopen WSL'
  [wsl.unknown]='unknown'
  [wsl.conf_exists]='/etc/wsl.conf exists'
  [wsl.conf_append_false]='appendWindowsPath=false is set (Windows PATH is not merged into WSL; this looks deliberate)'
  [wsl.conf_missing]='/etc/wsl.conf does not exist (using defaults)'

  [node.missing]='node command not found'
  [node.missing.h1]='Claude Code, Codex CLI and similar tools all run on Node.js. Install it inside WSL with nvm:'
  [node.missing.h2]='Do not use the Windows build of Node.js as your WSL node; the two are not interchangeable.'
  [node.no_version]='node exists (%s) but its version could not be read (node -v failed)'
  [node.no_version.h1]='Usually a broken install, or a Windows executable that WSL currently cannot reach.'
  [node.unparsable]='Could not parse the Node.js version string: %s'
  [node.too_old]='Node.js v%s is too old (AI CLIs generally require v%s or newer)'
  [node.too_old.h1]='Most AI CLIs fail to install on older Node, or throw syntax errors at startup. Upgrade:'
  [node.below_rec]='Node.js v%s works, but upgrading to v%s or newer is recommended'
  [node.below_rec.h1]='Newer releases of AI CLI tools have been raising their minimum to v%s.'
  [node.ok]='Node.js v%s (>= v%s)'
  [node.win]='node points at a Windows install: %s'
  [node.win.h1]='This is the most common WSL trap. When node.exe from Windows is called from WSL:'
  [node.win.h2]='  * it understands Windows paths (C:\\...), so a Linux path (/home/...) resolves to nothing'
  [node.win.h3]='  * every access crosses /mnt, making npm install several times slower'
  [node.win.h4]='  * native modules (node-gyp) build Windows binaries that WSL cannot load'
  [node.win.h5]='Install a separate Linux build of Node.js inside WSL:'
  [node.native]='node is a native Linux install: %s'
  [node.wsl]='node is installed on the WSL side: %s'
  [npm.missing]='npm command not found'
  [npm.missing.h1]='A Node.js install normally ships npm; if only npm is missing, the install is incomplete.'
  [npm.missing.c1]='nvm install --lts   # reinstall a complete Node.js'
  [npm.mixed]='node is on the WSL side but npm points at Windows: %s'
  [npm.mixed.h1]='Mixing the two makes npm install packages into Windows directories that WSL node cannot find.'
  [npm.mixed.h2]='Make sure the WSL node directory comes before Windows paths in PATH, or reinstall nvm.'
  [npm.native]='npm is a native Linux install: %s (%s)'
  [npm.wsl]='npm is installed on the WSL side: %s (%s)'
  [npm.win]='npm points at a Windows install: %s'
  [npm.win.h1]='Same root cause as the previous item; fixing node normally fixes this too.'

  [path.count]='PATH has %s entries'
  [path.count_split]='PATH has %s entries (%s on the WSL side, %s on the Windows side)'
  [path.skip_interop]='Not a WSL environment, skipping Windows interop and cross-side resolution checks'
  [path.no_win]='PATH contains no Windows directories, so Windows commands cannot be called from WSL'
  [path.no_win.h1]='AI CLI login flows often need Windows to open a browser; with interop off, OAuth hangs.'
  [path.no_win.h2]='If /etc/wsl.conf sets appendWindowsPath=false, change it to true or remove the line:'
  [path.no_win.c2]='wsl --shutdown   # run in Windows PowerShell, then reopen'
  [path.too_many_win]='PATH contains %s Windows directories, which is a lot (recommended <= %s)'
  [path.too_many_win.h1]='Every Windows directory is searched across the 9p filesystem, slowing down command resolution and tab completion.'
  [path.too_many_win.h2]='Consider keeping only what you need: set appendWindowsPath=false in /etc/wsl.conf,'
  [path.too_many_win.h3]='then add back the few you actually use in ~/.bashrc (for example the directories holding cmd.exe and powershell.exe).'
  [path.interop_ok]='Windows interop paths look fine (%s entries)'
  [path.wintools_ok]='Windows commands are reachable from WSL (cmd.exe / powershell.exe)'
  [path.wintools_missing]='These Windows commands cannot be called from WSL: %s'
  [path.wintools_missing.h1]='OAuth login, opening a browser, and reading .wslconfig are all affected.'
  [path.wintools_missing.h2]='Check that [interop] enabled is not set to false in /etc/wsl.conf.'
  [path.shadow_ok]='Common dev commands all resolve to their WSL-side versions'
  [path.shadowed]='These commands resolve to the Windows version instead of the WSL one:'
  [path.shadowed.h1]='Cross-side execution causes path translation errors, permission problems and a performance hit.'
  [path.shadowed.h2]='Install the tools inside WSL and make sure WSL paths precede Windows paths in ~/.bashrc:'
  [path.shadowed.c2]='command -v -a node   # list every candidate and its priority'
  [path.empty]='PATH contains %s empty entries'
  [path.empty.h1]='An empty entry means the current directory, so the shell may execute a same-named file from your working directory. That is a security risk.'
  [path.empty.h2]='It usually comes from a stray colon in ~/.bashrc, such as PATH="$PATH:" or PATH=":$PATH".'
  [path.dup]='PATH has %s duplicate entries: %s'
  [path.dup.h1]='Usually ~/.bashrc or ~/.profile being sourced twice (for example export PATH placed in a block that re-runs).'
  [path.dup.h2]='Harmless for correctness, but it slows down lookups and makes PATH problems harder to debug.'
  [path.missing_dirs]='PATH has %s directories that do not exist: %s'
  [path.missing_dirs.h1]='Usually leftovers from removed tools. Cleaning them up avoids a wasted stat on every lookup.'
  [path.provisioned]='PATH references directories that do not exist yet: %s (an installed package manager creates them on demand, so this is not a problem)'
  [path.clean]='PATH is clean (no empty, duplicate or dead entries)'

  [npmg.no_npm]='npm not found, skipping global package checks'
  [npmg.no_npm.h1]='Fix the Node.js problems above first, then run this tool again.'
  [npmg.no_prefix]='Could not read the npm global prefix (npm config get prefix returned nothing)'
  [npmg.win_prefix]='The npm global prefix is on the Windows side: %s'
  [npmg.win_prefix.h1]='This is the number one cause of "npm install -g succeeded but the command is not found":'
  [npmg.win_prefix.h2]='  * packages land in Windows %%APPDATA%%\\npm as .cmd / .ps1 wrappers'
  [npmg.win_prefix.h3]='  * those wrappers are not executable Linux binaries under WSL bash'
  [npmg.win_prefix.h4]='  * even when they run, the Linux paths you pass them are meaningless on the Windows side'
  [npmg.win_prefix.h5]='Install a Linux build of Node.js inside WSL so the global prefix lands under $HOME:'
  [npmg.win_prefix.c3]='npm config get prefix   # should print a path starting with /home/...'
  [npmg.prefix]='npm global prefix: %s'
  [npmg.bin_missing]='The global bin directory does not exist: %s'
  [npmg.bin_missing.h1]='Normal if you have not installed any global package yet; otherwise the prefix is misconfigured.'
  [npmg.bin_in_path]='The global bin directory is in PATH: %s'
  [npmg.bin_not_in_path]='The global bin directory is not in PATH: %s'
  [npmg.bin_not_in_path.h1]='npm install -g will succeed, but every installed command reports "command not found". Add it to PATH:'
  [npmg.writable]='The global prefix is writable, so sudo is not needed to install'
  [npmg.not_writable]='The global prefix is not writable: %s'
  [npmg.not_writable.h1]='This forces sudo npm install -g, which leaves root-owned files behind,'
  [npmg.not_writable.h2]='so later npm update or uninstall can fail on permissions. Use a user-level prefix instead:'
  [npmg.none]='No global executables installed yet'
  [npmg.all_ok]='All %s global executables resolve correctly'
  [npmg.not_found]='These global executables are installed but cannot be found in the current shell: %s'
  [npmg.not_found.h1]='The classic "installed but no such command". %s is not in effect in the current PATH:'
  [npmg.not_found.c2]='hash -r   # clear the shell cache of command locations'
  [npmg.shadowed]='These global executables are shadowed by same-named commands elsewhere:'
  [npmg.shadowed.h1]='What you run is not the copy npm just installed, so versions may not match. Check the order:'
  [npmg.shadowed.c1]='command -v -a <command-name>'

  [net.skipped]='--skip-network given, skipping connectivity checks'
  [net.no_curl]='curl not found, cannot check connectivity'
  [net.proxy]='Proxy configuration detected: %s'
  [net.ok]='%s is reachable (HTTP %s)'
  [net.dns_fail]='%s failed DNS resolution'
  [net.tls_fail]='%s resolves via DNS, but the HTTPS connection failed (timeout %ss)'
  [net.diag]='Common causes of WSL network trouble, and what to do about them:'
  [net.diag.dns]='  Current DNS servers: %s'
  [net.diag.dns_none]='(none configured)'
  [net.diag.no_resolv]='  /etc/resolv.conf does not exist, so DNS cannot work at all.'
  [net.diag.gen1]='  1) resolv.conf is generated by WSL. If a corporate VPN or firewall interferes with DNS,'
  [net.diag.gen2]='     you can take it over (disable generation first, then write fixed DNS servers):'
  [net.diag.gen_c2]='wsl --shutdown   # run in PowerShell, reopen, then edit /etc/resolv.conf'
  [net.diag.mtu]='  2) On a VPN, the WSL MTU is often larger than the VPN interface, which stalls the TLS handshake:'
  [net.diag.cert]='  3) If a corporate firewall intercepts TLS, add the company root certificate to the WSL trust store:'
  [net.diag.global]='  4) First confirm whether everything is down, rather than only the API domains:'

  [wc.skip]='Not a WSL environment, there is no .wslconfig to check'
  [wc.no_winhome]='Could not locate the Windows user profile, skipping .wslconfig checks'
  [wc.no_winhome.h1]='Usually means Windows interop is disabled, or C: is not mounted at /mnt/c.'
  [wc.host]='Windows host: %s GB RAM / %s logical cores'
  [wc.current]='WSL currently has: %s GB RAM / %s cores'
  [wc.missing_small]='No .wslconfig found, and the host has limited memory (%s GB)'
  [wc.missing_small.h1]='WSL2 defaults to at most half of physical RAM; on a small machine, node plus an AI agent will hit OOM.'
  [wc.missing_small.h2]='Consider creating %s with explicit values (WSL reclaims memory automatically, so a higher limit is not a permanent reservation):'
  [wc.missing_ok]='No .wslconfig set, using WSL2 defaults (memory capped at roughly half of physical RAM)'
  [wc.missing_ok.info]='The defaults are fine for most machines; create %s if you need finer control.'
  [wc.path]='.wslconfig location: %s'
  [wc.mem_default]='memory not set, using the default (half of physical RAM)'
  [wc.mem_unparsable]='Could not parse the memory value: %s'
  [wc.mem_unparsable.h1]='It should look like memory=8GB or memory=8192MB. When malformed, WSL silently ignores the line and applies the default.'
  [wc.mem_low]='memory=%s is low (at least %sGB recommended)'
  [wc.mem_low.h1]='Node.js plus an AI agent file index and language servers use a lot of memory. Too little triggers'
  [wc.mem_low.h2]='the OOM killer, which shows up as an agent being killed mid-run with no warning. Suggested change:'
  [wc.mem_low.c1]='# edit %s, raise memory to %sGB or more, then run wsl --shutdown'
  [wc.mem_high]='memory=%s takes %s%% of host RAM (recommended at most %s%%)'
  [wc.mem_high.h1]='When Windows is left short of memory the whole machine starts paging, which slows WSL down too.'
  [wc.mem_high.h2]='Suggested ceiling: %sGB'
  [wc.mem_ok]='memory=%s (%sGB) is a reasonable allocation'
  [wc.cpu_default]='processors not set, using the default (all logical cores)'
  [wc.cpu_unparsable]='Could not parse the processors value: %s'
  [wc.cpu_unparsable.h1]='It should be a positive integer, for example processors=8.'
  [wc.cpu_low]='processors=%s is too low'
  [wc.cpu_low.h1]='npm install and the parallel file scanning of AI agents are noticeably slower on a single core. Use at least 2.'
  [wc.cpu_over]='processors=%s exceeds the host logical core count (%s)'
  [wc.cpu_over.h1]='The excess has no effect; WSL caps at the host core count.'
  [wc.cpu_full]='processors=%s uses every core; if Windows stutters during builds, leave 1-2 cores for the host.'
  [wc.cpu_ok]='processors=%s is a reasonable allocation'
  [wc.swap_zero]='swap=0 (disabled). Under memory pressure this triggers the OOM killer instead of slowing down.'
  [wc.swap]='swap=%s'
  [wc.restart]='Reminder: changes to .wslconfig require a WSL restart to take effect.'
  [wc.restart.c1]='wsl --shutdown   # run in Windows PowerShell'

  [sum.title]=' Summary (%s checks)'
  [sum.skip_note]='(not applicable here)'
  [sum.fail]='Status: needs fixing'
  [sum.fail.detail]=' — %s items will actively prevent AI CLI tools from working.'
  [sum.fail.action]=' Work through the [FAIL] items above, then run this tool again to confirm.'
  [sum.warn]='Status: usable'
  [sum.warn.detail]=' — nothing fatal, but %s items are worth adjusting.'
  [sum.warn.action]=' These mostly affect performance or stability rather than breaking things outright.'
  [sum.ok]='Status: healthy'
  [sum.ok.detail]=' — every check passed.'

  [ai.title]='🤖 Let an AI agent fix this'
  [ai.desc]='claude is installed on this machine, so you can hand the diagnosis straight to it:'
  [ai.prompt]='Run %s --json to get the environment diagnosis for this WSL machine. For every check whose status is fail or warn, explain the cause and help me fix it. Before touching any of my configuration files, tell me which file and which line you intend to change and wait for my confirmation.'

  [err.unknown_option]='ERROR: unknown option %s'
  [err.unknown_lang]='ERROR: unsupported language %s (available: zh-TW, en)'
  [err.lang_missing]='ERROR: --lang requires a language (zh-TW or en)'
)

# 從訊息目錄取字串並套用參數。缺少英文翻譯時回退到中文,避免輸出空白。
t() {
  local key="$1"; shift
  local fmt=""
  if [[ "$LANG_CODE" == "en" ]]; then
    fmt="${MSG_EN[$key]:-${MSG_ZH[$key]:-}}"
  else
    fmt="${MSG_ZH[$key]:-}"
  fi
  [[ -z "$fmt" ]] && { printf '<missing:%s>' "$key"; return; }
  # 必須加 --,否則以 - 開頭的訊息(例如 "--skip-network ...")會被 printf
  # 當成選項而整句消失。
  # shellcheck disable=SC2059  # 格式字串來自內部目錄,並非使用者輸入
  printf -- "$fmt" "$@"
}

# ---------------------------------------------------------------------------
# 結果集合
# ---------------------------------------------------------------------------

section_begin() {
  CURRENT_SECTION="$1"
}

# record <status> <id> <message> [--hint <文字>]... [--cmd <指令>]...
#
# status: pass | warn | fail | skip | info
# 檢查函式一律透過本函式回報,不直接輸出,輸出格式由 render_* 決定。
record() {
  local status="$1" id="$2" msg="$3"
  shift 3

  local hints="" cmds=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hint) hints+="${hints:+$US}$2"; shift 2 ;;
      --cmd)  cmds+="${cmds:+$US}$2";   shift 2 ;;
      *)      shift ;;
    esac
  done

  R_STATUS+=("$status")
  R_ID+=("$id")
  R_SECTION+=("$CURRENT_SECTION")
  R_MSG+=("$msg")
  R_HINTS+=("$hints")
  R_CMDS+=("$cmds")

  case "$status" in
    pass) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    warn) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    fail) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    skip) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    info) : ;;   # 中性資訊,不列入計分
  esac
}

# ---------------------------------------------------------------------------
# 共用工具函式
# ---------------------------------------------------------------------------

# 取得 kernel release 字串(WSL 會在其中標示 microsoft)
kernel_release() {
  cat /proc/sys/kernel/osrelease 2>/dev/null || uname -r 2>/dev/null || echo "unknown"
}

# 是否執行於 WSL 之中。三個獨立訊號任一成立即可,避免單一判斷失準:
#   1. kernel release 含 microsoft(WSL1/WSL2 皆有)
#   2. /run/WSL 存在(WSL 的 interop socket 目錄)
#   3. WSL_DISTRO_NAME 環境變數(由 WSL 注入)
is_wsl() {
  [[ "$(kernel_release)" =~ [Mm]icrosoft ]] && return 0
  [[ -e /run/WSL ]] && return 0
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  return 1
}

# 路徑是否位於 Windows 檔案系統(透過 /mnt 掛載)
is_win_path() {
  [[ "$1" == /mnt/[a-z]/* ]]
}

# 字串是否為 Windows 原生路徑(C:\...)
is_win_native_path() {
  [[ "$1" =~ ^[A-Za-z]:\\ ]]
}

# PATH 中不存在、但屬於已安裝套件管理器的目錄。
#
# 這類路徑是前瞻性的:套件管理器會在安裝第一個套件時自動建立它們,
# 並非「移除工具後沒清理的殘留」。對它們發警告會讓使用者去修一個
# 根本沒壞的東西 —— 例如 Ubuntu 預設就把 /snap/bin 寫進 /etc/environment,
# 只要還沒裝過任何 snap,該目錄就不存在。
is_provisioned_dir() {
  case "${1%/}" in
    /snap/bin) command -v snap >/dev/null 2>&1 && return 0 ;;
  esac
  return 1
}

# 該路徑元素是否已存在於 PATH 中
path_contains() {
  local needle="${1%/}" entry
  local IFS=':'
  for entry in $PATH; do
    [[ "${entry%/}" == "$needle" ]] && return 0
  done
  return 1
}

# 把 "8GB" / "8192MB" / "8G" / "8589934592" 轉成 MB(整數)
to_mb() {
  local raw unit num
  raw="$(printf '%s' "$1" | tr -d '[:space:]')"
  num="$(printf '%s' "$raw" | sed 's/[^0-9.].*$//')"
  unit="$(printf '%s' "$raw" | sed 's/^[0-9.]*//' | tr '[:upper:]' '[:lower:]')"
  [[ -z "$num" ]] && return 1

  case "$unit" in
    gb|g) awk -v n="$num" 'BEGIN{printf "%d", n*1024}' ;;
    mb|m) awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
    kb|k) awk -v n="$num" 'BEGIN{printf "%d", n/1024}' ;;
    b|"")  awk -v n="$num" 'BEGIN{printf "%d", (n > 1048576 ? n/1048576 : n)}' ;;
    *)    return 1 ;;
  esac
}

# 執行 Windows 端指令並取回單行輸出(去掉 CR)。失敗時回傳空字串。
win_query() {
  local out
  # 從 /mnt/c 執行,避免 cmd.exe 對 UNC 工作目錄發出警告
  out="$(cd /mnt/c 2>/dev/null && timeout 10 "$@" 2>/dev/null | tr -d '\r\n')" || return 1
  printf '%s' "$out"
}

# 取得「再執行一次本工具」的指令字串。
#
# 一般情況回傳腳本自身的路徑;若腳本是以管線方式執行(curl ... | bash),
# 檔案並不存在於磁碟上,$0 只會是 "bash",此時改回傳完整的下載指令,
# 讓提示中的指令實際可用。
self_invocation() {
  local self="${BASH_SOURCE[0]:-$0}"
  local dir

  if [[ -f "$self" ]]; then
    dir="$(cd "$(dirname "$self")" 2>/dev/null && pwd)"
    if [[ -n "$dir" ]]; then
      printf '%s/%s' "$dir" "$(basename "$self")"
    else
      printf '%s' "$self"
    fi
  else
    printf 'curl -fsSL %s | bash -s --' "$SELF_RAW_URL"
  fi
}

# 收集環境基本資訊(JSON 輸出用,也供檢查引用)
collect_environment() {
  ENV_KERNEL="$(kernel_release)"
  ENV_DISTRO="${WSL_DISTRO_NAME:-}"

  if [[ $NON_WSL -eq 1 ]]; then
    ENV_WSL_VERSION=""
  elif [[ "$ENV_KERNEL" == *"WSL2"* ]]; then
    ENV_WSL_VERSION="2"
  else
    ENV_WSL_VERSION="1"
  fi

  local pid1
  pid1="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')"
  [[ "$pid1" == "systemd" ]] && ENV_SYSTEMD="true" || ENV_SYSTEMD="false"
}

# ---------------------------------------------------------------------------
# 檢查 1:WSL 版本與設定
# ---------------------------------------------------------------------------

check_wsl() {
  section_begin wsl

  local osrelease="$ENV_KERNEL"

  # 非 WSL 環境(僅在 --allow-non-wsl 下會走到這裡):整段跳過,
  # 因為 WSL 版本、systemd 的 WSL 設定、/etc/wsl.conf 在此都不適用。
  if [[ $NON_WSL -eq 1 ]]; then
    record skip wsl.version "$(t wsl.skip "$osrelease")"
    return 0
  fi

  # --- WSL1 vs WSL2 ---
  if [[ "$osrelease" == *"WSL2"* ]]; then
    record pass wsl.version "$(t wsl.v2 "$osrelease")"
  else
    record fail wsl.version "$(t wsl.v1 "$osrelease")" \
      --hint "$(t wsl.v1.h1)" \
      --hint "$(t wsl.v1.h2)" \
      --cmd  "$(t wsl.v1.c1 "${WSL_DISTRO_NAME:-<distro>}")" \
      --cmd  "wsl --set-default-version 2"
  fi

  [[ -n "${WSL_DISTRO_NAME:-}" ]] && \
    record info wsl.distro "$(t wsl.distro "$WSL_DISTRO_NAME")"

  # --- systemd ---
  local pid1
  pid1="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')"

  if [[ "$pid1" == "systemd" ]]; then
    record pass wsl.systemd "$(t wsl.systemd_on)"
  else
    record warn wsl.systemd "$(t wsl.systemd_off "${pid1:-$(t wsl.unknown)}")" \
      --hint "$(t wsl.systemd.h1)" \
      --hint "$(t wsl.systemd.h2)" \
      --hint "$(t wsl.systemd.h3)" \
      --cmd  "printf '[boot]\\nsystemd=true\\n' | sudo tee -a /etc/wsl.conf" \
      --cmd  "$(t wsl.shutdown_cmd)"
  fi

  # --- /etc/wsl.conf ---
  if [[ -f /etc/wsl.conf ]]; then
    record info wsl.conf "$(t wsl.conf_exists)"
    if grep -qiE '^\s*appendWindowsPath\s*=\s*false' /etc/wsl.conf 2>/dev/null; then
      record info wsl.conf.append_windows_path "$(t wsl.conf_append_false)"
    fi
  else
    record info wsl.conf "$(t wsl.conf_missing)"
  fi
}

# ---------------------------------------------------------------------------
# 檢查 2:Node.js 版本
# ---------------------------------------------------------------------------

check_node() {
  section_begin node

  local node_path
  node_path="$(command -v node 2>/dev/null)"

  if [[ -z "$node_path" ]]; then
    # 提醒放在引導語之前:render 會先印完所有 hint 才印指令,
    # 以冒號結尾的引導語必須是最後一句,才能緊接著指令。
    record fail node.version "$(t node.missing)" \
      --hint "$(t node.missing.h2)" \
      --hint "$(t node.missing.h1)" \
      --cmd  "$NVM_INSTALL_CMD" \
      --cmd  'exec $SHELL -l' \
      --cmd  "nvm install --lts"
    return 1
  fi

  # --- 版本判定 ---
  local node_version major
  node_version="$(node -v 2>/dev/null | tr -d 'v\r')"

  if [[ -z "$node_version" ]]; then
    record fail node.version "$(t node.no_version "$node_path")" \
      --hint "$(t node.no_version.h1)" \
      --cmd  "command -v -a node"
    return 1
  fi

  major="${node_version%%.*}"

  if [[ ! "$major" =~ ^[0-9]+$ ]]; then
    record warn node.version "$(t node.unparsable "$node_version")"
  elif (( major < NODE_MIN_REQUIRED )); then
    record fail node.version "$(t node.too_old "$node_version" "$NODE_MIN_REQUIRED")" \
      --hint "$(t node.too_old.h1)" \
      --cmd  "nvm install --lts && nvm alias default lts/*"
  elif (( major < NODE_MIN_RECOMMENDED )); then
    record warn node.version "$(t node.below_rec "$node_version" "$NODE_MIN_RECOMMENDED")" \
      --hint "$(t node.below_rec.h1 "$NODE_MIN_RECOMMENDED")" \
      --cmd  "nvm install --lts && nvm alias default lts/*"
  else
    record pass node.version "$(t node.ok "$node_version" "$NODE_MIN_RECOMMENDED")"
  fi

  # --- 是不是誤用 Windows 版 Node ---
  if is_win_path "$node_path"; then
    record fail node.origin "$(t node.win "$node_path")" \
      --hint "$(t node.win.h1)" \
      --hint "$(t node.win.h2)" \
      --hint "$(t node.win.h3)" \
      --hint "$(t node.win.h4)" \
      --hint "$(t node.win.h5)" \
      --cmd  "$NVM_INSTALL_CMD" \
      --cmd  'exec $SHELL -l && nvm install --lts'
  elif [[ $NON_WSL -eq 1 ]]; then
    record pass node.origin "$(t node.native "$node_path")"
  else
    record pass node.origin "$(t node.wsl "$node_path")"
  fi

  # --- npm 是否存在,且與 node 來自同一側 ---
  local npm_path npm_version
  npm_path="$(command -v npm 2>/dev/null)"

  if [[ -z "$npm_path" ]]; then
    record fail npm.origin "$(t npm.missing)" \
      --hint "$(t npm.missing.h1)" \
      --cmd  "$(t npm.missing.c1)"
  elif is_win_path "$npm_path" && ! is_win_path "$node_path"; then
    record fail npm.origin "$(t npm.mixed "$npm_path")" \
      --hint "$(t npm.mixed.h1)" \
      --hint "$(t npm.mixed.h2)"
  elif ! is_win_path "$npm_path"; then
    npm_version="$(npm -v 2>/dev/null | tr -d '\r')"
    if [[ $NON_WSL -eq 1 ]]; then
      record pass npm.origin "$(t npm.native "$npm_path" "$npm_version")"
    else
      record pass npm.origin "$(t npm.wsl "$npm_path" "$npm_version")"
    fi
  else
    record warn npm.origin "$(t npm.win "$npm_path")" \
      --hint "$(t npm.win.h1)"
  fi
}

# ---------------------------------------------------------------------------
# 檢查 3:PATH 正確性(Windows / WSL 互相抓不到指令)
# ---------------------------------------------------------------------------

check_path() {
  section_begin path

  local -a entries=()
  local IFS=':'
  read -r -a entries <<< "$PATH"
  unset IFS

  local win_count=0 linux_count=0
  local -a empty_entries=() missing_dirs=() dup_entries=() seen=() provisioned=()
  local entry norm

  for entry in "${entries[@]}"; do
    if [[ -z "$entry" ]]; then
      empty_entries+=("(empty)")
      continue
    fi

    norm="${entry%/}"

    # 重複偵測
    local s found=0
    for s in ${seen[@]+"${seen[@]}"}; do
      [[ "$s" == "$norm" ]] && { found=1; break; }
    done
    if [[ $found -eq 1 ]]; then
      dup_entries+=("$norm")
    else
      seen+=("$norm")
    fi

    if is_win_path "$entry"; then
      win_count=$((win_count + 1))
    else
      linux_count=$((linux_count + 1))
      if [[ ! -d "$entry" ]]; then
        if is_provisioned_dir "$entry"; then
          provisioned+=("$entry")
        else
          missing_dirs+=("$entry")
        fi
      fi
    fi
  done

  if [[ $NON_WSL -eq 1 ]]; then
    record info path.summary "$(t path.count "${#entries[@]}")"
  else
    record info path.summary "$(t path.count_split "${#entries[@]}" "$linux_count" "$win_count")"
  fi

  # 以下三項都在檢查 WSL 與 Windows 之間的互通性,非 WSL 環境不適用。
  if [[ $NON_WSL -eq 1 ]]; then
    record skip path.interop "$(t path.skip_interop)"
  else
    # --- Windows interop 是否生效 ---
    if [[ $win_count -eq 0 ]]; then
      record warn path.interop "$(t path.no_win)" \
        --hint "$(t path.no_win.h1)" \
        --hint "$(t path.no_win.h2)" \
        --cmd  "sudo sed -i 's/appendWindowsPath *= *false/appendWindowsPath=true/' /etc/wsl.conf" \
        --cmd  "$(t path.no_win.c2)"
    elif [[ $win_count -gt $PATH_WIN_ENTRY_WARN ]]; then
      record warn path.interop "$(t path.too_many_win "$win_count" "$PATH_WIN_ENTRY_WARN")" \
        --hint "$(t path.too_many_win.h1)" \
        --hint "$(t path.too_many_win.h2)" \
        --hint "$(t path.too_many_win.h3)"
    else
      record pass path.interop "$(t path.interop_ok "$win_count")"
    fi

    # --- 從 WSL 呼叫 Windows 指令 ---
    local -a win_tools=(cmd.exe powershell.exe)
    local -a win_missing=()
    local wt
    for wt in "${win_tools[@]}"; do
      command -v "$wt" >/dev/null 2>&1 || win_missing+=("$wt")
    done

    if [[ ${#win_missing[@]} -eq 0 ]]; then
      record pass path.win_tools "$(t path.wintools_ok)"
    else
      record warn path.win_tools "$(t path.wintools_missing "${win_missing[*]}")" \
        --hint "$(t path.wintools_missing.h1)" \
        --hint "$(t path.wintools_missing.h2)"
    fi

    # --- 反向:WSL 指令被 Windows 版本蓋掉 ---
    # code / explorer.exe 這類本來就該用 Windows 版的不列入檢查。
    local -a shadow_targets=(node npm npx git python3 pip3)
    local -a shadowed=()
    local tool resolved
    for tool in "${shadow_targets[@]}"; do
      resolved="$(command -v "$tool" 2>/dev/null)" || continue
      [[ -n "$resolved" ]] && is_win_path "$resolved" && shadowed+=("$tool -> $resolved")
    done

    if [[ ${#shadowed[@]} -eq 0 ]]; then
      record pass path.shadowing "$(t path.shadow_ok)"
    else
      local -a shadow_args=()
      for tool in "${shadowed[@]}"; do
        shadow_args+=(--hint "$tool")
      done
      record fail path.shadowing "$(t path.shadowed)" \
        "${shadow_args[@]}" \
        --hint "$(t path.shadowed.h1)" \
        --hint "$(t path.shadowed.h2)" \
        --cmd  'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"' \
        --cmd  "$(t path.shadowed.c2)"
    fi
  fi

  # --- PATH 衛生檢查(與 WSL 無關,任何環境都適用) ---
  if [[ ${#empty_entries[@]} -gt 0 ]]; then
    record warn path.hygiene.empty "$(t path.empty "${#empty_entries[@]}")" \
      --hint "$(t path.empty.h1)" \
      --hint "$(t path.empty.h2)"
  fi

  if [[ ${#dup_entries[@]} -gt 0 ]]; then
    record warn path.hygiene.duplicates "$(t path.dup "${#dup_entries[@]}" "${dup_entries[*]}")" \
      --hint "$(t path.dup.h1)" \
      --hint "$(t path.dup.h2)"
  fi

  if [[ ${#missing_dirs[@]} -gt 0 ]]; then
    record warn path.hygiene.missing_dirs "$(t path.missing_dirs "${#missing_dirs[@]}" "${missing_dirs[*]}")" \
      --hint "$(t path.missing_dirs.h1)"
  fi

  # 尚未建立、但由已安裝的套件管理器負責建立的目錄:說明為何不視為問題,
  # 免得使用者看到 PASS 卻自己發現路徑不存在而困惑。
  if [[ ${#provisioned[@]} -gt 0 ]]; then
    record info path.hygiene.provisioned "$(t path.provisioned "${provisioned[*]}")"
  fi

  if [[ ${#empty_entries[@]} -eq 0 && ${#dup_entries[@]} -eq 0 && ${#missing_dirs[@]} -eq 0 ]]; then
    record pass path.hygiene "$(t path.clean)"
  fi
}

# ---------------------------------------------------------------------------
# 檢查 4:npm 全域執行檔是否真的在 PATH 裡
# ---------------------------------------------------------------------------

check_npm_global() {
  section_begin npm

  if ! command -v npm >/dev/null 2>&1; then
    record fail npm.global "$(t npmg.no_npm)" \
      --hint "$(t npmg.no_npm.h1)"
    return 1
  fi

  local prefix
  prefix="$(npm config get prefix 2>/dev/null | tr -d '\r')"

  if [[ -z "$prefix" || "$prefix" == "undefined" ]]; then
    record fail npm.prefix "$(t npmg.no_prefix)"
    return 1
  fi

  # --- 前綴落在 Windows 端 ---
  if is_win_native_path "$prefix" || is_win_path "$prefix"; then
    record fail npm.prefix_location "$(t npmg.win_prefix "$prefix")" \
      --hint "$(t npmg.win_prefix.h1)" \
      --hint "$(t npmg.win_prefix.h2)" \
      --hint "$(t npmg.win_prefix.h3)" \
      --hint "$(t npmg.win_prefix.h4)" \
      --hint "$(t npmg.win_prefix.h5)" \
      --cmd  "$NVM_INSTALL_CMD" \
      --cmd  'exec $SHELL -l && nvm install --lts' \
      --cmd  "$(t npmg.win_prefix.c3)"
    return 1
  fi

  record info npm.prefix "$(t npmg.prefix "$prefix")"

  local global_bin="$prefix/bin"

  if [[ ! -d "$global_bin" ]]; then
    record warn npm.bin_dir "$(t npmg.bin_missing "$global_bin")" \
      --hint "$(t npmg.bin_missing.h1)"
    return 0
  fi

  # --- 全域 bin 目錄有沒有在 PATH 裡 ---
  if path_contains "$global_bin"; then
    record pass npm.bin_in_path "$(t npmg.bin_in_path "$global_bin")"
  else
    record fail npm.bin_in_path "$(t npmg.bin_not_in_path "$global_bin")" \
      --hint "$(t npmg.bin_not_in_path.h1)" \
      --cmd  "echo 'export PATH=\"$global_bin:\$PATH\"' >> ~/.bashrc" \
      --cmd  "source ~/.bashrc"
  fi

  # --- 前綴目錄是否可寫(避免被迫 sudo npm -g) ---
  if [[ -w "$prefix" ]]; then
    record pass npm.prefix_writable "$(t npmg.writable)"
  else
    record warn npm.prefix_writable "$(t npmg.not_writable "$prefix")" \
      --hint "$(t npmg.not_writable.h1)" \
      --hint "$(t npmg.not_writable.h2)" \
      --cmd  "mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global" \
      --cmd  'echo '"'"'export PATH="$HOME/.npm-global/bin:$PATH"'"'"' >> ~/.bashrc && source ~/.bashrc'
  fi

  # --- 逐一比對:已安裝的執行檔是否真的叫得出來 ---
  local -a not_found=() shadowed=()
  local f name resolved count=0

  for f in "$global_bin"/*; do
    [[ -e "$f" ]] || continue          # 目錄為空時 glob 不展開
    [[ -x "$f" ]] || continue
    name="$(basename "$f")"
    count=$((count + 1))

    resolved="$(command -v "$name" 2>/dev/null)"
    if [[ -z "$resolved" ]]; then
      not_found+=("$name")
    elif [[ "$(readlink -f "$resolved" 2>/dev/null)" != "$(readlink -f "$f" 2>/dev/null)" ]]; then
      shadowed+=("$name -> $resolved")
    fi
  done

  if [[ $count -eq 0 ]]; then
    record info npm.executables "$(t npmg.none)"
    return 0
  fi

  if [[ ${#not_found[@]} -eq 0 && ${#shadowed[@]} -eq 0 ]]; then
    record pass npm.executables "$(t npmg.all_ok "$count")"
    return 0
  fi

  if [[ ${#not_found[@]} -gt 0 ]]; then
    record fail npm.executables "$(t npmg.not_found "${not_found[*]}")" \
      --hint "$(t npmg.not_found.h1 "$global_bin")" \
      --cmd  "echo 'export PATH=\"$global_bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" \
      --cmd  "$(t npmg.not_found.c2)"
  fi

  if [[ ${#shadowed[@]} -gt 0 ]]; then
    local -a shadow_args=()
    for name in "${shadowed[@]}"; do
      shadow_args+=(--hint "$name")
    done
    record warn npm.executables_shadowed "$(t npmg.shadowed)" \
      "${shadow_args[@]}" \
      --hint "$(t npmg.shadowed.h1)" \
      --cmd  "$(t npmg.shadowed.c1)"
  fi
}

# ---------------------------------------------------------------------------
# 檢查 5:對外網路連線
# ---------------------------------------------------------------------------

check_network() {
  section_begin net

  if [[ $SKIP_NETWORK -eq 1 ]]; then
    record info net.status "$(t net.skipped)"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    record fail net.status "$(t net.no_curl)" \
      --cmd "sudo apt update && sudo apt install -y curl"
    return 1
  fi

  # --- Proxy 設定(常見的連線異常來源) ---
  local proxy_value="${HTTPS_PROXY:-${https_proxy:-}}"
  [[ -n "$proxy_value" ]] && \
    record info net.proxy "$(t net.proxy "HTTPS_PROXY=$proxy_value")"

  local ep host code dns_ok
  local net_failed=0

  for ep in "${NET_ENDPOINTS[@]}"; do
    host="${ep#https://}"; host="${host%%/*}"

    # DNS 先行,才能區分「解析失敗」與「連得到但被擋」
    dns_ok=1
    getent hosts "$host" >/dev/null 2>&1 || dns_ok=0

    # 對 API 根路徑而言,401/403/404 都代表「連線成功」——有回應就是通了。
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
              --max-time "$NET_TIMEOUT" "$ep" 2>/dev/null)" || code="000"

    if [[ "$code" != "000" && -n "$code" ]]; then
      record pass "net.endpoint.$host" "$(t net.ok "$host" "$code")"
    elif [[ $dns_ok -eq 0 ]]; then
      record fail "net.endpoint.$host" "$(t net.dns_fail "$host")"
      net_failed=1
    else
      record fail "net.endpoint.$host" "$(t net.tls_fail "$host" "$NET_TIMEOUT")"
      net_failed=1
    fi
  done

  [[ $net_failed -eq 0 ]] && return 0

  # --- 連線失敗時,才輸出診斷資訊 ---
  local -a diag=()
  diag+=(--hint "$(t net.diag)")

  if [[ -f /etc/resolv.conf ]]; then
    local ns
    ns="$(grep -E '^\s*nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)"
    diag+=(--hint "$(t net.diag.dns "${ns:-$(t net.diag.dns_none)}")")

    if grep -qi 'generated by WSL' /etc/resolv.conf 2>/dev/null; then
      diag+=(--hint "$(t net.diag.gen1)")
      diag+=(--hint "$(t net.diag.gen2)")
      diag+=(--cmd  "printf '[network]\\ngenerateResolvConf=false\\n' | sudo tee -a /etc/wsl.conf")
      diag+=(--cmd  "$(t net.diag.gen_c2)")
      diag+=(--cmd  "printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n' | sudo tee /etc/resolv.conf")
    fi
  else
    diag+=(--hint "$(t net.diag.no_resolv)")
  fi

  diag+=(--hint "$(t net.diag.mtu)")
  diag+=(--cmd  "sudo ip link set dev eth0 mtu 1350")
  diag+=(--hint "$(t net.diag.cert)")
  diag+=(--cmd  "sudo cp company-root.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates")
  diag+=(--hint "$(t net.diag.global)")
  diag+=(--cmd  "curl -sS -o /dev/null -w '%{http_code}\\n' --max-time 8 https://example.com")

  record info net.diagnostics "" "${diag[@]}"
}

# ---------------------------------------------------------------------------
# 檢查 6:.wslconfig 資源配置
# ---------------------------------------------------------------------------

check_wslconfig() {
  section_begin wslconf

  if [[ $NON_WSL -eq 1 ]]; then
    record skip wslconf.file "$(t wc.skip)"
    return 0
  fi

  # --- 找出 Windows 使用者家目錄 ---
  local win_home_raw win_home=""
  if [[ -n "${WSL_AI_DOCTOR_WSLCONFIG:-}" ]]; then
    win_home="$(dirname "$WSL_AI_DOCTOR_WSLCONFIG")"
  elif command -v cmd.exe >/dev/null 2>&1; then
    win_home_raw="$(win_query cmd.exe /c "echo %USERPROFILE%")"
    if [[ -n "$win_home_raw" ]] && command -v wslpath >/dev/null 2>&1; then
      win_home="$(wslpath -u "$win_home_raw" 2>/dev/null)"
    fi
  fi

  # 退而求其次:直接掃 /mnt/c/Users(cmd.exe 不可用或 interop 關閉時)
  if [[ -z "$win_home" || ! -d "$win_home" ]]; then
    local candidate
    for candidate in /mnt/c/Users/*/; do
      [[ -f "${candidate}.wslconfig" ]] && { win_home="${candidate%/}"; break; }
    done
  fi

  if [[ -z "$win_home" || ! -d "$win_home" ]]; then
    record warn wslconf.file "$(t wc.no_winhome)" \
      --hint "$(t wc.no_winhome.h1)"
    return 1
  fi

  # 允許以環境變數指定 .wslconfig 路徑(便於測試,或供路徑非標準的環境使用)
  local wslconfig="${WSL_AI_DOCTOR_WSLCONFIG:-$win_home/.wslconfig}"

  # --- 取得主機實體資源(用於判斷配置是否合理) ---
  local host_mem_mb=0 host_cpus=0
  if command -v powershell.exe >/dev/null 2>&1; then
    local raw_mem raw_cpu
    raw_mem="$(win_query powershell.exe -NoProfile -NonInteractive -Command \
                "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory")"
    raw_cpu="$(win_query powershell.exe -NoProfile -NonInteractive -Command \
                "(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors")"
    [[ "$raw_mem" =~ ^[0-9]+$ ]] && host_mem_mb=$((raw_mem / 1024 / 1024))
    [[ "$raw_cpu" =~ ^[0-9]+$ ]] && host_cpus="$raw_cpu"
  fi

  local wsl_mem_mb wsl_cpus
  wsl_mem_mb="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
  wsl_cpus="$(nproc 2>/dev/null || echo 0)"
  [[ "$wsl_mem_mb" =~ ^[0-9]+$ ]] || wsl_mem_mb=0
  [[ "$wsl_cpus"   =~ ^[0-9]+$ ]] || wsl_cpus=0

  [[ $host_mem_mb -gt 0 ]] && \
    record info wslconf.host "$(t wc.host "$((host_mem_mb / 1024))" "$host_cpus")"
  record info wslconf.current "$(t wc.current "$((wsl_mem_mb / 1024))" "$wsl_cpus")"

  # --- .wslconfig 不存在:WSL2 預設值 ---
  if [[ ! -f "$wslconfig" ]]; then
    if [[ $host_mem_mb -gt 0 && $((host_mem_mb / 1024)) -lt $((WSLCONF_MEM_MIN_GB * 2)) ]]; then
      record warn wslconf.file "$(t wc.missing_small "$((host_mem_mb / 1024))")" \
        --hint "$(t wc.missing_small.h1)" \
        --hint "$(t wc.missing_small.h2 "$wslconfig")" \
        --cmd  "printf '[wsl2]\\nmemory=${WSLCONF_MEM_MIN_GB}GB\\nprocessors=$((wsl_cpus > 2 ? wsl_cpus / 2 : 1))\\n' > '$wslconfig'"
    else
      record pass wslconf.file "$(t wc.missing_ok)"
      record info wslconf.file.location "$(t wc.missing_ok.info "$wslconfig")"
    fi
    return 0
  fi

  record info wslconf.file "$(t wc.path "$wslconfig")"

  # --- 解析 [wsl2] 區段 ---
  local mem_raw cpu_raw swap_raw
  mem_raw="$(grep -iE '^\s*memory\s*=' "$wslconfig" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]\r')"
  cpu_raw="$(grep -iE '^\s*processors\s*=' "$wslconfig" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]\r')"
  swap_raw="$(grep -iE '^\s*swap\s*=' "$wslconfig" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]\r')"

  # --- 記憶體 ---
  if [[ -z "$mem_raw" ]]; then
    record pass wslconf.memory "$(t wc.mem_default)"
  else
    local mem_mb
    mem_mb="$(to_mb "$mem_raw")" || mem_mb=""

    if [[ -z "$mem_mb" || ! "$mem_mb" =~ ^[0-9]+$ ]]; then
      record warn wslconf.memory "$(t wc.mem_unparsable "$mem_raw")" \
        --hint "$(t wc.mem_unparsable.h1)"
    else
      local mem_gb=$((mem_mb / 1024))
      if (( mem_mb < WSLCONF_MEM_MIN_GB * 1024 )); then
        record warn wslconf.memory "$(t wc.mem_low "$mem_raw" "$WSLCONF_MEM_MIN_GB")" \
          --hint "$(t wc.mem_low.h1)" \
          --hint "$(t wc.mem_low.h2)" \
          --cmd  "$(t wc.mem_low.c1 "$wslconfig" "$WSLCONF_MEM_MIN_GB")"
      elif [[ $host_mem_mb -gt 0 ]] && (( mem_mb * 100 / host_mem_mb > WSLCONF_MEM_MAX_PCT )); then
        record warn wslconf.memory \
          "$(t wc.mem_high "$mem_raw" "$((mem_mb * 100 / host_mem_mb))" "$WSLCONF_MEM_MAX_PCT")" \
          --hint "$(t wc.mem_high.h1)" \
          --hint "$(t wc.mem_high.h2 "$((host_mem_mb * WSLCONF_MEM_MAX_PCT / 100 / 1024))")"
      else
        record pass wslconf.memory "$(t wc.mem_ok "$mem_raw" "$mem_gb")"
      fi
    fi
  fi

  # --- CPU ---
  if [[ -z "$cpu_raw" ]]; then
    record pass wslconf.processors "$(t wc.cpu_default)"
  elif [[ ! "$cpu_raw" =~ ^[0-9]+$ ]]; then
    record warn wslconf.processors "$(t wc.cpu_unparsable "$cpu_raw")" \
      --hint "$(t wc.cpu_unparsable.h1)"
  else
    if (( cpu_raw < 2 )); then
      record warn wslconf.processors "$(t wc.cpu_low "$cpu_raw")" \
        --hint "$(t wc.cpu_low.h1)"
    elif [[ $host_cpus -gt 0 ]] && (( cpu_raw > host_cpus )); then
      record warn wslconf.processors "$(t wc.cpu_over "$cpu_raw" "$host_cpus")" \
        --hint "$(t wc.cpu_over.h1)"
    elif [[ $host_cpus -gt 0 ]] && (( cpu_raw == host_cpus )); then
      record info wslconf.processors.note "$(t wc.cpu_full "$cpu_raw")"
      record pass wslconf.processors "$(t wc.cpu_ok "$cpu_raw")"
    else
      record pass wslconf.processors "$(t wc.cpu_ok "$cpu_raw")"
    fi
  fi

  # --- Swap ---
  if [[ "$swap_raw" == "0" ]]; then
    record info wslconf.swap "$(t wc.swap_zero)"
  elif [[ -n "$swap_raw" ]]; then
    record info wslconf.swap "$(t wc.swap "$swap_raw")"
  fi

  record info wslconf.restart "" \
    --hint "$(t wc.restart)" \
    --cmd  "$(t wc.restart.c1)"
}

# ---------------------------------------------------------------------------
# 輸出層:文字
# ---------------------------------------------------------------------------

setup_colors() {
  local enabled=0
  case "$USE_COLOR" in
    always) enabled=1 ;;
    never)  enabled=0 ;;
    auto)   [[ -t 1 && -z "${NO_COLOR:-}" ]] && enabled=1 ;;
  esac

  if [[ $enabled -eq 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
  else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED="";   C_GREEN=""; C_YELLOW=""
    C_BLUE="";  C_CYAN=""
  fi
}

status_color() {
  case "$1" in
    pass) printf '%s' "$C_GREEN"  ;;
    warn) printf '%s' "$C_YELLOW" ;;
    fail) printf '%s' "$C_RED"    ;;
    skip) printf '%s' "$C_DIM"    ;;
    *)    printf '%s' "$C_CYAN"   ;;
  esac
}

render_text() {
  local i last_section="" color label
  local -a parts=()

  for i in "${!R_STATUS[@]}"; do
    if [[ "${R_SECTION[$i]}" != "$last_section" ]]; then
      last_section="${R_SECTION[$i]}"
      printf '\n%s%s▸ %s%s\n' "$C_BOLD" "$C_BLUE" "$(t "sec.$last_section")" "$C_RESET"
    fi

    # 訊息為空的記錄僅承載建議與指令(例如網路診斷區塊)
    if [[ -n "${R_MSG[$i]}" ]]; then
      color="$(status_color "${R_STATUS[$i]}")"
      label="$(printf '%s' "${R_STATUS[$i]}" | tr '[:lower:]' '[:upper:]')"
      printf '  %s[%s]%s %s\n' "$color" "$label" "$C_RESET" "${R_MSG[$i]}"
    fi

    if [[ -n "${R_HINTS[$i]}" ]]; then
      IFS="$US" read -r -a parts <<< "${R_HINTS[$i]}"
      local h
      for h in "${parts[@]}"; do
        printf '         %s↳ %s%s\n' "$C_DIM" "$h" "$C_RESET"
      done
    fi

    if [[ -n "${R_CMDS[$i]}" ]]; then
      IFS="$US" read -r -a parts <<< "${R_CMDS[$i]}"
      local c
      for c in "${parts[@]}"; do
        printf '           %s$ %s%s\n' "$C_CYAN" "$c" "$C_RESET"
      done
    fi
  done
}

render_summary() {
  local total=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT + SKIP_COUNT))
  local bar="════════════════════════════════════════════"

  printf '\n%s%s\n' "$C_BOLD" "$bar"
  printf '%s%s\n\n' "$(t sum.title "$total")" "$C_RESET"
  printf '   %s● PASS%s  %3d\n' "$C_GREEN"  "$C_RESET" "$PASS_COUNT"
  printf '   %s● WARN%s  %3d\n' "$C_YELLOW" "$C_RESET" "$WARN_COUNT"
  printf '   %s● FAIL%s  %3d\n' "$C_RED"    "$C_RESET" "$FAIL_COUNT"
  [[ $SKIP_COUNT -gt 0 ]] && \
    printf '   %s● SKIP%s  %3d  %s%s%s\n' \
      "$C_DIM" "$C_RESET" "$SKIP_COUNT" "$C_DIM" "$(t sum.skip_note)" "$C_RESET"
  printf '\n'

  if [[ $FAIL_COUNT -gt 0 ]]; then
    printf ' %s%s%s%s%s\n' "$C_BOLD" "$C_RED" "$(t sum.fail)" "$C_RESET" \
      "$(t sum.fail.detail "$FAIL_COUNT")"
    printf '%s\n' "$(t sum.fail.action)"
  elif [[ $WARN_COUNT -gt 0 ]]; then
    printf ' %s%s%s%s%s\n' "$C_BOLD" "$C_YELLOW" "$(t sum.warn)" "$C_RESET" \
      "$(t sum.warn.detail "$WARN_COUNT")"
    printf '%s\n' "$(t sum.warn.action)"
  else
    printf ' %s%s%s%s%s\n' "$C_BOLD" "$C_GREEN" "$(t sum.ok)" "$C_RESET" \
      "$(t sum.ok.detail)"
  fi

  printf '%s%s%s\n' "$C_BOLD" "$bar" "$C_RESET"
}

# 有 WARN/FAIL 且本機裝有 claude 時,提供一行可直接複製的指令,
# 把 --json 診斷結果交給 AI agent 逐項修復。
#
# 只在文字模式輸出:--json 的結果必須保持純淨,任何額外內容都會讓
# 下游的解析器失敗。全部通過時也不印,沒有東西要修就不該多這一段。
render_ai_hint() {
  [[ "$OUTPUT_FORMAT" == "json" ]] && return 0
  [[ $((WARN_COUNT + FAIL_COUNT)) -eq 0 ]] && return 0
  command -v claude >/dev/null 2>&1 || return 0

  local invocation prompt
  invocation="$(self_invocation)"
  prompt="$(t ai.prompt "$invocation")"

  printf '\n%s%s%s%s\n' "$C_BOLD" "$C_CYAN" "$(t ai.title)" "$C_RESET"
  printf '   %s%s%s\n' "$C_DIM" "$(t ai.desc)" "$C_RESET"
  printf '   %s$ claude "%s"%s\n' "$C_CYAN" "$prompt" "$C_RESET"
}

# ---------------------------------------------------------------------------
# 輸出層:JSON
# ---------------------------------------------------------------------------

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# 把 US 分隔的字串轉成 JSON 陣列
json_array_from_us() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf '[]'
    return
  fi
  local -a parts=()
  IFS="$US" read -r -a parts <<< "$raw"
  local out="[" first=1 p
  for p in "${parts[@]}"; do
    [[ $first -eq 1 ]] && first=0 || out+=", "
    out+="\"$(json_escape "$p")\""
  done
  out+="]"
  printf '%s' "$out"
}

health_status() {
  if [[ $NON_WSL -eq 1 && $ALLOW_NON_WSL -eq 0 ]]; then
    printf 'not_applicable'
  elif [[ $FAIL_COUNT -gt 0 ]]; then
    printf 'needs_fix'
  elif [[ $WARN_COUNT -gt 0 ]]; then
    printf 'usable'
  else
    printf 'healthy'
  fi
}

render_json() {
  local exit_code="$1"
  local i first=1

  printf '{\n'
  printf '  "tool": "wsl-ai-doctor",\n'
  printf '  "version": "%s",\n' "$VERSION"
  printf '  "generated_at": "%s",\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '  "lang": "%s",\n' "$LANG_CODE"
  printf '  "environment": {\n'
  printf '    "is_wsl": %s,\n' "$([[ $NON_WSL -eq 1 ]] && echo false || echo true)"
  if [[ -n "$ENV_WSL_VERSION" ]]; then
    printf '    "wsl_version": %s,\n' "$ENV_WSL_VERSION"
  else
    printf '    "wsl_version": null,\n'
  fi
  printf '    "kernel": "%s",\n' "$(json_escape "$ENV_KERNEL")"
  if [[ -n "$ENV_DISTRO" ]]; then
    printf '    "distro": "%s",\n' "$(json_escape "$ENV_DISTRO")"
  else
    printf '    "distro": null,\n'
  fi
  printf '    "systemd": %s\n' "$ENV_SYSTEMD"
  printf '  },\n'
  printf '  "summary": {\n'
  printf '    "pass": %d,\n' "$PASS_COUNT"
  printf '    "warn": %d,\n' "$WARN_COUNT"
  printf '    "fail": %d,\n' "$FAIL_COUNT"
  printf '    "skip": %d,\n' "$SKIP_COUNT"
  printf '    "total": %d,\n' "$((PASS_COUNT + WARN_COUNT + FAIL_COUNT + SKIP_COUNT))"
  printf '    "health": "%s"\n' "$(health_status)"
  printf '  },\n'
  printf '  "exit_code": %d,\n' "$exit_code"
  printf '  "checks": [\n'

  for i in "${!R_STATUS[@]}"; do
    # 只承載提示的記錄(訊息為空)在 JSON 中沒有意義,略過
    [[ -z "${R_MSG[$i]}" && "${R_STATUS[$i]}" == "info" ]] && continue

    [[ $first -eq 1 ]] && first=0 || printf ',\n'
    printf '    {\n'
    printf '      "id": "%s",\n'       "$(json_escape "${R_ID[$i]}")"
    printf '      "section": "%s",\n'  "$(json_escape "${R_SECTION[$i]}")"
    printf '      "status": "%s",\n'   "${R_STATUS[$i]}"
    printf '      "message": "%s",\n'  "$(json_escape "${R_MSG[$i]}")"
    printf '      "hints": %s,\n'      "$(json_array_from_us "${R_HINTS[$i]}")"
    printf '      "commands": %s\n'    "$(json_array_from_us "${R_CMDS[$i]}")"
    printf '    }'
  done

  [[ $first -eq 0 ]] && printf '\n'
  printf '  ]\n'
  printf '}\n'
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
  if [[ "$LANG_CODE" == "en" ]]; then
    cat <<EOF
wsl-ai-doctor v$VERSION — health check for WSL environments running AI CLIs

Usage:
  ./wsl-ai-doctor.sh [options]

Options:
  -h, --help          Show this help
  -v, --version       Show version
      --no-color      Disable colored output (for files or CI)
      --color         Force colored output, even when not a terminal
      --json          Machine-readable JSON output (implies --no-color)
      --lang <code>   Diagnostic language: zh-TW (default) or en
      --skip-network  Skip the connectivity check (offline environments)
      --allow-non-wsl Run outside WSL too; WSL checks are marked SKIP (for CI)

Exit codes:
  0   Everything passed
  1   Warnings, no failures
  2   At least one failure
  3   Not running inside WSL; no checks were run
  64  Invalid command-line usage

Environment variables:
  WSL_AI_DOCTOR_LANG               Default language (zh-TW or en)
  WSL_AI_DOCTOR_NODE_MIN           Minimum Node.js version (default $NODE_MIN_REQUIRED)
  WSL_AI_DOCTOR_NODE_RECOMMENDED   Recommended Node.js version (default $NODE_MIN_RECOMMENDED)
  WSL_AI_DOCTOR_NET_TIMEOUT        Connectivity timeout in seconds (default $NET_TIMEOUT)
  WSL_AI_DOCTOR_MEM_MIN_GB         .wslconfig memory floor in GB (default $WSLCONF_MEM_MIN_GB)
  WSL_AI_DOCTOR_MEM_MAX_PCT        .wslconfig memory ceiling as %% of host RAM (default $WSLCONF_MEM_MAX_PCT)
  WSL_AI_DOCTOR_PATH_WIN_WARN      Threshold for Windows entries in PATH (default $PATH_WIN_ENTRY_WARN)
  WSL_AI_DOCTOR_WSLCONFIG          Explicit path to .wslconfig
  NO_COLOR                         Set to disable colored output
EOF
  else
    cat <<EOF
wsl-ai-doctor v$VERSION — WSL 環境健康檢查工具

用法:
  ./wsl-ai-doctor.sh [選項]

選項:
  -h, --help          顯示本說明
  -v, --version       顯示版本
      --no-color      停用彩色輸出(輸出到檔案或 CI 時使用)
      --color         強制啟用彩色輸出(即使不是終端機)
      --json          輸出機器可讀的 JSON(自動停用顏色)
      --lang <代碼>   診斷訊息語言:zh-TW(預設)或 en
      --skip-network  略過對外連線檢查(離線環境使用)
      --allow-non-wsl 非 WSL 環境也執行,WSL 相關檢查標記為 SKIP(CI 用)

離開代碼:
  0   全部通過
  1   有 WARN,無 FAIL
  2   有 FAIL
  3   不在 WSL 環境中,未執行任何檢查
  64  選項用法錯誤

環境變數:
  WSL_AI_DOCTOR_LANG               預設語言(zh-TW 或 en)
  WSL_AI_DOCTOR_NODE_MIN           Node.js 最低版本(預設 $NODE_MIN_REQUIRED)
  WSL_AI_DOCTOR_NODE_RECOMMENDED   Node.js 建議版本(預設 $NODE_MIN_RECOMMENDED)
  WSL_AI_DOCTOR_NET_TIMEOUT        網路檢查逾時秒數(預設 $NET_TIMEOUT)
  WSL_AI_DOCTOR_MEM_MIN_GB         .wslconfig 記憶體下限 GB(預設 $WSLCONF_MEM_MIN_GB)
  WSL_AI_DOCTOR_MEM_MAX_PCT        .wslconfig 記憶體佔主機比例上限 %%(預設 $WSLCONF_MEM_MAX_PCT)
  WSL_AI_DOCTOR_PATH_WIN_WARN      PATH 中 Windows 路徑數量警戒值(預設 $PATH_WIN_ENTRY_WARN)
  WSL_AI_DOCTOR_WSLCONFIG          指定 .wslconfig 路徑
  NO_COLOR                         設定即停用彩色輸出
EOF
  fi
}

validate_lang() {
  case "$1" in
    zh-TW|en) return 0 ;;
    *)        return 1 ;;
  esac
}

# 非 WSL 且未加 --allow-non-wsl 時的說明輸出
print_non_wsl_notice() {
  printf '\n  %s[SKIP]%s %s\n' "$C_YELLOW" "$C_RESET" "$(t gate.not_wsl "$ENV_KERNEL")"
  printf '         %s↳ %s\n' "$C_DIM" "$(t gate.h1)"
  printf '           %s%s\n' "$(t gate.h2)" "$C_RESET"
  printf '         %s↳ %s%s\n' "$C_DIM" "$(t gate.h3)" "$C_RESET"
  printf '           %s$ %s --allow-non-wsl%s\n' "$C_CYAN" "$(self_invocation)" "$C_RESET"
  printf '             %s%s%s\n\n' "$C_DIM" "$(t gate.h4)" "$C_RESET"
}

main() {
  # --help / --version 不在迴圈中立即處理,而是先解析完所有參數再輸出。
  # 否則 `--help --lang en` 會在讀到 --lang 之前就結束,印出錯誤語言的說明。
  local show_help=0 show_version=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)       show_help=1 ;;
      -v|--version)    show_version=1 ;;
      --no-color)      USE_COLOR=never ;;
      --color)         USE_COLOR=always ;;
      --json)          OUTPUT_FORMAT=json; USE_COLOR=never ;;
      --skip-network)  SKIP_NETWORK=1 ;;
      --allow-non-wsl) ALLOW_NON_WSL=1 ;;
      --lang)
        if [[ $# -lt 2 ]]; then
          printf '%s\n\n' "$(t err.lang_missing)" >&2
          exit 64
        fi
        if ! validate_lang "$2"; then
          printf '%s\n\n' "$(t err.unknown_lang "$2")" >&2
          exit 64
        fi
        LANG_CODE="$2"; shift
        ;;
      --lang=*)
        if ! validate_lang "${1#--lang=}"; then
          printf '%s\n\n' "$(t err.unknown_lang "${1#--lang=}")" >&2
          exit 64
        fi
        LANG_CODE="${1#--lang=}"
        ;;
      *)
        printf '%s\n\n' "$(t err.unknown_option "$1")" >&2
        setup_colors; usage >&2
        exit 64
        ;;
    esac
    shift
  done

  # 環境變數指定的語言若無效,靜默回退到預設,避免因設定錯誤而中斷
  validate_lang "$LANG_CODE" || LANG_CODE="zh-TW"

  setup_colors

  if [[ $show_version -eq 1 ]]; then
    printf 'wsl-ai-doctor v%s\n' "$VERSION"
    exit 0
  fi

  if [[ $show_help -eq 1 ]]; then
    usage
    exit 0
  fi

  if [[ "$OUTPUT_FORMAT" == "text" ]]; then
    printf '%s%swsl-ai-doctor v%s%s — %s\n' \
      "$C_BOLD" "$C_CYAN" "$VERSION" "$C_RESET" "$(t app.tagline)"
    printf '%s%s%s\n' "$C_DIM" "$(t app.time "$(date '+%Y-%m-%d %H:%M:%S')")" "$C_RESET"
  fi

  # --- 環境閘門:確認在 WSL 中,否則安全結束 ---
  # 本工具所有檢查的前提都是 WSL 環境。在純 Linux 上硬跑會產生誤導性結果
  # (例如建議去修改一台根本沒有 /etc/wsl.conf 的機器),因此預設直接結束。
  if ! is_wsl; then
    NON_WSL=1
    collect_environment
    if [[ $ALLOW_NON_WSL -eq 0 ]]; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        render_json 3
      else
        print_non_wsl_notice
      fi
      exit 3
    fi
    [[ "$OUTPUT_FORMAT" == "text" ]] && \
      printf '\n%s%s%s%s\n' "$C_BOLD" "$C_YELLOW" "$(t gate.forced)" "$C_RESET"
  fi

  collect_environment

  check_wsl
  check_node
  check_path
  check_npm_global
  check_network
  check_wslconfig

  local exit_code=0
  [[ $WARN_COUNT -gt 0 ]] && exit_code=1
  [[ $FAIL_COUNT -gt 0 ]] && exit_code=2

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    render_json "$exit_code"
  else
    render_text
    render_summary
    render_ai_hint
  fi

  exit "$exit_code"
}

main "$@"
