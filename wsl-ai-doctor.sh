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
# 注意:本腳本刻意不使用 `set -e`。每一項檢查失敗都是預期中的結果,
#       不應該中斷整份健檢流程。

set -uo pipefail

VERSION="0.1.0"

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

# ---------------------------------------------------------------------------
# 輸出樣式與計數器
# ---------------------------------------------------------------------------

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

USE_COLOR=auto
SKIP_NETWORK=0
ALLOW_NON_WSL=0   # --allow-non-wsl:非 WSL 環境也繼續執行(CI 用)
NON_WSL=0         # 執行期判定結果:1 代表目前不在 WSL 中

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

section() {
  printf '\n%s%s▸ %s%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1"
}

# 中性資訊,不列入計分
info() {
  printf '  %s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$1"
}

# 此環境不適用的檢查。單獨計分,不影響健康判定與離開代碼。
skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf '  %s[SKIP]%s %s\n' "$C_DIM" "$C_RESET" "$1"
}

# 修復建議說明文字
hint() {
  printf '         %s↳ %s%s\n' "$C_DIM" "$1" "$C_RESET"
}

# 可直接複製貼上的修復指令
cmd() {
  printf '           %s$ %s%s\n' "$C_CYAN" "$1" "$C_RESET"
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

# ---------------------------------------------------------------------------
# 檢查 1:WSL 版本與設定
# ---------------------------------------------------------------------------

check_wsl() {
  section "WSL 版本與設定"

  local osrelease
  osrelease="$(kernel_release)"

  # 非 WSL 環境(僅在 --allow-non-wsl 下會走到這裡):整段跳過,
  # 因為 WSL 版本、systemd 的 WSL 設定、/etc/wsl.conf 在此都不適用。
  if [[ $NON_WSL -eq 1 ]]; then
    skip "非 WSL 環境,略過 WSL 版本與設定檢查(kernel: $osrelease)"
    return 0
  fi

  # --- WSL1 vs WSL2 ---
  if [[ "$osrelease" == *"WSL2"* ]]; then
    pass "WSL2(kernel $osrelease)"
  else
    fail "偵測到 WSL1(kernel $osrelease)"
    hint "WSL1 沒有完整 Linux kernel,檔案 I/O 與網路行為和原生 Linux 差異大,"
    hint "跑 node 生態系與 AI CLI 工具容易出現難以診斷的問題。請升級到 WSL2:"
    cmd "wsl --set-version ${WSL_DISTRO_NAME:-<你的發行版>} 2   # 在 Windows PowerShell 執行"
    cmd "wsl --set-default-version 2"
  fi

  [[ -n "${WSL_DISTRO_NAME:-}" ]] && info "發行版:$WSL_DISTRO_NAME"

  # --- systemd ---
  local pid1
  pid1="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')"

  if [[ "$pid1" == "systemd" ]]; then
    pass "systemd 已啟用(PID 1 = systemd)"
  else
    warn "systemd 未啟用(PID 1 = ${pid1:-未知})"
    hint "沒有 systemd 時,以 service/systemctl 管理的元件(docker、ssh-agent、"
    hint "自訂背景服務)無法正常啟動,部分開發工具的背景常駐程序也會受影響。"
    hint "在 /etc/wsl.conf 加入以下設定後,於 PowerShell 執行 wsl --shutdown 重啟:"
    cmd "printf '[boot]\\nsystemd=true\\n' | sudo tee -a /etc/wsl.conf"
    cmd "wsl --shutdown   # 在 Windows PowerShell 執行,再重開 WSL"
  fi

  # --- /etc/wsl.conf 的 interop 設定 ---
  if [[ -f /etc/wsl.conf ]]; then
    info "/etc/wsl.conf 存在"
    if grep -qiE '^\s*appendWindowsPath\s*=\s*false' /etc/wsl.conf 2>/dev/null; then
      info "已設定 appendWindowsPath=false(Windows PATH 不會併入 WSL,屬刻意設定)"
    fi
  else
    info "/etc/wsl.conf 不存在(使用預設設定)"
  fi
}

# ---------------------------------------------------------------------------
# 檢查 2:Node.js 版本
# ---------------------------------------------------------------------------

check_node() {
  section "Node.js 版本"

  local node_path
  node_path="$(command -v node 2>/dev/null)"

  if [[ -z "$node_path" ]]; then
    fail "找不到 node 指令"
    hint "Claude Code、Codex CLI 等工具都以 Node.js 執行。建議用 nvm 在 WSL 內安裝:"
    cmd "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
    cmd "exec \$SHELL -l"
    cmd "nvm install --lts"
    hint "請勿把 Windows 版 Node.js 當成 WSL 的 node 使用,兩者無法互通。"
    return 1
  fi

  # --- 版本判定 ---
  local node_version major
  node_version="$(node -v 2>/dev/null | tr -d 'v\r')"

  if [[ -z "$node_version" ]]; then
    fail "node 指令存在($node_path),但無法取得版本(node -v 執行失敗)"
    hint "多半是 node 指到已損毀的安裝,或指向一個目前無法從 WSL 存取的 Windows 執行檔。"
    cmd "command -v -a node"
    return 1
  fi

  major="${node_version%%.*}"

  if [[ ! "$major" =~ ^[0-9]+$ ]]; then
    warn "無法解析 Node.js 版本字串:$node_version"
  elif (( major < NODE_MIN_REQUIRED )); then
    fail "Node.js v$node_version 過舊(AI CLI 工具普遍要求 v${NODE_MIN_REQUIRED} 以上)"
    hint "多數 AI CLI 在舊版 Node 上會直接安裝失敗,或啟動時報語法錯誤。請升級:"
    cmd "nvm install --lts && nvm alias default lts/*"
  elif (( major < NODE_MIN_RECOMMENDED )); then
    warn "Node.js v$node_version 可用,但建議升級到 v${NODE_MIN_RECOMMENDED} 以上"
    hint "較新版本的 AI CLI 工具已陸續把最低需求拉高到 v${NODE_MIN_RECOMMENDED}。"
    cmd "nvm install --lts && nvm alias default lts/*"
  else
    pass "Node.js v$node_version(>= v${NODE_MIN_RECOMMENDED})"
  fi

  # --- 是不是誤用 Windows 版 Node ---
  if is_win_path "$node_path"; then
    fail "node 指向 Windows 安裝:$node_path"
    hint "這是 WSL 上最常見的地雷。Windows 版 node.exe 從 WSL 呼叫時:"
    hint "  • 認得的是 Windows 路徑(C:\\...),拿到 Linux 路徑(/home/...)會找不到檔案"
    hint "  • 透過 /mnt 跨檔案系統存取,npm install 會慢上數倍"
    hint "  • 原生模組(node-gyp)編出來的是 Windows 二進位檔,在 WSL 內無法載入"
    hint "請在 WSL 內另外安裝一份 Linux 版 Node.js:"
    cmd "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
    cmd "exec \$SHELL -l && nvm install --lts"
  elif [[ $NON_WSL -eq 1 ]]; then
    pass "node 為原生 Linux 安裝:$node_path"
  else
    pass "node 為 WSL 端安裝:$node_path"
  fi

  # --- npm 是否存在,且與 node 來自同一側 ---
  local npm_path
  npm_path="$(command -v npm 2>/dev/null)"

  if [[ -z "$npm_path" ]]; then
    fail "找不到 npm 指令"
    hint "Node.js 安裝通常會一併帶上 npm;若只缺 npm,多半是安裝不完整。"
    cmd "nvm install --lts   # 重新安裝一份完整的 Node.js"
  elif is_win_path "$npm_path" && ! is_win_path "$node_path"; then
    fail "node 在 WSL 端,npm 卻指向 Windows 端:$npm_path"
    hint "兩者混用時,npm 會把套件裝到 Windows 的目錄,而 WSL 的 node 找不到它們。"
    hint "請確認 PATH 中 WSL 的 node 目錄排在 Windows 路徑之前,或重裝 nvm。"
  elif ! is_win_path "$npm_path"; then
    if [[ $NON_WSL -eq 1 ]]; then
      pass "npm 為原生 Linux 安裝:$npm_path($(npm -v 2>/dev/null | tr -d '\r'))"
    else
      pass "npm 為 WSL 端安裝:$npm_path($(npm -v 2>/dev/null | tr -d '\r'))"
    fi
  else
    warn "npm 指向 Windows 安裝:$npm_path"
    hint "與上一項為同一個根因,修好 node 之後這項通常會一起解決。"
  fi
}

# ---------------------------------------------------------------------------
# 檢查 3:PATH 正確性(Windows / WSL 互相抓不到指令)
# ---------------------------------------------------------------------------

check_path() {
  section "PATH 設定"

  local -a entries=()
  local IFS=':'
  read -r -a entries <<< "$PATH"
  unset IFS

  local win_count=0 linux_count=0
  local -a empty_entries=() missing_dirs=() dup_entries=() seen=()
  local entry norm

  for entry in "${entries[@]}"; do
    if [[ -z "$entry" ]]; then
      empty_entries+=("(空值)")
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
      [[ -d "$entry" ]] || missing_dirs+=("$entry")
    fi
  done

  if [[ $NON_WSL -eq 1 ]]; then
    info "PATH 共 ${#entries[@]} 個項目"
  else
    info "PATH 共 ${#entries[@]} 個項目(WSL 端 $linux_count、Windows 端 $win_count)"
  fi

  # 以下三項都在檢查 WSL 與 Windows 之間的互通性,非 WSL 環境不適用。
  if [[ $NON_WSL -eq 1 ]]; then
    skip "非 WSL 環境,略過 Windows interop 與跨側指令解析檢查"
  else

  # --- Windows interop 是否生效 ---
  if [[ $win_count -eq 0 ]]; then
    warn "PATH 中沒有任何 Windows 路徑,無法從 WSL 呼叫 Windows 指令"
    hint "AI CLI 的登入流程常需要呼叫 Windows 開啟瀏覽器;關掉 interop 後 OAuth 會卡住。"
    hint "若 /etc/wsl.conf 裡設了 appendWindowsPath=false,請改為 true 或移除該行:"
    cmd "sudo sed -i 's/appendWindowsPath *= *false/appendWindowsPath=true/' /etc/wsl.conf"
    cmd "wsl --shutdown   # 在 Windows PowerShell 執行後重開"
  elif [[ $win_count -gt $PATH_WIN_ENTRY_WARN ]]; then
    warn "PATH 中有 $win_count 個 Windows 路徑,數量偏多(建議 <= $PATH_WIN_ENTRY_WARN)"
    hint "每個 Windows 路徑都跨 9p 檔案系統查找,會拖慢每次指令解析與 tab 補全。"
    hint "可改為只保留必要的 Windows 路徑:在 /etc/wsl.conf 設 appendWindowsPath=false,"
    hint "再於 ~/.bashrc 手動補上真正需要的幾個(例如 cmd.exe、powershell.exe 所在目錄)。"
  else
    pass "Windows interop 路徑正常($win_count 個)"
  fi

  # --- 從 WSL 呼叫 Windows 指令 ---
  local -a win_tools=(cmd.exe powershell.exe)
  local -a win_missing=()
  local t
  for t in "${win_tools[@]}"; do
    command -v "$t" >/dev/null 2>&1 || win_missing+=("$t")
  done

  if [[ ${#win_missing[@]} -eq 0 ]]; then
    pass "可從 WSL 呼叫 Windows 指令(cmd.exe / powershell.exe)"
  else
    warn "以下 Windows 指令無法從 WSL 呼叫:${win_missing[*]}"
    hint "OAuth 登入、開啟瀏覽器、讀取 .wslconfig 等功能會受影響。"
    hint "請確認 /etc/wsl.conf 中 [interop] enabled 未被設為 false。"
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
    pass "常用開發指令都解析到 WSL 端版本"
  else
    fail "以下指令解析到 Windows 端版本,而非 WSL 端:"
    for tool in "${shadowed[@]}"; do
      hint "$tool"
    done
    hint "跨側執行會導致路徑轉換錯誤、權限問題與效能損失。請在 WSL 內安裝對應工具,"
    hint "並確認 ~/.bashrc 中 WSL 路徑排在 Windows 路徑之前:"
    cmd "export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\""
    cmd "command -v -a node   # 確認所有候選路徑與優先順序"
  fi

  fi   # end: NON_WSL 互通性檢查區塊

  # --- PATH 衛生檢查(與 WSL 無關,任何環境都適用) ---
  if [[ ${#empty_entries[@]} -gt 0 ]]; then
    warn "PATH 中含有 ${#empty_entries[@]} 個空值項目"
    hint "空值等同於「當前目錄」,會讓 shell 執行到工作目錄下的同名檔案,有安全風險。"
    hint "通常來自 ~/.bashrc 裡寫成 PATH=\"\$PATH:\" 或 PATH=\":\$PATH\" 的多餘冒號。"
  fi

  if [[ ${#dup_entries[@]} -gt 0 ]]; then
    warn "PATH 中有 ${#dup_entries[@]} 個重複項目:${dup_entries[*]}"
    hint "多半是 ~/.bashrc 或 ~/.profile 被重複載入(例如 export PATH 寫在會重跑的區塊)。"
    hint "不影響正確性,但會拖慢指令查找,也讓排查 PATH 問題變得困難。"
  fi

  if [[ ${#missing_dirs[@]} -gt 0 ]]; then
    warn "PATH 中有 ${#missing_dirs[@]} 個不存在的目錄:${missing_dirs[*]}"
    hint "通常是移除工具後、rc 檔沒有跟著清理。清掉可減少每次指令查找的無效 stat。"
  fi

  if [[ ${#empty_entries[@]} -eq 0 && ${#dup_entries[@]} -eq 0 && ${#missing_dirs[@]} -eq 0 ]]; then
    pass "PATH 內容乾淨(無空值、重複或失效目錄)"
  fi
}

# ---------------------------------------------------------------------------
# 檢查 4:npm 全域執行檔是否真的在 PATH 裡
# ---------------------------------------------------------------------------

check_npm_global() {
  section "npm 全域安裝與 PATH"

  if ! command -v npm >/dev/null 2>&1; then
    fail "找不到 npm,略過全域套件檢查"
    hint "請先解決上面的 Node.js 問題,再重新執行本工具。"
    return 1
  fi

  local prefix
  prefix="$(npm config get prefix 2>/dev/null | tr -d '\r')"

  if [[ -z "$prefix" || "$prefix" == "undefined" ]]; then
    fail "無法取得 npm 全域安裝路徑(npm config get prefix 沒有回應)"
    return 1
  fi

  # --- 前綴落在 Windows 端 ---
  if is_win_native_path "$prefix" || is_win_path "$prefix"; then
    fail "npm 全域安裝路徑位於 Windows 端:$prefix"
    hint "這正是「明明 npm install -g 裝好了,指令卻找不到」最常見的原因:"
    hint "  • 套件被裝進 Windows 的 %APPDATA%\\npm,產生的是 .cmd / .ps1 包裝檔"
    hint "  • 這些包裝檔在 WSL 的 bash 裡不是可執行的 Linux 執行檔"
    hint "  • 即使能執行,傳進去的 Linux 路徑 Windows 端也解讀不了"
    hint "請在 WSL 內安裝 Linux 版 Node.js,讓全域前綴落在 \$HOME 底下:"
    cmd "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
    cmd "exec \$SHELL -l && nvm install --lts"
    cmd "npm config get prefix   # 應顯示 /home/... 開頭的路徑"
    return 1
  fi

  info "npm 全域前綴:$prefix"

  local global_bin="$prefix/bin"

  if [[ ! -d "$global_bin" ]]; then
    warn "全域執行檔目錄不存在:$global_bin"
    hint "尚未安裝任何全域套件時屬正常;若已安裝過,代表 prefix 設定有誤。"
    return 0
  fi

  # --- 全域 bin 目錄有沒有在 PATH 裡 ---
  if path_contains "$global_bin"; then
    pass "全域執行檔目錄已在 PATH 中:$global_bin"
  else
    fail "全域執行檔目錄不在 PATH 中:$global_bin"
    hint "npm install -g 會成功,但裝好的指令一律「command not found」。加入 PATH:"
    cmd "echo 'export PATH=\"$global_bin:\$PATH\"' >> ~/.bashrc"
    cmd "source ~/.bashrc"
  fi

  # --- 前綴目錄是否可寫(避免被迫 sudo npm -g) ---
  if [[ -w "$prefix" ]]; then
    pass "全域前綴目錄可寫入,不需要 sudo 安裝"
  else
    warn "全域前綴目錄不可寫入:$prefix"
    hint "會逼你用 sudo npm install -g,而 sudo 裝出來的檔案屬 root,"
    hint "之後 npm update / 移除都可能因權限失敗。建議改用使用者層級的前綴:"
    cmd "mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global"
    cmd "echo 'export PATH=\"\$HOME/.npm-global/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
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
    info "尚未安裝任何全域執行檔"
    return 0
  fi

  if [[ ${#not_found[@]} -eq 0 && ${#shadowed[@]} -eq 0 ]]; then
    pass "全部 $count 個全域執行檔都能正常解析"
    return 0
  fi

  if [[ ${#not_found[@]} -gt 0 ]]; then
    fail "以下全域執行檔已安裝,但在目前 shell 中找不到:${not_found[*]}"
    hint "典型的「裝了但指令不存在」。$global_bin 沒有生效於當前 PATH:"
    cmd "echo 'export PATH=\"$global_bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
    cmd "hash -r   # 清掉 shell 快取的舊指令位置"
  fi

  if [[ ${#shadowed[@]} -gt 0 ]]; then
    warn "以下全域執行檔被其他路徑的同名指令蓋過:"
    for name in "${shadowed[@]}"; do
      hint "$name"
    done
    hint "你執行到的不是 npm 剛裝的那一份,版本可能不一致。確認優先順序:"
    cmd "command -v -a <指令名稱>"
  fi
}

# ---------------------------------------------------------------------------
# 檢查 5:對外網路連線
# ---------------------------------------------------------------------------

check_network() {
  section "對外網路連線"

  if [[ $SKIP_NETWORK -eq 1 ]]; then
    info "已指定 --skip-network,略過網路檢查"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    fail "找不到 curl,無法檢查網路連線"
    cmd "sudo apt update && sudo apt install -y curl"
    return 1
  fi

  # --- Proxy 設定(常見的連線異常來源) ---
  local proxy_note=""
  [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]] && proxy_note="HTTPS_PROXY=${HTTPS_PROXY:-$https_proxy}"
  [[ -n "$proxy_note" ]] && info "偵測到 proxy 設定:$proxy_note"

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
      pass "$host 可連線(HTTP $code)"
    elif [[ $dns_ok -eq 0 ]]; then
      fail "$host DNS 解析失敗"
      net_failed=1
    else
      fail "$host DNS 正常,但 HTTPS 連線失敗(逾時 ${NET_TIMEOUT}s)"
      net_failed=1
    fi
  done

  [[ $net_failed -eq 0 ]] && return 0

  # --- 連線失敗時,才輸出診斷資訊 ---
  hint "WSL 網路異常常見的幾個原因與對應處理:"

  if [[ -f /etc/resolv.conf ]]; then
    local ns
    ns="$(grep -E '^\s*nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)"
    hint "  目前 DNS 伺服器:${ns:-（未設定）}"

    if grep -qi 'generated by WSL' /etc/resolv.conf 2>/dev/null; then
      hint "  1) resolv.conf 由 WSL 自動產生。若公司 VPN 或防火牆干擾了 DNS,"
      hint "     可改為自行指定(先關掉自動產生,再寫入固定 DNS):"
      cmd "printf '[network]\\ngenerateResolvConf=false\\n' | sudo tee -a /etc/wsl.conf"
      cmd "wsl --shutdown   # PowerShell 執行後重開,再設定 /etc/resolv.conf"
      cmd "printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n' | sudo tee /etc/resolv.conf"
    fi
  else
    hint "  /etc/resolv.conf 不存在,DNS 完全無法運作。"
  fi

  hint "  2) 使用 VPN 時,WSL 的 MTU 常大於 VPN 介面,造成 TLS 交握卡死:"
  cmd "sudo ip link set dev eth0 mtu 1350"
  hint "  3) 企業防火牆做 TLS 攔截時,需要把公司根憑證加入 WSL 的信任清單:"
  cmd "sudo cp company-root.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates"
  hint "  4) 先確認是否為全域斷網(而非只有 API 網域被擋):"
  cmd "curl -sS -o /dev/null -w '%{http_code}\\n' --max-time 8 https://example.com"
}

# ---------------------------------------------------------------------------
# 檢查 6:.wslconfig 資源配置
# ---------------------------------------------------------------------------

check_wslconfig() {
  section ".wslconfig 資源配置"

  if [[ $NON_WSL -eq 1 ]]; then
    skip "非 WSL 環境,沒有 .wslconfig 可檢查"
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
    warn "無法定位 Windows 使用者家目錄,略過 .wslconfig 檢查"
    hint "通常代表 Windows interop 被關閉,或 C: 未掛載到 /mnt/c。"
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

  if [[ $host_mem_mb -gt 0 ]]; then
    info "Windows 主機:$((host_mem_mb / 1024)) GB RAM / ${host_cpus} 邏輯核心"
  fi
  info "WSL 目前可用:$((wsl_mem_mb / 1024)) GB RAM / ${wsl_cpus} 核心"

  # --- .wslconfig 不存在:WSL2 預設值 ---
  if [[ ! -f "$wslconfig" ]]; then
    if [[ $host_mem_mb -gt 0 && $((host_mem_mb / 1024)) -lt $((WSLCONF_MEM_MIN_GB * 2)) ]]; then
      warn "找不到 .wslconfig,且主機記憶體偏小($((host_mem_mb / 1024)) GB)"
      hint "WSL2 預設最多用一半實體記憶體,在小記憶體機器上跑 node + AI agent 容易 OOM。"
      hint "建議建立 $wslconfig 明確配置(記憶體回收由 WSL 自動處理,設高不代表一直佔用):"
      cmd "printf '[wsl2]\\nmemory=${WSLCONF_MEM_MIN_GB}GB\\nprocessors=$((wsl_cpus > 2 ? wsl_cpus / 2 : 1))\\n' > '$wslconfig'"
    else
      pass "未設定 .wslconfig,採用 WSL2 預設值(記憶體上限約為實體記憶體一半)"
      info "預設值對多數機器已足夠;需要精細控制時可建立:$wslconfig"
    fi
    return 0
  fi

  info ".wslconfig 位置:$wslconfig"

  # --- 解析 [wsl2] 區段 ---
  local mem_raw cpu_raw swap_raw
  mem_raw="$(grep -iE '^\s*memory\s*=' "$wslconfig" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]\r')"
  cpu_raw="$(grep -iE '^\s*processors\s*=' "$wslconfig" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]\r')"
  swap_raw="$(grep -iE '^\s*swap\s*=' "$wslconfig" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]\r')"

  # --- 記憶體 ---
  if [[ -z "$mem_raw" ]]; then
    pass "未指定 memory,採用預設值(實體記憶體的一半)"
  else
    local mem_mb
    mem_mb="$(to_mb "$mem_raw")" || mem_mb=""

    if [[ -z "$mem_mb" || ! "$mem_mb" =~ ^[0-9]+$ ]]; then
      warn "memory 值無法解析:$mem_raw"
      hint "格式應為 memory=8GB 或 memory=8192MB。寫錯時 WSL 會忽略整行,靜默套用預設值。"
    else
      local mem_gb=$((mem_mb / 1024))
      if (( mem_mb < WSLCONF_MEM_MIN_GB * 1024 )); then
        warn "memory=$mem_raw 偏低(建議至少 ${WSLCONF_MEM_MIN_GB}GB)"
        hint "Node.js 加上 AI agent 的檔案索引與語言伺服器很吃記憶體,配得太低會頻繁觸發"
        hint "OOM killer,症狀是 agent 跑到一半無預警被砍掉。建議調整:"
        cmd "# 編輯 $wslconfig,將 memory 改為 ${WSLCONF_MEM_MIN_GB}GB 以上,再執行 wsl --shutdown"
      elif [[ $host_mem_mb -gt 0 ]] && (( mem_mb * 100 / host_mem_mb > WSLCONF_MEM_MAX_PCT )); then
        warn "memory=$mem_raw 佔主機記憶體 $((mem_mb * 100 / host_mem_mb))%(建議不超過 ${WSLCONF_MEM_MAX_PCT}%)"
        hint "留給 Windows 的記憶體不足時,整台機器會開始頻繁換頁,反而讓 WSL 也一起變慢。"
        hint "建議上限:$((host_mem_mb * WSLCONF_MEM_MAX_PCT / 100 / 1024))GB"
      else
        pass "memory=$mem_raw(${mem_gb}GB)配置合理"
      fi
    fi
  fi

  # --- CPU ---
  if [[ -z "$cpu_raw" ]]; then
    pass "未指定 processors,採用預設值(全部邏輯核心)"
  elif [[ ! "$cpu_raw" =~ ^[0-9]+$ ]]; then
    warn "processors 值無法解析:$cpu_raw"
    hint "應為正整數,例如 processors=8。"
  else
    if (( cpu_raw < 2 )); then
      warn "processors=$cpu_raw 過低"
      hint "npm install 與 AI agent 的平行檔案掃描在單核心下會明顯變慢。建議至少 2 核心。"
    elif [[ $host_cpus -gt 0 ]] && (( cpu_raw > host_cpus )); then
      warn "processors=$cpu_raw 超過主機邏輯核心數($host_cpus)"
      hint "超出的部分不會生效,WSL 會直接以主機核心數為上限。"
    elif [[ $host_cpus -gt 0 ]] && (( cpu_raw == host_cpus )); then
      info "processors=$cpu_raw 已用滿全部核心;若編譯時 Windows 端會卡頓,可保留 1-2 核給主機。"
      pass "processors=$cpu_raw 在有效範圍內"
    else
      pass "processors=$cpu_raw 配置合理"
    fi
  fi

  # --- Swap ---
  if [[ "$swap_raw" == "0" ]]; then
    info "swap=0(已停用)。記憶體吃緊時會直接觸發 OOM killer,而非降速。"
  elif [[ -n "$swap_raw" ]]; then
    info "swap=$swap_raw"
  fi

  hint "提醒:修改 .wslconfig 後需要重啟 WSL 才會生效。"
  cmd "wsl --shutdown   # 在 Windows PowerShell 執行"
}

# ---------------------------------------------------------------------------
# 總結
# ---------------------------------------------------------------------------

print_summary() {
  local total=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT + SKIP_COUNT))

  printf '\n%s%s\n' "$C_BOLD" "════════════════════════════════════════════"
  printf ' 健檢總結(共 %d 項)%s\n\n' "$total" "$C_RESET"
  printf '   %s● PASS%s  %3d\n' "$C_GREEN"  "$C_RESET" "$PASS_COUNT"
  printf '   %s● WARN%s  %3d\n' "$C_YELLOW" "$C_RESET" "$WARN_COUNT"
  printf '   %s● FAIL%s  %3d\n' "$C_RED"    "$C_RESET" "$FAIL_COUNT"
  [[ $SKIP_COUNT -gt 0 ]] && \
    printf '   %s● SKIP%s  %3d  %s(此環境不適用)%s\n' "$C_DIM" "$C_RESET" "$SKIP_COUNT" "$C_DIM" "$C_RESET"
  printf '\n'

  if [[ $FAIL_COUNT -gt 0 ]]; then
    printf ' %s%s環境狀態:需要修復%s — 有 %d 項會直接導致 AI CLI 工具無法正常運作。\n' \
      "$C_BOLD" "$C_RED" "$C_RESET" "$FAIL_COUNT"
    printf ' 請依上方 %s[FAIL]%s 項目的建議指令處理,修復後重新執行本工具確認。\n' "$C_RED" "$C_RESET"
  elif [[ $WARN_COUNT -gt 0 ]]; then
    printf ' %s%s環境狀態:堪用%s — 沒有致命問題,但有 %d 項建議調整。\n' \
      "$C_BOLD" "$C_YELLOW" "$C_RESET" "$WARN_COUNT"
    printf ' 這些多半影響效能或穩定性,不會立刻讓工具失效。\n'
  else
    printf ' %s%s環境狀態:健康%s — 所有檢查項目都通過。\n' \
      "$C_BOLD" "$C_GREEN" "$C_RESET"
  fi

  printf '%s%s%s\n' "$C_BOLD" "════════════════════════════════════════════" "$C_RESET"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
wsl-ai-doctor v$VERSION — WSL 環境健康檢查工具

用法:
  ./wsl-ai-doctor.sh [選項]

選項:
  -h, --help          顯示本說明
  -v, --version       顯示版本
      --no-color      停用彩色輸出(輸出到檔案或 CI 時使用)
      --color         強制啟用彩色輸出(即使不是終端機)
      --skip-network  略過對外連線檢查(離線環境使用)
      --allow-non-wsl 非 WSL 環境也執行,WSL 相關檢查標記為 SKIP(CI 用)

離開代碼:
  0   全部通過
  1   有 WARN,無 FAIL
  2   有 FAIL
  3   不在 WSL 環境中,未執行任何檢查
  64  選項用法錯誤

環境變數:
  WSL_AI_DOCTOR_NODE_MIN           Node.js 最低版本(預設 $NODE_MIN_REQUIRED)
  WSL_AI_DOCTOR_NODE_RECOMMENDED   Node.js 建議版本(預設 $NODE_MIN_RECOMMENDED)
  WSL_AI_DOCTOR_NET_TIMEOUT        網路檢查逾時秒數(預設 $NET_TIMEOUT)
  WSL_AI_DOCTOR_MEM_MIN_GB         .wslconfig 記憶體下限 GB(預設 $WSLCONF_MEM_MIN_GB)
  WSL_AI_DOCTOR_MEM_MAX_PCT        .wslconfig 記憶體佔主機比例上限 %(預設 $WSLCONF_MEM_MAX_PCT)
  NO_COLOR                         設定即停用彩色輸出
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)     setup_colors; usage; exit 0 ;;
      -v|--version)  printf 'wsl-ai-doctor v%s\n' "$VERSION"; exit 0 ;;
      --no-color)    USE_COLOR=never ;;
      --color)       USE_COLOR=always ;;
      --skip-network) SKIP_NETWORK=1 ;;
      --allow-non-wsl) ALLOW_NON_WSL=1 ;;
      *)
        printf 'ERROR: 未知的選項 %s\n\n' "$1" >&2
        setup_colors; usage >&2
        exit 64
        ;;
    esac
    shift
  done

  setup_colors

  printf '%s%swsl-ai-doctor v%s%s — WSL AI coding agent 環境健檢\n' \
    "$C_BOLD" "$C_CYAN" "$VERSION" "$C_RESET"
  printf '%s檢查時間:%s%s\n' "$C_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET"

  # --- 環境閘門:確認在 WSL 中,否則安全結束 ---
  # 本工具所有檢查的前提都是 WSL 環境。在純 Linux 上硬跑會產生誤導性結果
  # (例如建議去修改一台根本沒有 /etc/wsl.conf 的機器),因此預設直接結束。
  if ! is_wsl; then
    NON_WSL=1
    if [[ $ALLOW_NON_WSL -eq 0 ]]; then
      printf '\n  %s[SKIP]%s 目前不在 WSL 環境中(kernel: %s)\n' \
        "$C_YELLOW" "$C_RESET" "$(kernel_release)"
      printf '         %s↳ 本工具專為 WSL 設計,在原生 Linux 或容器中執行只會得到誤導性結果,\n' "$C_DIM"
      printf '           因此不進行任何檢查。請在 WSL 發行版的終端機內執行。%s\n' "$C_RESET"
      printf '         %s↳ 若你確定要在此環境執行(例如 CI 冒煙測試),可加上:%s\n' "$C_DIM" "$C_RESET"
      printf '           %s$ %s --allow-non-wsl%s\n' "$C_CYAN" "$0" "$C_RESET"
      printf '             %s與 WSL 相關的檢查會標記為 SKIP,其餘檢查照常執行。%s\n\n' "$C_DIM" "$C_RESET"
      exit 3
    fi
    printf '\n%s%s⚠ 非 WSL 環境,以 --allow-non-wsl 繼續執行;WSL 相關檢查將標記為 SKIP。%s\n' \
      "$C_BOLD" "$C_YELLOW" "$C_RESET"
  fi

  check_wsl
  check_node
  check_path
  check_npm_global
  check_network
  check_wslconfig

  print_summary

  [[ $FAIL_COUNT -gt 0 ]] && exit 2
  [[ $WARN_COUNT -gt 0 ]] && exit 1
  exit 0
}

main "$@"
