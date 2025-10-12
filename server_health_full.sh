#!/usr/bin/env bash
#
# server_health_full.sh (v2.3)
# 15 項整合式硬體/系統健檢 (BMC + OS；可整合 UPS)
#
#
# v2.3 新增 / 改進 (2025-10-10):
#  - Judgement 機制全面升級：
#    - 所有 15 個檢測項目均包含詳細的 judgement 欄位（criteria, policy, checks, thresholds）
#    - Items 1-5, 7-8, 12：使用 build_judgement() + set_check_result_with_jdg() 實作詳細判斷邏輯
#    - Items 6, 9-11, 13-15：透過增強的 set_status() 自動生成項目特定的詳細 judgement
#  - Markdown 報告增強：
#    - 新增 Policy 規則顯示（PASS/WARN/FAIL/SKIP/INFO 條件）
#    - 完整呈現每個項目的判斷依據與檢查結果，便於離線審查
#  - Master JSON 完整性：
#    - 修正 build_master_json() 優先使用 ALL_CHECK_RESULTS 確保 judgement 欄位正確輸出
#  - Bug 修復：
#    - 修正 io_status_from_log() 算術運算錯誤（改用字串比較避免空格導致的語法錯誤）
#
# [MOD] Gemini-CLI Interactive Session (2025-10-06):
# Major refactoring and bug fixing session. Key changes include:
#
#  - Reporting Overhaul:
#    - Implemented a new, robust JSON-based reporting architecture using `set_check_result`.
#    - Deprecated the legacy `set_status` function.
#    - Refactored all major check functions (PSU, Disks, Memory, CPU, NIC, Fans, Env, BMC, Logs)
#      to produce detailed JSON output with metrics and evidence paths.
#
#  - Final Report Enhancements:
#    - The final console report now displays detailed `TIPS` and `LOGS` for all items,
#      regardless of status, to improve transparency.
#    - The `Reason` string for passing checks (e.g., Fans) is now enriched with summary data.
#
#  - Specific Function Fixes & Improvements:
#    - PSU: Corrected event counting logic to prevent false warnings from empty logs.
#    - Disks: Made `storcli64` command output visible on the console for easier debugging.
#    - Fans:
#      - Switched to a more compatible IPMI command (`sdr elist | grep`) to find fans.
#      - Fixed a critical `unbound variable` bug in an `if` condition.
#      - Added logic to correctly parse RPM data from IPMI `sdr` output.
#      - Added pipe-separated `DEBUG FAN:` output for consistency.
#    - Env: Added a filter to only process temperature sensors in Celsius, avoiding misinterpretation of other units.
#
#  - New Features:
#    - Added `--log-days` parameter and a comprehensive `analyze_system_logs` function
#      for deeper system log analysis.
#
# v2.2 新增 / 改進：
#  - --with-ups（取代語意反直覺的 --ups-check；仍保留相容）
#  - SEL 解析強化：空 log / 欄位防護 / 空 sensor 避免 bad subscript
#  - Master JSON (object) 格式，含 meta / items / sel / ups / duration
#  - --legacy-json 回輸舊陣列 JSON
#  - --thresholds-json 匯出本次閾值
#  - CPU 溫度 warn/crit 分級：--cpu-temp-warn / --cpu-temp-crit
#  - --output-prefix 指定檔名前綴
#  - --color=auto|always|never + 舊 --no-color 相容
#  - NIC baseline（--nic-baseline）增量判斷 error/drop 增加才 WARN
#  - SEL Top sensors JSON 已含在 master JSON (sel.top_sensors)
#  - Locale 固定 LC_ALL=C
#  - UPS 結果整合 meta.ups
#  - smartctl / sudo 權限判斷
#
# [MOD] v2.2-consolidated:
#  - 內嵌 public_report_builder.sh 的彙整報告邏輯
#  - 新增 Final Consolidated Report 區塊 (終端/Markdown)
#  - 新增 --net-iperf-min, --io-read-min, --cable-* 等參數
#  - Master JSON 新增 reason, tips 欄位
#
set -u
LC_ALL=C
LANG=C

SCRIPT_START_TS=$(date +%s)

# ----------------- 預設參數 -----------------
BMC_IP="${BMC_IP:-}"
BMC_USER="${BMC_USER:-}"
: "${IPMI_TIMEOUT:=8}"

RUN_FIO=0
FIO_FILE="/website/data/storage/vol001/fio_test_4G.bin"
FIO_SIZE="4G"
FIO_NUMJOBS_READ=4
FIO_BS="1M"

OUTPUT_DIR="logs"
OUTPUT_PREFIX=""
: "${LOG_DIR:=$OUTPUT_DIR}"
MARKDOWN_OUTPUT=1
CSV_OUTPUT=1
JSON_OUTPUT=1
LEGACY_JSON=0
JSON_OUT_FILE=""
THRESHOLDS_JSON=""

SKIP_BMC=0
ASK_PASS=0
COLOR_MODE="auto"
NO_COLOR=0  # 相容舊參數
SEL_SHOW=8

# UPS check is now a separate script.

# SEL 新參數
SEL_DAYS=0
SEL_NOISE_HIDE=0
SEL_SEVERITY_MAP=""
SEL_EVENTS_JSON=""
SEL_TOP_JSON=""

INTERNAL_NOISE_LIST=("pef action" "001c4c" "drive present" "power button pressed")

OFFLINE=0
PING_HOST=""
IPERF_TARGET=""
IPERF_TIME=5

# CPU 溫度閾值
CPU_TEMP_WARN=80
CPU_TEMP_CRIT=90
CPU_TEMP_TH=0  # 舊參數（只作 warn）

# 環境溫度閾值 (攝氏)
ENV_TEMP_WARN=35
ENV_TEMP_CRIT=40

FAN_RPM_TH=300
: "${DEVIATION_WARN_PCT:=20}"
: "${DEVIATION_CRIT_PCT:=40}"

NIC_BASELINE_FILE=""
STORCLI_BIN="/opt/MegaRAID/storcli/storcli64"
RAID_CONTROLLER_LIST=""   # 使用者指定 (例如: "0,1")

# ---- NIC Warn thresholds (can override via env) ----
: "${NIC_WARN_MIN_DELTA:=100}"             # 最低 Δrx_dropped（絕對值門檻）
: "${NIC_WARN_MIN_PCT:=0.01}"              # 最低丟包百分比 (%)
: "${NIC_WARN_MIN_RX_DROP_RATE:=0.5}"      # 最低 Δrx_dropped / sec
: "${NIC_RATE_MIN_DELTA:=200}"             # rate/pct 觸發時需要的最小 Δ（降噪）
: "${NIC_MIN_WINDOW_SEC:=180}"             # 最小視窗時間（秒），避免短視窗誤報（建議 120~300）
: "${NIC_MIN_RX_PKTS:=50000}"              # 最小封包數，樣本太小不評分（建議 50000~100000）

# === CONSOLIDATE START ===
# [NEW] 整合報告相關參數
# Thresholds from public_report_builder
NET_IPERF_MIN=100   # Mbps
IO_READ_MIN=300     # MB/s
IO_WRITE_MIN=200    # MB/s

# Cabling policy
CABLE_UPLINK_IFACES=""
CABLE_IGNORE_REGEX='^(docker0|br-|veth|lo)$'
CABLE_MIN_MBPS=1000
CABLE_MAX_FLAPS=10
CABLE_WARN_HALF=1

# SEL analysis params
RECOVER_DAYS=30
LOG_DAYS=1 # NEW: Days to look back for system logs (journalctl)
# === CONSOLIDATE END ===


# ----------------- 使用說明 -----------------
print_usage() {
  cat <<EOF
用法: $0 [選項]
  BMC / 基本:
    --bmc-ip <IP>            --bmc-user <USER>  --ask-pass
    --skip-bmc
  模式:
    --offline (或 --skip-ext)
  網路:
    --ping-host <HOST>
    --iperf <HOST>           --iperf-time <N>
    --net-iperf-min <Mbps>   (預設: $NET_IPERF_MIN)
  CPU / FAN:
    --cpu-temp-th <N>        (舊, = warn)
    --cpu-temp-warn <N>
    --cpu-temp-crit <N>
    --env-temp-warn <N>      (預設: $ENV_TEMP_WARN)
    --env-temp-crit <N>      (預設: $ENV_TEMP_CRIT)
    --fan-th <N>
  磁碟 I/O:
    --run-fio
    --fio-file <path>        --fio-size <size>
    --io-read-min <MB/s>     (預設: $IO_READ_MIN)
    --io-write-min <MB/s>    (預設: $IO_WRITE_MIN)
  Cabling:
    --cable-uplink-ifaces "<csv>"
    --cable-ignore "<regex>"
    --cable-min-mbps <N>
    --cable-max-flaps <N>
    --cable-warn-half / --no-cable-warn-half
  SEL & System Logs:
    --sel-show <N>
    --sel-days <N>           (For BMC/SEL hardware logs)
    --log-days <N>           (For OS kernel logs, default: 1)
  NIC:
    --nic-baseline <file>    (紀錄上次 counters，判斷增量)
  RAID:
    --storcli-bin <path>     (預設 /opt/MegaRAID/storcli/storcli64，可含 sudo)
    --raid-controllers <list>  逗號列出控制器 (例: 0,1)；未指定則自動偵測
  輸出:
    --output-dir <dir>
    --output-prefix <TAG>
    --no-markdown
    --no-csv
    --no-json
    --legacy-json
    --json-out <file>
    --thresholds-json <file>
  顏色:
    --color=auto|always|never
    --no-color               (相容寫法，等於 --color=never)
  其它:
    --help
Exit Code:
  0 全 PASS（或僅 INFO/SKIP）
  1 存在 WARN 且無 FAIL
  2 存在 FAIL
EOF
}

ITEM_NAME=(
  ""
  "1 PSU" "2 Disks/RAID/SMART" "3 Memory/ECC" "4 CPU" "5 NIC"
  "6 GPU" "7 Fans" "8 Env" "9 UPS" "10 Network Reach/Perf"
  "11 Cabling" "12 BMC/SEL" "13 System Logs" "14 Firmware" "15 I/O Perf"
)

# ----------------- 參數解析 -----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bmc-ip) BMC_IP="$2"; shift 2;;
    --bmc-user) BMC_USER="$2"; shift 2;;
    --ask-pass) ASK_PASS=1; shift;;
    --skip-bmc) SKIP_BMC=1; shift;;
    --offline|--skip-ext) OFFLINE=1; shift;;
    --ping-host) PING_HOST="$2"; shift 2;;
    --iperf) IPERF_TARGET="$2"; shift 2;;
    --iperf-time) IPERF_TIME="$2"; shift 2;;
    --cpu-temp-th) CPU_TEMP_TH="$2"; shift 2;;
    --cpu-temp-warn) CPU_TEMP_WARN="$2"; shift 2;;
    --cpu-temp-crit) CPU_TEMP_CRIT="$2"; shift 2;;
    --env-temp-warn) ENV_TEMP_WARN="$2"; shift 2;;
    --env-temp-crit) ENV_TEMP_CRIT="$2"; shift 2;;
    --fan-th) FAN_RPM_TH="$2"; shift 2;;
    --run-fio) RUN_FIO=1; shift;;
    --fio-file) FIO_FILE="$2"; shift 2;;
    --fio-size) FIO_SIZE="$2"; shift 2;;
    --sel-show) SEL_SHOW="$2"; shift 2;;
    --sel-days) SEL_DAYS="$2"; shift 2;;
    --sel-noise-hide) SEL_NOISE_HIDE=1; shift;;
    --sel-severity-map) SEL_SEVERITY_MAP="$2"; shift 2;;
    --sel-events-json) SEL_EVENTS_JSON="$2"; shift 2;;
    --sel-top-json) SEL_TOP_JSON="$2"; shift 2;;
    --nic-baseline) NIC_BASELINE_FILE="$2"; shift 2;;
    --storcli-bin) STORCLI_BIN="$2"; shift 2;;
    --raid-controllers) RAID_CONTROLLER_LIST="$2"; shift 2;;
    --no-markdown) MARKDOWN_OUTPUT=0; shift;;
    --no-csv) CSV_OUTPUT=0; shift;;
    --no-json) JSON_OUTPUT=0; shift;;
    --legacy-json) LEGACY_JSON=1; shift;;
    --json-out) JSON_OUT_FILE="$2"; shift 2;;
    --thresholds-json) THRESHOLDS_JSON="$2"; shift 2;;
    --color=*) COLOR_MODE="${1#--color=}"; shift;;
    --no-color) COLOR_MODE="never"; NO_COLOR=1; shift;;
    --output-dir) OUTPUT_DIR="$2"; shift 2;;
    --output-prefix) OUTPUT_PREFIX="$2"; shift 2;;
    # [NEW] Consolidated report args
    --net-iperf-min) NET_IPERF_MIN="$2"; shift 2;;
    --io-read-min) IO_READ_MIN="$2"; shift 2;;
    --io-write-min) IO_WRITE_MIN="$2"; shift 2;;
    --cable-uplink-ifaces) CABLE_UPLINK_IFACES="$2"; shift 2;;
    --cable-ignore) CABLE_IGNORE_REGEX="$2"; shift 2;;
    --cable-min-mbps) CABLE_MIN_MBPS="$2"; shift 2;;
    --cable-max-flaps) CABLE_MAX_FLAPS="$2"; shift 2;;
    --cable-warn-half) CABLE_WARN_HALF=1; shift;;
    --no-cable-warn-half) CABLE_WARN_HALF=0; shift;;
    --log-days) LOG_DAYS="$2"; shift 2;;
    --help|-h) print_usage; exit 0;;
    *) echo "未知參數: $1"; print_usage; exit 1;;
  esac
done

# [FIX] LOG_DIR must be set *after* parsing --output-dir
: "${LOG_DIR:=$OUTPUT_DIR}"

# 如果使用舊 --cpu-temp-th 但沒指定 warn，賦值
if (( CPU_TEMP_TH > 0 )); then
  CPU_TEMP_WARN="$CPU_TEMP_TH"
fi

if (( ASK_PASS )) && [[ -z "${IPMI_PASSWORD:-}" ]]; then
  read -s -p "輸入 BMC 密碼: " IPMI_PASSWORD; echo
  export IPMI_PASSWORD
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUTPUT_DIR"

# 統一檔名前綴
FILE_BASE="${OUTPUT_PREFIX:+${OUTPUT_PREFIX}_}health_${TIMESTAMP}"

LOG_TXT="$OUTPUT_DIR/${FILE_BASE}.log"
LOG_MD="$OUTPUT_DIR/${FILE_BASE}.md"
LOG_CSV="$OUTPUT_DIR/${FILE_BASE}_summary.csv"
SEL_DETAIL_FILE="$OUTPUT_DIR/${FILE_BASE}_sel_detail.log"
[[ -z "$JSON_OUT_FILE" ]] && JSON_OUT_FILE="$OUTPUT_DIR/${FILE_BASE}.json"
[[ -z "$SEL_EVENTS_JSON" ]] && SEL_EVENTS_JSON="$OUTPUT_DIR/${FILE_BASE}_sel_events.json"
JOURNAL_ANALYSIS_LOG="$OUTPUT_DIR/${FILE_BASE}_journal_analysis.log" # NEW: For detailed journalctl analysis output

UPS_JSON_PATH="$OUTPUT_DIR/${FILE_BASE}_ups_summary.json"   # 若啟用 UPS

exec > >(tee -a "$LOG_TXT") 2>&1

# ----------------- 顏色控制 -----------------
enable_color=0
case "$COLOR_MODE" in
  always) enable_color=1;;
  never) enable_color=0;;
  auto)
    if [[ -t 1 ]]; then enable_color=1; else enable_color=0; fi
    ;;
  *) enable_color=0;;
esac
(( NO_COLOR )) && enable_color=0

if (( enable_color )); then
  C_RESET="\e[0m"; C_GREEN="\e[32m"; C_RED="\e[31m"; C_YELLOW="\e[33m"; C_BLUE="\e[34m"; C_BOLD="\e[1m"
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

echo -e "${C_BLUE}=== 系統健檢開始：$TIMESTAMP ===${C_RESET}"
echo "[INFO] offline=$OFFLINE ping_host=$PING_HOST iperf=$IPERF_TARGET iperf_time=$IPERF_TIME"
echo "[INFO] cpu_warn=$CPU_TEMP_WARN cpu_crit=$CPU_TEMP_CRIT fan_th=$FAN_RPM_TH sel_days=$SEL_DAYS noise_hide=$SEL_NOISE_HIDE"
echo "[INFO] nic_baseline=$NIC_BASELINE_FILE output_prefix=${OUTPUT_PREFIX:-'(none)'}"

# --- [NEW] 全域結果儲存陣列 ---
declare -A ALL_CHECK_RESULTS

# --- [NEW] 統一的結果設定函式 ---
# 用法: set_check_result <ID> <完整的結果JSON字串>
set_check_result() {
    local id="$1"
    local json_data="$2"

    # 將完整的 JSON 結果存入全域陣列
    ALL_CHECK_RESULTS["$id"]="$json_data"

    # 為了向下相容，同時更新舊的陣列，確保未修改的函式不受影響
    local status reason
    status=$(echo "$json_data" | jq -r .status)
    reason=$(echo "$json_data" | jq -r .reason)
    RESULT_STATUS["$id"]="$status"
    RESULT_NOTE["$id"]="$reason"

    # 同時更新舊的 json_items (最終會被 build_master_json 取代)
    add_json_item "$id" "$status" "$reason"
}

# ----------------- Judgement Utilities (v2.3 新增) -----------------
# 統一建構 judgement JSON
# 參數:
#   $1: criteria (string) - 判斷邏輯的人類可讀描述
#   $2: pass_rules (JSON array string) - PASS 條件列表
#   $3: warn_rules (JSON array string) - WARN 條件列表
#   $4: fail_rules (JSON array string) - FAIL 條件列表
#   $5: checks_json (JSON array string) - 實際檢查結果列表
#   $6: th_json (JSON object string) - 本次生效的閾值
build_judgement() {
  local criteria="$1"; shift
  local pass_rules="$1"; shift
  local warn_rules="$1"; shift
  local fail_rules="$1"; shift
  local checks_json="$1"; shift
  local th_json="$1"; shift

  jq -n \
    --arg criteria "$criteria" \
    --argjson policy "$(jq -n --argjson pass "$pass_rules" --argjson warn "$warn_rules" --argjson fail "$fail_rules" \
                        '{pass:$pass, warn:$warn, fail:$fail}')" \
    --argjson checks "$checks_json" \
    --argjson thresholds "$th_json" \
    '{criteria:$criteria, policy:$policy, checks:$checks, thresholds:$thresholds}'
}

# 包裝函式：將 judgement 併入 set_check_result 的 JSON
# 參數:
#   $1: id (檢查項目編號)
#   $2: base_json (原有的 status/reason/metrics/evidence/tips JSON)
#   $3: jdg_json (judgement JSON)
set_check_result_with_jdg() {
  local id="$1" ; shift
  local base_json="$1" ; shift
  local jdg_json="$1"  ; shift

  # 將 judgement 併入
  local merged
  merged=$(jq -c --argjson j "$jdg_json" '. + {judgement:$j}' <<< "$base_json")
  set_check_result "$id" "$merged"
}

# --- [LEGACY] 舊的結果儲存陣列 (逐步淘汰) ---
declare -A RESULT_STATUS RESULT_NOTE
json_items=()

# --- [LEGACY] 舊的函式 (逐步淘汰) ---
add_json_item(){
  local id="$1" status="$2" note="$3"
  local esc
  esc=$(echo "$note" | sed 's/"/\\"/g')
  json_items+=("{\"id\":$id,\"status\":\"$status\",\"note\":\"$esc\"}")
}

set_status() {
  local id="$1" st="$2" note="$3"
  if [[ ! "$id" =~ ^[0-9]+$ ]] && [[ "$st" =~ ^[0-9]+$ ]]; then
    # Safeguard against swapped parameters from legacy call sites
    local tmp="$id"
    id="$st"
    st="$tmp"
  fi
  RESULT_STATUS["$id"]="$st"
  RESULT_NOTE["$id"]="$note"
  add_json_item "$id" "$st" "$note"

  # --- Auto-generate detailed judgement for legacy set_status calls (v2.3) ---
  # Items 6,9-11,13-15 now have item-specific detailed criteria and policy
  local item_name="${ITEM_NAME[$id]:-Unknown}"
  local criteria=""
  local pass_rules=""
  local warn_rules=""
  local fail_rules=""
  local skip_rules=""
  local info_rules=""
  local checks_json=""
  local th_json='{}'

  # Generate item-specific judgement based on ID
  case "$id" in
    6) # GPU
      criteria="檢查 NVIDIA GPU 是否可用。若 nvidia-smi 指令存在且成功執行，視為 PASS；若指令不存在則 SKIP。"
      pass_rules='["nvidia-smi 指令存在", "成功列出 GPU 資訊"]'
      warn_rules='[]'
      fail_rules='["nvidia-smi 執行失敗"]'

      local gpu_cmd_exists=false
      local gpu_status_ok=false
      command -v nvidia-smi >/dev/null 2>&1 && gpu_cmd_exists=true
      [[ "$st" == "PASS" ]] && gpu_status_ok=true

      checks_json=$(jq -n \
        --argjson exists "$gpu_cmd_exists" \
        --argjson ok "$gpu_status_ok" \
        --arg st "$st" \
        '[
          {"name":"nvidia-smi available", "ok":$exists, "value":($exists|tostring)},
          {"name":"GPU enumeration", "ok":$ok, "value":$st}
        ]')
      ;;

    9) # UPS
      criteria="UPS 檢測已改由獨立腳本執行（ups_check.sh）。此項目保留以維持項目編號一致性，狀態固定為 SKIP。"
      skip_rules='["UPS 檢測由 ups_check.sh 獨立處理"]'

      checks_json=$(jq -n \
        '[{"name":"Separate UPS script used", "ok":true, "value":"UPS check is now in separate script"}]')
      ;;

    10) # Network Performance
      criteria="檢查網路連通性、頻寬與時間同步。測試項目：預設閘道 ping、公共 DNS ping（8.8.8.8/1.1.1.1）、可選的自訂 PING_HOST、可選的 iperf3 頻寬測試、時間同步狀態（chronyc/timedatectl）。若在 OFFLINE 模式則跳過外網測試。"
      pass_rules='["外網 DNS 可達（非 OFFLINE 模式）", "時間同步正常"]'
      warn_rules='["外網 DNS 不可達", "閘道不可達", "iperf3 頻寬低於預期"]'
      fail_rules='["OFFLINE=1 且無 default route"]'

      local gw_ok=false
      local dns_ok=false
      local time_sync="unknown"

      # Check if we can reach gateway
      local gw
      gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
      [[ -n "$gw" ]] && ping -c1 -W1 "$gw" >/dev/null 2>&1 && gw_ok=true

      # Check DNS if not OFFLINE
      if (( ! OFFLINE )); then
        ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 || ping -c1 -W1 1.1.1.1 >/dev/null 2>&1
        [[ $? -eq 0 ]] && dns_ok=true
      fi

      # Extract time sync info from note
      if [[ "$note" =~ chronyc_offset ]]; then
        time_sync="chronyc"
      elif [[ "$note" =~ timedatectl ]]; then
        time_sync="timedatectl"
      fi

      checks_json=$(jq -n \
        --argjson gw_ok "$gw_ok" \
        --argjson dns_ok "$dns_ok" \
        --arg time "$time_sync" \
        --arg st "$st" \
        --arg note_val "$note" \
        --argjson offline "${OFFLINE:-0}" \
        '[
          {"name":"Default gateway reachable", "ok":$gw_ok, "value":($gw_ok|tostring)},
          {"name":"Public DNS reachable", "ok":($offline==1 or $dns_ok), "value":(if $offline==1 then "skipped (OFFLINE)" else ($dns_ok|tostring) end)},
          {"name":"Time sync", "ok":($time!="unknown"), "value":$time},
          {"name":"Overall status", "ok":($st=="PASS" or $st=="INFO"), "value":$note_val}
        ]')
      ;;

    11) # Cabling
      criteria="檢查網路介面卡的實體連線狀態與 Link Flap 事件。使用 ethtool 查詢各 NIC 的 Speed/Duplex/Link 狀態，並透過 journalctl 或 dmesg 搜尋近期的 'link up/down'、'carrier lost'、'resetting' 等事件。此項目為 INFO 狀態，需人工判讀是否有異常的 link flap。"
      info_rules='["列出所有實體 NIC link 狀態", "搜尋 link flap 事件供人工判讀"]'

      # Count NICs
      local nic_count=0
      local nics
      nics=$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker.*|veth.*|br-.*|cni.*|flannel.*|cali.*|tun.*|tap.*|virbr.*)$' || true)
      [[ -n "$nics" ]] && nic_count=$(echo "$nics" | wc -l)

      checks_json=$(jq -n \
        --argjson nic_count "$nic_count" \
        --arg st "$st" \
        '[
          {"name":"Physical NICs found", "ok":($nic_count>0), "value":($nic_count|tostring)},
          {"name":"Link status check", "ok":true, "value":"ethtool executed"},
          {"name":"Link flap search", "ok":true, "value":"journalctl/dmesg searched"},
          {"name":"Manual review required", "ok":($st=="INFO"), "value":"Human interpretation needed"}
        ]')
      ;;

    13) # System Logs
      criteria="分析系統日誌中的高優先級訊息（priority 0-3：emerg/alert/crit/err）。使用 journalctl -k -p 0..3 統計過去 LOG_DAYS 天內的高優先級日誌數量。若超過 1 筆則觸發 WARN 並生成詳細分析報告。"
      pass_rules='["過去 N 天內高優先級日誌 ≤1 筆"]'
      warn_rules='["過去 N 天內高優先級日誌 >1 筆"]'
      fail_rules='["系統日誌服務異常"]'

      th_json=$(jq -n \
        --argjson days "${LOG_DAYS:-7}" \
        '{"LOG_DAYS":$days, "critical_threshold":1}')

      local has_journalctl=false
      local critical_count=0
      command -v journalctl >/dev/null 2>&1 && has_journalctl=true

      # Try to extract count from note
      if [[ "$note" =~ ([0-9]+)[[:space:]]*筆 ]]; then
        critical_count="${BASH_REMATCH[1]}"
      fi

      checks_json=$(jq -n \
        --argjson has_jctl "$has_journalctl" \
        --argjson count "$critical_count" \
        --arg st "$st" \
        --arg note_val "$note" \
        '[
          {"name":"journalctl available", "ok":$has_jctl, "value":($has_jctl|tostring)},
          {"name":"Critical log count", "ok":($count<=1), "value":($count|tostring)},
          {"name":"Status", "ok":($st=="PASS" or $st=="INFO"), "value":$note_val}
        ]')
      ;;

    14) # Firmware
      criteria="列舉系統各組件的韌體/驅動版本，包括：BIOS（dmidecode）、BMC（ipmitool mc info）、NIC driver/firmware（ethtool -i）、GPU driver（nvidia-smi）、磁碟韌體（smartctl）、NVMe（nvme list）。此為 INFO 項目，需人工比對是否為最新版本或已知穩定版本。"
      info_rules='["列出 BIOS/BMC/NIC/GPU/Disk 韌體版本供人工比對"]'

      local bios_ok=false
      [[ -n "${BIOS_VERSION:-}" ]] && bios_ok=true

      checks_json=$(jq -n \
        --argjson bios_ok "$bios_ok" \
        --arg st "$st" \
        '[
          {"name":"BIOS version retrieved", "ok":$bios_ok, "value":($bios_ok|tostring)},
          {"name":"Firmware enumeration", "ok":true, "value":"dmidecode/ethtool/smartctl executed"},
          {"name":"Manual comparison required", "ok":($st=="INFO"), "value":"Human review needed"}
        ]')
      ;;

    15) # I/O Performance
      criteria="使用 fio 執行順序讀寫測試以評估磁碟 I/O 效能。若 RUN_FIO=0 則 SKIP；若無 fio 指令則 FAIL。測試檔案路徑、大小、block size、jobs 數量由環境變數控制（FIO_FILE、FIO_SIZE、FIO_BS、FIO_NUMJOBS_READ）。測試完成後提取 Write/Read 頻寬並與最低門檻值（IO_WRITE_MIN、IO_READ_MIN）比較。"
      pass_rules='["RUN_FIO=1", "fio 指令存在", "Write >= IO_WRITE_MIN MB/s", "Read >= IO_READ_MIN MB/s"]'
      warn_rules='["Write < IO_WRITE_MIN 或 Read < IO_READ_MIN"]'
      fail_rules='["RUN_FIO=1 但 fio 不存在"]'
      skip_rules='["RUN_FIO=0（未啟用 fio 測試）"]'

      th_json=$(jq -n \
        --argjson run_fio "${RUN_FIO:-0}" \
        --argjson write_min "${IO_WRITE_MIN:-100}" \
        --argjson read_min "${IO_READ_MIN:-100}" \
        '{"RUN_FIO":$run_fio, "IO_WRITE_MIN":$write_min, "IO_READ_MIN":$read_min}')

      local fio_enabled=false
      local fio_exists=false
      (( RUN_FIO )) && fio_enabled=true
      command -v fio >/dev/null 2>&1 && fio_exists=true

      checks_json=$(jq -n \
        --argjson enabled "$fio_enabled" \
        --argjson exists "$fio_exists" \
        --arg st "$st" \
        --arg note_val "$note" \
        '[
          {"name":"RUN_FIO enabled", "ok":$enabled, "value":($enabled|tostring)},
          {"name":"fio command exists", "ok":($enabled==false or $exists), "value":(if $enabled then ($exists|tostring) else "N/A" end)},
          {"name":"Test result", "ok":($st!="FAIL"), "value":$note_val}
        ]')
      ;;

    *) # Default for other items
      criteria="Legacy check: $item_name"
      pass_rules='["項目檢查通過"]'
      warn_rules='["項目檢查發現警告"]'
      fail_rules='["項目檢查失敗"]'
      skip_rules='["項目檢查跳過"]'
      info_rules='["項目提供資訊"]'

      checks_json=$(jq -n --arg status "$st" --arg reason "$note" \
        '[{"name":"Status","ok":($status=="PASS" or $status=="INFO" or $status=="SKIP"),"value":$status},
          {"name":"Reason","ok":true,"value":$reason}]')
      ;;
  esac

  # Build policy_json based on available rules
  local policy_json
  if [[ "$id" == "9" || "$id" == "11" || "$id" == "14" ]]; then
    # INFO or SKIP items with specific rules
    if [[ -n "$info_rules" ]]; then
      policy_json=$(jq -n --argjson info "$info_rules" '{"info":$info}')
    elif [[ -n "$skip_rules" ]]; then
      policy_json=$(jq -n --argjson skip "$skip_rules" '{"skip":$skip}')
    else
      policy_json='{}'
    fi
  elif [[ "$id" == "15" ]]; then
    # I/O Perf can be SKIP, FAIL, or INFO
    case "$st" in
      SKIP)
        policy_json=$(jq -n --argjson skip "$skip_rules" '{"skip":$skip}')
        ;;
      FAIL)
        policy_json=$(jq -n --argjson pass "$pass_rules" --argjson warn "$warn_rules" --argjson fail "$fail_rules" \
          '{"pass":$pass, "warn":$warn, "fail":$fail}')
        ;;
      *)
        policy_json=$(jq -n --argjson pass "$pass_rules" --argjson warn "$warn_rules" --argjson fail "$fail_rules" \
          '{"pass":$pass, "warn":$warn, "fail":$fail}')
        ;;
    esac
  else
    # Items with full PASS/WARN/FAIL rules (6, 10, 13)
    policy_json=$(jq -n --argjson pass "$pass_rules" --argjson warn "$warn_rules" --argjson fail "$fail_rules" \
      '{"pass":$pass, "warn":$warn, "fail":$fail}')
  fi

  # 組合 judgement
  local jdg_json
  jdg_json=$(jq -n \
    --arg criteria "$criteria" \
    --argjson policy "$policy_json" \
    --argjson checks "$checks_json" \
    --argjson thresholds "$th_json" \
    '{"criteria":$criteria, "policy":$policy, "checks":$checks, "thresholds":$thresholds}')

  # 生成完整的 JSON 結果並同步到 ALL_CHECK_RESULTS
  local full_json
  full_json=$(jq -n \
    --arg status "$st" \
    --arg item "$item_name" \
    --arg reason "$note" \
    --argjson judgement "$jdg_json" \
    '{"status":$status, "item":$item, "reason":$reason, "judgement":$judgement}')

  ALL_CHECK_RESULTS["$id"]="$full_json"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || echo "[警告] 缺少指令: $1"
}

echo "[Info] 指令存在檢查"
STORCLI_BASE_BIN=$(echo "$STORCLI_BIN" | awk '{print $NF}')
STORCLI_BASE_BIN=${STORCLI_BASE_BIN//sudo/}
STORCLI_BASE_BIN=$(echo "$STORCLI_BASE_BIN" | xargs)
for c in ipmitool smartctl lsblk dmidecode sensors ethtool lscpu mpstat sar free awk sed grep fio nvme chronyc timedatectl ss iperf3 hostnamectl jq; do
  need_cmd "$c"
done
# storcli 可選 (不列為硬性失敗)
if [[ -n "$STORCLI_BASE_BIN" ]]; then
  need_cmd "$STORCLI_BASE_BIN"
fi

# ---------- ipmi helper ----------
ipmi_try(){
  local CMD=("$@")
  if (( SKIP_BMC )); then
    echo "[ipmi_try SKIP] BMC check skipped." >&2
    return 1
  fi
  if [[ -z "${BMC_IP}" || -z "${BMC_USER}" || -z "${IPMI_PASSWORD:-}" ]]; then
    echo "[ipmi_try FAIL] BMC connection parameters are incomplete." >&2
    return 1
  fi
  if ! command -v ipmitool >/dev/null 2>&1; then
    echo "[ipmi_try FAIL] ipmitool command not found." >&2
    return 1
  fi

  local out rc=0
  
  # Try lanplus
  out=$(timeout ${IPMI_TIMEOUT}s ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -E "${CMD[@]}" 2>&1)
  rc=$?
  if (( rc == 0 )); then echo "$out"; return 0; fi
  local err_lanplus="$out" # Save error for later

  # Try lanplus with C17
  out=$(timeout ${IPMI_TIMEOUT}s ipmitool -I lanplus -C17 -H "$BMC_IP" -U "$BMC_USER" -E "${CMD[@]}" 2>&1)
  rc=$?
  if (( rc == 0 )); then echo "$out"; return 0; fi

  # Try lan
  out=$(timeout ${IPMI_TIMEOUT}s ipmitool -I lan -H "$BMC_IP" -U "$BMC_USER" -E "${CMD[@]}" 2>&1)
  rc=$?
  if (( rc == 0 )); then echo "$out"; return 0; fi

  # All attempts failed. Print the first captured error to stderr and return 1.
  echo "[ipmi_try FAIL] All IPMI attempts failed. First error:" >&2
  echo "$err_lanplus" >&2
  return 1
}

hr(){ echo "----------------------------------------------"; }

# === CONSOLIDATE START ===
# [NEW] Functions ported/adapted from public_report_builder.sh

item_regex(){
  case "$1" in
    1) echo '(psu|power (fail|down)|volt(age)? (fail|fault)|redundancy lost|ac lost)';;
    2) echo '(raid|rebuild|rbld|degrad|vd .* (dgrd|offln|flt|fail)|predict(ive)?|foreign|drive .*fail|pd .*fail)';;
    3) echo '(ecc|edac|mce|uncorrect|corrected|memory error)';;
    4) echo '(thermal (trip|throttle)|overheat|cpu .*fail)';;
    7) echo '(fan.*(fail|fault|lower|stop)|tach)';;
    8) echo '(inlet .*over|ambient .*over|temp(erature)?.*critical|overheat)';;
    12) echo '(fail|failure|degrad|ecc|uncorrect|thermal|overheat|ac lost|power down|voltage failure|fan failure|predict)';;
    *) echo '';;
  esac
}

sel_is_noise(){
  local l="$1"
  [[ "$l" == *"pef action"* || "$l" == *"drive present"* || "$l" == *"power button pressed"* || "$l" == *"001c4c"* ]]
}

trim(){ sed 's/^ *//;s/ *$//' ; }

float_gt(){
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { exit ((a+0) > (b+0)) ? 0 : 1 }'
}

float_ge(){
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { exit ((a+0) >= (b+0)) ? 0 : 1 }'
}

# —— 安全數值工具 —— #
# 將輸入清理成數字或 0，避免算術展開錯誤
num_or_0() { printf '%s' "${1:-0}" | awk 'BEGIN{v=0} {if($0 ~ /^-?[0-9]+(\.[0-9]+)?$/) v=$0; print v}'; }
# a>=b -> exit 0 (成功)
ge() { awk -v a="$(num_or_0 "$1")" -v b="$(num_or_0 "$2")" 'BEGIN{exit (a>=b)?0:1}'; }
# a>b -> exit 0 (成功)
gt() { awk -v a="$(num_or_0 "$1")" -v b="$(num_or_0 "$2")" 'BEGIN{exit (a>b)?0:1}'; }

last_event_epoch_in_sel(){
  local sel="$1" now_epoch="$2" since_days="$3" regex="$4"
  [[ -z "$sel" || ! -f "$sel" || -z "$regex" ]] && { echo ""; return; }
  local cutoff=$(( now_epoch - since_days*86400 ))
  local last=0
  while IFS=$'\n' read -r line; do
    [[ -z "$line" || "$line" != *"|"* ]] && continue
    local cnt; cnt=$(grep -o '|' <<< "$line" | wc -l)
    (( cnt < 5 )) && continue
    grep -qi 'Deasserted' <<< "$line" && continue
    IFS='|' read -r f1 f2 f3 f4 f5 rest <<< "$line"
    f2=$(printf '%s' "$f2" | trim); f3=$(printf '%s' "$f3" | trim)
    local ts; ts=$(date -d "$f2 $f3" +%s 2>/dev/null || echo "")
    [[ -z "$ts" ]] && continue
    (( ts < cutoff )) && continue
    local low; low=$(echo "$line" | tr '[:upper:]' '[:lower:]')
    sel_is_noise "$low" && continue
    if echo "$low" | grep -Eiq "$regex"; then
      (( ts > last )) && last=$ts
    fi
  done < "$sel"
  [[ "$last" -gt 0 ]] && echo "$last" || echo ""
}

is_recovered(){
  local item="$1" sel="$2" now_epoch="$3" since_days="$4" recover_days="$5"
  local re re_last cutoff
  re="$(item_regex "$item")"
  [[ -z "$re" ]] && return 1
  re_last="$(last_event_epoch_in_sel "$sel" "$now_epoch" "$since_days" "$re")"
  [[ -z "$re_last" ]] && return 1
  cutoff=$(( now_epoch - recover_days*86400 ))
  (( re_last < cutoff )) && return 0 || return 1
}

to_mbps(){
  local val="$1" unit="$2"  # unit in {K,M,G}
  case "$unit" in
    G|g) awk -v v="$val" 'BEGIN{printf "%.0f", v*1000}' ;;
    M|m) awk -v v="$val" 'BEGIN{printf "%.0f", v}' ;;
    K|k) awk -v v="$val" 'BEGIN{printf "%.3f", v/1000}' ;;
    *) echo "$val" ;;
  esac
}

to_mbs(){ # MiB/s or MB/s to MB/s
  local val="$1" unit="$2" # unit in {MiB/s,MB/s,KiB/s}
  case "$unit" in
    MiB/s|MiB) awk -v v="$val" 'BEGIN{printf "%.1f", v*1.048576}' ;;
    KiB/s|KiB) awk -v v="$val" 'BEGIN{printf "%.3f", v/1024}' ;;
    *) awk -v v="$val" 'BEGIN{printf "%.1f", v}' ;;
  esac
}

net_status_from_log(){
  local lf="$1"
  [[ -z "$lf" || ! -f "$lf" ]] && { echo ""; return; }

  local offline ping_ok=-1 iperf_mbps=0

  offline=$(grep -m1 -Eo 'offline=([01])' "$lf" | awk -F= '{print $2}' || echo "")
  if grep -Eiq '([0-9]+)% packet loss' "$lf"; then
    local loss; loss=$(grep -Eio '([0-9]+)% packet loss' "$lf" | tail -n1 | awk '{print $1}' | tr -d '%')
    if [[ -n "$loss" ]]; then
      if (( loss == 100 )); then ping_ok=0
      elif (( loss == 0 )); then ping_ok=1
      else ping_ok=1
      fi
    fi
  elif grep -Eiq 'rtt min/avg/max|bytes from' "$lf"; then
    ping_ok=1
  elif grep -Eiq 'destination host unreachable|network is unreachable|time[ -]out' "$lf"; then
    ping_ok=0
  fi

  local line bw unit
  line=$(grep -E 'iperf(3)? .* (sender|receiver)' "$lf" | tail -n1 || true)
  if [[ -z "$line" ]]; then
    line=$(grep -E '([0-9.]+) *[KMG]bits/sec' "$lf" | tail -n1 || true)
  fi
  if [[ -n "$line" ]]; then
    bw=$(echo "$line" | grep -Eo '([0-9]+(\.[0-9]+)?) *[KMG]bits/sec' | tail -n1 | awk '{print $1}')
    unit=$(echo "$line" | grep -Eo '([0-9]+(\.[0-9]+)?) *[KMG]bits/sec' | tail -n1 | sed -E 's/.*([KMG])bits\/sec/\1/')
    [[ -n "$bw" && -n "$unit" ]] && iperf_mbps=$(to_mbps "$bw" "$unit")
  fi

  if [[ "${offline:-}" == "1" && $ping_ok -lt 0 && $iperf_mbps -eq 0 ]]; then
    echo "INFO|Offline mode"
    return
  fi
  if (( ping_ok == 0 )); then
    echo "FAIL|Ping failed"
    return
  fi
  if (( $(awk -v v1="$iperf_mbps" -v v2="$NET_IPERF_MIN" 'BEGIN{print (v1>0 && v1<v2)?1:0}') )); then
    echo "WARN|iperf throughput ${iperf_mbps}Mbps < ${NET_IPERF_MIN}Mbps"
    return
  fi
  if (( ping_ok == 1 )); then
    echo "PASS|Ping OK, iperf ${iperf_mbps}Mbps"
    return
  fi
  if (( $(awk -v v1="$iperf_mbps" -v v2="$NET_IPERF_MIN" 'BEGIN{print (v1>=v2)?1:0}') )); then
    echo "PASS|iperf ${iperf_mbps}Mbps"
    return
  fi
  echo "INFO|No specific network issues detected"
}

parse_if_blocks(){
  local lf="$1"
  awk '
    /^-- / { gsub(/\r/,""); iface=$2; sub(/--/,"",iface); sub(/--$/,"",iface); gsub(/^[ \t]+|[ \t]+$/,""); next }
    /Speed:/   { s=$2; spd=""; if (s ~ /Unknown/) { spd="" } else if (s ~ /([0-9]+)Mb\/s/) { spd=gensub(/.* ([0-9]+)Mb\/s.*/,"\\1","g",$0) } }
    /Duplex:/  { d=$2; if (d ~ /Full|Half/) { dup=d } else { dup="" } }
    /Link detected:/ { ld=$3; if (ld ~ /yes|no/) { link=ld } else { link="" }
      if (iface!="") {
        print iface "|" (spd==""?"":spd) "|" (dup==""?"":dup) "|" (link==""?"":link)
      }
      spd=""; dup=""; link="";
    }
  ' "$lf" 2>/dev/null | sed '/^$/d'
}

count_flaps(){
  local lf="$1"
  grep -Eci 'link (is )?(up|down)' "$lf" 2>/dev/null || echo 0
}

cabling_status_from_log(){
  local lf="$1"
  [[ -z "$lf" || ! -f "$lf" ]] && { echo "SKIP|Log file not found"; return; }

  local flaps; flaps=$(count_flaps "$lf")
  local lines; mapfile -t lines < <(parse_if_blocks "$lf")
  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "INFO|No ethtool interface data found in log"
    return
  fi

  declare -A IF_SPEED IF_DUP IF_LINK
  local l iface sp dup link
  for l in "${lines[@]}"; do
    IFS='|' read -r iface sp dup link <<< "$l"
    IF_SPEED["$iface"]="${sp:-}"
    IF_DUP["$iface"]="${dup:-}"
    IF_LINK["$iface"]="${link:-}"
  done

  local ignore_re="$CABLE_IGNORE_REGEX"
  declare -a uplist
  if [[ -n "${CABLE_UPLINK_IFACES}" ]]; then
    IFS=',' read -r -a uplist <<< "${CABLE_UPLINK_IFACES}"
  else
    for iface in "${!IF_LINK[@]}"; do
      if [[ "$iface" =~ $ignore_re ]]; then continue; fi
      uplist+=("$iface")
    done
  fi

  local have_any=0 have_yes=0 warn_reason=""
  local min_mbps="$CABLE_MIN_MBPS"
  local warn_half="$CABLE_WARN_HALF"
  local max_flaps="$CABLE_MAX_FLAPS"
  local yes_cnt=0 no_cnt=0
  local summary_ifaces=()

  for iface in "${uplist[@]}"; do
    [[ -z "$iface" ]] && continue
    if [[ "$iface" =~ $ignore_re ]]; then continue; fi
    have_any=1
    sp="${IF_SPEED[$iface]:-}"
    dup="${IF_DUP[$iface]:-}"
    link="${IF_LINK[$iface]:-}"

    if [[ "$link" == "yes" ]]; then ((yes_cnt++)); have_yes=1; fi
    if [[ "$link" == "no" ]]; then ((no_cnt++)); fi

    if [[ -n "$sp" && "$sp" -lt "$min_mbps" ]]; then warn_reason+="${iface}:speed<${min_mbps}Mbps;"; fi
    if (( warn_half )) && [[ "${dup,,}" == "half" ]]; then warn_reason+="${iface}:half-duplex;"; fi
    if [[ "$link" == "no" ]]; then warn_reason+="${iface}:link=no;"; fi

    local sp_show=${sp:-?}; local dup_show=${dup:-?}; local lnk_show=${link:-?}
    summary_ifaces+=("${iface}=${sp_show}/${dup_show}/${lnk_show}")
  done

  if [[ "${have_any:-0}" == "0" ]]; then
    echo "INFO|No uplink interfaces found to check"
    return
  fi
  if [[ "${have_yes:-0}" == "0" ]]; then
    echo "FAIL|All uplinks down. Details: ${summary_ifaces[*]}. Flaps: $flaps"
    return
  fi
  if gt "$flaps" "$max_flaps"; then warn_reason+="flaps(${flaps})>${max_flaps};"; fi
  if [[ "${no_cnt:-0}" != "0" ]] || [[ -n "$warn_reason" ]]; then
    echo "WARN|${warn_reason} Uplinks: ${summary_ifaces[*]}. Flaps: $flaps"
    return
  fi
  echo "PASS|Uplinks OK: ${summary_ifaces[*]}. Flaps: $flaps"
}

io_status_from_log(){
  local lf="$1"
  [[ -z "$lf" || ! -f "$lf" ]] && { echo ""; return; }

  # NOTE: The check for 'I/O error' strings was removed from this function
  # as per user request. Item 15 is now a pure performance metric.
  # Critical I/O errors are now detected by the Item 13 log analysis.

  local r_line w_line r_val r_unit w_val w_unit r_mb w_mb
  r_line=$(grep -E 'read:.*BW=' "$lf" | tail -n1 || true)
  w_line=$(grep -E 'write:.*BW=' "$lf" | tail -n1 || true)

  r_mb=0; w_mb=0
  if [[ -n "$r_line" ]]; then
    r_val=$(echo "$r_line" | grep -Eo 'BW=([0-9]+(\.[0-9]+)?) *(MiB/s|MB/s|KiB/s)' | awk -F'[= ]' '{print $2}')
    r_unit=$(echo "$r_line" | grep -Eo 'BW=([0-9]+(\.[0-9]+)?) *(MiB/s|MB/s|KiB/s)' | awk '{print $NF}')
    [[ -n "$r_val" && -n "$r_unit" ]] && r_mb=$(to_mbs "$r_val" "$r_unit")
  fi
  if [[ -n "$w_line" ]]; then
    w_val=$(echo "$w_line" | grep -Eo 'BW=([0-9]+(\.[0-9]+)?) *(MiB/s|MB/s|KiB/s)' | awk -F'[= ]' '{print $2}')
    w_unit=$(echo "$w_line" | grep -Eo 'BW=([0-9]+(\.[0-9]+)?) *(MiB/s|MB/s|KiB/s)' | awk '{print $NF}')
    [[ -n "$w_val" && -n "$w_unit" ]] && w_mb=$(to_mbs "$w_val" "$w_unit")
  fi

  if (( $(awk -v r="$r_mb" 'BEGIN{print (r==0)?1:0}') )); then
    local dd_r; dd_r=$(grep -E 'read.* ([0-9]+(\.[0-9]+)?) *MB/s' "$lf" | tail -n1 | grep -Eo '([0-9]+(\.[0-9]+)?) *MB/s' | awk '{print $1}' || true)
    [[ -n "$dd_r" ]] && r_mb="$dd_r"
  fi
  if (( $(awk -v w="$w_mb" 'BEGIN{print (w==0)?1:0}') )); then
    local dd_w; dd_w=$(grep -E 'write.* ([0-9]+(\.[0-9]+)?) *MB/s' "$lf" | tail -n1 | grep -Eo '([0-9]+(\.[0-9]+)?) *MB/s' | awk '{print $1}' || true)
    [[ -n "$dd_w" ]] && w_mb="$dd_w"
  fi

  if (( $(awk -v r="$r_mb" -v w="$w_mb" 'BEGIN{print (r==0 && w==0)?1:0}') )); then
    echo "INFO|No fio performance data found in log"; return
  fi

  local r_ok=0 w_ok=0
  (( $(awk -v r="$r_mb" -v min="$IO_READ_MIN" 'BEGIN{print (r>=min)?1:0}') )) && r_ok=1
  (( $(awk -v w="$w_mb" -v min="$IO_WRITE_MIN" 'BEGIN{print (w>=min)?1:0}') )) && w_ok=1

  # 將空值正規化為 0，避免算術解析錯誤
  r_ok="${r_ok:-0}"
  w_ok="${w_ok:-0}"

  if [[ "$r_ok" == "1" && "$w_ok" == "1" ]]; then
    echo "PASS|Read=${r_mb}MB/s, Write=${w_mb}MB/s"
  else
    local reason_parts=()
    [[ "$r_ok" != "1" ]] && reason_parts+=("Read=${r_mb}MB/s(<${IO_READ_MIN})")
    [[ "$w_ok" != "1" ]] && reason_parts+=("Write=${w_mb}MB/s(<${IO_WRITE_MIN})")
    local reason
    IFS=';'
    reason="${reason_parts[*]}"
    IFS=$' \t\n'
    echo "WARN|$reason"
  fi
}

# [NEW]
get_item_tips() {
  local id="$1"
  # These heredocs expand variables like $BMC_IP at runtime.
  case "$id" in
    1) cat <<TIPS
ipmitool -I lanplus -H "${BMC_IP:-<ip>}" -U "${BMC_USER:-<user>}" -E sel list | grep -Ei 'psu|power|volt'
ipmitool -I lanplus -H "${BMC_IP:-<ip>}" -U "${BMC_USER:-<user>}" -E sdr elist | grep -Ei 'Power|PSU|Volt'
TIPS
    ;;
    2) cat <<TIPS
${STORCLI_BIN:-/opt/MegaRAID/storcli/storcli64} show all | less
sudo smartctl -H -A /dev/sdX  # Replace sdX with the correct device
nvme smart-log /dev/nvme0n1 # Replace with correct device
TIPS
    ;;
    3) cat <<TIPS
dmesg | grep -Ei 'mce|edac|ecc'
journalctl -k | grep -Ei 'mce|edac|ecc'
TIPS
    ;;
    4) cat <<TIPS
sensors | grep -Ei 'cpu|core|temp'
lscpu && journalctl -k | grep -Ei 'thermal|throttle'
TIPS
    ;;
    5) cat <<TIPS
ip -s link show
ethtool -S <iface> | egrep 'err|drop|crc' # Replace <iface>
TIPS
    ;;
    6) cat <<TIPS
nvidia-smi -q -d TEMPERATURE,POWER
dmesg | grep -i nvidia
TIPS
    ;;
    7) cat <<TIPS
sensors | grep -Ei 'fan'
ipmitool -I lanplus -H "${BMC_IP:-<ip>}" -U "${BMC_USER:-<user>}" -E sdr elist | grep -i fan
TIPS
    ;;
    8) cat <<TIPS
sensors | egrep -i 'inlet|ambient|temp'
ipmitool -I lanplus -H "${BMC_IP:-<ip>}" -U "${BMC_USER:-<user>}" -E sdr elist | egrep -i 'inlet|ambient|temp'
TIPS
    ;;
    9) cat <<TIPS
./ups_analyze.sh --json "${UPS_JSON_PATH}" # If used
upsc <upsname>@<host> 2>/dev/null || echo 'NUT not configured or command failed'
TIPS
    ;;
    10) cat <<TIPS
ping -c 5 "${PING_HOST:-8.8.8.8}"
iperf3 -c "${IPERF_TARGET:-<target>}" -t ${IPERF_TIME:-8}
TIPS
    ;;
    11) cat <<TIPS
ethtool <iface> | egrep 'Speed|Duplex|Link detected' # Replace <iface>
grep -i 'link down' /var/log/syslog | tail
TIPS
    ;;
    12) cat <<TIPS
ipmitool -I lanplus -H "${BMC_IP:-<ip>}" -U "${BMC_USER:-<user>}" -E sel elist
ipmitool -I lanplus -H "${BMC_IP:-<ip>}" -U "${BMC_USER:-<user>}" -E sensor
TIPS
    ;;
    13) cat <<TIPS
journalctl -p 3 -xb
dmesg -T | tail -n 200
TIPS
    ;;
    14) cat <<TIPS
fwupdmgr get-devices
dmidecode -t bios
TIPS
    ;;
    15) cat <<TIPS
fio --filename "${FIO_FILE:-/tmp/fio.bin}" --name=read --rw=read --bs=1M --numjobs=4 --size=${FIO_SIZE:-1G} --direct=1 --group_reporting
iostat -x 1 3
TIPS
    ;;
  esac
}
# === CONSOLIDATE END ===

# ----------------- 1 PSU -----------------
check_psu() {
    local item="PSU.Status"
    echo -e "${C_BLUE}[1] 電源供應器 (PSU)${C_RESET}"

    if (( SKIP_BMC )); then
        local skip_json=$(jq -n --arg item "$item" '{status:"SKIP", item:$item, reason:"BMC skipped"}')
        set_check_result 1 "$skip_json"
        return
    fi

    # Define paths
    local chassis_log="${LOG_DIR}/ipmi_chassis_status_${TIMESTAMP}.log"
    local sel_log="${LOG_DIR}/ipmi_sel_psu_${TIMESTAMP}.log"
    local metrics_path="${LOG_DIR}/psu/metrics_${TIMESTAMP}.json"
    mkdir -p "${LOG_DIR}/psu"

    # --- Check Chassis Status ---
    local chassis_out
    chassis_out=$(ipmi_try chassis status)
    local chassis_rc=$?
    echo "$chassis_out" > "$chassis_log"

    if (( chassis_rc != 0 )); then
        local reason="IPMI command to get chassis status failed."
        local fail_json=$(jq -n --arg item "$item" --arg reason "$reason" --argjson evidence "{\"chassis_log\":\"$chassis_log\"}" \
            '{status:"FAIL", item:$item, reason:$reason, evidence:$evidence}')
        set_check_result 1 "$fail_json"
        return
    fi

    local psu_fail_count
    psu_fail_count=$(echo "$chassis_out" | grep -c -i 'failure detected')
    local psu_status_summary
    psu_status_summary=$(echo "$chassis_out" | grep -i 'Power Supply')

    # --- Check SEL for recent events ---
    local sel_out
    sel_out=$(ipmi_try sel list 2>/dev/null | egrep -i 'psu|power fail|volt fail|fault' || true)
    echo "$sel_out" > "$sel_log"
    local sel_count=0
    if [[ -n "$sel_out" ]]; then
        sel_count=$(echo "$sel_out" | wc -l)
    fi

    # --- Determine Status ---
    local final_status="PASS"
    local final_reason="PSU status is normal."
    
    if (( psu_fail_count > 0 )); then
        final_status="FAIL"
        final_reason="Chassis status reports ${psu_fail_count} PSU failure(s). Details: ${psu_status_summary}"
    elif (( sel_count > 0 )); then
        final_status="WARN"
        final_reason="PSU status appears OK, but found ${sel_count} related events in SEL. Please review."
    fi

    local metrics_json
    metrics_json=$(jq -n --argjson psu_fail "$psu_fail_count" --argjson sel_events "$sel_count" \
        '{chassis_psu_failures:$psu_fail, sel_power_events:$sel_events}')
    local evidence_json
    evidence_json=$(jq -n --arg chassis "$chassis_log" --arg sel "$sel_log" \
        '{chassis_log:$chassis, sel_log:$sel}')

    local final_json
    final_json=$(jq -n \
        --arg status "$final_status" \
        --arg item "$item" \
        --argjson metrics "$metrics_json" \
        --argjson evidence "$evidence_json" \
        --arg reason "$final_reason" \
        '{status: $status, item: $item, metrics: $metrics, evidence: $evidence, reason: $reason}')

    # --- Build judgement ---
    local th_json
    th_json=$(jq -n --arg sel_days "$SEL_DAYS" '{SEL_DAYS: ($sel_days|tonumber)}')

    local checks_json
    checks_json=$(jq -n \
      --arg chassis_rc "$( [[ $chassis_rc -eq 0 ]] && echo 0 || echo 1 )" \
      --arg psu_fail_count "$psu_fail_count" \
      --arg sel_count "$sel_count" \
      --arg chassis_log "$chassis_log" \
      --arg sel_log "$sel_log" \
      '[{"name":"ipmitool chassis status rc==0","ok":($chassis_rc|tonumber==0),"value":("rc="+$chassis_rc)},
        {"name":"chassis 報告 PSU 故障數=0","ok":($psu_fail_count|tonumber==0),"value":("count="+$psu_fail_count)},
        {"name":"SEL 關聯事件=0（視窗內）","ok":($sel_count|tonumber==0),"value":("count="+$sel_count)},
        {"name":"evidence","ok":true,"value":("chassis="+$chassis_log+", sel="+$sel_log)}]')

    local pass_rules='["chassis rc==0 且 PSU 故障數=0 且 SEL 電源相關事件=0"]'
    local warn_rules='["chassis rc==0 且 PSU 故障數=0 但 SEL 有電源相關事件"]'
    local fail_rules='["chassis rc!=0 或 PSU 故障數>0"]'
    local criteria="PSU 正常：IPMI 正常、chassis 無 PSU failure、SEL 視窗內無電源/電壓故障事件"

    local jdg_json
    jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

    echo "$final_json" > "$metrics_path"
    set_check_result_with_jdg 1 "$final_json" "$jdg_json"
}

# ----------------- 2 Disks -----------------
RAID_SUMMARY_JSON="{}"            # 最終 JSON 片段
RAID_STATUS_IMPACT=""             # FAIL / WARN / "" (影響 item 2)
RAID_TMP_DIR="$(mktemp -d)"
RAID_REBUILD_PRESENT=0

# 決定實際執行 storcli 的命令 (可能需要 sudo)
resolve_storcli_cmd() {
  if [[ "$STORCLI_BIN" == sudo* ]]; then
    RAID_STORCLI_CMD="$STORCLI_BIN"
    return
  fi
  if [[ -x "$STORCLI_BIN" ]]; then
    RAID_STORCLI_CMD="$STORCLI_BIN"
    return
  fi
  if [[ -f "$STORCLI_BIN" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      RAID_STORCLI_CMD="sudo $STORCLI_BIN"
      return
    fi
  fi
  RAID_STORCLI_CMD="$STORCLI_BIN"
}

resolve_storcli_cmd

collect_raid_megaraid() {
  # 若 storcli 不存在或不能執行 → 直接返回
  echo "[RAID DEBUG] STORCLI_BIN='$STORCLI_BIN' RAID_STORCLI_CMD='$RAID_STORCLI_CMD'"
  real_bin="$RAID_STORCLI_CMD"
  real_bin="${real_bin#sudo }"
  real_bin="${real_bin%% *}"
  if [[ -z "$real_bin" ]]; then
    RAID_SUMMARY_JSON='{"overall":"SKIP","reason":"storcli_cmd_empty"}'
    return
  fi
  if ! command -v "$real_bin" >/dev/null 2>&1 && [[ ! -x "$real_bin" ]]; then
    echo "[RAID] 無法找到 storcli 執行檔: $real_bin"
    RAID_SUMMARY_JSON='{"overall":"SKIP","reason":"storcli_not_found"}'
    return
  fi

  # 先抓一次 system overview 文字，抽出 model 對照
  local sys_overview
  sys_overview=$($RAID_STORCLI_CMD show 2>/dev/null | tee /dev/stderr || true)
  declare -A CTL_MODEL
  while read -r line; do
    # 行首有控制器號碼 + 型號 → 取前兩欄
    # e.g. '  0 MegaRAID9560-16i8GB    16   2   1 ...'
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([A-Za-z0-9._-]+) ]]; then
      cid="${BASH_REMATCH[1]}"
      mdl="${BASH_REMATCH[2]}"
      CTL_MODEL["$cid"]="$mdl"
    fi
  done <<< "$sys_overview"


  local ctl_list=()
  if [[ -n "$RAID_CONTROLLER_LIST" ]]; then
    IFS=',' read -r -a ctl_list <<< "$RAID_CONTROLLER_LIST"
  else
    if out_json=$($RAID_STORCLI_CMD show J 2>/dev/null); then
      # 嘗試多種 key 取得 Controller ID
      mapfile -t ctl_list < <(echo "$out_json" | jq -r '
        .Controllers[]
        | (."Command Status".Controller
           // ."Command Status".ControllerID
           // ."Command".Controller
           // ."Command Status"."Controller"
           // empty)' 2>/dev/null)
    fi
    if [[ ${#ctl_list[@]} -eq 0 ]]; then
      local raw_show
      raw_show=$($RAID_STORCLI_CMD show 2>&1 | tee /dev/stderr || true)

      # 先試舊格式: 'Controller = 0'
      mapfile -t ctl_list < <(
        echo "$raw_show" | awk '/[Cc]ontroller *= *[0-9]+/ {
          for(i=1;i<=NF;i++){ if($i=="="){print $(i+1); break} }
        }' | tr -d ': ' | grep -E '^[0-9]+$' | sort -n | uniq
      )

      # 若還是空 → 用 'Number of Controllers = N'
      if [[ ${#ctl_list[@]} -eq 0 ]]; then
        local n
        n=$(echo "$raw_show" | grep -i 'Number of Controllers' | grep -Eo '[0-9]+' | head -n1 || echo "")
        if [[ -n "$n" && "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]; then
          for ((i=0;i<n;i++)); do ctl_list+=("$i"); done
          echo "[RAID DETECT] 由 'Number of Controllers = $n' 推導: ${ctl_list[*]}"
        else
          echo "[RAID DETECT] 無法從文字輸出偵測控制器"
        fi
      else
        echo "[RAID DETECT] 純文字模式抓到控制器: ${ctl_list[*]}"
      fi
    fi

  fi
  [[ ${#ctl_list[@]} -eq 0 ]] && { RAID_SUMMARY_JSON='{"overall":"SKIP","reason":"no_controllers"}'; return; }

  local controllers_json=()
  local worst="PASS"
  local agg_vd_total=0 agg_vd_dgrd=0 agg_vd_fail=0
  local agg_pd_total=0 agg_pd_fail=0 agg_pd_missing=0 agg_pd_hot=0 agg_pd_pred=0

  for cid in "${ctl_list[@]}"; do
    local ctag="/c${cid}"
    local raw_c_file="$RAID_TMP_DIR/raid_${cid}_controller.txt"
    local raw_pd_file="$RAID_TMP_DIR/raid_${cid}_pd.txt"
    local ctl_state="Unknown"
    local vd_total=0 vd_dgrd=0 vd_fail=0
    local pd_total=0 pd_fail=0 pd_missing=0 pd_hotspare=0 pd_predictive=0
    local bbu_state=""
    local rebuild_pct="" init_pct="" op_flags=()

    # 取 controller / VD
    if $RAID_STORCLI_CMD $ctag show 2>&1 | tee "$raw_c_file" | tee /dev/stderr >/dev/null; then
      # 解析 Virtual Drive 區塊
      # VD 行範例: "0 VD1 ... Optl" 或 "0 ... Dgrd"
      while read -r line; do
        [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]] ]] || continue
        echo "$line" | grep -qi 'VD' && continue
        # 抓最後欄位的狀態
        st=$(echo "$line" | awk '{print $NF}')
        [[ -z "$st" ]] && continue
        ((vd_total++))
        case "$st" in
          *Dgrd*|*dgrd*) ((vd_dgrd++));;
          *Flt*|*Offln*|*Fail*|*Dead*) ((vd_fail++));;
        esac
      done < <(grep -iE 'VD|Dgrd|Optl|Offln|Flt|Fail' "$raw_c_file")

      # 抓 Controller Status（找 Optimal / Degraded 關鍵字）
      if grep -qi 'Degraded' "$raw_c_file"; then
        ctl_state="Degraded"
      elif grep -qi 'Optimal' "$raw_c_file"; then
        ctl_state="Optimal"
      elif grep -qi 'Needs Attention' "$raw_c_file"; then
        ctl_state="Attention"
      else
        ctl_state=$(grep -i 'Status' "$raw_c_file" | head -n1 | awk -F= '{print $2}' | xargs || echo "Unknown")
      fi
      # 偵測 Rebuild / Initialize 百分比
      rebuild_pct=$(grep -Ei 'Rebuild|Rbld' "$raw_c_file" | grep -Eo '[0-9]+%' | head -n1 || true)
      init_pct=$(grep -Ei 'Init' "$raw_c_file" | grep -Eo '[0-9]+%' | head -n1 || true)
      [[ -n "$rebuild_pct" ]] && op_flags+=("rebuild=$rebuild_pct")
      [[ -n "$init_pct" ]] && op_flags+=("init=$init_pct")
      if [[ -n "$rebuild_pct" || -n "$init_pct" ]]; then
        RAID_REBUILD_PRESENT=1
      fi      
    fi

    # 取所有 PD
    if $RAID_STORCLI_CMD $ctag /eall /sall show 2>&1 | tee "$raw_pd_file" | tee /dev/stderr >/dev/null; then
      # 行範例包含 Onln / UGood / Gd / Dhs / Flt / Msng / Ubad / Pred
      while read -r line; do
        [[ "$line" =~ ^[[:space:]]*E[0-9]+:S[0-9]+ ]] || [[ "$line" =~ ^[0-9]+:[0-9]+ ]] || continue
        ((pd_total++))
        lcl=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        if   echo "$lcl" | grep -q 'hotspare'; then ((pd_hotspare++))
        elif echo "$lcl" | grep -q 'dhs'; then ((pd_hotspare++))
        fi
        if echo "$lcl" | grep -Eq 'flt|offln|fail|ubad'; then ((pd_fail++)); fi
        if echo "$lcl" | grep -Eq 'msng|missing'; then ((pd_missing++)); fi
        if echo "$lcl" | grep -Eq 'ugood|pred'; then ((pd_predictive++)); fi
      done < "$raw_pd_file"
      # BBU 狀態 (若有)
      if grep -qi 'BBU' "$raw_c_file"; then
        bbu_state=$(grep -i 'BBU' -A4 "$raw_c_file" | grep -i 'Status' | head -n1 | awk -F= '{print $2}' | xargs)
      fi
    fi

    # 判斷單控制器等級
    local lvl="PASS"
    if (( vd_fail>0 || vd_dgrd>0 || pd_fail>0 )); then
      lvl="FAIL"
    elif (( pd_predictive>0 )); then
      lvl="WARN"
    elif (( pd_hotspare>0 )); then
      lvl="WARN"
    fi

    # 更新 overall
    case "$lvl" in
      FAIL) worst="FAIL";;
      WARN) [[ "$worst" != "FAIL" ]] && worst="WARN";;
    esac
    # 聚合
    ((agg_vd_total+=vd_total))
    ((agg_vd_dgrd+=vd_dgrd))
    ((agg_vd_fail+=vd_fail))
    ((agg_pd_total+=pd_total))
    ((agg_pd_fail+=pd_fail))
    ((agg_pd_missing+=pd_missing))
    ((agg_pd_hot+=pd_hotspare))
    ((agg_pd_pred+=pd_predictive))
  
    local rebuild_json='null'
    [[ -n "$rebuild_pct" || -n "$init_pct" ]] && rebuild_json="{\"rebuild_pct\":\"${rebuild_pct:-}\",\"init_pct\":\"${init_pct:-}\"}"

    controllers_json+=("{\"controller\":\"$cid\",\"model\":\"${CTL_MODEL[$cid]:-}\",\"status\":\"$ctl_state\",\"level\":\"$lvl\",\"vd\":{\"total\":$vd_total,\"degraded\":$vd_dgrd,\"failed\":$vd_fail},\"pd\":{\"total\":$pd_total,\"failed\":$pd_fail,\"missing\":$pd_missing,\"hotspare\":$pd_hotspare,\"predictive\":$pd_predictive},\"ops\":$rebuild_json,\"bbu\":{\"status\":\"${bbu_state:-}\"},\"raw_files\":{\"controller\":\"$raw_c_file\",\"pd\":\"$raw_pd_file\"}}")
  done

  # 若有 rebuild/init 且尚未 FAIL → overall 至少 WARN
  if (( RAID_REBUILD_PRESENT==1 )) && [[ "$worst" == "PASS" ]]; then
    worst="WARN"
  fi


  # 組 JSON
  {
    echo -n '{"overall":"'"$worst"'","agg":{"controllers":'${#ctl_list[@]}',"vd_total":'$agg_vd_total',"vd_degraded":'$agg_vd_dgrd',"vd_failed":'$agg_vd_fail',"pd_total":'$agg_pd_total',"pd_failed":'$agg_pd_fail',"pd_missing":'$agg_pd_missing',"pd_hotspare":'$agg_pd_hot',"pd_predictive":'$agg_pd_pred'},"controllers":['
    local first=1
    for j in "${controllers_json[@]}"; do
      if (( first )); then
        printf '%s' "$j"; first=0
      else
        printf ',%s' "$j"
      fi
    done
    echo ']}'
  } > "$RAID_TMP_DIR/raid_summary.json"
  RAID_SUMMARY_JSON=$(cat "$RAID_TMP_DIR/raid_summary.json")

  # 提供給 item 2 狀態覆寫
  case "$worst" in
    FAIL) RAID_STATUS_IMPACT="FAIL";;
    WARN) RAID_STATUS_IMPACT="WARN";;
    *) RAID_STATUS_IMPACT="";;
  esac
}

check_disks() {
    local item="Disks.RAID.SMART"
    echo -e "${C_BLUE}[2] 磁碟 / RAID / SMART${C_RESET}"

    # --- Sudo pre-check ---
    if ! sudo -n true 2>/dev/null; then
        local reason="無法免密碼執行 sudo，跳過 SMART/NVMe 詳細檢查。"

        # 建立 base JSON
        local base_json
        base_json=$(jq -n \
          --arg status "WARN" \
          --arg item "$item" \
          --arg reason "$reason" \
          --arg tips "$(get_item_tips 2)" \
          '{status:$status, item:$item, reason:$reason, tips:($tips|split("\n")|map(select(.!="")))}')

        # 判斷基準
        local pass_rules='["RAID 控制器/VD/PD 皆正常","SMART/NVMe 健康 OK"]'
        local warn_rules='["RAID 正常但 SMART/NVMe 因權限/工具缺失而跳過"]'
        local fail_rules='["RAID 降級/故障或 SMART/NVMe 顯示故障/預警"]'

        # 蒐集能拿到的事證（工具可用性、是否 root、storcli/nvme/smartctl）
        local can_storcli=false; command -v ${STORCLI_BIN%% *} >/dev/null 2>&1 && can_storcli=true
        local can_smart=false;   command -v smartctl >/dev/null 2>&1 && can_smart=true
        local can_nvme=false;    command -v nvme >/dev/null 2>&1 && can_nvme=true
        local is_root=false;     [[ "$(id -u)" == "0" ]] && is_root=true

        local checks_json
        checks_json=$(jq -n \
          --argjson stor "$can_storcli" \
          --argjson smt  "$can_smart" \
          --argjson nvm  "$can_nvme" \
          --argjson root "$is_root" \
          '[
            {"name":"storcli 可用","ok":$stor,"value":($stor|tostring)},
            {"name":"smartctl 可用","ok":$smt,"value":($smt|tostring)},
            {"name":"nvme 可用","ok":$nvm,"value":($nvm|tostring)},
            {"name":"root 權限","ok":$root,"value":($root|tostring)}
          ]')

        local th_json='{"SMART_REQUIRED":true,"NVME_REQUIRED":true,"ROOT_REQUIRED":true}'

        local criteria="磁碟健康：RAID/SMART/NVMe 檢查。無 root/免密碼時以 RAID 結果為主，SMART/NVMe 註記為跳過（WARN）。"
        local jdg_json
        jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

        set_check_result_with_jdg 2 "$base_json" "$jdg_json"
        collect_raid_megaraid
        return
    fi

    # --- Refactored Logic --- 
    lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,MOUNTPOINT || true
    
    local smart_results_json="[]"
    local nvme_results_json="[]"
    local overall_status="PASS"
    local reason_details=()

    # --- SMART (HDD/SSD) Check ---
    for d in /dev/sd?; do
        [[ -b "$d" ]] || continue
        echo "== $d =="
        local smart_output
        smart_output=$(sudo smartctl -A -H "$d" 2>/dev/null)
        if [[ -z "$smart_output" ]]; then continue; fi

        local health_status="PASS"
        if echo "$smart_output" | grep -qi 'FAILED'; then
            health_status="FAIL"
        elif echo "$smart_output" | grep -qi 'pre-fail'; then
            health_status="WARN"
        fi

        local reallocated; reallocated=$(echo "$smart_output" | awk '/Reallocated_Sector_Ct/ {print $10}'); [[ -z "$reallocated" ]] && reallocated=0
        local pending; pending=$(echo "$smart_output" | awk '/Current_Pending_Sector/ {print $10}'); [[ -z "$pending" ]] && pending=0
        local power_on; power_on=$(echo "$smart_output" | awk '/Power_On_Hours/ {print $10}'); [[ -z "$power_on" ]] && power_on=0

        if (( reallocated > 0 || pending > 0 )); then
            health_status="WARN"
        fi

        if [[ "$health_status" != "PASS" ]]; then
            reason_details+=("$d is $health_status (Reallocated:$reallocated, Pending:$pending)")
            if [[ "$health_status" == "FAIL" ]]; then overall_status="FAIL"; fi
            if [[ "$health_status" == "WARN" && "$overall_status" != "FAIL" ]]; then overall_status="WARN"; fi
        fi

        local disk_json=$(jq -n --arg dev "$d" --arg status "$health_status" --argjson re "$reallocated" --argjson pend "$pending" --argjson poh "$power_on" \
            '{device:$dev, status:$status, attributes:{reallocated_sectors:$re, pending_sectors:$pend, power_on_hours:$poh} }')
        smart_results_json=$(echo "$smart_results_json" | jq ". + [$disk_json]")
    done

    # --- NVMe Check ---
    if command -v nvme >/dev/null 2>&1; then
        for n in /dev/nvme?n1; do
            [[ -c "$n" ]] || continue # NVMe devices are char devices
            echo "== $n (nvme smart-log) =="
            local nvme_output
            nvme_output=$(sudo nvme smart-log "$n" 2>/dev/null)
            if [[ -z "$nvme_output" ]]; then continue; fi

            local crit_warn=$(echo "$nvme_output" | grep -i 'critical_warning' | awk -F: '{print $2}' | xargs)
            local temp=$(echo "$nvme_output" | grep -i 'temperature' | awk -F: '{print $2}' | xargs)
            local media_err=$(echo "$nvme_output" | grep -i 'media_errors' | awk -F: '{print $2}' | xargs)

            local nvme_status="PASS"
            if [[ "$crit_warn" != "0" ]]; then
                nvme_status="FAIL"
                reason_details+=("$n has critical_warning: $crit_warn")
                overall_status="FAIL"
            elif (( media_err > 0 )); then
                nvme_status="WARN"
                if [[ "$overall_status" != "FAIL" ]]; then overall_status="WARN"; fi
                reason_details+=("$n has media_errors: $media_err")
            fi

            local nvme_disk_json=$(jq -n --arg dev "$n" --arg status "$nvme_status" --argjson cw "$crit_warn" --arg temp "$temp" --argjson me "$media_err" \
                '{device:$dev, status:$status, attributes:{critical_warning:$cw, temperature_celsius:$temp, media_errors:$me} }')
            nvme_results_json=$(echo "$nvme_results_json" | jq ". + [$nvme_disk_json]")
        done
    fi

    # --- Software RAID Check ---
    local mdstat_status="NA" mdstat_reason=""
    local mdstat_json="null"
    if [[ -r /proc/mdstat ]]; then
        mdstat_status="PASS"
        mdstat_reason="mdadm status is clean."
        if grep -q 'degraded' /proc/mdstat; then
            mdstat_status="FAIL"; mdstat_reason="mdadm array is DEGRADED."
            overall_status="FAIL"
        elif grep -q 'resync' /proc/mdstat; then
            mdstat_status="WARN"; mdstat_reason="mdadm array is resyncing."
            if [[ "$overall_status" != "FAIL" ]]; then overall_status="WARN"; fi
        fi
        mdstat_json=$(jq -n --arg status "$mdstat_status" --arg reason "$mdstat_reason" '{status:$status, reason:$reason}')
    fi

    # --- Hardware RAID Check ---
    collect_raid_megaraid
    local raid_status=$(echo "$RAID_SUMMARY_JSON" | jq -r .overall 2>/dev/null || echo "SKIP")
    if [[ "$raid_status" == "FAIL" ]]; then
        overall_status="FAIL"
        reason_details+=("Hardware RAID status is FAIL.")
    elif [[ "$raid_status" == "WARN" && "$overall_status" != "FAIL" ]]; then
        overall_status="WARN"
        reason_details+=("Hardware RAID status is WARN.")
    fi

    # --- Final Aggregation ---
    local final_reason
    if [[ "$overall_status" == "PASS" ]]; then
        final_reason="All disk, RAID, and SMART checks passed."
    else
        final_reason=$(IFS=; echo "${reason_details[*]}")
    fi

    local metrics_json=$(jq -n \
        --argjson smart "$smart_results_json" \
        --argjson nvme "$nvme_results_json" \
        --argjson mdstat "$mdstat_json" \
        --argjson hwrail "$RAID_SUMMARY_JSON" \
        '{smart_devices:$smart, nvme_devices:$nvme, software_raid:$mdstat, hardware_raid:$hwrail}')

    local evidence_json
    evidence_json=$(jq -n --arg main_log "$LOG_TXT" '{main_output_log:$main_log}')

    local final_json
    final_json=$(jq -n \
        --arg status "$overall_status" \
        --arg item "$item" \
        --argjson metrics "$metrics_json" \
        --arg reason "$final_reason" \
        --argjson evidence "$evidence_json" \
        '{status: $status, item: $item, metrics: $metrics, reason: $reason, evidence: $evidence}')

    # --- Build judgement ---
    local vd_failed=$(echo "$RAID_SUMMARY_JSON" | jq -r '.vd_failed // 0' 2>/dev/null)
    local vd_degraded=$(echo "$RAID_SUMMARY_JSON" | jq -r '.vd_degraded // 0' 2>/dev/null)
    local pd_failed=$(echo "$RAID_SUMMARY_JSON" | jq -r '.pd_failed // 0' 2>/dev/null)
    local rebuild_present=$(echo "$RAID_SUMMARY_JSON" | jq -r '.rebuild_present // false' 2>/dev/null)

    local th_json='{}'  # Disks 項目無固定數值閾值

    local checks_json
    checks_json=$(jq -n \
      --arg raid_status "$raid_status" \
      --arg vd_failed "$vd_failed" \
      --arg vd_degraded "$vd_degraded" \
      --arg pd_failed "$pd_failed" \
      --arg rebuild "$rebuild_present" \
      --arg mdstat_status "$mdstat_status" \
      '[{"name":"硬體 RAID VD 故障=0","ok":($vd_failed|tonumber==0),"value":("vd_failed="+$vd_failed)},
        {"name":"硬體 RAID VD 降級=0","ok":($vd_degraded|tonumber==0),"value":("vd_degraded="+$vd_degraded)},
        {"name":"硬體 RAID PD 故障=0","ok":($pd_failed|tonumber==0),"value":("pd_failed="+$pd_failed)},
        {"name":"無 Rebuild/Init 進行中","ok":($rebuild!="true"),"value":("rebuild="+$rebuild)},
        {"name":"軟體 RAID 狀態","ok":($mdstat_status!="FAIL"),"value":("mdstat="+$mdstat_status)}]')

    local pass_rules='["VD/PD 故障=0 且 VD 降級=0 且無 Rebuild 且 SMART 無異常"]'
    local warn_rules='["Rebuild/Init 進行中 或 SMART 有 pre-fail/reallocated sectors 或軟體 RAID resyncing"]'
    local fail_rules='["VD 故障>0 或 PD 故障>0 或 VD 降級>0 或軟體 RAID degraded 或 SMART FAILED"]'
    local criteria="磁碟健康：硬體/軟體 RAID 無故障/降級、無 rebuild、SMART 屬性正常"

    local jdg_json
    jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

    set_check_result_with_jdg 2 "$final_json" "$jdg_json"
}

# ----------------- 3 Memory / ECC -----------------
check_memory() {
  local item="Memory.ECC"
  echo -e "${C_BLUE}[3] 記憶體 / ECC${C_RESET}"
  free -h || true

  local log_dir="$OUTPUT_DIR/memory"
  mkdir -p "$log_dir"
  local log_file="$log_dir/ecc_events_${TIMESTAMP}.log"

  local log_source=""
  local log_output=""

  if command -v journalctl >/dev/null 2>&1; then
    log_source="journalctl"
    echo "[INFO] Checking for ECC/MCE events via journalctl (last ${LOG_DAYS} days)."
    local journal_raw=""
    local journal_rc=0
    journal_raw=$(journalctl -k --since "${LOG_DAYS} days ago" 2>&1) || journal_rc=$?
    if (( journal_rc != 0 )); then
      local err_preview
      err_preview=$(echo "$journal_raw" | head -n1)
      [[ -z "$err_preview" ]] && err_preview="exit code $journal_rc"
      echo "$journal_raw" > "$log_file"

      local reason="journalctl 讀取失敗 (${err_preview}). 需要 root 或加入 systemd-journal 群組才能檢查 ECC/MCE。"
      local metrics_json
      metrics_json=$(jq -n '{corrected_errors:0, uncorrected_errors:0, other_matches:0, log_source:"journalctl"}')
      local evidence_json
      evidence_json=$(jq -n --arg file "$log_file" '{log_file:$file}')
      local result_json
      result_json=$(jq -n \
        --arg status "WARN" \
        --arg item "$item" \
        --arg reason "$reason" \
        --argjson metrics "$metrics_json" \
        --argjson evidence "$evidence_json" \
        '{status:$status,item:$item,reason:$reason,metrics:$metrics,evidence:$evidence}')
      set_check_result 3 "$result_json"
      return
    fi
    log_output=$(printf '%s\n' "$journal_raw" | egrep -i '\bedac\b|\becc\b|\bmce\b|machine check|hardware error' || true)
  else
    echo "[WARN] journalctl not found, attempting sudo dmesg for ECC/MCE check."
    if sudo -n true 2>/dev/null; then
      log_source="sudo dmesg"
      log_output=$(sudo -n dmesg 2>/dev/null | egrep -i '\bedac\b|\becc\b|\bmce\b|machine check|hardware error' || true)
    else
      local reason="journalctl 不可用且缺少免密碼 sudo 無法讀取 dmesg，無法檢查 ECC/MCE"
      local metrics_json
      metrics_json=$(jq -n '{corrected_errors:0, uncorrected_errors:0, other_matches:0, log_source:"unavailable"}')
      local evidence_json
      evidence_json=$(jq -n '{log_file:null}')
      local result_json
      result_json=$(jq -n \
        --arg status "WARN" \
        --arg item "$item" \
        --arg reason "$reason" \
        --argjson metrics "$metrics_json" \
        --argjson evidence "$evidence_json" \
        '{status:$status,item:$item,reason:$reason,metrics:$metrics,evidence:$evidence}')
      set_check_result 3 "$result_json"
      return
    fi
  fi

  echo "$log_output" > "$log_file"

  local corrected=0
  local uncorrected=0
  local other=0

  if [[ -n "$log_output" ]]; then
    echo "$log_output"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local lower=${line,,}
      # Categorize errors. Start with the most severe.
      if [[ $lower =~ (uncorrect|non[-\ ]recoverable|fatal|machine\ check|mce|hardware\ error) ]]; then
        ((uncorrected++))
      elif [[ $lower =~ (corrected|correctable|recover(ed|able)|soft\ error) ]]; then
        ((corrected++))
      elif [[ $lower =~ (error|fail|fault) ]]; then
        # Catch generic errors that weren't classified as corrected/uncorrected.
        # This avoids flagging informational messages like "EDAC MC: Ver: 3.0.0"
        ((other++))
      fi
    done <<< "$log_output"
  fi

  local status="PASS"
  local reason="過去 ${LOG_DAYS} 天內未偵測到 ECC/MCE 相關事件"

  if (( uncorrected > 0 )); then
    status="FAIL"
    reason="發現 ${uncorrected} 筆不可修正/嚴重記憶體錯誤，另外有 ${corrected} 筆可修正錯誤"
  elif (( corrected > 0 )); then
    status="WARN"
    reason="發現 ${corrected} 筆可修正記憶體錯誤 (不可修正錯誤 ${uncorrected} 筆)"
  elif (( other > 0 )); then
    status="WARN"
    reason="偵測到 ${other} 筆可能與記憶體錯誤相關的訊息，需人工確認"
  fi

  local metrics_json
  metrics_json=$(jq -n \
    --argjson corrected "$corrected" \
    --argjson uncorrected "$uncorrected" \
    --argjson other "$other" \
    --arg source "$log_source" \
    '{corrected_errors:$corrected,uncorrected_errors:$uncorrected,other_matches:$other,log_source:$source}')

  local evidence_json
  evidence_json=$(jq -n --arg file "$log_file" '{log_file:$file}')

  local result_json
  result_json=$(jq -n \
    --arg status "$status" \
    --arg item "$item" \
    --arg reason "$reason" \
    --argjson metrics "$metrics_json" \
    --argjson evidence "$evidence_json" \
    '{status:$status,item:$item,reason:$reason,metrics:$metrics,evidence:$evidence}')

  # --- Build judgement ---
  local th_json
  th_json=$(jq -n --arg log_days "$LOG_DAYS" '{LOG_DAYS: ($log_days|tonumber)}')

  local checks_json
  checks_json=$(jq -n \
    --arg corrected "$corrected" \
    --arg uncorrected "$uncorrected" \
    --arg other "$other" \
    --arg log_source "$log_source" \
    '[{"name":"不可修正錯誤=0","ok":($uncorrected|tonumber==0),"value":("uncorrected="+$uncorrected)},
      {"name":"可修正錯誤=0","ok":($corrected|tonumber==0),"value":("corrected="+$corrected)},
      {"name":"其他相關訊息=0","ok":($other|tonumber==0),"value":("other="+$other)},
      {"name":"Log 來源","ok":true,"value":$log_source}]')

  local pass_rules='["不可修正錯誤=0 且 可修正錯誤=0 且其他相關訊息=0"]'
  local warn_rules='["可修正錯誤>0 或 其他相關訊息>0 (但不可修正錯誤=0)"]'
  local fail_rules='["不可修正錯誤>0"]'
  local criteria="記憶體健康：LOG_DAYS 視窗內無不可修正 ECC/MCE 錯誤、可修正錯誤需為 0"

  local jdg_json
  jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

  set_check_result_with_jdg 3 "$result_json" "$jdg_json"
}

# ----------------- 4 CPU -----------------

check_cpu() {
    local item="CPU.Temp"
    echo -e "${C_BLUE}[4] CPU (溫度)${C_RESET}"
    lscpu | egrep 'Model name|Socket|Core|Thread|CPU MHz' || true

    # Define paths
    local raw_log_path="${LOG_DIR}/sensors_output_${TIMESTAMP}.log"
    local baseline_path="${LOG_DIR}/cpu_baseline.json"
    local metrics_dir="${LOG_DIR}/cpu"
    local metrics_path="${metrics_dir}/metrics_${TIMESTAMP}.json"
    mkdir -p "${metrics_dir}"

    # Get sensor data
    local sensors_out
    sensors_out=$(sensors 2>/dev/null)
    if [[ $? -ne 0 || -z "$sensors_out" ]]; then
        local fail_json=$(jq -n --arg item "$item" '{status:"FAIL", item:$item, reason:"無法讀取 sensors 資料"}')
        set_check_result 4 "$fail_json"
        return
    fi
    echo "$sensors_out" > "$raw_log_path"

    local total=0
    local count=0
    local max_temp=0
    local hottest_sensor=""

    while IFS=$'\t' read -r name temp; do
        echo "DEBUG CPU: name='$name', temp='$temp'" >&2
        [[ -z "$name" || -z "$temp" ]] && continue
        local current_temp
        current_temp=$(awk -v x="$temp" 'BEGIN {print x+0}')

        if (( count == 0 )); then
            max_temp=$current_temp
            hottest_sensor="$name"
        elif float_gt "$current_temp" "$max_temp"; then
            max_temp=$current_temp
            hottest_sensor="$name"
        fi

        total=$(awk -v a="$total" -v b="$current_temp" 'BEGIN { printf "%.6f", (a+0)+(b+0) }')
        ((count++))
    done < <(echo "$sensors_out" | awk -F: '/(Core|CPU|Package id|Tdie|Tctl)/ {
            name=$1; gsub(/^[ \t]+|[ \t]+$/, "", name);
            val=$2;
            if (match(val, /[-+]?[0-9]+(\.[0-9]+)?/)) {
                temp = substr(val, RSTART, RLENGTH);
                gsub(/^[+]/, "", temp);
                printf "%s\t%s\n", name, temp;
            }
        }')

    if (( count == 0 )); then
        local warn_json=$(jq -n --arg item "$item" '{status:"WARN", item:$item, reason:"在 sensors 輸出中找不到 CPU 核心溫度"}')
        set_check_result 4 "$warn_json"
        return
    fi

    local avg_temp
    avg_temp=$(awk -v sum="$total" -v cnt="$count" 'BEGIN { if (cnt>0) printf "%.4f", sum/cnt; else print 0 }')
    local max_temp_display avg_temp_display
    max_temp_display=$(awk -v v="$max_temp" 'BEGIN { printf "%.1f", v }')
    avg_temp_display=$(awk -v v="$avg_temp" 'BEGIN { printf "%.1f", v }')

    # Read or create baseline
    local baseline_avg=0
    if [[ -f "${baseline_path}" && "${RE_BASELINE:-false}" != "true" ]]; then
        baseline_avg=$(jq -r '.baseline_avg // 0' "${baseline_path}")
    else
        baseline_avg=${avg_temp}
        echo "{\"baseline_avg\": ${avg_temp}, \"updated_at\": \"$(date -u --iso-8601=seconds)\"}" > "${baseline_path}"
        echo "[INFO] CPU baseline created/updated: ${baseline_avg}°C"
    fi

    # --- Historical Analysis (using LOG_DAYS) ---
    local history_days="$LOG_DAYS"
    local historical_files
    mapfile -t historical_files < <(find "$metrics_dir" -name "metrics_*.json" -mtime -"$history_days" 2>/dev/null)
    
    local peak_max_temp="null"
    local rolling_avg_temp="null"
    if [[ ${#historical_files[@]} -gt 0 ]]; then
        local stats
        stats=$(jq -s '
            {
                peak: (map(.metrics.max // null) | max),
                avg_sum: ([.[] | .metrics.average // 0] | add),
                avg_count: ([.[] | .metrics.average // null] | length)
            }
        ' "${historical_files[@]}")
        
        peak_max_temp=$(echo "$stats" | jq -r '.peak')
        local avg_sum
        avg_sum=$(echo "$stats" | jq -r '.avg_sum')
        local avg_count
        avg_count=$(echo "$stats" | jq -r '.avg_count')

        if (( avg_count > 0 )); then
            rolling_avg_temp=$(awk -v sum="$avg_sum" -v count="$avg_count" 'BEGIN {printf "%.1f", sum/count}')
        fi
    fi
    [[ "$peak_max_temp" == "null" ]] && peak_max_temp=$max_temp
    local peak_display
    peak_display=$(awk -v v="$peak_max_temp" 'BEGIN { printf "%.1f", v }')

    # Logic
    local status="PASS"
    local reason=""
    local temp_diff
    temp_diff=$(awk -v avg="$avg_temp" -v base="$baseline_avg" 'BEGIN { printf "%.4f", avg-base }')

    if float_ge "$max_temp" "$CPU_TEMP_CRIT"; then
        status="FAIL"
        reason="CPU 溫度嚴重過高. Max: ${max_temp_display}°C (閾值: ${CPU_TEMP_CRIT}°C). ${history_days}d Peak: ${peak_display}°C."
    elif float_ge "$max_temp" "$CPU_TEMP_WARN"; then
        status="WARN"
        reason="CPU 溫度警告. Max: ${max_temp_display}°C (閾值: ${CPU_TEMP_WARN}°C). ${history_days}d Peak: ${peak_display}°C."
    elif float_ge "$temp_diff" 15; then
        status="FAIL"
        reason="CPU 平均溫度 (${avg_temp_display}°C) 相比基準 (${baseline_avg}°C) 異常升高 ${temp_diff}°C."
    elif float_ge "$temp_diff" 10; then
        status="WARN"
        reason="CPU 平均溫度 (${avg_temp_display}°C) 相比基準 (${baseline_avg}°C) 升高 ${temp_diff}°C."
    else
        reason="CPU 溫度正常. Max: ${max_temp_display}°C (${history_days}d Peak: ${peak_display}°C), Avg: ${avg_temp_display}°C."
    fi

    # Final JSON
    local metrics_json
    metrics_json=$(jq -n --argjson max "$max_temp" --argjson avg "$avg_temp" \
        '{max: $max, average: $avg}')
    
    local thresholds_json
    thresholds_json=$(jq -n --argjson warn "$CPU_TEMP_WARN" --argjson crit "$CPU_TEMP_CRIT" --argjson base "$baseline_avg" \
        '{warn_celsius:$warn, crit_celsius:$crit, baseline_avg_celsius:$base}')

    local historical_stats_json
    historical_stats_json=$(jq -n --argjson peak "$peak_max_temp" --argjson roll_avg "$rolling_avg_temp" --argjson days "$history_days" \
        "{\"peak_max_temp_\(\$days)d\": \$peak, \"rolling_avg_temp_\(\$days)d\": \$roll_avg, \"days\": \$days}")

    local evidence_json
    evidence_json=$(jq -n --arg raw "$raw_log_path" --arg base "$baseline_path" \
        '{raw_log:$raw, baseline_file:$base}')

    local final_json
    final_json=$(jq -n \
        --arg status "$status" \
        --arg item "$item" \
        --arg reason "$reason" \
        --argjson metrics "$metrics_json" \
        --argjson thresholds "$thresholds_json" \
        --argjson history "$historical_stats_json" \
        --argjson evidence "$evidence_json" \
        '{status: $status, item: $item, reason: $reason, metrics: $metrics, thresholds: $thresholds, historical_stats: $history, evidence: $evidence}')

    # --- Build judgement ---
    local th_json
    th_json=$(jq -n --arg warn "$CPU_TEMP_WARN" --arg crit "$CPU_TEMP_CRIT" \
      '{CPU_TEMP_WARN: ($warn|tonumber), CPU_TEMP_CRIT: ($crit|tonumber)}')

    local checks_json
    checks_json=$(jq -n \
      --arg max_temp "$max_temp" \
      --arg max_display "$max_temp_display" \
      --arg avg_temp "$avg_temp_display" \
      --arg peak "$peak_display" \
      --arg warn "$CPU_TEMP_WARN" \
      --arg crit "$CPU_TEMP_CRIT" \
      '[
         {"name":"Max Temp <= WARN","ok":((($max_temp|tonumber) <= ($warn|tonumber))),"value":("max="+$max_display+"°C")},
         {"name":"Max Temp <= CRIT","ok":((($max_temp|tonumber) <= ($crit|tonumber))),"value":("max="+$max_display+"°C")},
         {"name":"Rolling Avg (90d)","ok":true,"value":("avg="+$avg_temp+"°C")},
         {"name":"90d Peak","ok":true,"value":("peak="+$peak+"°C")}
       ]')

    local pass_rules='["最大 CPU 溫度 <= WARN"]'
    local warn_rules='["WARN < 最大 CPU 溫度 <= CRIT"]'
    local fail_rules='["最大 CPU 溫度 > CRIT"]'
    local criteria="CPU 溫度：代表性核心的當前最大值 ≤ WARN（${CPU_TEMP_WARN}°C）為 PASS；WARN < Max ≤ CRIT（${CPU_TEMP_CRIT}°C）為 WARN；Max > CRIT 為 FAIL。附帶 90 天峰值與移動平均作對照。"

    local jdg_json
    jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

    echo "$final_json" > "$metrics_path"
    set_check_result_with_jdg 4 "$final_json" "$jdg_json"
}

# ----------------- 5 NIC -----------------
declare -A NIC_PREV
load_nic_baseline(){
  [[ -z "$NIC_BASELINE_FILE" ]] && return
  [[ ! -f "$NIC_BASELINE_FILE" ]] && return
  while IFS=, read -r nic key val ts_field; do
    [[ -z "$nic" || -z "$key" ]] && continue
    # 新格式：nic,timestamp,<epoch> (key="timestamp")
    if [[ "$key" == "timestamp" ]]; then
      NIC_PREV["$nic:timestamp"]="$val"
      continue
    fi
    # 一般 counter: nic,key,value 或舊格式 nic,key,value,ts
    [[ -z "$val" ]] && continue
    NIC_PREV["$nic:$key"]="$val"
    # 舊格式可能在第四欄帶 ts (向後兼容)
    if [[ -n "$ts_field" && -z "${NIC_PREV["$nic:timestamp"]:-}" ]]; then
      NIC_PREV["$nic:timestamp"]="$ts_field"
    fi
  done < <(grep -v '^#' "$NIC_BASELINE_FILE" || true)
}

write_nic_baseline(){
  [[ -z "$NIC_BASELINE_FILE" ]] && return
  local ts tmp_file
  ts=$(date +%s)
  tmp_file="${NIC_BASELINE_FILE}.tmp.$$"

  # 原子寫：先寫到暫存檔
  {
    echo "# nic,key,value (auto-generated baseline for next run, timestamp stored per-interface)"
    echo "# Baseline timestamp: $ts"
    for nic in $(ls /sys/class/net 2>/dev/null | grep -vE 'lo|docker|veth|br-' || true); do
      # 為每個介面寫入一個 timestamp entry
      echo "$nic,timestamp,$ts"
      for key in rx_errors tx_errors rx_dropped tx_dropped rx_crc_errors rx_packets; do
        local path="/sys/class/net/$nic/statistics/$key"
        if [[ -f "$path" ]]; then
            local val
            val=$(cat "$path" 2>/dev/null || echo 0)
            echo "$nic,$key,$val"
        fi
      done
    done
  } > "$tmp_file" 2>/dev/null

  # 原子替換
  if [[ -f "$tmp_file" ]]; then
    if mv -f "$tmp_file" "$NIC_BASELINE_FILE" 2>/dev/null; then
      chmod 0644 "$NIC_BASELINE_FILE" 2>/dev/null
      echo "[NIC] Baseline updated: $NIC_BASELINE_FILE (ts=$ts)"
    else
      echo "[NIC] ERROR: Failed to move tmp file to $NIC_BASELINE_FILE" >&2
      rm -f "$tmp_file" 2>/dev/null
      return 1
    fi
  else
    echo "[NIC] ERROR: Failed to create tmp baseline file" >&2
    return 1
  fi
}

check_nic() {
    local item="NIC.Errors"
    echo -e "${C_BLUE}[5] 網路卡 (NIC)${C_RESET}"
    ip -br link || true

    load_nic_baseline

    local final_status="PASS"
    local final_reason=""
    local reason_details=()
    local metrics_array=()

    # === Softnet drops（核心佇列丟包）baseline + rate ===
    _read_softnet_drops() {
        awk '{sum+=strtonum("0x"$2)} END{print sum+0}' /proc/net/softnet_stat 2>/dev/null || echo 0
    }

    local NOW_TS
    NOW_TS=$(date +%s)
    local SOFTNET_BASELINE_FILE=""
    local SOFTNET_PREV_VAL="0" SOFTNET_PREV_TS="0"
    local SOFTNET_NOW="0" SOFTNET_DELTA="0"
    local have_softnet_baseline="0"
    local window_seconds_used=0
    local softnet_rate_per_sec="0"

    if [[ -n "$NIC_BASELINE_FILE" ]]; then
        SOFTNET_BASELINE_FILE="${NIC_BASELINE_FILE}.softnet"
        if [[ -f "$SOFTNET_BASELINE_FILE" ]]; then
            have_softnet_baseline="1"
            read -r SOFTNET_PREV_VAL SOFTNET_PREV_TS < <(awk '{print $1, ($2?$2:0)}' "$SOFTNET_BASELINE_FILE" 2>/dev/null)
            [[ -z "$SOFTNET_PREV_VAL" ]] && SOFTNET_PREV_VAL=0
            [[ -z "$SOFTNET_PREV_TS"  ]] && SOFTNET_PREV_TS=0
        fi
    fi
    SOFTNET_NOW=$(_read_softnet_drops)
    if [[ "$have_softnet_baseline" == "1" ]]; then
        SOFTNET_DELTA=$((SOFTNET_NOW - SOFTNET_PREV_VAL))
        (( SOFTNET_DELTA < 0 )) && SOFTNET_DELTA=0
    fi

    if [[ -n "${SOFTNET_WINDOW_SECONDS:-}" && "$SOFTNET_WINDOW_SECONDS" -gt 0 ]]; then
        window_seconds_used="$SOFTNET_WINDOW_SECONDS"
    elif [[ "$have_softnet_baseline" == "1" && "$SOFTNET_PREV_TS" -gt 0 && "$NOW_TS" -ge "$SOFTNET_PREV_TS" ]]; then
        window_seconds_used=$((NOW_TS - SOFTNET_PREV_TS))
    else
        window_seconds_used=0
    fi

    if (( window_seconds_used > 0 )); then
        softnet_rate_per_sec=$(awk -v d="$SOFTNET_DELTA" -v w="$window_seconds_used" 'BEGIN{ if(w>0) printf "%.6f", d/w; else print 0 }')
    else
        softnet_rate_per_sec="0"
    fi

    # 排除 lo/docker/veth/bridge/tunnel 類虛擬介面
    local nics
    nics=$(ls /sys/class/net | grep -vE '^(lo|docker.*|veth.*|br-.*|cni.*|flannel.*|cali.*|tun.*|tap.*|virbr.*)$' || true)

    if [[ -z "$nics" ]]; then
        final_status="SKIP"
        final_reason="No physical NICs detected."
    else
        local have_baseline="0"
        [[ -n "$NIC_BASELINE_FILE" && -f "$NIC_BASELINE_FILE" ]] && have_baseline="1"

        # 先加入 softnet 指標（全域，不分介面）
        metrics_array+=("$(jq -n \
          --arg scope "softnet" \
          --argjson softnet_now "$SOFTNET_NOW" \
          --argjson softnet_delta "$SOFTNET_DELTA" \
          --argjson softnet_rate_per_sec "$softnet_rate_per_sec" \
          --argjson softnet_window_seconds_used "$window_seconds_used" \
          '{scope:$scope, softnet_drops_now:$softnet_now, softnet_drops_delta:$softnet_delta, softnet_rate_per_sec:$softnet_rate_per_sec, softnet_window_seconds_used:$softnet_window_seconds_used}')")

        if [[ "$have_softnet_baseline" == "1" && "$SOFTNET_DELTA" -gt 0 ]]; then
            final_status="WARN"
            reason_details+=("softnet_drops+=$SOFTNET_DELTA (~${softnet_rate_per_sec}/s)")
        fi

        # 逐介面檢查
        for nic in $nics; do
            local ethtool_out speed duplex link_detected
            ethtool_out=$(ethtool "$nic" 2>/dev/null)
            speed=$(echo "$ethtool_out" | grep -i 'Speed' | awk -F: '{print $2}' | xargs)
            duplex=$(echo "$ethtool_out" | grep -i 'Duplex' | awk -F: '{print $2}' | xargs)
            link_detected=$(echo "$ethtool_out" | grep -i 'Link detected' | awk -F: '{print $2}' | xargs)

            local rx_pkts_path="/sys/class/net/$nic/statistics/rx_packets"
            local rx_pkts_now=0 rx_pkts_prev=0 d_rx_pkts=0
            if [[ -f "$rx_pkts_path" ]]; then
              rx_pkts_now=$(cat "$rx_pkts_path" 2>/dev/null || echo 0)
              rx_pkts_prev=${NIC_PREV["$nic:rx_packets"]:-$rx_pkts_now}
              (( rx_pkts_now > rx_pkts_prev )) && d_rx_pkts=$(( rx_pkts_now - rx_pkts_prev )) || d_rx_pkts=0
            fi

            local counter_increments='{}'
            for key in rx_dropped tx_dropped rx_errors tx_errors rx_crc_errors; do
                local path="/sys/class/net/$nic/statistics/$key"
                if [[ -f "$path" ]]; then
                    local val_now val_prev diff
                    val_now=$(cat "$path" 2>/dev/null || echo 0)
                    val_prev=${NIC_PREV["$nic:$key"]:-$val_now}
                    diff=0
                    (( val_now > val_prev )) && diff=$(( val_now - val_prev ))
                    if (( diff > 0 )); then
                        counter_increments=$(echo "$counter_increments" | jq --arg k "$key" --argjson v "$diff" '. + {($k): $v}')
                    fi
                fi
            done

            local d_rx_d=$(echo "$counter_increments" | jq -r '.rx_dropped // 0')

            # 計算此介面自己的視窗時間 (使用介面的 timestamp)
            local nic_prev_ts="${NIC_PREV["$nic:timestamp"]:-}"
            local nic_window_sec=0
            if [[ -n "$nic_prev_ts" && "$nic_prev_ts" -gt 0 ]]; then
                nic_window_sec=$((NOW_TS - nic_prev_ts))
                [[ "$nic_window_sec" -lt 1 ]] && nic_window_sec=1
            else
                # 無 baseline 或首次運行，使用 softnet 視窗或設為 1
                nic_window_sec=${window_seconds_used:-1}
                [[ "$nic_window_sec" -lt 1 ]] && nic_window_sec=1
            fi

            local r_rx_d=$(awk -v a="$d_rx_d" -v b="$nic_window_sec" 'BEGIN{printf "%.6f", a/b}')

            local drop_pct="0.000000"
            if [[ "$d_rx_pkts" -gt 0 ]]; then
              drop_pct=$(awk -v d="$d_rx_d" -v p="$d_rx_pkts" 'BEGIN{printf "%.6f", (d/p)*100.0}')
            fi

            # 檢查樣本是否足夠（避免短視窗/小樣本誤報）
            local sample_pkts=$(( d_rx_pkts + d_rx_d ))
            local sample_ok=true
            local sample_skip_reason=""

            if (( nic_window_sec < NIC_MIN_WINDOW_SEC )); then
                sample_ok=false
                sample_skip_reason="window=${nic_window_sec}s < ${NIC_MIN_WINDOW_SEC}s"
            fi
            if (( sample_pkts < NIC_MIN_RX_PKTS )); then
                sample_ok=false
                [[ -n "$sample_skip_reason" ]] && sample_skip_reason+=", "
                sample_skip_reason+="pkts=${sample_pkts} < ${NIC_MIN_RX_PKTS}"
            fi

            # 判斷是否為 uplink 介面
            local is_uplink=false
            case ",${CABLE_UPLINK_IFACES:-}," in
                *,"$nic",*) is_uplink=true ;;
            esac

            # 格式化數值顯示（避免過多小數）
            local drop_pct_str r_rx_d_str
            printf -v drop_pct_str '%.3f' "$drop_pct"
            printf -v r_rx_d_str '%.3f' "$r_rx_d"

            # 判斷是否異常：只有樣本充足時才評分
            local warn_hit=0
            local nic_summary="$nic: Δrx_d=$d_rx_d, drop=${drop_pct_str}%, rate=${r_rx_d_str}/s (${nic_window_sec}s), link=$link_detected"

            if [[ "$sample_ok" == "false" ]]; then
                # 樣本不足，不評分（視為 OK，但記錄原因）
                reason_details+=("SAMPLE|$nic_summary ($sample_skip_reason)")
            else
                # 樣本充足，開始評分
                # 新策略：降噪條件
                # ① Δrx_dropped 超過門檻（絕對值）
                if ge "$d_rx_d" "$NIC_WARN_MIN_DELTA"; then
                    warn_hit=1
                fi
                # ② 丟包率超過門檻 AND Δ >= NIC_RATE_MIN_DELTA（需同時滿足）
                if ge "$drop_pct" "$NIC_WARN_MIN_PCT" && ge "$d_rx_d" "$NIC_RATE_MIN_DELTA"; then
                    warn_hit=1
                fi
                # ③ 丟包速率超過門檻 AND Δ >= NIC_RATE_MIN_DELTA（需同時滿足）
                if ge "$r_rx_d" "$NIC_WARN_MIN_RX_DROP_RATE" && ge "$d_rx_d" "$NIC_RATE_MIN_DELTA"; then
                    warn_hit=1
                fi
                # ④ link=no 只針對 uplink 觸發
                if [[ "${link_detected,,}" == "no" && "$is_uplink" == "true" ]]; then
                    warn_hit=1
                fi

                if [[ "$warn_hit" == "1" ]]; then
                    final_status="WARN"
                    reason_details+=("ISSUE|$nic_summary")
                else
                    reason_details+=("OK|$nic_summary")
                fi
            fi

            local metric_json
            metric_json=$(jq -n \
              --arg scope "iface" \
              --arg iface "$nic" \
              --arg speed "$speed" \
              --arg duplex "$duplex" \
              --arg link "$link_detected" \
              --argjson increments "$counter_increments" \
              --argjson rx_pkts_now "$rx_pkts_now" \
              --argjson rx_pkts_delta "$d_rx_pkts" \
              --arg rx_drop_rate_per_sec "$r_rx_d" \
              --arg drop_percentage "$drop_pct" \
              --argjson thresholds "$(jq -n \
                  --argjson d "$NIC_WARN_MIN_DELTA" \
                  --arg p "$NIC_WARN_MIN_PCT" \
                  --arg r "$NIC_WARN_MIN_RX_DROP_RATE" \
                  --arg rate_min "$NIC_RATE_MIN_DELTA" \
                  --arg win "$NIC_MIN_WINDOW_SEC" \
                  --arg pkts "$NIC_MIN_RX_PKTS" \
                  '{min_delta:$d,
                    min_pct:($p|tonumber),
                    min_rx_drop_rate_per_sec:($r|tonumber),
                    rate_min_delta:($rate_min|tonumber),
                    min_window_sec:($win|tonumber),
                    min_rx_pkts:($pkts|tonumber)}')" \
              '{scope:$scope, iface:$iface, speed:$speed, duplex:$duplex, link:$link,
                counters:$increments,
                rx_packets:($rx_pkts_now|tonumber), rx_packets_delta:$rx_pkts_delta,
                rx_dropped_rate_per_sec:($rx_drop_rate_per_sec|tonumber),
                drop_percentage:($drop_percentage|tonumber), thresholds:$thresholds }')
            metrics_array+=("$metric_json")
        done

        # 用 printf 和 sed 來確保分隔符有空白
        local details_str=""
        if [[ "${#reason_details[@]}" -gt 0 ]]; then
            details_str=$(printf '%s; ' "${reason_details[@]}")
            details_str="${details_str%; }"  # 移除最後的 "; "
        fi

        if [[ "$final_status" == "PASS" ]]; then
            final_reason="NIC counters stable. Details: ${details_str}"
        else
            final_reason="NIC issues detected. Details: ${details_str}"
        fi
        
        if [[ ! -f "$NIC_BASELINE_FILE" ]]; then
            final_reason="Baseline initialized; counters will be compared on next run."
        fi
    fi

    local evidence_obj
    evidence_obj=$(jq -n \
        --arg file "$NIC_BASELINE_FILE" \
        --arg softnet_file "$SOFTNET_BASELINE_FILE" \
        --argjson softnet_window_seconds_used "${window_seconds_used:-0}" \
        '{baseline_file:$file, softnet_baseline_file:$softnet_file, softnet_window_seconds_used:$softnet_window_seconds_used}')

    local final_json
    final_json=$(jq -n \
        --arg status "$final_status" \
        --arg item "$item" \
        --arg reason "$final_reason" \
        --argjson metrics "[$(IFS=,; echo "${metrics_array[*]}")]" \
        --argjson evidence "$evidence_obj" \
        '{status:$status, item:$item, reason:$reason, metrics:$metrics, evidence:$evidence}')

    # --- Build judgement ---
    local th_json
    th_json=$(jq -n \
      --arg min_delta "$NIC_WARN_MIN_DELTA" \
      --arg min_pct "$NIC_WARN_MIN_PCT" \
      --arg min_rx_drop_rate "$NIC_WARN_MIN_RX_DROP_RATE" \
      --arg rate_min_delta "$NIC_RATE_MIN_DELTA" \
      --arg min_window "$NIC_MIN_WINDOW_SEC" \
      --arg min_rx_pkts "$NIC_MIN_RX_PKTS" \
      '{NIC_WARN_MIN_DELTA: ($min_delta|tonumber),
        NIC_WARN_MIN_PCT: ($min_pct|tonumber),
        NIC_WARN_MIN_RX_DROP_RATE: ($min_rx_drop_rate|tonumber),
        NIC_RATE_MIN_DELTA: ($rate_min_delta|tonumber),
        NIC_MIN_WINDOW_SEC: ($min_window|tonumber),
        NIC_MIN_RX_PKTS: ($min_rx_pkts|tonumber)}')

    # 只把標記為 ISSUE 的介面列入 checks (ok:false)
    local checks_json='[]'
    local has_issues=0
    for detail in "${reason_details[@]}"; do
        if [[ "$detail" == "ISSUE|"* ]]; then
            has_issues=1
            local clean_detail="${detail#ISSUE|}"
            checks_json=$(echo "$checks_json" | jq --arg d "$clean_detail" '. + [{"name":"NIC Issue","ok":false,"value":$d}]')
        fi
    done

    # 如果沒有 issue，輸出 All checks passed
    if [[ "$has_issues" == "0" ]]; then
        checks_json='[{"name":"All checks passed","ok":true,"value":"所有 NIC 計數器穩定"}]'
    fi

    local pass_rules='["所有 NIC rx_dropped/tx_dropped/rx_errors/tx_errors 等計數器穩定，link=yes"]'
    local warn_rules
    warn_rules=$(printf '["任一 NIC 滿足：① Δrx_dropped ≥ %s；② drop%% ≥ %s%% 且 Δ ≥ %s；③ rx_drop_rate ≥ %s/s 且 Δ ≥ %s；④ uplink link=no"]' \
      "$NIC_WARN_MIN_DELTA" "$NIC_WARN_MIN_PCT" "$NIC_RATE_MIN_DELTA" "$NIC_WARN_MIN_RX_DROP_RATE" "$NIC_RATE_MIN_DELTA")
    local fail_rules='["（保留給未來擴充：嚴重錯誤率或持續 link down）"]'
    local criteria="NIC 健康：樣本需滿足視窗 ≥ ${NIC_MIN_WINDOW_SEC}s 且封包數 ≥ ${NIC_MIN_RX_PKTS}。若任一介面符合 ① Δrx_dropped ≥ ${NIC_WARN_MIN_DELTA}；② drop% ≥ ${NIC_WARN_MIN_PCT}% 且 Δ ≥ ${NIC_RATE_MIN_DELTA}；③ rx_drop_rate ≥ ${NIC_WARN_MIN_RX_DROP_RATE}/s 且 Δ ≥ ${NIC_RATE_MIN_DELTA}；或 ④ uplink link=no（非 uplink 僅記錄）則 WARN；全部穩定則 PASS。"

    local jdg_json
    jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

    set_check_result_with_jdg 5 "$final_json" "$jdg_json"

    # 寫回 NIC baseline（供下次運行比較）
    if [[ -n "${NIC_BASELINE_FILE:-}" ]]; then
        local baseline_dir
        baseline_dir="$(dirname "$NIC_BASELINE_FILE")"

        # 確保目錄存在且可寫
        if ! mkdir -p "$baseline_dir" 2>/dev/null; then
            echo "[NIC] ERROR: Cannot create baseline directory: $baseline_dir" >&2
        elif ! [[ -w "$baseline_dir" ]]; then
            echo "[NIC] ERROR: Baseline directory not writable: $baseline_dir" >&2
        else
            # 呼叫 write_nic_baseline（內部已處理原子寫）
            write_nic_baseline

            # 同時寫回 softnet baseline（原子寫）
            if [[ -n "${SOFTNET_BASELINE_FILE:-}" ]]; then
                local softnet_tmp="${SOFTNET_BASELINE_FILE}.tmp.$$"
                if printf '%s %s\n' "$SOFTNET_NOW" "$NOW_TS" > "$softnet_tmp" 2>/dev/null; then
                    mv -f "$softnet_tmp" "$SOFTNET_BASELINE_FILE" && chmod 0644 "$SOFTNET_BASELINE_FILE" 2>/dev/null
                else
                    echo "[NIC] ERROR: Cannot write softnet baseline to $SOFTNET_BASELINE_FILE" >&2
                    rm -f "$softnet_tmp" 2>/dev/null
                fi
            fi
        fi
    fi
}

# ----------------- 6 GPU -----------------
check_gpu() {
  local item="GPU.Health"
  echo -e "${C_BLUE}[6] GPU${C_RESET}"

  local nvidia_smi_available=false
  local gpu_count=0
  local final_status="SKIP"
  local final_reason="無 nvidia-smi"

  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia_smi_available=true
    # 嘗試列出 GPU
    local gpu_list
    gpu_list=$(nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw --format=csv 2>&1)
    if [[ $? -eq 0 ]]; then
      echo "$gpu_list"
      gpu_count=$(echo "$gpu_list" | tail -n +2 | wc -l | tr -d ' ')
      if [[ "$gpu_count" -gt 0 ]]; then
        final_status="PASS"
        final_reason="偵測到 ${gpu_count} 張 GPU，狀態正常"
      else
        final_status="SKIP"
        final_reason="nvidia-smi 執行成功但未偵測到 GPU"
      fi
    else
      final_status="WARN"
      final_reason="nvidia-smi 存在但執行失敗"
      echo "[WARN] nvidia-smi failed: $gpu_list"
    fi
  fi

  # 建立 judgement - SKIP 時避免顯示誤導的 [✗]
  local checks_json
  local nvidia_ok="$nvidia_smi_available"
  local gpu_cnt_ok="true"

  if [[ "$final_status" == "SKIP" ]]; then
    # SKIP 時設為 null (中性)，渲染層不顯示 [✗]
    # 並提供明確的 "Not applicable" 訊息
    nvidia_ok="null"
    gpu_cnt_ok="null"
    checks_json='[{"name":"GPU installed","ok":null,"value":"N/A (no NVIDIA GPU detected)"},{"name":"nvidia-smi available","ok":null,"value":"N/A (command not found)"}]'
  elif [[ "$gpu_count" -eq 0 ]]; then
    gpu_cnt_ok="false"
    checks_json=$(jq -n \
      --argjson nvidia_avail "$nvidia_ok" \
      --argjson gpu_cnt_ok "$gpu_cnt_ok" \
      --arg gpu_cnt "$gpu_count" \
      '[{"name":"nvidia-smi 可用","ok":$nvidia_avail,"value":($nvidia_avail|tostring)},
        {"name":"GPU 數量","ok":$gpu_cnt_ok,"value":("count="+$gpu_cnt)}]')
  else
    checks_json=$(jq -n \
      --argjson nvidia_avail "$nvidia_ok" \
      --argjson gpu_cnt_ok "$gpu_cnt_ok" \
      --arg gpu_cnt "$gpu_count" \
      '[{"name":"nvidia-smi 可用","ok":$nvidia_avail,"value":($nvidia_avail|tostring)},
        {"name":"GPU 數量","ok":$gpu_cnt_ok,"value":("count="+$gpu_cnt)}]')
  fi

  local pass_rules='["nvidia-smi 存在且成功執行","至少偵測到 1 張 GPU","GPU 無 Critical Error"]'
  local warn_rules='["nvidia-smi 存在但查詢異常或偵測到溫度/功耗超出正常範圍"]'
  local fail_rules='["nvidia-smi 存在但執行失敗 (rc!=0)"]'
  local criteria="檢查 NVIDIA GPU 是否可用。若 nvidia-smi 指令存在且成功執行，視為 PASS；若指令不存在則 SKIP；若存在但執行失敗則 WARN。"

  local th_json='{"GPU_TEMP_WARN":85,"GPU_TEMP_CRIT":92,"GPU_POWER_WATCH":0}'

  local base_json
  base_json=$(jq -n \
    --arg status "$final_status" \
    --arg item "$item" \
    --arg reason "$final_reason" \
    --arg tips "$(get_item_tips 6)" \
    '{status:$status, item:$item, reason:$reason, tips:($tips|split("\n")|map(select(.!="")))}')

  local jdg_json
  jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

  set_check_result_with_jdg 6 "$base_json" "$jdg_json"
}

check_fans() {
    local item="Fan.Speed"
    echo -e "${C_BLUE}[7] 風扇 / 散熱 (Fans)${C_RESET}"

    # Define paths
    local raw_sensors_log="${LOG_DIR}/sensors_output_${TIMESTAMP}.log" # This file is already created by check_cpu
    local raw_ipmi_sdr_log="${LOG_DIR}/ipmi_sdr_fan_${TIMESTAMP}.log"
    local baseline_path="${LOG_DIR}/fan_baseline.json"
    local metrics_dir="${LOG_DIR}/fan"
    local metrics_path="${metrics_dir}/metrics_${TIMESTAMP}.json"
    mkdir -p "${metrics_dir}"

    # Get OS-level sensor data
    local fan_out
    fan_out=$(sensors 2>/dev/null | egrep -i '^fan[0-9a-zA-Z]+:' || true)
    echo "$fan_out"

    # Get IPMI-level SDR data
    local ipmi_sdr_out=""
    if (( ! SKIP_BMC )); then
        ipmi_sdr_out=$(ipmi_try sdr elist | grep -i fan)
        echo "$ipmi_sdr_out" > "$raw_ipmi_sdr_log"
        echo "$ipmi_sdr_out"
    fi

    # If no data from either source, exit with INFO and evidence
    if [[ -z "$fan_out" && -z "$ipmi_sdr_out" ]]; then
        local reason="無 OS (sensors) 風扇資料, 且 IPMI 未回傳風扇資訊"
        local evidence
        evidence=$(jq -n --arg sensors_log "$raw_sensors_log" --arg ipmi_log "$raw_ipmi_sdr_log" \
            '{sensors_log_attempt:$sensors_log, ipmi_sdr_log_attempt:$ipmi_log}')
        local info_json
        info_json=$(jq -n --arg item "$item" --arg reason "$reason" --argjson evidence "$evidence" \
            '{status:"INFO", item:$item, reason:$reason, evidence:$evidence}')
        set_check_result 7 "$info_json"
        return
    fi

    # Read or create file-based baseline from previous OS-level sensor readings
    declare -A FILE_BASELINE_RPM
    if [[ -f "$baseline_path" && "${RE_BASELINE:-false}" != "true" ]]; then
        mapfile -t fan_keys < <(jq -r 'keys[]' "$baseline_path" 2>/dev/null || true)
        for key in "${fan_keys[@]}"; do
            FILE_BASELINE_RPM["$key"]=$(jq -r ".\"$key\"" "$baseline_path")
        done
    fi

    local low_rpm_count=0
    local deviation_warn_count=0
    local deviation_crit_count=0
    local metrics_json_array=()
    local reason_details=()
    local fan_summary_array=() # For PASS reason summary
    local needs_baseline_update=0

    # --- Process OS-level `sensors` data ---
    while read -r line; do
        local fan_name=$(echo "$line" | awk -F: '{print $1}' | xargs | tr ' ' '_' | tr -d '-')
        local current_rpm=$(echo "$line" | grep -oP '[0-9]+' | head -n1)
        [[ -z "$current_rpm" ]] && continue

        local baseline_rpm=0
        local baseline_source="none"
        if [[ -n "${FILE_BASELINE_RPM[$fan_name]:-}" ]]; then
            baseline_rpm=${FILE_BASELINE_RPM[$fan_name]}
            baseline_source="file"
        else
            baseline_rpm=$current_rpm
            FILE_BASELINE_RPM["$fan_name"]=$current_rpm
            needs_baseline_update=1
            baseline_source="new"
        fi

        local deviation_pct=0
        if (( baseline_rpm > 50 )); then
            deviation_pct=$(awk -v cur="$current_rpm" -v base="$baseline_rpm" 'BEGIN { printf "%.0f", (cur-base)*100/base }')
            deviation_pct=${deviation_pct#-}
        fi

        local fan_status="OK"
        if (( current_rpm < 100 )); then
            ((low_rpm_count++)); fan_status="CRIT (Stopped)"; reason_details+=("${fan_name}:${current_rpm}RPM")
        elif (( deviation_pct > 40 )); then
            ((deviation_crit_count++)); fan_status="CRIT (Dev >40%)"; reason_details+=("${fan_name}:${current_rpm}RPM,Dev:${deviation_pct}%")
        elif (( current_rpm < FAN_RPM_TH )); then
            ((low_rpm_count++)); fan_status="WARN (<${FAN_RPM_TH}RPM)"; reason_details+=("${fan_name}:${current_rpm}RPM")
        elif (( deviation_pct > 20 )); then
            ((deviation_warn_count++)); fan_status="WARN (Dev >20%)"; reason_details+=("${fan_name}:${current_rpm}RPM,Dev:${deviation_pct}%")
        fi
        
        metrics_json_array+=( $(jq -n --arg name "$fan_name" --arg status "$fan_status" --argjson rpm "$current_rpm" --argjson base_rpm "$baseline_rpm" --arg bsrc "$baseline_source" --argjson dev_pct "$deviation_pct" \
            '{name:$name, status:$status, current_rpm:$rpm, baseline_rpm:$base_rpm, baseline_source:$bsrc, deviation_pct:$dev_pct}') )

    done <<< "$fan_out"

    # --- Process IPMI SDR data ---
    if [[ -n "$ipmi_sdr_out" ]]; then
        while read -r line; do
            echo "$line" | grep -q "RPM" || continue

            local fan_name; fan_name=$(echo "$line" | cut -d'|' -f1 | xargs | tr ' ' '_' | tr -d '-')
            local current_rpm; current_rpm=$(echo "$line" | cut -d'|' -f5 | grep -oE '[0-9]+' | head -n 1)
            [[ -z "$fan_name" || -z "$current_rpm" ]] && continue

            local fan_status="OK"
            if (( current_rpm < FAN_RPM_TH )); then
                ((low_rpm_count++)); fan_status="WARN (<${FAN_RPM_TH}RPM)"; reason_details+=("${fan_name}:${current_rpm}RPM")
            fi
            fan_summary_array+=("${fan_name}|${current_rpm}|${FAN_RPM_TH}")
            echo "DEBUG FAN: ${fan_name}|${current_rpm}|${FAN_RPM_TH}" >&2

            metrics_json_array+=( $(jq -n --arg name "$fan_name" --arg status "$fan_status" --argjson rpm "$current_rpm" --arg bsrc "ipmi" \
                '{name:$name, status:$status, current_rpm:$rpm, baseline_source:$bsrc}') )
        done <<< "$ipmi_sdr_out"
    fi

    # [FIX] Corrected if statement syntax
    if (( needs_baseline_update )) || [[ "${RE_BASELINE:-false}" == "true" ]]; then
        jq -n '$ARGS.positional | . as $a | reduce ($a | length - 1) as $i (-1; . + {($a[$i*2]): ($a[$i*2+1]|tonumber)})' --args "${!FILE_BASELINE_RPM[@]}" "${FILE_BASELINE_RPM[@]}" > "$baseline_path"
        echo "[INFO] Fan baseline updated: $baseline_path"
    fi

    local final_status="PASS"
    local final_reason="所有風扇轉速正常"
    if (( ${#metrics_json_array[@]} == 0 )); then
        final_reason="從 IPMI/OS 取得風扇資料, 但無法解析出任何 RPM 讀值"
        final_status="WARN"
    elif (( low_rpm_count > 0 )); then
         final_status="WARN"
         final_reason="風扇轉速警告: ${low_rpm_count} 個風扇轉速低於 ${FAN_RPM_TH} RPM. (${reason_details[*]})."
    elif (( deviation_crit_count > 0 )); then
         final_status="FAIL"
         final_reason="風扇嚴重異常: ${deviation_crit_count} 個偏差過大. (${reason_details[*]})."
    elif (( deviation_warn_count > 0 )); then
         final_status="WARN"
         final_reason="風扇轉速警告: ${deviation_warn_count} 個偏差>20%. (${reason_details[*]})."
    elif (( ${#fan_summary_array[@]} > 0 )); then
        final_reason+=". Details: $(IFS=', '; echo "${fan_summary_array[*]}")"
    fi

    local final_json
    final_json=$(jq -n \
        --arg status "$final_status" \
        --arg item "$item" \
        --arg reason "$final_reason" \
        --argjson metrics "[$(IFS=,; echo "${metrics_array[*]}")]" \
        --argjson thresholds "{\"low_rpm_th\": ${FAN_RPM_TH}, \"deviation_warn_pct\": ${DEVIATION_WARN_PCT}, \"deviation_crit_pct\": ${DEVIATION_CRIT_PCT}}" \
        --argjson evidence "{\"sensors_log\": \"${raw_sensors_log}\", \"ipmi_sdr_log\": \"${raw_ipmi_sdr_log}\", \"baseline_file\": \"${baseline_path}\"}" \
        '{status:$status, item:$item, reason:$reason, metrics:$metrics, thresholds:$thresholds, evidence:$evidence}')

    # --- Build judgement ---
    local th_json
    th_json=$(jq -n \
      --arg rpm_th "$FAN_RPM_TH" \
      --arg warn_pct "$DEVIATION_WARN_PCT" \
      --arg crit_pct "$DEVIATION_CRIT_PCT" \
      '{FAN_RPM_TH: ($rpm_th|tonumber), DEVIATION_WARN_PCT: ($warn_pct|tonumber), DEVIATION_CRIT_PCT: ($crit_pct|tonumber)}')

    local fan_count="${#metrics_json_array[@]}"
    local checks_json
    checks_json=$(jq -n \
      --arg low_count "$low_rpm_count" \
      --arg dev_crit_count "$deviation_crit_count" \
      --arg dev_warn_count "$deviation_warn_count" \
      --arg fan_count "${fan_count:-0}" \
      --arg rpm_th "$FAN_RPM_TH" \
      --arg warn_pct "$DEVIATION_WARN_PCT" \
      --arg crit_pct "$DEVIATION_CRIT_PCT" \
      '[
         {"name":"低轉速風扇數=0","ok":($low_count|tonumber==0),"value":("low_rpm_count="+$low_count)},
         {"name":"嚴重偏差風扇數=0","ok":($dev_crit_count|tonumber==0),"value":("deviation_crit="+$dev_crit_count)},
         {"name":"警告偏差風扇數=0","ok":($dev_warn_count|tonumber==0),"value":("deviation_warn="+$dev_warn_count)},
         {"name":"檢測到的風扇數","ok":($fan_count|tonumber>0),"value":("fans="+$fan_count)},
         {"name":"門檻","ok":true,"value":("FAN_RPM_TH="+$rpm_th+", WARN_PCT="+$warn_pct+"%, CRIT_PCT="+$crit_pct+"%")}
       ]')

    local pass_rules=$(printf '["所有風扇轉速 >= FAN_RPM_TH 且偏差 <= %s%%"]' "$DEVIATION_WARN_PCT")
    local warn_rules=$(printf '["任一風扇轉速 < FAN_RPM_TH 或 %s%% < 偏差 <= %s%%"]' "$DEVIATION_WARN_PCT" "$DEVIATION_CRIT_PCT")
    local fail_rules=$(printf '["任一風扇偏差 > %s%%"]' "$DEVIATION_CRIT_PCT")
    local criteria="風扇健康：所有風扇 RPM ≥ ${FAN_RPM_TH}；相對 baseline 偏差 ≤ ${DEVIATION_WARN_PCT}% 為 PASS；偏差 > ${DEVIATION_CRIT_PCT}% 為 FAIL。"

    local jdg_json
    jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

    echo "$final_json" > "$metrics_path"
    set_check_result_with_jdg 7 "$final_json" "$jdg_json"
}

check_env() {
    local item="Environment.Temp"
    echo -e "${C_BLUE}[8] 機房環境 (Inlet/Ambient)${C_RESET}"

    if (( SKIP_BMC )); then
        set_check_result 8 "$(jq -n --arg item "$item" '{status:"SKIP", item:$item, reason:"BMC skipped"}')"
        return
    fi

    # Define paths
    local raw_log_path="${LOG_DIR}/ipmi_sdr_env_${TIMESTAMP}.log"
    local metrics_dir="${LOG_DIR}/env"
    local metrics_path="${metrics_dir}/metrics_${TIMESTAMP}.json"
    mkdir -p "${metrics_dir}"

    local sdr_out
    sdr_out=$(ipmi_try sdr elist)
    if [[ $? -ne 0 || -z "$sdr_out" ]]; then
        set_check_result 8 "$(jq -n --arg item "$item" '{status:"FAIL", item:$item, reason:"無法取得 IPMI SDR 資料"}')"
        return
    fi
    
    printf '%s\n' "$sdr_out" > "$raw_log_path"

    # --- Historical Analysis ---
    local history_days="$LOG_DAYS"
    local historical_files
    mapfile -t historical_files < <(find "$metrics_dir" -name "metrics_*.json" -mtime -"$history_days" 2>/dev/null)
    local historical_stats_json='{}'
    if [[ ${#historical_files[@]} -gt 0 ]]; then
        historical_stats_json=$(jq -s '
            map(.metrics[]) | group_by(.name) | map({
                (.[0].name): {
                    peak_temp: (map(.value) | max),
                    avg_temp: ((map(.value) | add) / length)
                }
            }) | add
        ' "${historical_files[@]}")
    fi

    local include_regex='(inlet|ambient|board|mb|bp|pch|scm|psu|system|chassis|backplane|center|centre)'
    local exclude_regex='(cpu|vr|mem|dim|nvme|ssd|gpu|asic|retimer|ocp|vcore)'
    local -a primary_sensor_lines=()
    local -a fallback_sensor_lines=()

    while IFS= read -r line; do
        [[ -z "$line" || "$line" != *"|"* ]] && continue
        line=${line%$'\r'}

        # [FIX] Only process lines that are actual temperature readings in Celsius
        echo "$line" | grep -q -i "degrees C" || continue

        IFS='|' read -r raw_name _ raw_status _ raw_value _ <<< "$line"
        local name value_field temp_val name_lower
        name=$(printf '%s' "${raw_name:-}" | trim)
        [[ -z "$name" ]] && continue
        value_field=$(printf '%s' "${raw_value:-}" | trim)
        value_field=${value_field%$'\r'}
        if [[ ! "$value_field" =~ ^([+-]?[0-9]+(\.[0-9]+)?) ]]; then
            continue
        fi
        temp_val="${BASH_REMATCH[1]#+}"
        name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        if [[ "$name_lower" =~ $exclude_regex ]]; then
            continue
        fi
        local entry="${name}|${temp_val}|${ENV_TEMP_WARN}|${ENV_TEMP_CRIT}"
        if [[ "$name_lower" =~ $include_regex ]]; then
            primary_sensor_lines+=("$entry")
        else
            fallback_sensor_lines+=("$entry")
        fi
    done <<< "$sdr_out"

    local -a sensor_lines=()
    local used_fallback=0
    if (( ${#primary_sensor_lines[@]} > 0 )); then
        sensor_lines=("${primary_sensor_lines[@]}")
    elif (( ${#fallback_sensor_lines[@]} > 0 )); then
        sensor_lines=("${fallback_sensor_lines[@]}")
        used_fallback=1
    fi
    echo "DEBUG ENV: sensor_lines count=${#sensor_lines[@]}" >&2
    if ((${#sensor_lines[@]} > 0)); then
      echo "DEBUG ENV: first line='${sensor_lines[0]}'" >&2
    fi

    if (( ${#sensor_lines[@]} == 0 )); then
        local warn_json
        warn_json=$(jq -n --arg item "$item" --arg raw "$raw_log_path" '{status:"WARN", item:$item, reason:"無法解析環境溫度感測器資料", evidence:{raw_sdr_log:$raw}}')
        set_check_result 8 "$warn_json"
        return
    fi

    local final_status="PASS"
    local final_reason=""
    local -a reason_details=()
    local -a sensor_summary=()
    local metrics_array=()
    local overall_warn=""
    local overall_crit=""

    for line in "${sensor_lines[@]}"; do
        IFS='|' read -r name reading warn_raw crit_raw <<< "$line"
        [[ -z "$name" || -z "$reading" ]] && continue

        local reading_val
        reading_val=$(awk -v v="$reading" 'BEGIN { if (v+0==v) printf "%.2f", v; else print "" }')
        [[ -z "$reading_val" ]] && continue

        local warn_val="" crit_val=""
        [[ "$warn_raw" =~ ^[0-9]+(\.[0-9]+)?$ ]] && warn_val="$warn_raw"
        [[ "$crit_raw" =~ ^[0-9]+(\.[0-9]+)?$ ]] && crit_val="$crit_raw"

        sensor_summary+=( "$(printf '%s:%s°C' "$name" "$(awk -v v="$reading_val" 'BEGIN{printf "%.1f", v}')")" )

        if [[ -n "$warn_val" ]]; then
            if [[ -z "$overall_warn" ]] || awk -v a="$warn_val" -v b="$overall_warn" 'BEGIN { exit (a < b) ? 0 : 1 }'; then
                overall_warn="$warn_val"
            fi
        fi
        if [[ -n "$crit_val" ]]; then
            if [[ -z "$overall_crit" ]] || awk -v a="$crit_val" -v b="$overall_crit" 'BEGIN { exit (a < b) ? 0 : 1 }'; then
                overall_crit="$crit_val"
            fi
        fi

        local sensor_status="PASS"
        if [[ -n "$crit_val" ]] && float_ge "$reading_val" "$crit_val"; then
            sensor_status="FAIL"
            final_status="FAIL"
            reason_details+=( "$(printf '%s: %.1f°C >= %.1f°C' "$name" "$reading_val" "$crit_val")" )
        elif [[ -n "$warn_val" ]] && float_ge "$reading_val" "$warn_val"; then
            sensor_status="WARN"
            [[ "$final_status" != "FAIL" ]] && final_status="WARN"
            reason_details+=( "$(printf '%s: %.1f°C >= %.1f°C' "$name" "$reading_val" "$warn_val")" )
        fi

        local sensor_history
        sensor_history=$(echo "$historical_stats_json" | jq -c --arg name "$name" '.[$name] // null' 2>/dev/null)
        [[ -z "$sensor_history" ]] && sensor_history="null"

        metrics_array+=( "$(jq -n \
            --arg name "$name" \
            --arg status "$sensor_status" \
            --arg value "$reading_val" \
            --arg unit "C" \
            --arg warn "$warn_val" \
            --arg crit "$crit_val" \
            --argjson history "$sensor_history" \
            '{name:$name, status:$status, value:($value|tonumber), unit:$unit,
              warn_threshold:(if $warn=="" then null else ($warn|tonumber) end),
              crit_threshold:(if $crit=="" then null else ($crit|tonumber) end),
              historical_stats:$history}')" )
    done

    if (( ${#metrics_array[@]} == 0 )); then
        local warn_json
        warn_json=$(jq -n --arg item "$item" --arg raw "$raw_log_path" '{status:"WARN", item:$item, reason:"無法解析環境溫度感測器資料", evidence:{raw_sdr_log:$raw}}')
        set_check_result 8 "$warn_json"
        return
    fi

    if [[ "$final_status" == "PASS" ]]; then
        local warn_disp="-" crit_disp="-"
        [[ -n "$overall_warn" ]] && warn_disp=$(awk -v v="$overall_warn" 'BEGIN{printf "%.1f", v}')
        [[ -n "$overall_crit" ]] && crit_disp=$(awk -v v="$overall_crit" 'BEGIN{printf "%.1f", v}')
        local summary_line=""
        if (( ${#sensor_summary[@]} > 0 )); then
            summary_line=$(IFS=', '; echo "${sensor_summary[*]}")
        fi
        final_reason="環境溫度正常 (警戒 ${warn_disp}°C / 臨界 ${crit_disp}°C)。${summary_line}"
    else
        local detail_line=$(IFS='; '; echo "${reason_details[*]}")
        final_reason="環境溫度異常: ${detail_line}"
    fi
    if (( used_fallback )); then
        final_reason+="（以後備感測器分類）"
    fi

    local metrics_json
    metrics_json=$(printf '%s\n' "${metrics_array[@]}" | jq -s '.')

    local thresholds_json
    thresholds_json=$(jq -n \
        --arg warn "$overall_warn" \
        --arg crit "$overall_crit" \
        '{observed_warn_celsius:(if $warn=="" then null else ($warn|tonumber) end),
          observed_crit_celsius:(if $crit=="" then null else ($crit|tonumber) end),
          policy:"sdr"}')

    local final_json
    final_json=$(jq -n \
        --arg status "$final_status" \
        --arg item "$item" \
        --arg reason "$final_reason" \
        --argjson metrics "$metrics_json" \
        --argjson thresholds "$thresholds_json" \
        --argjson evidence "$(jq -n --arg raw "$raw_log_path" '{raw_sdr_log:$raw}')" \
        '{status:$status, item:$item, reason:$reason, metrics:$metrics, thresholds:$thresholds, evidence:$evidence}')

    # --- Build judgement ---
    local th_json
    th_json=$(jq -n \
      --arg warn "$overall_warn" \
      --arg crit "$overall_crit" \
      '{ENV_TEMP_WARN: (if $warn=="" then null else ($warn|tonumber) end),
        ENV_TEMP_CRIT: (if $crit=="" then null else ($crit|tonumber) end)}')

    local max_temp_val=$(echo "$metrics_json" | jq -r 'map(.value) | max // 0')
    local checks_json
    checks_json=$(jq -n \
      --arg max_temp "$max_temp_val" \
      --arg warn "$overall_warn" \
      --arg crit "$overall_crit" \
      '[{"name":"Max Temp <= WARN","ok":(if $warn=="" then true else (($max_temp|tonumber) <= ($warn|tonumber)) end),"value":("max="+$max_temp+"°C")},
        {"name":"Max Temp <= CRIT","ok":(if $crit=="" then true else (($max_temp|tonumber) <= ($crit|tonumber)) end),"value":("max="+$max_temp+"°C")}]')

    local pass_rules='["最大環境溫度 <= WARN"]'
    local warn_rules='["WARN < 最大環境溫度 <= CRIT"]'
    local fail_rules='["最大環境溫度 > CRIT"]'
    local criteria="環境溫度：代表性傳感器（Inlet/Ambient）最大值 ≤ WARN（\${ENV_TEMP_WARN}°C）為 PASS；WARN < Max ≤ CRIT（\${ENV_TEMP_CRIT}°C）為 WARN；Max > CRIT 為 FAIL。"

    local jdg_json
    jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

    echo "$final_json" > "$metrics_path"
    set_check_result_with_jdg 8 "$final_json" "$jdg_json"
}

# ----------------- 9 Power / UPS -----------------
check_power_ups() {
  echo -e "${C_BLUE}[9] 電力 / UPS (概況)${C_RESET}"
  set_status 9 "SKIP" "UPS check is now performed by a separate script. See the consolidated report for details."
  UPS_OVERALL="SEPARATED" # Set this for master JSON compatibility
  # This function is kept for item numbering consistency.
}

# ----------------- 10 Network Perf -----------------
check_network_perf() {
  echo -e "${C_BLUE}[10] 網路 (連通/頻寬/時間同步)${C_RESET}"
  local gw=""
  gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
  if [[ -n "$gw" ]]; then
    if ping -c1 -W1 "$gw" >/dev/null 2>&1; then echo "[GW] $gw OK"; else echo "[GW] $gw FAIL"; fi
  else
    echo "[GW] 無 default route"
  fi
  if (( OFFLINE )); then
    echo "[NET] 外網測試略過 (offline)"
  else
    if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 || ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
      echo "[NET] 公共 DNS ICMP OK"
    else
      echo "[NET] 公共 DNS ICMP FAIL"
    fi
  fi
  if [[ -n "$PING_HOST" ]]; then
    if ping -c1 -W1 "$PING_HOST" >/dev/null 2>&1; then
      echo "[PING_HOST] $PING_HOST OK"
    else
      echo "[PING_HOST] $PING_HOST FAIL"
    fi
  fi
  if [[ -n "$IPERF_TARGET" ]]; then
    if command -v iperf3 >/dev/null 2>&1; then
      echo "[iperf3] 測試 $IPERF_TARGET 時間 ${IPERF_TIME}s"
      iperf_out=$(iperf3 -c "$IPERF_TARGET" -t "$IPERF_TIME" 2>&1 || true)
      echo "$iperf_out"
      bw_line=$(echo "$iperf_out" | grep -E 'SUM.*bits/sec|receiver' | tail -n1)
      [[ -n "$bw_line" ]] && echo "[iperf3] $bw_line"
    else
      echo "[iperf3] 無 iperf3 指令"
    fi
  fi
  if command -v ss >/dev/null 2>&1; then ss -s || true; fi
  local time_note=""
  if command -v chronyc >/dev/null 2>&1; then
    off=$(chronyc tracking 2>/dev/null | grep -i 'Last offset' | awk '{print $(NF-1)}' || echo 0)
    time_note="chronyc_offset=$off"
    echo "[Time] $time_note"
  elif command -v timedatectl >/dev/null 2>&1; then
    td=$(timedatectl 2>/dev/null | grep 'System clock synchronized' || true)
    time_note="timedatectl_sync=$(echo "$td" | awk '{print $4}')"
    echo "[Time] $time_note"
  else
    time_note="no_timesync_tool"
    echo "[Time] 無 chronyc / timedatectl"
  fi
  if (( OFFLINE )); then
    set_status 10 "INFO" "Offline 模式 $time_note"
  else
    if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 || ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
      set_status 10 "PASS" "外網可達 $time_note"
    else
      set_status 10 "WARN" "外網不可達 $time_note"
    fi
  fi
}

# ----------------- 11 Cabling -----------------
check_cabling() {
  echo -e "${C_BLUE}[11] 線材與 Link Flap${C_RESET}"

  local nics
  nics=$(ls /sys/class/net | grep -vE '^(lo|docker.*|veth.*|br-.*|cni.*|flannel.*|cali.*|tun.*|tap.*|virbr.*)$' || true)
  for nic in $nics; do
      echo "-- $nic --"
      ethtool "$nic" 2>/dev/null | egrep -i 'Speed|Duplex|Link detected' || true
  done

  if command -v journalctl >/dev/null 2>&1; then
    echo "[INFO] Checking journal for link flaps in the last ${LOG_DAYS} days."
    journalctl --since "${LOG_DAYS} days ago" | egrep -i 'link is (up|down)|carrier lost|resetting' || true
  else
    echo "[WARN] journalctl not found, falling back to dmesg for link flaps."
    sudo dmesg | egrep -i 'link is (up|down)|carrier lost|resetting' | tail -n 60 || true
  fi
  set_status 11 "INFO" "列出 link/carrier/resetting (人工判讀)"
}

# -------- SEL 規則處理結構 --------
declare -a MAP_LEVEL MAP_TYPE MAP_PATTERN
load_severity_map() {
  [[ -z "$SEL_SEVERITY_MAP" ]] && return 0
  if [[ ! -f "$SEL_SEVERITY_MAP" ]]; then
    echo "[SEL] severity map 檔案不存在: $SEL_SEVERITY_MAP"; return 1
  fi
  local line idx=0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    local lvl rest type pattern
    lvl=$(echo "$line" | awk '{print $1}')
    rest=$(echo "$line" | cut -d' ' -f2-)
    lvl=$(echo "$lvl" | tr '[:lower:]' '[:upper:]')
    [[ -z "$rest" ]] && continue
    if [[ "$rest" =~ ^substr: ]]; then
      type="substr"; pattern="${rest#substr:}"
    elif [[ "$rest" =~ ^regex:/ ]]; then
      type="regex"; pattern="${rest#regex:/}"; pattern="${pattern%/}"
    elif [[ "$rest" =~ ^sensor: ]]; then
      type="sensor"; pattern="${rest#sensor:}"
    elif [[ "$rest" =~ ^exact: ]]; then
      type="exact"; pattern="${rest#exact:}"
    elif [[ "$rest" =~ ^noise: ]]; then
      type="substr"; pattern="${rest#noise:}"; lvl="NOISE"
    else
      type="substr"; pattern="$rest"
    fi
    MAP_LEVEL[idx]="$lvl"
    MAP_TYPE[idx]="$type"
    MAP_PATTERN[idx]="$pattern"
    ((idx++))
  done < "$SEL_SEVERITY_MAP"
  echo "[SEL] 載入自訂 map 條目數: ${#MAP_LEVEL[@]}"
}

severity_from_rules() {
  local sensor="$1" event="$2"
  local sensor_l event_l
  sensor_l=$(echo "$sensor" | tr '[:upper:]' '[:lower:]')
  event_l=$(echo "$event" | tr '[:upper:]' '[:lower:]')
  local i pat t lvl
  for i in "${!MAP_LEVEL[@]}"; do
    lvl="${MAP_LEVEL[$i]}"; t="${MAP_TYPE[$i]}"; pat="${MAP_PATTERN[$i]}"
    case "$t" in
      substr)
        if [[ "$event_l" == *$(echo "$pat" | tr '[:upper:]' '[:lower:]')* ]]; then
          echo "$lvl"; return 0
        fi ;;
      sensor)
        if [[ "$sensor_l" == *$(echo "$pat" | tr '[:upper:]' '[:lower:]')* ]]; then
          echo "$lvl"; return 0
        fi ;;
      exact)
        if [[ "$event_l" == "$(echo "$pat" | tr '[:upper:]' '[:lower:]')" ]]; then
          echo "$lvl"; return 0
        fi ;;
      regex)
        if echo "$event" | grep -Eiq "$pat"; then
          echo "$lvl"; return 0
        fi ;;
    esac
  done
  return 1
}

# [MOD] Replaced with sel_is_noise from builder
is_internal_noise(){
  sel_is_noise "$1"
}

# ----------------- 12 BMC / SEL -----------------
SEL_CRIT=0 SEL_WARN=0 SEL_INFO=0 SEL_NOISE_RAW=0
SEL_TOP_ARRAY=()          # top sensors
SEL_CW_EVENTS_ARRAY=()    # 內嵌 CRIT/WARN
check_bmc() {
  local item="BMC.SEL"
  echo -e "${C_BLUE}[12] BMC / SEL${C_RESET}"

  if (( SKIP_BMC )); then
    local skip_json
    skip_json=$(jq -n --arg item "$item" '{status:"SKIP", item:$item, reason:"BMC skipped", evidence:{}}')
    set_check_result 12 "$skip_json"
    return
  fi

  ipmi_try mc info 2>/dev/null | egrep -i 'Firmware|Version' || true

  local sel_raw
  sel_raw=$(ipmi_try sel elist 2>/dev/null || ipmi_try sel list 2>/dev/null || echo "")
  
  local evidence
  evidence=$(jq -n --arg sel_detail "$SEL_DETAIL_FILE" --arg sel_events "$SEL_EVENTS_JSON" \
    '{sel_detail_log:$sel_detail, sel_events_json:$sel_events}')

  if [[ -z "$sel_raw" ]]; then
    local warn_json
    warn_json=$(jq -n --arg item "$item" --arg reason "無法取得 SEL" --argjson evidence "$evidence" \
        '{status:"WARN", item:$item, reason:$reason, evidence:$evidence}')
    set_check_result 12 "$warn_json"
    return
  fi

  echo "$sel_raw" > "$SEL_DETAIL_FILE"
  echo "[Info] SEL 詳細寫入: $SEL_DETAIL_FILE"

  if echo "$sel_raw" | grep -qi 'no entries'; then
    echo "[SEL] 空 (no entries)"
    echo '[]' > "$SEL_EVENTS_JSON"
    SEL_CRIT=0; SEL_WARN=0; SEL_INFO=0; SEL_NOISE_RAW=0
    local pass_json
    pass_json=$(jq -n --arg item "$item" --arg reason "SEL 空 (no entries)" --argjson evidence "$evidence" \
        '{status:"PASS", item:$item, reason:$reason, evidence:$evidence}')
    set_check_result 12 "$pass_json"
    return
  fi

  load_severity_map

  local now_epoch=$(date +%s) cutoff=0
  (( SEL_DAYS>0 )) && cutoff=$(( now_epoch - SEL_DAYS*86400 ))

  declare -A SENSOR_SUMMARY
  declare -a EVENTS_JSON
  while IFS=$'\n' read -r rawline; do
    [[ -z "$rawline" ]] && continue
    [[ "$rawline" != *"|"* ]] && continue
    local pipe_cnt
    pipe_cnt=$(grep -o '|' <<< "$rawline" | wc -l)
    (( pipe_cnt < 5 )) && continue

    IFS='|' read -r f1 f2 f3 f4 f5 f6 rest <<< "$rawline"
    for v in f1 f2 f3 f4 f5 f6; do
      eval "$v=\"$(echo \"\${$v}\" | sed 's/^ *//;s/ *$//')\""
    done
    echo "$f6" | grep -iq 'Deasserted' && continue
    [[ -z "$f4" || -z "$f5" ]] && continue

    if (( SEL_DAYS>0 )) && [[ "$f2" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ ]]; then
      evt_epoch=$(date -d "$f2 $f3" +%s 2>/dev/null || echo 0)
      if (( evt_epoch>0 && evt_epoch<cutoff )); then
        continue
      fi
    fi

    local sensor="$f4" event="$f5" event_l
    event_l=$(echo "$event" | tr '[:upper:]' '[:lower:]')
    local sev=""
    if severity_from_rules "$sensor" "$event" >/dev/null 2>&1; then
      sev=$(severity_from_rules "$sensor" "$event")
    else
      if [[ "$event_l" =~ predictive\ failure ]]; then
        sev="WARN"
      elif [[ "$event_l" =~ (uncorrect|fatal|thermal\ trip|overheat|ac\ lost|power\ down|voltage\ failure|fan\ failure|cpu\ failure) ]]; then
        sev="CRIT"
      elif [[ "$event_l" =~ (fail|failure|degraded|ecc|correct|threshold|redundancy\ lost) ]]; then
        sev="WARN"
      else
        sev="INFO"
      fi
      if is_internal_noise "$event_l"; then
        [[ "$sev" == "INFO" ]] && sev="NOISE"
      fi
    fi

    if [[ "$sev" == "NOISE" ]]; then
      ((SEL_NOISE_RAW++))
      (( SEL_NOISE_HIDE )) && continue || sev="INFO"
    fi
    case "$sev" in
      CRIT) ((SEL_CRIT++));;
      WARN) ((SEL_WARN++));;
      *)    ((SEL_INFO++));;
    esac
    [[ -n "$sensor" ]] && SENSOR_SUMMARY["$sensor"]=$(( ${SENSOR_SUMMARY["$sensor"]:-0} + 1 ))

    local dt_iso="$(echo "$f2" | sed 's/\//-/g')T${f3}"
    local esc_event esc_sensor raw_esc
    esc_event=$(echo "$event" | sed 's/"/\\"/g')
    esc_sensor=$(echo "$sensor" | sed 's/"/\\"/g')
    raw_esc=$(echo "$rawline" | sed 's/"/\\"/g')
    EVENTS_JSON+=("{\"id\":\"$f1\",\"date\":\"$f2\",\"time\":\"$f3\",\"datetime\":\"$dt_iso\",\"sensor\":\"$esc_sensor\",\"event\":\"$esc_event\",\"severity\":\"$sev\",\"level\":\"$sev\",\"raw\":\"$raw_esc\"}")
    if [[ "$sev" == "CRIT" || "$sev" == "WARN" ]]; then
      SEL_CW_EVENTS_ARRAY+=("{\"id\":\"$f1\",\"datetime\":\"$dt_iso\",\"sensor\":\"$esc_sensor\",\"event\":\"$esc_event\",\"severity\":\"$sev\",\"level\":\"$sev\"}")
    fi
  done <<< "$sel_raw"

  local top_str
  top_str=$(for k in "${!SENSOR_SUMMARY[@]}"; do echo "${SENSOR_SUMMARY[$k]} $k"; done | sort -rn | head -n "$SEL_SHOW" | awk '{printf "%s:%s ",$2,$1}')
  [[ -z "$top_str" ]] && top_str="無"

  # 組 top sensors array for JSON
  SEL_TOP_ARRAY=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local cnt; cnt=$(echo "$line" | cut -d':' -f1)
    local name; name=$(echo "$line" | cut -d':' -f2-)
    local esc_name; esc_name=$(echo "$name" | jq -R . | sed 's/^"//;s/"$//')
    SEL_TOP_ARRAY+=("{\"sensor\":\"$esc_name\",\"count\":$cnt}")
  done < <(for k in "${!SENSOR_SUMMARY[@]}"; do echo "${SENSOR_SUMMARY[$k]}:$k"; done | sort -rn | head -n "$SEL_SHOW")

  echo "[SEL] CRIT=$SEL_CRIT WARN=$SEL_WARN INFO=$SEL_INFO (noise_hidden=$SEL_NOISE_HIDE noise_raw=$SEL_NOISE_RAW) (Top: $top_str)"

  {
    echo '['
    local first=1
    for e in "${EVENTS_JSON[@]}"; do
      if (( first )); then printf "%s" "$e"; first=0; else printf ",%s" "$e"; fi
    done
    printf ',{"summary":{"crit":%d,"warn":%d,"info":%d,"noise_raw":%d,"noise_hidden":%d}}' \
      "$SEL_CRIT" "$SEL_WARN" "$SEL_INFO" "$SEL_NOISE_RAW" "$SEL_NOISE_HIDE"
    echo ']'
  } > "$SEL_EVENTS_JSON"
  echo "[SEL] 事件明細 JSON: $SEL_EVENTS_JSON"

  if [[ -n "$SEL_TOP_JSON" ]]; then
    {
      echo '['
      local first=1
      for t in "${SEL_TOP_ARRAY[@]}"; do
        if (( first )); then printf "%s" "$t"; first=0; else printf ",%s" "$t"; fi
      done
      echo ']'
    } > "$SEL_TOP_JSON"
    echo "[SEL] Top sensors JSON: $SEL_TOP_JSON"
  fi

  local final_status="PASS"
  local final_reason="SEL 無關鍵事件"
  if (( SEL_CRIT > 0 )); then
    final_status="FAIL"
    final_reason="SEL CRIT=$SEL_CRIT WARN=$SEL_WARN"
  elif (( SEL_WARN > 0 )); then
    final_status="WARN"
    final_reason="SEL WARN=$SEL_WARN"
  fi

  local last_cw_date="" last_cw_ts="" _dt="" _mmdd="" days_since_last=""

  # ---- [SEL] append "X 天前" 到 Reason ----
  # 需要：SEL_EVENTS_JSON、SEL_DAYS、SCRIPT_START_TS、final_reason、SEL_CRIT、SEL_WARN
  {
    last_cw_date="$(jq -r 'map(select(.level=="CRIT" or .level=="WARN")) | last | .datetime // empty' "$SEL_EVENTS_JSON" 2>/dev/null)"
  } || true

  if [[ -n "$last_cw_date" ]]; then
    _dt="${last_cw_date/T/ }"
    last_cw_ts="$(date -d "$_dt" +%s 2>/dev/null || true)"
    if [[ -z "$last_cw_ts" ]]; then
      _mmdd="$(sed -E 's#^([0-9]{2})-([0-9]{2})-([0-9]{4})#\3-\1-\2#' <<< "$_dt")"
      last_cw_ts="$(date -d "$_mmdd" +%s 2>/dev/null || true)"
    fi
    if [[ -n "$last_cw_ts" ]]; then
      days_since_last=$(( (SCRIPT_START_TS - last_cw_ts) / 86400 ))
      if (( SEL_CRIT==0 && SEL_WARN==0 )); then
        final_reason="過去 ${SEL_DAYS} 天內無 CRIT/WARN；距今已 ${days_since_last} 天未再發"
      else
        final_reason+=" (最近一次 CRIT/WARN 為 ${days_since_last} 天前)"
      fi
    fi
  fi
  # -----------------------------------------

  local final_json
  final_json=$(jq -n --arg item "$item" --arg status "$final_status" --arg reason "$final_reason" --argjson evidence "$evidence" \
    '{status:$status, item:$item, reason:$reason, evidence:$evidence}')

  # --- Build judgement ---
  local th_json
  th_json=$(jq -n --arg sel_days "$SEL_DAYS" '{SEL_DAYS: ($sel_days|tonumber)}')

  local checks_json
  checks_json=$(jq -n \
    --arg crit "$SEL_CRIT" \
    --arg warn "$SEL_WARN" \
    --arg info "$SEL_INFO" \
    --arg days_since "$days_since_last" \
    '[{"name":"SEL CRIT 事件=0","ok":($crit|tonumber==0),"value":("crit="+$crit)},
      {"name":"SEL WARN 事件=0","ok":($warn|tonumber==0),"value":("warn="+$warn)},
      {"name":"SEL INFO 事件計數","ok":true,"value":("info="+$info)},
      {"name":"距上次 CRIT/WARN 天數","ok":true,"value":("days_since_last="+$days_since)}]')

  local pass_rules='["SEL_DAYS 視窗內 CRIT=0 且 WARN=0"]'
  local warn_rules='["SEL WARN>0 但 CRIT=0"]'
  local fail_rules='["SEL CRIT>0"]'
  local criteria="BMC/SEL 健康：過去 ${SEL_DAYS} 天內 CRIT=0 且 WARN=0 為 PASS；有 WARN 且無 CRIT 為 WARN；有 CRIT 為 FAIL。"

  local jdg_json
  jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

  set_check_result_with_jdg 12 "$final_json" "$jdg_json"
}

# ----------------- 13 Logs -----------------
# NEW function for detailed log analysis
analyze_system_logs() {
  local days="$1"
  local output_file="$2"
  echo -e "\n${C_YELLOW}--- System Log Analysis Summary (Last ${days} Days) ---${C_RESET}"

  echo "[INFO] Saving full high-priority logs (p0-3) to ${output_file}..."
  sudo journalctl -p 0..3 --since "${days} days ago" -o short-iso > "$output_file"

  echo -e "\n${C_BOLD}Top 20 Error-producing Processes (p3):${C_RESET}"
  sudo journalctl -p 3 --since "${days} days ago" -o short-unix | awk '{print $5}' | sed 's/://;s/\[.*//' | sort | uniq -c | sort -nr | head -n 20 | tee -a "$output_file"

  echo -e "\n${C_BOLD}Categorized Error Summary (p3):${C_RESET}"
  {
    echo -e "\n--- ECC/MCE (Memory/CPU Errors) ---"
    sudo journalctl -p 3 --since "${days} days ago" | egrep -i 'mce|machine check|edac|ecc|uncorrect' || echo "None found."
    echo -e "\n--- Disk/RAID/NVMe/FS Errors ---"
    sudo journalctl -p 3 --since "${days} days ago" | egrep -i 'i/o error|buffer i/o|blk_update|nvme|smartd|mdadm|raid|rebuild|degrade|ext4|xfs|btrfs|filesystem|journal abort' || echo "None found."
    echo -e "\n--- Network Errors ---"
    sudo journalctl -p 3 --since "${days} days ago" | egrep -i 'link is down|link down|carrier|mlx|ixgbe|e1000|igb|rtnetlink|dns|NetworkManager' || echo "None found."
    echo -e "\n--- GPU/NVIDIA Errors ---"
    sudo journalctl -p 3 --since "${days} days ago" | egrep -i 'nvidia|gpu|xid' || echo "None found."
    echo -e "\n--- Service/System Stability ---"
    sudo journalctl -p 3 --since "${days} days ago" | egrep -i 'segfault|core dump|oom-killer|killed process|out of memory|assert|panic' || echo "None found."
  } | tee -a "$output_file"
  echo -e "${C_YELLOW}--- End of System Log Analysis ---${C_RESET}"
}

check_logs() {
  echo -e "${C_BLUE}[13] 系統日誌 (硬體/RAS)${C_RESET}"
  local critical
  if command -v journalctl >/dev/null 2>&1; then
    critical=$(journalctl -k -p 0..3 --since "${LOG_DAYS} days ago" 2>/dev/null | wc -l)
    echo "[過去 ${LOG_DAYS} 天 p0..3 行數] $critical"
    if (( critical>1 )); then
      set_status 13 "WARN" "過去 ${LOG_DAYS} 天內發現 ${critical} 筆高優先級日誌 (詳見主日誌摘要與 ${JOURNAL_ANALYSIS_LOG##*/})"
      analyze_system_logs "$LOG_DAYS" "$JOURNAL_ANALYSIS_LOG"
    else
      set_status 13 "PASS" "過去 ${LOG_DAYS} 天內高優先級日誌正常"
    fi
  else
    set_status 13 "SKIP" "無 journalctl"
  fi
}

# ----------------- 14 Firmware -----------------
BIOS_VERSION=""
check_firmware() {
  echo -e "${C_BLUE}[14] 韌體版本${C_RESET}"
  local bios
  bios=$(sudo dmidecode -t bios 2>/dev/null | egrep -i 'Version|Release Date' || true)
  echo "$bios"
  BIOS_VERSION=$(echo "$bios" | grep -i 'Version' | head -n1 | awk -F: '{print $2}' | xargs || echo "")
  if (( ! SKIP_BMC )); then
    ipmi_try mc info 2>/dev/null | egrep -i 'Firmware|Version' || true
  fi
  for nic in $(ls /sys/class/net | grep -v lo); do
    echo "NIC $nic:"
    ethtool -i "$nic" 2>/dev/null | egrep -i 'driver|firmware|version' || true
  done
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=driver_version,firmware_version --format=csv 2>/dev/null || true
  fi
  for d in /dev/sd?; do
    [[ -b "$d" ]] || continue
    smartctl -i "$d" 2>/dev/null | egrep -i 'Device Model|Model Number|Firmware|Serial' || true
  done
  if command -v nvme >/dev/null 2>&1; then
    nvme list 2>/dev/null || true
  fi
  set_status 14 "INFO" "列出 BIOS/NIC/GPU/Disk/NVMe (人工比對)"
}

# ----------------- 15 Fio -----------------
check_io_perf() {
  echo -e "${C_BLUE}[15] I/O 讀寫測試 (fio)${C_RESET}"
  if (( RUN_FIO==0 )); then
    set_status 15 "SKIP" "未啟用 fio"
    return
  fi
  if ! command -v fio >/dev/null 2>&1; then
    set_status 15 "FAIL" "fio 不存在"
    return
  fi
  echo "[寫入測試] file=$FIO_FILE size=$FIO_SIZE bs=$FIO_BS"
  sudo fio --name=prep --filename="$FIO_FILE" --size="$FIO_SIZE" --bs="$FIO_BS" --rw=write \
      --ioengine=libaio --iodepth=32 --numjobs=1 --direct=1 --group_reporting 2>&1 | tee /tmp/fio_write.out
  echo "[讀取測試]"
  sudo fio --name=seqreadA --filename="$FIO_FILE" --size="$FIO_SIZE" --bs="$FIO_BS" --rw=read \
      --ioengine=libaio --iodepth=32 --numjobs="$FIO_NUMJOBS_READ" --direct=1 --group_reporting 2>&1 | tee /tmp/fio_read.out
  local w_bw r_bw
  w_bw=$(grep -i 'WRITE:' /tmp/fio_write.out | grep -Eo '([0-9.]+)(MiB|MB)/s' | head -n1)
  r_bw=$(grep -i 'READ:'  /tmp/fio_read.out  | grep -Eo '([0-9.]+)(MiB|MB)/s' | head -n1)
  set_status 15 "INFO" "Write=$w_bw Read=$r_bw"
}

# ----------------- 執行所有 -----------------
check_psu; hr
check_disks; hr
check_memory; hr
check_cpu; hr
check_nic; hr
check_gpu; hr
check_fans; hr
check_env; hr
check_power_ups; hr
check_network_perf; hr
check_cabling; hr
check_bmc; hr
check_logs; hr
check_firmware; hr
check_io_perf; hr

# ----------------- 彙總 -----------------
# [MOD] Original summary table removed to reduce redundancy.

# === CONSOLIDATE START ===
# [NEW] Final consolidated report generation

# Global arrays for final results
declare -gA FINAL_STATUS FINAL_REASON FINAL_TIPS_MAP

# [NEW] Appends the consolidated report to the main markdown file
append_consolidated_report_to_md() {
  (( MARKDOWN_OUTPUT == 0 )) && return
  {
    echo ""
    echo "## Final Consolidated Report"
    echo ""
    for i in $(seq 1 15); do
      local status="${FINAL_STATUS[$i]}"
      local reason="${FINAL_REASON[$i]}"
      local tips="${FINAL_TIPS_MAP[$i]:-}"
      local status_icon="⚪️"
      if [[ "$status" == "PASS" ]]; then status_icon="✅"
      elif [[ "$status" == "WARN" ]]; then status_icon="⚠️"
      elif [[ "$status" == "FAIL" ]]; then status_icon="❌"
      elif [[ "$status" == "SKIP" ]]; then status_icon="➡️"
      fi

      echo "### ${status_icon} ${ITEM_NAME[$i]} - $status"
      echo "> ${reason}"

      # Add judgement information (v2.3)
      local judgement_json
      judgement_json=$(echo "${ALL_CHECK_RESULTS[$i]:-}" | jq -c .judgement 2>/dev/null)
      if [[ -n "$judgement_json" && "$judgement_json" != "null" && "$judgement_json" != "{}" ]]; then
        echo ""
        echo "**Judgement**:"
        local criteria=$(echo "$judgement_json" | jq -r '.criteria // ""')
        if [[ -n "$criteria" && "$criteria" != "null" ]]; then
          echo "- **Criteria**: $criteria"
        fi

        # Display Policy rules (v2.3 enhancement)
        local policy_json=$(echo "$judgement_json" | jq -c '.policy // {}')
        if [[ -n "$policy_json" && "$policy_json" != "{}" && "$policy_json" != "null" ]]; then
          echo "- **Policy**:"

          # PASS rules
          local pass_rules=$(echo "$policy_json" | jq -r '.pass // [] | if length > 0 then map("    - \(.)") | join("\n") else "" end')
          if [[ -n "$pass_rules" ]]; then
            echo "  - **PASS**:"
            echo "$pass_rules"
          fi

          # WARN rules
          local warn_rules=$(echo "$policy_json" | jq -r '.warn // [] | if length > 0 then map("    - \(.)") | join("\n") else "" end')
          if [[ -n "$warn_rules" ]]; then
            echo "  - **WARN**:"
            echo "$warn_rules"
          fi

          # FAIL rules
          local fail_rules=$(echo "$policy_json" | jq -r '.fail // [] | if length > 0 then map("    - \(.)") | join("\n") else "" end')
          if [[ -n "$fail_rules" ]]; then
            echo "  - **FAIL**:"
            echo "$fail_rules"
          fi

          # SKIP rules
          local skip_rules=$(echo "$policy_json" | jq -r '.skip // [] | if length > 0 then map("    - \(.)") | join("\n") else "" end')
          if [[ -n "$skip_rules" ]]; then
            echo "  - **SKIP**:"
            echo "$skip_rules"
          fi

          # INFO rules
          local info_rules=$(echo "$policy_json" | jq -r '.info // [] | if length > 0 then map("    - \(.)") | join("\n") else "" end')
          if [[ -n "$info_rules" ]]; then
            echo "  - **INFO**:"
            echo "$info_rules"
          fi
        fi

        local thresholds=$(echo "$judgement_json" | jq -r '.thresholds // {} | to_entries | map("  - \(.key): \(.value)") | join("\n")')
        if [[ -n "$thresholds" && "$thresholds" != "" ]]; then
          echo "- **Thresholds**:"
          echo "$thresholds"
        fi
        local checks=$(echo "$judgement_json" | jq -r '.checks // [] | map("  - \(.name): \(.value) [\(if .ok then "✓" else "✗" end)]") | join("\n")')
        if [[ -n "$checks" ]]; then
          echo "- **Checks**:"
          echo "$checks"
        fi
      fi

      if [[ -n "$tips" ]]; then
        echo ""
        echo "**Suggested Commands**:"
        echo '```bash'
        echo -n "${tips}"
        echo '```'
      fi
      echo ""
    done
  } >> "$LOG_MD"
  echo "[Info] Appended consolidated report to $LOG_MD"
}

# [NEW] Main function to generate the consolidated report
consolidate_report() {
  echo -e "\n${C_BLUE}=== Final Consolidated Report ===${C_RESET}"

  local now_epoch=$SCRIPT_START_TS
  local status_order='{"CRIT":5, "FAIL":4, "WARN":3, "PASS":2, "INFO":1, "SKIP":0, "NA":0}'

  for i in $(seq 1 15); do
    # 1. Get result from new architecture if available, otherwise fall back to legacy
    if [[ -n "${ALL_CHECK_RESULTS[$i]:-}" ]]; then
        # New architecture: Parse from the full JSON result
        FINAL_STATUS[$i]=$(echo "${ALL_CHECK_RESULTS[$i]}" | jq -r .status)
        FINAL_REASON[$i]=$(echo "${ALL_CHECK_RESULTS[$i]}" | jq -r .reason)
    else
        # Legacy fallback for non-refactored checks
        FINAL_STATUS[$i]="${RESULT_STATUS[$i]:-NA}"
        FINAL_REASON[$i]="${RESULT_NOTE[$i]:-}"
    fi

    # 2. Override/supplement with log analysis for items 10, 11, 15
    local log_status_full="" log_status="" log_reason=""
    case "$i" in
      10) log_status_full=$(net_status_from_log "$LOG_TXT");;
      11) log_status_full=$(cabling_status_from_log "$LOG_TXT");;
      15) if (( RUN_FIO )); then log_status_full=$(io_status_from_log "$LOG_TXT"); fi;;
    esac

    if [[ -n "$log_status_full" ]]; then
      log_status="${log_status_full%%|*}"
      log_reason="${log_status_full#*|}"
      
      local current_p; current_p=$(jq -r ".${FINAL_STATUS[$i]}" <<< "$status_order")
      local log_p; log_p=$(jq -r ".${log_status}" <<< "$status_order")
      [[ "$current_p" == "null" || -z "$current_p" ]] && current_p=-1
      [[ "$log_p" == "null" || -z "$log_p" ]] && log_p=-1

      if (( log_p > current_p )); then
        FINAL_STATUS[$i]="$log_status"
        FINAL_REASON[$i]="$log_reason"
      fi
    fi

    # 3. Supplement with SEL analysis
    local sel_regex; sel_regex=$(item_regex "$i")
    if [[ -n "$sel_regex" && -f "$SEL_DETAIL_FILE" ]]; then
      if [[ "${FINAL_STATUS[$i]}" == "FAIL" || "${FINAL_STATUS[$i]}" == "WARN" ]]; then
        local last_evt; last_evt=$(last_event_epoch_in_sel "$SEL_DETAIL_FILE" "$now_epoch" "$SEL_DAYS" "$sel_regex")
        if [[ -n "$last_evt" ]]; then
          FINAL_REASON[$i]="${FINAL_REASON[$i]}; Last relevant SEL event: $(date -d@"${last_evt}")"
        fi
      elif [[ "${FINAL_STATUS[$i]}" == "PASS" ]]; then
        if is_recovered "$i" "$SEL_DETAIL_FILE" "$now_epoch" "$SEL_DAYS" "$RECOVER_DAYS"; then
          FINAL_REASON[$i]="${FINAL_REASON[$i]} [Recovered]"
        fi
      fi
    fi

    # 4. Generate tips for all statuses
    FINAL_TIPS_MAP[$i]="$(get_item_tips "$i")"
  done

  # 5. Print colored table to stdout
  printf "${C_BOLD}%-4s %-24s %-8s %s${C_RESET}\n" "ID" "Item" "Status" "Reason"
  for i in $(seq 1 15); do
    local st="${FINAL_STATUS[$i]}"
    local color="$C_RESET"
    if [[ "$st" == "PASS" ]]; then color="$C_GREEN"
    elif [[ "$st" == "WARN" ]]; then color="$C_YELLOW"
    elif [[ "$st" == "FAIL" ]]; then color="$C_RED"
    fi
    printf "%-4s %-24s ${color}%-8s${C_RESET} %s\n" "$i" "${ITEM_NAME[$i]}" "$st" "${FINAL_REASON[$i]}"

    # Print Tips if they exist
    if [[ -n "${FINAL_TIPS_MAP[$i]:-}" ]]; then
      echo -e "     ${C_BLUE}TIPS:${C_RESET}"
      # Use sed to indent
      echo "${FINAL_TIPS_MAP[$i]}" | sed 's/^/       /'
    fi

    # Print Evidence log paths if they exist
    local evidence_json
    evidence_json=$(echo "${ALL_CHECK_RESULTS[$i]:-}" | jq -c .evidence 2>/dev/null)
    if [[ -n "$evidence_json" && "$evidence_json" != "null" && "$evidence_json" != "{}" ]]; then
        echo -e "     ${C_BLUE}LOGS:${C_RESET}"
        echo "$evidence_json" | jq -r 'to_entries[] | "       \(.key): \(.value)"'
    fi

    # Print Judgement information if it exists (v2.3 新增)
    local judgement_json
    judgement_json=$(echo "${ALL_CHECK_RESULTS[$i]:-}" | jq -c .judgement 2>/dev/null)
    if [[ -n "$judgement_json" && "$judgement_json" != "null" && "$judgement_json" != "{}" ]]; then
        echo -e "     ${C_BLUE}JUDGEMENT:${C_RESET}"

        # 顯示 criteria
        local criteria=$(echo "$judgement_json" | jq -r '.criteria // ""')
        if [[ -n "$criteria" && "$criteria" != "null" ]]; then
            echo -e "       ${C_BOLD}Criteria:${C_RESET} $criteria"
        fi

        # 顯示 checks 摘要（只顯示失敗的或關鍵的）
        local checks_summary=$(echo "$judgement_json" | jq -r '
          .checks // [] |
          map(select(.ok == false or .name == "Status")) |
          if length > 0 then
            map("  - \(.name): \(.value) [\(if .ok then "✓" else "✗" end)]") | join("\n")
          else
            "  All checks passed"
          end')
        if [[ -n "$checks_summary" && "$checks_summary" != "null" ]]; then
            echo -e "       ${C_BOLD}Key Checks:${C_RESET}"
            echo "$checks_summary" | sed 's/^/       /'
        fi

        # 顯示 thresholds（如果有）
        local thresholds=$(echo "$judgement_json" | jq -r '.thresholds // {} | to_entries | map("\(.key)=\(.value)") | join(", ")')
        if [[ -n "$thresholds" && "$thresholds" != "" ]]; then
            echo -e "       ${C_BOLD}Thresholds:${C_RESET} $thresholds"
        fi
    fi
  done

  # 6. Append to Markdown file
  append_consolidated_report_to_md
}
# === CONSOLIDATE END ===

# [MOD] Call the new consolidate report function
consolidate_report

SCRIPT_END_TS=$(date +%s)
DURATION=$((SCRIPT_END_TS - SCRIPT_START_TS))
echo "執行總耗時: ${DURATION}s"

# ----------------- Markdown -----------------
if (( MARKDOWN_OUTPUT )); then
  {
    echo "# 健檢報告 ($TIMESTAMP)"
    echo ""
    echo "耗時: ${DURATION}s"
    echo ""
    echo "| 編號 | 狀態 | 備註 (原始) |"
    echo "|------|------|-------------|"
    for i in $(seq 1 15); do
      echo "| $i | ${RESULT_STATUS[$i]:-NA} | ${RESULT_NOTE[$i]:-} |"
    done
    echo ""
    echo "原始輸出檔：$LOG_TXT"
  } > "$LOG_MD"
  echo "[Info] 產生 Markdown: $LOG_MD"
  # The consolidated report is now appended by the consolidate_report function
fi

# ----------------- CSV -----------------
if (( CSV_OUTPUT )); then
  {
    echo "id,status,reason" # [MOD] header
    for i in $(seq 1 15); do
      # [MOD] Use FINAL_REASON for the note in CSV
      note="${FINAL_REASON[$i]:-}"
      note="${note//,/;}"
      echo "$i,${FINAL_STATUS[$i]:-NA},\"$note\""
    done
  } > "$LOG_CSV"
  echo "[Info] 產生 CSV: $LOG_CSV"
fi

# [REMOVED] build_public_report and suggest_checks_for_item are now replaced by the new consolidation logic.

# ----------------- 閾值 JSON (可選) -----------------
if [[ -n "$THRESHOLDS_JSON" ]]; then
  {
    cat <<TJSON
{
  "cpu_temp_warn": $CPU_TEMP_WARN,
  "cpu_temp_crit": $CPU_TEMP_CRIT,
  "fan_rpm_th": $FAN_RPM_TH,
  "sel_days": $SEL_DAYS,
  "sel_noise_hide": $SEL_NOISE_HIDE,
  "nic_baseline": "$(echo "$NIC_BASELINE_FILE")",
  "fio_enabled": $RUN_FIO,
  "net_iperf_min": $NET_IPERF_MIN,
  "io_read_min": $IO_READ_MIN,
  "io_write_min": $IO_WRITE_MIN,
  "nic_warn_min_delta":  "$NIC_WARN_MIN_DELTA",
  "nic_warn_min_pct":    "$NIC_WARN_MIN_PCT",
  "nic_warn_min_rx_drop_rate": "$NIC_WARN_MIN_RX_DROP_RATE",
  "nic_min_window_sec": "$NIC_MIN_WINDOW_SEC",
  "nic_min_rx_pkts": "$NIC_MIN_RX_PKTS",
  "nic_rate_min_delta": "$NIC_RATE_MIN_DELTA"
}
TJSON
  } > "$THRESHOLDS_JSON"
  echo "[Info] 輸出閾值 JSON: $THRESHOLDS_JSON"
fi

# ----------------- Master JSON (object) -----------------

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
KERNEL=$(uname -r)
UPS_JSON_REF=""
[[ -f "$UPS_JSON_PATH" ]] && UPS_JSON_REF="$UPS_JSON_PATH"

# [MOD] Modified to use consolidated results and add new fields
build_master_json() {
  # Create a temporary file to hold the array of item objects
  local tmp_items
  tmp_items=$(mktemp)

  # Start the JSON array
  echo '[' > "$tmp_items"

  # Loop through each check item and generate its JSON object using jq
  for i in $(seq 1 15); do
    local id="$i"

    # 先試著用 ALL_CHECK_RESULTS[i] 作為「完整新制 JSON」來源
    local item_json="${ALL_CHECK_RESULTS[$i]:-}"
    local ok=0
    if [[ -n "$item_json" ]] && jq -e . >/dev/null 2>&1 <<<"$item_json"; then
      ok=1
    fi

    if (( ok )); then
      # 以新制 JSON 為基礎，補上舊欄位 note/reason/tips（仍以新制為準）
      local tips_str="${FINAL_TIPS_MAP[$i]:-}"
      jq -c --arg tips "$tips_str" '
        . as $it
        | $it + {
            tips: ($tips | split("\n") | map(select(. != "")))
          }
      ' <<< "$item_json" >> "$tmp_items"
    else
      # 回退：用 FINAL_STATUS/NOTE/REASON + TIPS 生出舊制 JSON（沒有 judgement）
      local status="${FINAL_STATUS[$i]:-NA}"
      local original_note="${RESULT_NOTE[$i]:-}"
      local final_reason="${FINAL_REASON[$i]:-}"
      local tips_str="${FINAL_TIPS_MAP[$i]:-}"

      jq -n \
        --argjson id "$id" \
        --arg status "$status" \
        --arg note "$original_note" \
        --arg reason "$final_reason" \
        --arg tips "$tips_str" \
        '{id:$id, status:$status, note:$note, reason:$reason, tips:($tips | split("\n") | map(select(. != "")))}' >> "$tmp_items"
    fi

    # Add a comma between objects, but not after the last one
    if (( i < 15 )); then
      echo ',' >> "$tmp_items"
    fi
  done

  # Close the JSON array
  echo ']' >> "$tmp_items"

  # --- The rest of the function remains largely the same, but now uses the robustly generated tmp_items file ---

  local tmp_top
  tmp_top=$(mktemp)
  {
    echo '['
    for i in "${!SEL_TOP_ARRAY[@]}"; do
      if (( i < ${#SEL_TOP_ARRAY[@]} - 1 )); then
        printf '%s,\n' "${SEL_TOP_ARRAY[$i]}"
      else
        printf '%s\n' "${SEL_TOP_ARRAY[$i]}"
      fi
    done
    echo ']'
  } > "$tmp_top"

  local tmp_cw
  tmp_cw=$(mktemp)
  {
    echo '['
    for i in "${!SEL_CW_EVENTS_ARRAY[@]}"; do
      if (( i < ${#SEL_CW_EVENTS_ARRAY[@]} - 1 )); then
        printf '%s,\n' "${SEL_CW_EVENTS_ARRAY[$i]}"
      else
        printf '%s\n' "${SEL_CW_EVENTS_ARRAY[$i]}"
      fi
    done
    echo ']'
  } > "$tmp_cw"

  local tmp_raid
  tmp_raid=$(mktemp)
  echo "$RAID_SUMMARY_JSON" > "$tmp_raid"
  local tmp_out
  tmp_out=$(mktemp)

  jq -n \
    --arg script_version "2.3" \
    --arg hostname "$HOSTNAME" \
    --arg timestamp "$TIMESTAMP" \
    --arg bios "$BIOS_VERSION" \
    --arg kernel "$KERNEL" \
    --arg ups_overall "$UPS_OVERALL" \
    --arg events_file "$SEL_EVENTS_JSON" \
    --argjson start $SCRIPT_START_TS \
    --argjson end $SCRIPT_END_TS \
    --argjson duration $DURATION \
    --argjson sel_days $SEL_DAYS \
    --argjson sel_noise_hide $SEL_NOISE_HIDE \
    --argjson sel_crit $SEL_CRIT \
    --argjson sel_warn $SEL_WARN \
    --argjson sel_info $SEL_INFO \
    --argjson sel_noise_raw $SEL_NOISE_RAW \
    --arg ups_json_ref "$UPS_JSON_REF" \
    --arg log_txt "$LOG_TXT" \
    --arg log_md "$LOG_MD" \
    --arg log_csv "$LOG_CSV" \
    --arg journal_log "$JOURNAL_ANALYSIS_LOG" \
    --slurpfile items "$tmp_items" \
    --slurpfile top "$tmp_top" \
    --slurpfile cw "$tmp_cw" \
    --slurpfile raid "$tmp_raid" \
    '{meta:{
        script_version:$script_version,
        hostname:$hostname,
        timestamp:$timestamp,
        start_epoch:$start,
        end_epoch:$end,
        duration_sec:$duration,
            bios_version:$bios,
            kernel:$kernel,
            ups_overall:$ups_overall,
            sel_days_filter:$sel_days,        sel_noise_hide:$sel_noise_hide
      },
      items:$items[0],
      sel:{
        summary:{
          crit:$sel_crit,
          warn:$sel_warn,
          info:$sel_info,
          noise_raw:$sel_noise_raw,
          noise_hidden:$sel_noise_hide
        },
        events_file:$events_file,
        crit_warn_events:$cw[0],
        top_sensors:$top[0]
      },
      raid:$raid[0],
      ups:{
        overall:$ups_overall,
        summary_file:$ups_json_ref
      },
      files:{
        log_txt:$log_txt,
        log_md:$log_md,
        log_csv:$log_csv,
        journal_analysis_log:$journal_log
      }
    }' > "$tmp_out"

  mv "$tmp_out" "$JSON_OUT_FILE"
  rm -f "$tmp_items" "$tmp_top" "$tmp_cw" "$tmp_raid"
  echo "[Info] 產生 Master JSON (jq): $JSON_OUT_FILE"
}

if (( JSON_OUTPUT )); then
  build_master_json
fi


# ----------------- Legacy JSON (array) -----------------
if (( LEGACY_JSON && JSON_OUTPUT )); then
  legacy="${JSON_OUT_FILE%.json}_legacy_array.json"
  # [MOD] This still uses the original json_items for compatibility.
  # For consolidated results, use the main master JSON.
  jq '.items' "$JSON_OUT_FILE" > "$legacy"
  echo "[Info] 產生 legacy JSON (array from master): $legacy"
fi

# ----------------- Exit Code -----------------
FAIL_CNT=0; WARN_CNT=0
for i in $(seq 1 15); do
  case "${FINAL_STATUS[$i]:-}" in # [MOD] Use final status for exit code
    FAIL) ((FAIL_CNT++));;
    WARN) ((WARN_CNT++));;
  esac
done
echo "[SUMMARY] FAIL_CNT=$FAIL_CNT WARN_CNT=$WARN_CNT"

if (( FAIL_CNT>0 )); then
  EXIT_CODE=2
elif (( WARN_CNT>0 )); then
  EXIT_CODE=1
else
  EXIT_CODE=0
fi

if (( EXIT_CODE==0 )); then
  echo -e "${C_GREEN}健檢完成 (All Good)${C_RESET}"
elif (( EXIT_CODE==1 )); then
  echo -e "${C_YELLOW}健檢完成 (有 WARN)${C_RESET}"
else
  echo -e "${C_RED}健檢完成 (有 FAIL)${C_RESET}"
fi

# Cleanup
rm -rf "$RAID_TMP_DIR"

exit $EXIT_CODE
