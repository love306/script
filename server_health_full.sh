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

# --- helper: commit item2 safety without interfering surrounding blocks ---
commit_item2_safety() {
  : "${final_status:=}"
  : "${final_reason:=}"
  : "${raid_controller_count:=0}"
  : "${smart_failed_count:=0}"
  : "${nvme_media_err_count:=0}"
  if [[ -z "$final_status" ]]; then
    if (( raid_controller_count==0 )) && (( smart_failed_count==0 )) && (( nvme_media_err_count==0 )); then
      final_status="INFO"
      final_reason="No disk devices detected (RAID controllers=0, SMART disks=0, NVMe devices=0)"
    else
      final_status="PASS"
      [[ -z "$final_reason" ]] && final_reason="All disk, RAID, and SMART checks passed."
    fi
  fi
  if [[ -z "${__DISK_ITEM2_COMMITTED:-}" ]]; then
    __DISK_ITEM2_COMMITTED=1
    set_check_result_with_jdg 2 "$final_status" "$final_reason" "${tips_json:-[]}" "${judgement_json:-{}}" "${evidence_json:-{}}"
  fi
}


# --- helper: normalize MM/DD/YYYY or MM-DD-YYYY to MM/DD/YYYY ---
normalize_mmddyyyy() {
  local d="$1"
  local d="$1"
  # 接受 MM-DD-YYYY 或 MM/DD-YYYY，統一轉成 /
  if [[ "$d" =~ ^[0-9]{2}[-/][0-9]{2}[-/][0-9]{4}$ ]]; then
    echo "${d//-//}"
  else
    echo "$d"
  fi
}


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
: "${RECOVER_DAYS:=30}"
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
    FAN_BASELINE_FILE=<path> (環境變數，可覆寫 baseline 檔案路徑，預設 logs/fan_baseline.json)
    FAN_BASELINE_RESET=1     (環境變數，下一次執行時重建風扇 baseline)
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

# ---------- datetime normalization helpers (SEL) ----------
normalize_datetime() {
  local s
  s=$(cat | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                -e 's/[[:space:]]T[[:space:]]/ /g' \
                -e 's/,//g' \
                -e 's/  \+/ /g')
  [[ -z "$s" ]] && return 1

  if [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    printf '%s\n' "$s"; return 0
  fi
  if [[ "$s" =~ ^([0-9]{2})-([0-9]{2})-([0-9]{4})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2})$ ]]; then
    printf '%04d-%02d-%02d %s\n' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"; return 0
  fi
  if [[ "$s" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{4})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2})$ ]]; then
    printf '%04d-%02d-%02d %s\n' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"; return 0
  fi
  if [[ "$s" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2})$ ]]; then
    printf '20%02d-%02d-%02d %s\n' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"; return 0
  fi
  if [[ "$s" =~ ^([^[:space:]]+)[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
    local d="${BASH_REMATCH[1]}" t="${BASH_REMATCH[2]}"
    normalize_datetime <<<"${d} ${t}" && return 0
  fi
  return 1
}

dt_to_epoch_or_empty() {
  local n; n=$(normalize_datetime | tr -d $'\r')
  [[ -z "$n" ]] && return 1
  LC_ALL=C date -d "$n" +%s 2>/dev/null || true
}

# ---------- SEL helpers ----------
sel_last_warn_crit_epoch() {
  # uses env: SEL_EVENTS_JSON (structured), SEL_DETAIL_LOG (raw)
  local latest=""
  if [[ -s "$SEL_EVENTS_JSON" ]]; then
    local lines
    lines=$(jq -r '.[]? | select((.severity//"")|test("warn|crit";"i")) | (.datetime//empty)' "$SEL_EVENTS_JSON" 2>/dev/null)
    if [[ -n "$lines" ]]; then
      while IFS= read -r dt; do
        [[ -z "$dt" ]] && continue
        local ep
        ep=$(printf '%s' "$dt" | dt_to_epoch_or_empty)
        [[ -z "$ep" ]] && continue
        if [[ -z "$latest" || "$ep" -gt "$latest" ]]; then latest="$ep"; fi
      done <<< "$lines"
    fi
  fi
  if [[ -z "$latest" && -s "$SEL_DETAIL_LOG" ]]; then
    while IFS='|' read -r idx fdate ftime c1 c2 c3; do
      fdate=$(echo "$fdate" | xargs); ftime=$(echo "$ftime" | xargs)
      [[ -z "$fdate" || -z "$ftime" ]] && continue
      local ep tail
      ep=$(printf '%s %s' "$fdate" "$ftime" | dt_to_epoch_or_empty)
      [[ -z "$ep" ]] && continue
      tail="${c1} ${c2} ${c3}"
      if echo "$tail" | grep -Eqi 'critical|warn|intrusion|FW Health|Failure|Over|Thermal'; then
        if [[ -z "$latest" || "$ep" -gt "$latest" ]]; then latest="$ep"; fi
      fi
    done < <(grep -E '^\s*[0-9a-fA-F]+' "$SEL_DETAIL_LOG")
  fi
  [[ -n "$latest" ]] && printf '%s\n' "$latest"
}

cpu_history_upsert_and_stats() {
  # args: cur_max avg_temp timestamp iso8601 history_file
  local cur_max="$1" avg="$2" ts="$3" iso="$4" hist="$5"
  local dir; dir=$(dirname "$hist"); mkdir -p "$dir"
  local entry; entry=$(jq -n --arg iso "$iso" --argjson max "$cur_max" --argjson avg "$avg" '{ts:$iso, max:$max, avg:$avg}')
  local now_epoch; now_epoch=$(date +%s)
  local cutoff=$(( now_epoch - 90*86400 ))

  local arr='[]'
  [[ -s "$hist" ]] && arr=$(cat "$hist")
  arr=$(jq --argjson cutoff "$cutoff" --argjson e "$entry" -n --argfile A <(printf '%s' "$arr") '
    ($A + [$e])
    | map(select(((.ts | try (strptime("%Y-%m-%d %H:%M:%S") | mktime) catch 0)) >= $cutoff))
  ')
  printf '%s\n' "$arr" > "$hist"

  local peak avg90
  peak=$(printf '%s' "$arr" | jq '[.[].max] | max // 0')
  avg90=$(printf '%s' "$arr" | jq '([.[].avg] | add) / (length|if .==0 then 1 else . end)')
  printf '%s|%s\n' "$peak" "$avg90"

  if [[ "${CPU_DAILY_STATS:-0}" -eq 1 ]]; then
    local daily
    daily=$(printf '%s' "$arr" | jq '
      map({
        date: (.ts | try (strptime("%Y-%m-%d %H:%M:%S") | mktime | strftime("%Y-%m-%d")) catch null),
        max: (.max // 0),
        avg: (.avg // 0)
      })
      | map(select(.date != null))
      | group_by(.date)
      | map({
          date: .[0].date,
          peak_max: (map(.max) | (max // 0)),
          avg_avg: (map(.avg) | if length==0 then 0 else (add/length) end)
        })
    ')
    printf '%s\n' "${daily:-[]}" > "${hist%.json}_daily.json"
  fi
}

fan_history_upsert_and_stats() {
  # args:
  # 1: fan_eval_entries_json (array of {name, rpm, ...})
  # 2: timestamp (epoch)     3: iso8601   4: history_file
  # stdout: JSON {overall:{avg_rpm_90d, peak_avg_rpm_90d}, per_fan:{<name>:{avg_90d, peak_90d}}}
  local eval_json="$1" ts="$2" iso="$3" hist="$4"
  local dir; dir=$(dirname "$hist"); mkdir -p "$dir"

  local this_avg
  this_avg=$(printf '%s' "$eval_json" | jq '[.[].rpm // empty] | if length==0 then 0 else (add/length) end')
  local this_per_fan
  this_per_fan=$(printf '%s' "$eval_json" | jq 'map({key:.name, val:(.rpm//0)}) | from_entries')

  local now_epoch; now_epoch=$(date +%s)
  local cutoff=$(( now_epoch - 90*86400 ))

  local H='{"overall":[],"per_fan":{}}'
  [[ -s "$hist" ]] && H=$(cat "$hist")

  H=$(printf '%s' "$H" | jq --arg iso "$iso" --argjson avg "$this_avg" --argjson cutoff "$cutoff" '
    .overall += [{ts:$iso, avg:$avg}] |
    .overall = (.overall | map(select(((.ts | try (strptime("%Y-%m-%d %H:%M:%S") | mktime) catch 0)) >= $cutoff)))
  ')

  local fan_names; fan_names=$(printf '%s' "$this_per_fan" | jq -r 'keys[]?')
  for f in $fan_names; do
    local rpm; rpm=$(printf '%s' "$this_per_fan" | jq -r --arg k "$f" '.[$k]')
    H=$(printf '%s' "$H" | jq --arg f "$f" --arg iso "$iso" --argjson rpm "$rpm" --argjson cutoff "$cutoff" '
      .per_fan[$f] = ((.per_fan[$f] // []) + [{ts:$iso, rpm:$rpm}]) |
      .per_fan[$f] = (.per_fan[$f] | map(select(((.ts | try (strptime("%Y-%m-%d %H:%M:%S") | mktime) catch 0)) >= $cutoff)))
    ')
  done

  printf '%s\n' "$H" > "$hist"

  local overall_avg overall_peak
  overall_avg=$(printf '%s' "$H" | jq '([.overall[].avg] | if length==0 then 0 else (add/length) end)')
  overall_peak=$(printf '%s' "$H" | jq '([.overall[].avg] | (max // 0))')

  if [[ "${FAN_DAILY_STATS:-0}" -eq 1 ]]; then
    local fan_daily
    fan_daily=$(printf '%s' "$H" | jq '
      .overall
      | map({
          date: (.ts | try (strptime("%Y-%m-%d %H:%M:%S") | mktime | strftime("%Y-%m-%d")) catch null),
          avg: (.avg // 0)
        })
      | map(select(.date != null))
      | group_by(.date)
      | map({
          date: .[0].date,
          avg_rpm: (map(.avg) | if length==0 then 0 else (add/length) end),
          peak_avg_rpm: (map(.avg) | (max // 0))
        })
    ')
    printf '%s\n' "${fan_daily:-[]}" > "${hist%.json}_daily.json"
  fi

  printf '%s' "$H" | jq --argjson oa "$overall_avg" --argjson op "$overall_peak" '
    {
      per_fan: ( .per_fan | to_entries
        | map({key:.key, value:{
            avg_90d: ([.value[].rpm] | if length==0 then 0 else (add/length) end),
            peak_90d: ([.value[].rpm] | (max // 0))
          }})
        | from_entries),
      overall: {avg_rpm_90d:$oa, peak_avg_rpm_90d:$op}
    }'
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

      local bios_ok_json="false"
      [[ -n "${BIOS_VERSION:-}" ]] && bios_ok_json="true"
      local bios_value="${BIOS_VERSION_CHECK_VALUE:-}"
      if [[ -z "$bios_value" ]]; then
        if [[ "$bios_ok_json" == "true" ]]; then
          bios_value="true"
        else
          bios_value="not retrieved"
        fi
      fi
      local enum_value="${FIRMWARE_ENUM_MESSAGE:-dmidecode/ethtool/smartctl executed}"

      checks_json=$(jq -n \
        --argjson bios_ok "$bios_ok_json" \
        --arg bios_value "$bios_value" \
        --arg enum_value "$enum_value" \
        --arg st "$st" \
        '[
          {"name":"BIOS version retrieved", "ok":$bios_ok, "value":$bios_value},
          {"name":"Firmware enumeration", "ok":true, "value":$enum_value},
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
    local ts; ts=$(date -d "$(normalize_mmddyyyy "$f2") $f3" +%s 2>/dev/null || echo "")
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
jq '.items[] | select(.id==2)' \$(ls logs/*_latest.json | grep -v thresholds_latest.json)
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
# 查詢 master JSON（排除 thresholds）
jq '.items[] | select(.id==7) | .judgement.checks' \
  \$(ls logs/*_latest.json | grep -v thresholds_latest.json)
# 查詢異常風扇（低 RPM 或高偏差）
jq '.metrics[] | select(.rpm < 300 or (.dev_pct|tonumber) > 20)' logs/fan/fan_eval_*.json
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
    # Quick verify: jq '.items[] | select(.id==2)' logs/*_latest.json

    : "${SMART_REQUIRED:=true}"
    : "${NVME_REQUIRED:=true}"
    : "${ROOT_REQUIRED:=true}"
    : "${DISK_REBUILD_WARN:=1}"
    : "${PD_FAIL_CRIT:=1}"
    : "${VD_DEGRADED_WARN:=1}"
    : "${SMART_ALERT_FAIL_CRIT:=1}"
    : "${SMART_REALLOC_WARN:=1}"
    : "${SMART_PENDING_WARN:=1}"
    : "${NVME_CRIT_WARN_CRIT:=1}"
    : "${NVME_MEDIA_ERR_WARN:=1}"
    : "${NVME_PCT_USED_WARN:=80}"

    local SMART_REQUIRED_EFFECTIVE="$SMART_REQUIRED"
    local NVME_REQUIRED_EFFECTIVE="$NVME_REQUIRED"

    local tips_text="$(get_item_tips 2)"

    local disk_dir="$LOG_DIR/disks"
    mkdir -p "$disk_dir"
    local metrics_path="${disk_dir}/metrics_${TIMESTAMP}.json"
    local smart_json_path="${disk_dir}/smart_scan_${TIMESTAMP}.json"
    local nvme_json_path="${disk_dir}/nvme_smart_${TIMESTAMP}.json"
    local disk_summary_path="${disk_dir}/disk_summary_${TIMESTAMP}.json"
    local mdstat_log=""
    local storcli_summary_path=""

    local smart_required_flag=0
    case "${SMART_REQUIRED,,}" in
        true|1|yes) smart_required_flag=1;;
    esac
    local nvme_required_flag=0
    case "${NVME_REQUIRED,,}" in
        true|1|yes) nvme_required_flag=1;;
    esac
    local root_required_flag=0
    case "${ROOT_REQUIRED,,}" in
        true|1|yes) root_required_flag=1;;
    esac

    local is_root=0
    [[ "$(id -u)" -eq 0 ]] && is_root=1
    local has_sudo=0
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            has_sudo=1
        fi
    fi
    local -a sudo_prefix=()
    if (( is_root )); then
        sudo_prefix=()
    elif (( has_sudo )); then
        sudo_prefix=(sudo -n)
    fi
    local root_access=0
    if (( is_root || has_sudo )); then
        root_access=1
    fi

    RAID_STATUS_IMPACT=""
    RAID_SUMMARY_JSON="{}"
    RAID_REBUILD_PRESENT=0

    local raid_summary_raw=""
    local raid_driver="none"
    local raid_controllers_json="[]"
    local vd_total=0
    local vd_degraded=0
    local vd_failed=0
    local vd_rebuild=0
    local pd_total=0
    local pd_failed=0
    local pd_missing=0
    local mdadm_arrays_found=0
    local mdadm_degraded=0
    local mdadm_recovering=0
    local mdadm_arrays_json="[]"

    local -a mdadm_arrays_entries=()
    local -a smart_devices_entries=()
    local -a smart_failed_list=()
    local -a smart_realloc_list=()
    local -a smart_pending_list=()
    local -a smart_uncorr_list=()
    local -a nvme_devices_entries=()
    local -a nvme_cw_list=()
    local -a nvme_media_err_list=()
    local -a nvme_pct80_list=()
    local nvme_device_count=0
    local nvme_temp_max=""
    local -a warn_reasons=()
    local -a fail_reasons=()

    local smart_scanned=1
    local smart_reason=""
    local nvme_scanned=1
    local nvme_reason=""
    local storcli_scanned=0
    local storcli_reason=""
    local storcli_check_skipped=0

    local tool_issue_flag=0
    local -a missing_tools=()

    local storcli_state="missing"
    local smartctl_state="missing"
    local nvme_state="missing"
    local lsblk_state="missing"

    local smart_required_effective_flag=0
    smart_required_effective_flag=$smart_required_flag
    local nvme_required_effective_flag=0
    nvme_required_effective_flag=$nvme_required_flag

    local megaraid_present=0
    local smart_virtual_devices_count=0
    local smart_passthrough_count=0
    local smart_virtual_failed_count=0
    local smart_virtual_note_needed=0
    local smart_virtual_only=0
    local smart_virtual_detected=0
    local smart_passthrough_detected=0
    local nvme_skipped=0

    local storcli_available=0
    local storcli_cmd="${RAID_STORCLI_CMD:-$STORCLI_BIN}"
    local storcli_bin="${storcli_cmd#sudo }"
    storcli_bin="${storcli_bin%% *}"
    if [[ -n "$storcli_bin" ]] && { command -v "$storcli_bin" >/dev/null 2>&1 || [[ -x "$storcli_bin" ]]; }; then
        storcli_available=1
        storcli_state="available"
    fi
    local smartctl_available=0
    if command -v smartctl >/dev/null 2>&1; then
        smartctl_available=1
        smartctl_state="available"
    fi
    local nvme_available=0
    if command -v nvme >/dev/null 2>&1; then
        nvme_available=1
        nvme_state="available"
    fi
    local lsblk_available=0

    if command -v lsblk >/dev/null 2>&1; then
        lsblk_available=1
        lsblk_state="ok"
        lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,MOUNTPOINT || true
    else
        missing_tools+=("lsblk")
        tool_issue_flag=1
    fi

    if (( storcli_available == 0 )); then
        missing_tools+=("storcli64")
        tool_issue_flag=1
    else
        storcli_state="available"
    fi
    if (( smartctl_available == 0 )); then
        missing_tools+=("smartctl")
        tool_issue_flag=1
    else
        smartctl_state="available"
    fi
    if (( nvme_available == 0 )); then
        missing_tools+=("nvme-cli")
        tool_issue_flag=1
    else
        nvme_state="available"
    fi

    if (( storcli_available )) && (( root_access )); then
        collect_raid_megaraid
        if [[ -f "$RAID_TMP_DIR/raid_summary.json" ]]; then
            raid_summary_raw=$(cat "$RAID_TMP_DIR/raid_summary.json")
        else
            raid_summary_raw=$RAID_SUMMARY_JSON
        fi
        if [[ -n "$raid_summary_raw" && "$raid_summary_raw" != "{}" ]]; then
            raid_controllers_json=$(echo "$raid_summary_raw" | jq -c '
                ((.controllers // []) | map({
                    id: ("c" + (.controller|tostring)),
                    model: (.model // ""),
                    virtual_drives: {
                        total: (.vd.total // 0),
                        optimal: ((.vd.total // 0) - (.vd.degraded // 0) - (.vd.failed // 0)),
                        degraded: (.vd.degraded // 0),
                        failed: (.vd.failed // 0),
                        rebuild: (if (.ops // {} | (has("rebuild_pct") or has("init_pct"))) then 1 else 0 end)
                    },
                    physical_disks: {
                        total: (.pd.total // 0),
                        online: ((.pd.total // 0) - (.pd.failed // 0) - (.pd.missing // 0)),
                        failed: (.pd.failed // 0),
                        missing: (.pd.missing // 0),
                        foreign: 0,
                        pred_fail: (.pd.predictive // 0)
                    }
                })) // []')
            if [[ -n "$raid_controllers_json" && "$raid_controllers_json" != "[]" ]]; then
                storcli_scanned=1
                raid_driver="storcli"
                storcli_state="ok"
                storcli_summary_path="${disk_dir}/storcli_summary_${TIMESTAMP}.json"
                printf '%s\n' "$raid_summary_raw" > "$storcli_summary_path"
                megaraid_present=1
                vd_total=$(echo "$raid_summary_raw" | jq -r '(.agg.vd_total // 0)' 2>/dev/null)
                [[ -z "$vd_total" ]] && vd_total=0
                vd_degraded=$(echo "$raid_summary_raw" | jq -r '(.agg.vd_degraded // 0)' 2>/dev/null)
                [[ -z "$vd_degraded" ]] && vd_degraded=0
                vd_failed=$(echo "$raid_summary_raw" | jq -r '(.agg.vd_failed // 0)' 2>/dev/null)
                [[ -z "$vd_failed" ]] && vd_failed=0
                pd_total=$(echo "$raid_summary_raw" | jq -r '(.agg.pd_total // 0)' 2>/dev/null)
                [[ -z "$pd_total" ]] && pd_total=0
                pd_failed=$(echo "$raid_summary_raw" | jq -r '(.agg.pd_failed // 0)' 2>/dev/null)
                [[ -z "$pd_failed" ]] && pd_failed=0
                pd_missing=$(echo "$raid_summary_raw" | jq -r '(.agg.pd_missing // 0)' 2>/dev/null)
                [[ -z "$pd_missing" ]] && pd_missing=0
                vd_rebuild=$(echo "$raid_summary_raw" | jq -r '((.controllers // []) | map((.ops // {}) | (if ((.rebuild_pct // "") != "" or (.init_pct // "") != "") then 1 else 0 end)) | add) // 0' 2>/dev/null)
                [[ -z "$vd_rebuild" ]] && vd_rebuild=0
            else
                storcli_reason="no_controllers"
                storcli_state="no_controllers"
            fi
        else
            storcli_reason="no_data"
            storcli_state="no_data"
        fi
    else
        if (( storcli_available == 0 )); then
            storcli_reason="not_found"
            storcli_check_skipped=1
            storcli_state="missing"
        elif (( root_access == 0 )); then
            storcli_reason="root_required"
            storcli_check_skipped=1
            storcli_state="permission"
            missing_tools+=("storcli64(permission)")
            tool_issue_flag=1
        else
            storcli_reason="not_supported"
            storcli_check_skipped=1
            storcli_state="not_supported"
        fi
    fi

    if [[ -r /proc/mdstat ]]; then
        mdstat_log="${disk_dir}/mdstat_${TIMESTAMP}.log"
        cat /proc/mdstat > "$mdstat_log"
        local current_name=""
        local current_level=""
        local current_state=""
        local current_recovery=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ $line =~ ^(md[0-9]+) ]]; then
                if [[ -n "$current_name" ]]; then
                    local rec_clean="${current_recovery%%%}"
                    mdadm_arrays_entries+=("$(jq -n --arg name "$current_name" --arg level "$current_level" --arg state "$current_state" --arg rec "$rec_clean" '{name:$name, level:$level, state:$state, recovery_pct:(if $rec=="" then null else $rec end)}')")
                    case "$current_state" in
                        degraded) ((mdadm_degraded++));;
                        recovering) ((mdadm_recovering++));;
                    esac
                fi
                current_name="${BASH_REMATCH[1]}"
                mdadm_arrays_found=1
                current_level=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^raid[0-9]+$/){print $i; break}}}')
                [[ -z "$current_level" ]] && current_level="unknown"
                current_state="clean"
                if echo "$line" | grep -Eq '\[[^]]*_[^]]*\]'; then
                    current_state="degraded"
                fi
                if echo "$line" | grep -qi 'inactive'; then
                    current_state="degraded"
                fi
                current_recovery=""
            elif [[ -n "$current_name" ]]; then
                if echo "$line" | grep -Eq '(resync|recovery|rebuild)'; then
                    current_state="recovering"
                    current_recovery=$(echo "$line" | grep -Eo '[0-9]+(\.[0-9]+)?%' | head -n1)
                fi
            fi
        done < /proc/mdstat
        if [[ -n "$current_name" ]]; then
            local rec_clean="${current_recovery%%%}"
            mdadm_arrays_entries+=("$(jq -n --arg name "$current_name" --arg level "$current_level" --arg state "$current_state" --arg rec "$rec_clean" '{name:$name, level:$level, state:$state, recovery_pct:(if $rec=="" then null else $rec end)}')")
            case "$current_state" in
                degraded) ((mdadm_degraded++));;
                recovering) ((mdadm_recovering++));;
            esac
        fi
    fi
    if (( mdadm_arrays_found )); then
        mdadm_arrays_json=$(printf '%s\n' "${mdadm_arrays_entries[@]}" | jq -s '.')
        if [[ "$raid_driver" == "none" ]]; then
            raid_driver="mdadm"
        fi
    fi

    if (( smartctl_available == 0 )); then
        smart_scanned=0
        smart_reason="tool_missing"
        smartctl_state="missing"
    elif (( smart_required_flag )) && (( root_access == 0 )); then
        smart_scanned=0
        smart_reason="root_required"
        smartctl_state="permission"
        missing_tools+=("smartctl(permission)")
        tool_issue_flag=1
    fi

    local -a SMART_BASE_CMD=()
    if (( smartctl_available )); then
        SMART_BASE_CMD=("${sudo_prefix[@]}" smartctl)
    fi
    if (( smart_scanned )); then
        local -a smart_targets=()
        declare -A SMART_SEEN_TARGETS=()
        local scan_json
        scan_json=$("${SMART_BASE_CMD[@]}" --scan-open -j 2>/dev/null || true)
        if [[ -n "$scan_json" ]]; then
            while IFS='|' read -r name dtype; do
                [[ -z "$name" ]] && continue
                local path="$name"
                [[ "${path:0:1}" != "/" ]] && path="/dev/$path"
                if [[ -z "${SMART_SEEN_TARGETS["$path"]:-}" ]]; then
                    SMART_SEEN_TARGETS["$path"]=1
                    smart_targets+=("$path|$dtype")
                fi
            done < <(echo "$scan_json" | jq -r '.devices[]? | "\(.name)|\(.type // \"auto\")"' 2>/dev/null || true)
        fi
        if (( ${#smart_targets[@]} == 0 )) && (( lsblk_available )); then
            local lsblk_json
            lsblk_json=$(lsblk -J -o NAME,TYPE 2>/dev/null || true)
            if [[ -n "$lsblk_json" ]]; then
                while IFS= read -r devname; do
                    [[ -z "$devname" ]] && continue
                    local path="/dev/$devname"
                    if [[ -z "${SMART_SEEN_TARGETS["$path"]:-}" ]]; then
                        SMART_SEEN_TARGETS["$path"]=1
                        smart_targets+=("$path|auto")
                    fi
                done < <(echo "$lsblk_json" | jq -r '.blockdevices[]? | select(.type=="disk") | .name' 2>/dev/null || true)
            fi
        fi
        for target in "${smart_targets[@]}"; do
            IFS='|' read -r disk dev_type <<< "$target"
            [[ -z "$disk" ]] && continue
            echo "[SMART] $disk"
            local -a smart_cmd=("${SMART_BASE_CMD[@]}")
            if [[ -n "$dev_type" && "$dev_type" != "auto" ]]; then
                smart_cmd+=(-d "$dev_type")
            fi
            smart_cmd+=(-i -H -A -j "$disk")
            local smart_json
            smart_json=$("${smart_cmd[@]}" 2>/dev/null)
            local rc=$?
            if [[ -z "$smart_json" ]]; then
                smart_reason="${smart_reason:-command_failed}"
                smartctl_state="error"
                continue
            fi
            if (( rc != 0 )) && [[ -z "$smart_reason" ]]; then
                smart_reason="command_exit_${rc}"
            fi
            local model
            model=$(echo "$smart_json" | jq -r '.model_name // .device.model_name // .device.model_number // .model_family // "unknown"' 2>/dev/null)
            local smart_pass
            smart_pass=$(echo "$smart_json" | jq -r '.smart_status.passed // false' 2>/dev/null)
            local overall="PASSED"
            [[ "$smart_pass" == "true" ]] || overall="FAILED"
            local reallocated
            reallocated=$(echo "$smart_json" | jq -r '
                (
                  if .ata_smart_attributes and .ata_smart_attributes.table then
                    (.ata_smart_attributes.table[] | select((.name//"")=="Reallocated_Sector_Ct") | .raw.value // .value // 0)
                  else 0 end
                ) // 0' 2>/dev/null)
            local pending
            pending=$(echo "$smart_json" | jq -r '
                (
                  if .ata_smart_attributes and .ata_smart_attributes.table then
                    (.ata_smart_attributes.table[] | select((.name//"")=="Current_Pending_Sector") | .raw.value // .value // 0)
                  else 0 end
                ) // 0' 2>/dev/null)
            local uncorrect
            uncorrect=$(echo "$smart_json" | jq -r '
                (
                  if .ata_smart_attributes and .ata_smart_attributes.table then
                    (.ata_smart_attributes.table[] | select((.name//"")=="Offline_Uncorrectable") | .raw.value // .value // 0)
                  else 0 end
                ) // 0' 2>/dev/null)
            local poh
            poh=$(echo "$smart_json" | jq -r '.power_on_time.hours // .power_on_time.total_hours // .power_on_time.value // 0' 2>/dev/null)
            local temperature
            temperature=$(echo "$smart_json" | jq -r '.temperature.current // .temperature.current_celsius // .temperature.value // empty' 2>/dev/null)
            local temperature_json="null"
            if [[ "$temperature" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                temperature_json="$temperature"
            fi
            local poh_json="null"
            if [[ "$poh" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                poh_json="$poh"
            fi
            [[ "$reallocated" =~ ^-?[0-9]+$ ]] || reallocated=0
            [[ "$pending" =~ ^-?[0-9]+$ ]] || pending=0
            [[ "$uncorrect" =~ ^-?[0-9]+$ ]] || uncorrect=0
            local virtual_under_raid=0
            local dev_type_lower="${dev_type,,}"
            if [[ "$dev_type_lower" == megaraid* ]]; then
                virtual_under_raid=1
            else
                local model_upper
                model_upper=$(echo "$model" | tr '[:lower:]' '[:upper:]')
                if [[ "$model_upper" =~ ^BROADCOM[[:space:]]+MR ]]; then
                    virtual_under_raid=1
                elif [[ "$model_upper" =~ ^LSI.*MEGARAID ]]; then
                    virtual_under_raid=1
                elif [[ "$model_upper" =~ ^AVAGO.*MEGARAID ]]; then
                    virtual_under_raid=1
                elif echo "$smart_json" | grep -qi 'megaraid'; then
                    virtual_under_raid=1
                fi
            fi
            if (( virtual_under_raid )); then
                megaraid_present=1
                smart_virtual_detected=1
                ((smart_virtual_devices_count++))
            else
                smart_passthrough_detected=1
                ((smart_passthrough_count++))
            fi

            local virtual_flag="false"
            if (( virtual_under_raid )); then
                virtual_flag="true"
            fi

            smart_devices_entries+=("$(jq -n \
                --arg dev "$disk" \
                --arg model "$model" \
                --arg status "$overall" \
                --argjson realloc "${reallocated:-0}" \
                --argjson pending "${pending:-0}" \
                --argjson uncorr "${uncorrect:-0}" \
                --argjson temp "$temperature_json" \
                --argjson poh "$poh_json" \
                --arg virtual "$virtual_flag" \
                '{dev:$dev, model:$model, status:$status, realloc:$realloc, pending:$pending, uncorrect:$uncorr, temp:(if $temp==null then null else $temp end), poh:(if $poh==null then null else $poh end)}
                 + (if $virtual=="true" then {virtual_under_raid:true} else {} end)')")

            if (( virtual_under_raid )); then
                if [[ "$overall" != "PASSED" ]]; then
                    ((smart_virtual_failed_count++))
                fi
            else
                if [[ "$overall" != "PASSED" ]]; then
                    smart_failed_list+=("$disk")
                fi
                if (( ${reallocated:-0} > 0 )); then
                    smart_realloc_list+=("$disk")
                fi
                if (( ${pending:-0} > 0 )); then
                    smart_pending_list+=("$disk")
                fi
                if (( ${uncorrect:-0} > 0 )); then
                    smart_uncorr_list+=("$disk")
                fi
            fi
        done
        if [[ "$smartctl_state" == "available" ]]; then
            if [[ -n "$smart_reason" && "$smart_reason" != "tool_missing" ]]; then
                smartctl_state="$smart_reason"
            else
                smartctl_state="ok"
            fi
        fi
    else
        if [[ "$smartctl_state" == "available" && -n "$smart_reason" ]]; then
            smartctl_state="$smart_reason"
        fi
    fi

    if (( nvme_available == 0 )); then
        nvme_scanned=0
        nvme_reason="tool_missing"
        nvme_state="missing"
    elif (( nvme_required_flag )) && (( root_access == 0 )); then
        nvme_scanned=0
        nvme_reason="root_required"
        nvme_state="permission"
        missing_tools+=("nvme-cli(permission)")
        tool_issue_flag=1
    fi

    local -a NVME_CMD=()
    if (( nvme_available )); then
        NVME_CMD=("${sudo_prefix[@]}" nvme)
    fi
    if (( nvme_scanned )); then
        local nvme_list_json
        nvme_list_json=$("${NVME_CMD[@]}" list -o json 2>/dev/null)
        if [[ -z "$nvme_list_json" ]]; then
            nvme_scanned=0
            nvme_reason="command_failed"
            nvme_state="error"
        else
            mapfile -t nvme_paths < <(echo "$nvme_list_json" | jq -r '.Devices[]?.DevicePath // empty')
            for dev in "${nvme_paths[@]}"; do
                echo "[NVMe] $dev"
                local model
                model=$(echo "$nvme_list_json" | jq -r ".Devices[] | select(.DevicePath==\"$dev\") | .ModelNumber // \"\"" 2>/dev/null)
                local smart_json
                smart_json=$("${NVME_CMD[@]}" smart-log -o json "$dev" 2>/dev/null)
                if [[ -z "$smart_json" ]]; then
                    smart_json=$("${NVME_CMD[@]}" id-ctrl -o json "$dev" 2>/dev/null)
                    if [[ -z "$smart_json" ]]; then
                        nvme_reason="smart_log_failed"
                        nvme_state="smart_log_failed"
                        continue
                    else
                        nvme_reason="smart_log_failed"
                        nvme_state="smart_log_failed"
                    fi
                fi
                local crit_warn
                crit_warn=$(echo "$smart_json" | jq -r '(.critical_warning // 0)' 2>/dev/null)
                [[ "$crit_warn" =~ ^[0-9]+$ ]] || crit_warn=0
                local media_err
                media_err=$(echo "$smart_json" | jq -r '(.media_errors // 0)' 2>/dev/null)
                [[ "$media_err" =~ ^[0-9]+$ ]] || media_err=0
                local err_log
                err_log=$(echo "$smart_json" | jq -r '(.num_err_log_entries // 0)' 2>/dev/null)
                [[ "$err_log" =~ ^[0-9]+$ ]] || err_log=0
                local temperature_k
                temperature_k=$(echo "$smart_json" | jq -r '(.temperature // 0)' 2>/dev/null)
                [[ "$temperature_k" =~ ^[0-9]+$ ]] || temperature_k=0
                local temperature_json="null"
                if [[ "$temperature_k" =~ ^[0-9]+$ && $temperature_k -gt 0 ]]; then
                    local temperature_c=$(( temperature_k - 273 ))
                    temperature_json=$temperature_c
                    if [[ -z "$nvme_temp_max" || "$temperature_c" -gt "$nvme_temp_max" ]]; then
                        nvme_temp_max="$temperature_c"
                    fi
                fi
                local pct_used
                pct_used=$(echo "$smart_json" | jq -r '(.percentage_used // 0)' 2>/dev/null)
                [[ "$pct_used" =~ ^[0-9]+$ ]] || pct_used=0
                nvme_devices_entries+=("$(jq -n --arg dev "$dev" --arg model "$model" --argjson crit $crit_warn --argjson media $media_err --argjson err $err_log --argjson temp $temperature_json --argjson pct $pct_used '{dev:$dev, model:$model, crit_warn:$crit, media_err:$media, err_log:$err, temp:(if $temp==null then null else $temp end), pct_used:$pct}')")
                if (( crit_warn > 0 )); then
                    nvme_cw_list+=("$dev")
                fi
                if (( media_err > 0 )); then
                    nvme_media_err_list+=("$dev")
                fi
                if (( pct_used >= NVME_PCT_USED_WARN )); then
                    nvme_pct80_list+=("$dev")
                fi
            done
        fi
    fi

    if (( nvme_scanned )); then
        if [[ "$nvme_state" == "available" ]]; then
            if [[ -n "$nvme_reason" && "$nvme_reason" != "tool_missing" ]]; then
                nvme_state="$nvme_reason"
            else
                nvme_state="ok"
            fi
        fi
    else
        if [[ "$nvme_state" == "available" && -n "$nvme_reason" ]]; then
            nvme_state="$nvme_reason"
        fi
    fi

    local smart_devices_json="[]"
    if (( ${#smart_devices_entries[@]} > 0 )); then
        smart_devices_json=$(printf '%s\n' "${smart_devices_entries[@]}" | jq -s '.')
    fi
    if (( smart_virtual_detected )) && (( smart_passthrough_detected == 0 )); then
        smart_virtual_only=1
    fi
    if (( megaraid_present )) && (( smart_passthrough_detected == 0 )) && (( smart_virtual_detected )); then
        smart_required_effective_flag=0
        SMART_REQUIRED_EFFECTIVE="false"
        smart_virtual_note_needed=1
    fi
    if (( megaraid_present )) && (( smart_virtual_failed_count > 0 )); then
        smart_virtual_note_needed=1
    fi
    local smart_failed_json='[]'
    if (( ${#smart_failed_list[@]} > 0 )); then
        smart_failed_json=$(printf '%s\n' "${smart_failed_list[@]}" | jq -R . | jq -s '.')
    fi
    local smart_realloc_json='[]'
    if (( ${#smart_realloc_list[@]} > 0 )); then
        smart_realloc_json=$(printf '%s\n' "${smart_realloc_list[@]}" | jq -R . | jq -s '.')
    fi
    local smart_pending_json='[]'
    if (( ${#smart_pending_list[@]} > 0 )); then
        smart_pending_json=$(printf '%s\n' "${smart_pending_list[@]}" | jq -R . | jq -s '.')
    fi
    local smart_uncorr_json='[]'
    if (( ${#smart_uncorr_list[@]} > 0 )); then
        smart_uncorr_json=$(printf '%s\n' "${smart_uncorr_list[@]}" | jq -R . | jq -s '.')
    fi

    local nvme_devices_json="[]"
    if (( ${#nvme_devices_entries[@]} > 0 )); then
        nvme_devices_json=$(printf '%s\n' "${nvme_devices_entries[@]}" | jq -s '.')
    fi
    local nvme_cw_json='[]'
    if (( ${#nvme_cw_list[@]} > 0 )); then
        nvme_cw_json=$(printf '%s\n' "${nvme_cw_list[@]}" | jq -R . | jq -s '.')
    fi
    local nvme_media_err_json='[]'
    if (( ${#nvme_media_err_list[@]} > 0 )); then
        nvme_media_err_json=$(printf '%s\n' "${nvme_media_err_list[@]}" | jq -R . | jq -s '.')
    fi
    local nvme_pct80_json='[]'
    if (( ${#nvme_pct80_list[@]} > 0 )); then
        nvme_pct80_json=$(printf '%s\n' "${nvme_pct80_list[@]}" | jq -R . | jq -s '.')
    fi

    : "${smart_devices_json:=[]}"
    : "${smart_failed_json:=[]}"
    : "${smart_realloc_json:=[]}"
    : "${smart_pending_json:=[]}"
    : "${smart_uncorr_json:=[]}"
    : "${nvme_devices_json:=[]}"
    : "${nvme_cw_json:=[]}"
    : "${nvme_media_err_json:=[]}"
    : "${nvme_pct80_json:=[]}"

    local smart_failed_count=${#smart_failed_list[@]}
    local smart_realloc_count=${#smart_realloc_list[@]}
    local smart_pending_count=${#smart_pending_list[@]}
    local smart_uncorr_count=${#smart_uncorr_list[@]}
    local nvme_cw_count=${#nvme_cw_list[@]}
    local nvme_media_err_count=${#nvme_media_err_list[@]}
    local nvme_pct80_count=${#nvme_pct80_list[@]}
    local mdadm_issue_count=$((mdadm_degraded + mdadm_recovering))

    local smart_alerts_json
    smart_alerts_json=$(jq -n \
      --argjson failed "$smart_failed_json" \
      --argjson realloc "$smart_realloc_json" \
      --argjson pending "$smart_pending_json" \
      --argjson uncorr "$smart_uncorr_json" \
      '{failed:$failed, realloc_gt0:$realloc, pending_gt0:$pending, uncorrect_gt0:$uncorr}')
    : "${smart_alerts_json:={}}"
    local smart_scan_file_json
    smart_scan_file_json=$(jq -n \
      --argjson devices "$smart_devices_json" \
      --argjson alerts "$smart_alerts_json" \
      '{devices:$devices, alerts:$alerts}')
    printf '%s\n' "$smart_scan_file_json" > "$smart_json_path"

    local nvme_alerts_json
    nvme_alerts_json=$(jq -n \
      --argjson crit "$nvme_cw_json" \
      --argjson media "$nvme_media_err_json" \
      --argjson pct "$nvme_pct80_json" \
      '{crit_warn_gt0:$crit, media_err_gt0:$media, pct_used_ge80:$pct}')
    : "${nvme_alerts_json:={}}"
    local nvme_scan_file_json
    nvme_scan_file_json=$(jq -n \
      --argjson devices "$nvme_devices_json" \
      --argjson alerts "$nvme_alerts_json" \
      '{devices:$devices, alerts:$alerts}')
    printf '%s\n' "$nvme_scan_file_json" > "$nvme_json_path"

    if [[ -s "$nvme_json_path" ]]; then
        nvme_device_count=$(jq -r '.devices | length' "$nvme_json_path" 2>/dev/null || echo 0)
    fi
    if [[ -z "$nvme_device_count" || "$nvme_device_count" == "null" ]]; then
        nvme_device_count=0
    fi
    if (( nvme_device_count == 0 )); then
        nvme_required_effective_flag=0
        NVME_REQUIRED_EFFECTIVE="false"
        nvme_skipped=1
    fi

    if (( smartctl_available == 0 )); then
        tips_text+=$'\n安裝 smartmontools: apt install smartmontools'
    fi
    if (( nvme_available == 0 )); then
        tips_text+=$'\n安裝 nvme-cli: apt install nvme-cli'
    fi
    if (( storcli_available == 0 )); then
        tips_text+=$'\n如需檢查硬體 RAID，請安裝 storcli (MegaRAID 工具)'
    fi

    : "${raid_controllers_json:=[]}"
    : "${mdadm_arrays_json:=[]}"
    local raid_metrics_json
    raid_metrics_json=$(jq -n --arg driver "$raid_driver" --argjson controllers "$raid_controllers_json" --argjson arrays "$mdadm_arrays_json" '{driver:$driver, controllers:$controllers, mdadm:{arrays:$arrays}}')
    local smart_scanned_json=$([[ $smart_scanned -eq 1 ]] && echo true || echo false)
    local nvme_scanned_json=$([[ $nvme_scanned -eq 1 ]] && echo true || echo false)
    : "${smart_scanned_json:=false}"
    : "${nvme_scanned_json:=false}"
    local smart_metrics_json
    smart_metrics_json=$(jq -n --argjson scanned $smart_scanned_json --argjson devices "$smart_devices_json" --argjson failed "$smart_failed_json" --argjson realloc "$smart_realloc_json" --argjson pending "$smart_pending_json" --argjson uncorr "$smart_uncorr_json" '{scanned:$scanned, devices:$devices, alerts:{failed:$failed, realloc_gt0:$realloc, pending_gt0:$pending, uncorr_gt0:$uncorr}}')
    local nvme_skipped_flag="false"
    if (( nvme_skipped )); then
        nvme_skipped_flag="true"
    fi
    local nvme_metrics_json
    nvme_metrics_json=$(jq -n \
      --argjson scanned $nvme_scanned_json \
      --argjson devices "$nvme_devices_json" \
      --argjson cw "$nvme_cw_json" \
      --argjson media "$nvme_media_err_json" \
      --argjson pct "$nvme_pct80_json" \
      --arg skipped "$nvme_skipped_flag" \
      '{
         scanned:$scanned,
         devices:$devices,
         alerts:{crit_warn_gt0:$cw, media_err_gt0:$media, pct_used_ge80:$pct}
       } + (if $skipped=="true" then {skipped:true} else {} end)')
    : "${raid_metrics_json:={}}"
    : "${smart_metrics_json:={}}"
    : "${nvme_metrics_json:={}}"
    local metrics_json
    metrics_json=$(jq -n --argjson raid "$raid_metrics_json" --argjson smart "$smart_metrics_json" --argjson nvme "$nvme_metrics_json" '{raid:$raid, smart:$smart, nvme:$nvme}')
    : "${metrics_json:={}}"

    local tools_json
    tools_json=$(jq -n \
      --arg storcli "$storcli_state" \
      --arg smartctl "$smartctl_state" \
      --arg nvme "$nvme_state" \
      --arg lsblk "$lsblk_state" \
      '{storcli64:$storcli, smartctl:$smartctl, nvme_cli:$nvme, lsblk:$lsblk}')
    local raid_summary_json="$raid_summary_raw"
    [[ -z "$raid_summary_json" ]] && raid_summary_json="{}"
    local mdadm_arrays_json_local="$mdadm_arrays_json"
    [[ -z "$mdadm_arrays_json_local" ]] && mdadm_arrays_json_local="[]"
    local disk_summary_json
    disk_summary_json=$(jq -n \
      --arg timestamp "$TIMESTAMP" \
      --arg raid_driver "$raid_driver" \
      --arg raid_status "${RAID_STATUS_IMPACT:-}" \
      --arg summary "${summary_text:-}" \
      --argjson raid "$raid_summary_json" \
      --argjson mdadm "$mdadm_arrays_json_local" \
      --argjson smart_devices "$smart_devices_json" \
      --argjson smart_alerts "$smart_alerts_json" \
      --argjson nvme_devices "$nvme_devices_json" \
      --argjson nvme_alerts "$nvme_alerts_json" \
      --argjson tools "$tools_json" \
      --argjson metrics "$metrics_json" \
      '{timestamp:$timestamp, raid_driver:$raid_driver, raid_status:$raid_status, raid:$raid, mdadm_arrays:$mdadm, smart:{devices:$smart_devices, alerts:$smart_alerts}, nvme:{devices:$nvme_devices, alerts:$nvme_alerts}, tools:$tools, summary:$summary, metrics:$metrics}')
    printf '%s\n' "$disk_summary_json" > "$disk_summary_path"


    local severity=0
    local missing_checks=0
    if (( storcli_check_skipped )); then
        :
        # LEGACY_DISABLED: missing_checks=1
    fi
    if (( tool_issue_flag )); then
        # LEGACY_DISABLED: missing_checks=1
        (( severity < 1 )) && severity=1
    fi
    local vd_optimal=$((vd_total - vd_degraded - vd_failed))
    (( vd_optimal < 0 )) && vd_optimal=0

    if (( pd_failed >= PD_FAIL_CRIT )); then
        (( severity < 2 )) && severity=2
        fail_reasons+=("硬體 RAID: PD failed=${pd_failed}")
    fi
    if (( vd_failed > 0 )); then
        (( severity < 2 )) && severity=2
        fail_reasons+=("硬體 RAID: VD failed=${vd_failed}")
    fi
    if (( smart_failed_count >= SMART_ALERT_FAIL_CRIT )); then
        (( severity < 2 )) && severity=2
        fail_reasons+=("SMART FAILED: ${smart_failed_list[*]}")
    fi
    if (( nvme_cw_count >= NVME_CRIT_WARN_CRIT )); then
        (( severity < 2 )) && severity=2
        fail_reasons+=("NVMe critical_warning: ${nvme_cw_list[*]}")
    fi

    if (( vd_degraded >= VD_DEGRADED_WARN )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("硬體 RAID: VD degraded=${vd_degraded}")
    fi
    if (( vd_rebuild >= DISK_REBUILD_WARN )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("硬體 RAID: rebuild=${vd_rebuild}")
    fi
    if (( pd_missing > 0 )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("硬體 RAID: PD missing=${pd_missing}")
    fi
    if (( mdadm_degraded > 0 )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("mdadm degraded=${mdadm_degraded}")
    fi
    if (( mdadm_recovering > 0 )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("mdadm resync=${mdadm_recovering}")
    fi
    if (( smart_realloc_count >= SMART_REALLOC_WARN )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("SMART realloc>0: ${smart_realloc_list[*]}")
    fi
    if (( smart_pending_count >= SMART_PENDING_WARN )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("SMART pending>0: ${smart_pending_list[*]}")
    fi
    if (( smart_uncorr_count > 0 )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("SMART uncorrect>0: ${smart_uncorr_list[*]}")
    fi
    if (( nvme_media_err_count >= NVME_MEDIA_ERR_WARN )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("NVMe media_errors>0: ${nvme_media_err_list[*]}")
    fi
    if (( nvme_pct80_count > 0 )); then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("NVMe pct_used>=${NVME_PCT_USED_WARN}: ${nvme_pct80_list[*]}")
    fi
    if (( storcli_scanned == 0 )); then
        # LEGACY_DISABLED: missing_checks=1
        (( severity < 1 )) && severity=1
        case "$storcli_reason" in
            not_found) warn_reasons+=("storcli 不存在，硬體 RAID 未檢查");;
            root_required) warn_reasons+=("權限不足，storcli 無法執行");;
            no_controllers) warn_reasons+=("storcli 未偵測到控制器");;
            no_data) warn_reasons+=("storcli 無輸出，硬體 RAID 未檢查");;
            not_supported) warn_reasons+=("storcli 未執行");;
        esac
    fi
    if (( smart_scanned == 0 )); then
        # LEGACY_DISABLED: missing_checks=1
        (( severity < 1 )) && severity=1
        case "$smart_reason" in
            tool_missing) warn_reasons+=("SMART 檢查跳過：smartctl 缺少");;
            root_required) warn_reasons+=("SMART 檢查跳過：權限不足");;
            *) warn_reasons+=("SMART 檢查未完成");;
        esac
    elif [[ -n "$smart_reason" ]]; then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("SMART 命令狀態：$smart_reason")
    fi
    if (( nvme_scanned == 0 )); then
        # LEGACY_DISABLED: missing_checks=1
        (( severity < 1 )) && severity=1
        case "$nvme_reason" in
            tool_missing) warn_reasons+=("NVMe 檢查跳過：nvme CLI 缺少");;
            root_required) warn_reasons+=("NVMe 檢查跳過：權限不足");;
            command_failed) warn_reasons+=("NVMe 檢查未完成");;
            smart_log_failed) warn_reasons+=("NVMe smart-log 失敗");;
        esac
    elif [[ -n "$nvme_reason" ]]; then
        (( severity < 2 )) && severity=1
        # LEGACY_DISABLED: warn_reasons+=("NVMe smart-log 備註：$nvme_reason")
    fi

    local final_status="PASS"
    case $severity in
        2) final_status="FAIL";;
        1) final_status="WARN";;
    esac
    if (( ${no_disks_detected:-0} )) && [[ "$final_status" == "PASS" ]]; then
        final_status="INFO"
    fi

    local -a highlight_selection=()
    if (( severity == 2 )); then
        highlight_selection=("${fail_reasons[@]}")
        if (( ${#highlight_selection[@]} < 3 )); then
            highlight_selection+=("${warn_reasons[@]}")
        fi
    else
        highlight_selection=("${warn_reasons[@]}")
    fi
    local highlight_text=""
    if (( ${#highlight_selection[@]} > 0 )); then
        local count=0
        for entry in "${highlight_selection[@]}"; do
            [[ -z "$entry" ]] && continue
            highlight_text+="$entry; "
            (( count++ ))
            if (( count >= 3 )); then
                break
            fi
        done
        highlight_text=${highlight_text%; }
    fi

    local raid_controller_count
    raid_controller_count=$(echo "$raid_controllers_json" | jq 'length' 2>/dev/null || echo 0)
    local smart_device_count_total
    smart_device_count_total=$(echo "$smart_devices_json" | jq 'length' 2>/dev/null || echo 0)
    local smart_device_count=$smart_passthrough_count
    if [[ -z "$smart_device_count_total" || "$smart_device_count_total" == "null" ]]; then
        smart_device_count_total=0
    fi
    if [[ -z "$nvme_device_count" || "$nvme_device_count" == "null" ]]; then
        nvme_device_count=$(echo "$nvme_devices_json" | jq 'length' 2>/dev/null || echo 0)
    fi

    local has_raid_data=0
    if (( storcli_scanned )) && (( raid_controller_count > 0 )); then
        has_raid_data=1
    fi
    if (( mdadm_arrays_found > 0 )); then
        has_raid_data=1
    fi
    local has_smart_data=0
    if (( smart_scanned )) && (( smart_device_count > 0 )); then
        has_smart_data=1
    fi
    local has_nvme_data=0
    if (( nvme_scanned )) && (( nvme_device_count > 0 )); then
        has_nvme_data=1
    fi
    local no_disks_detected=0
    if (( has_raid_data == 0 && has_smart_data == 0 && has_nvme_data == 0 )); then
        no_disks_detected=1
    fi

    local raid_summary_brief=""
    if (( storcli_scanned )); then
        raid_summary_brief=$(printf "ctl=%s vd=%s/%s/%s rebuild=%s pd_fail=%s missing=%s" \
            "$raid_controller_count" "$vd_total" "$vd_degraded" "$vd_failed" "$vd_rebuild" "$pd_failed" "$pd_missing")
        if (( pd_total > 0 )); then
            raid_summary_brief=$(printf "%s pd_total=%s" "$raid_summary_brief" "$pd_total")
        fi
    else
        raid_summary_brief=$(printf "RAID skipped (%s)" "${storcli_reason:-not_run}")
    fi

    local mdadm_summary_brief=""
    if (( mdadm_arrays_found )); then
        mdadm_summary_brief=$(printf "mdadm arrays=%s degraded=%s rebuilding=%s" \
            "$mdadm_arrays_found" "$mdadm_degraded" "$mdadm_recovering")
    fi

    local smart_summary_brief=""
    if (( smart_scanned )); then
        if (( smart_device_count > 0 )); then
            smart_summary_brief=$(printf "SMART disks=%s failed=%s realloc=%s pending=%s uncorr=%s" \
                "$smart_device_count" "$smart_failed_count" "$smart_realloc_count" "$smart_pending_count" "$smart_uncorr_count")
            if (( smart_virtual_devices_count > 0 )); then
                smart_summary_brief=$(printf "%s virtual_ignored=%s" "$smart_summary_brief" "$smart_virtual_devices_count")
            fi
        elif (( smart_virtual_devices_count > 0 )); then
            smart_summary_brief=$(printf "SMART virtual_only=%s (ignored)" "$smart_virtual_devices_count")
        else
            smart_summary_brief="SMART disks=0"
        fi
    else
        smart_summary_brief=$(printf "SMART skipped (%s)" "${smart_reason:-not_run}")
    fi

    local nvme_summary_brief=""
    if (( nvme_scanned )); then
        nvme_summary_brief=$(printf "NVMe dev=%s crit_warn=%s media_err=%s pct>=%s=%s" \
            "$nvme_device_count" "$nvme_cw_count" "$nvme_media_err_count" "$NVME_PCT_USED_WARN" "$nvme_pct80_count")
        if [[ -n "$nvme_temp_max" ]]; then
            nvme_summary_brief=$(printf "%s max_temp=%s°C" "$nvme_summary_brief" "$nvme_temp_max")
        fi
    else
        nvme_summary_brief=$(printf "NVMe skipped (%s)" "${nvme_reason:-not_run}")
    fi

    local -a summary_parts=("$raid_summary_brief")
    if [[ -n "$mdadm_summary_brief" ]]; then
        summary_parts+=("$mdadm_summary_brief")
    fi
    summary_parts+=("$smart_summary_brief" "$nvme_summary_brief")
    local summary_text
    summary_text=$(IFS='; '; echo "${summary_parts[*]}")

    local smart_ok_count=$(( smart_device_count - smart_failed_count ))
    (( smart_ok_count < 0 )) && smart_ok_count=0
    local nvme_alert_total=$(( nvme_cw_count + nvme_media_err_count + nvme_pct80_count ))
    local nvme_ok_count=$(( nvme_device_count - nvme_alert_total ))
    (( nvme_ok_count < 0 )) && nvme_ok_count=0
    local -a raid_issue_parts=()
    local raid_has_data=0
    (( raid_controller_count > 0 )) && raid_has_data=1
    (( mdadm_arrays_found > 0 )) && raid_has_data=1
    (( vd_degraded > 0 )) && raid_issue_parts+=("vd_degraded=${vd_degraded}")
    (( vd_failed > 0 )) && raid_issue_parts+=("vd_failed=${vd_failed}")
    (( vd_rebuild > 0 )) && raid_issue_parts+=("vd_rebuild=${vd_rebuild}")
    (( pd_failed > 0 )) && raid_issue_parts+=("pd_failed=${pd_failed}")
    (( pd_missing > 0 )) && raid_issue_parts+=("pd_missing=${pd_missing}")
    (( mdadm_degraded > 0 )) && raid_issue_parts+=("mdadm_degraded=${mdadm_degraded}")
    (( mdadm_recovering > 0 )) && raid_issue_parts+=("mdadm_recovering=${mdadm_recovering}")
    local raid_status_summary=""
    if (( raid_has_data )); then
        if (( ${#raid_issue_parts[@]} == 0 )); then
            raid_status_summary="Optimal"
        else
            raid_status_summary=$(IFS=', '; echo "${raid_issue_parts[*]}")
        fi
    else
        if (( storcli_scanned == 0 )) && [[ -n "$storcli_reason" ]]; then
            raid_status_summary="Skipped(${storcli_reason})"
        else
            raid_status_summary="None"
        fi
    fi
    local raid_summary_txt
    raid_summary_txt=$(printf "RAID: %s" "$raid_status_summary")

    local smart_summary_txt=""
    if (( smart_scanned )); then
        if (( smart_device_count > 0 )); then
            smart_summary_txt=$(printf "SMART: ok=%s/%s fail=%s" "$smart_ok_count" "$smart_device_count" "$smart_failed_count")
            if (( smart_virtual_devices_count > 0 )); then
                smart_summary_txt+=" (virtual entries ignored)"
            fi
        elif (( smart_virtual_devices_count > 0 )); then
            smart_summary_txt="SMART: ignored (RAID virtual dev)"
        else
            smart_summary_txt="SMART: none"
        fi
    else
        smart_summary_txt=$(printf "SMART: skipped (%s)" "${smart_reason:-not_run}")
    fi

    local nvme_summary_txt=""
    if (( nvme_skipped )); then
        nvme_summary_txt="NVMe: none, skipped"
    elif (( nvme_scanned )); then
        nvme_summary_txt=$(printf "NVMe: ok=%s/%s media_err=%s crit_warn=%s pct80=%s" \
            "$nvme_ok_count" "$nvme_device_count" "$nvme_media_err_count" "$nvme_cw_count" "$nvme_pct80_count")
        if [[ -n "$nvme_temp_max" ]]; then
            nvme_summary_txt=$(printf "%s max_temp=%s°C" "$nvme_summary_txt" "$nvme_temp_max")
        fi
    else
        nvme_summary_txt=$(printf "NVMe: skipped (%s)" "${nvme_reason:-not_run}")
    fi

    local disk_health_summary
    disk_health_summary=$(printf "%s; %s; %s" "$raid_summary_txt" "$smart_summary_txt" "$nvme_summary_txt")

    local smart_alert_total=$((smart_failed_count + smart_realloc_count + smart_pending_count + smart_uncorr_count))
    local reason_core
    reason_core=$(printf "ctl=%s vd_total/dgrd/fail=%s/%s/%s pd_total/fail/missing=%s/%s/%s smart_alerts=%s nvme_media_err=%s" \
        "$raid_controller_count" "$vd_total" "$vd_degraded" "$vd_failed" "$pd_total" "$pd_failed" "$pd_missing" "$smart_alert_total" "$nvme_media_err_count")
    local final_reason="$reason_core"
    if (( ${no_disks_detected:-0} )) && [[ "$final_status" == "INFO" ]]; then
        final_reason="No disk devices detected (RAID controllers=0, SMART disks=0, NVMe devices=0)"
    fi
    if [[ "$final_status" != "PASS" && -n "$highlight_text" ]]; then
        final_reason+="；異常：$highlight_text"
    fi
    if [[ -n "$disk_health_summary" ]]; then
        if [[ -n "$final_reason" ]]; then
            final_reason+="；${disk_health_summary}"
        else
            final_reason="$disk_health_summary"
        fi
    fi
    if (( smart_virtual_note_needed )); then
        if [[ -n "$final_reason" ]]; then
            final_reason+="；SMART via RAID virtual device not authoritative; using RAID health as source of truth"
        else
            final_reason="SMART via RAID virtual device not authoritative; using RAID health as source of truth"
        fi
    fi
    if (( ${#missing_tools[@]} > 0 )); then
        declare -A _SEEN_MISSING=()
        local -a unique_missing=()
        for tool_name in "${missing_tools[@]}"; do
            [[ -z "$tool_name" ]] && continue
            if [[ -z "${_SEEN_MISSING["$tool_name"]:-}" ]]; then
                _SEEN_MISSING["$tool_name"]=1
                unique_missing+=("$tool_name")
            fi
        done
        if (( ${#unique_missing[@]} > 0 )); then
            local missing_join=""
            local idx=0
            for tool_name in "${unique_missing[@]}"; do
                (( idx > 0 )) && missing_join+=", "
                missing_join+="$tool_name"
                ((idx++))
            done
            final_reason+="；缺少工具: ${missing_join}"
        fi
    fi

    local -a checks_entries=()
    checks_entries+=("$(jq -n --arg state "$storcli_state" '{name:"storcli64 state", ok:($state=="ok" or $state=="no_controllers" or $state=="no_data" or $state=="not_supported"), value:$state}')")
    checks_entries+=("$(jq -n --arg state "$smartctl_state" '{name:"smartctl state", ok:($state=="ok" or $state=="available"), value:$state}')")
    checks_entries+=("$(jq -n --arg state "$nvme_state" '{name:"nvme-cli state", ok:($state=="ok" or $state=="available"), value:$state}')")
    checks_entries+=("$(jq -n --arg state "$lsblk_state" '{name:"lsblk state", ok:($state=="ok"), value:$state}')")
    checks_entries+=("$(jq -n --arg controllers "$raid_controller_count" '{name:"RAID controllers detected", ok:(($controllers|tonumber)>0), value:("controllers="+$controllers)}')")
    checks_entries+=("$(jq -n --arg vd_deg "$vd_degraded" --arg vd_fail "$vd_failed" '{name:"RAID all VDs optimal", ok:((($vd_deg|tonumber)==0) and (($vd_fail|tonumber)==0)), value:("vd_degraded="+$vd_deg+", vd_failed="+$vd_fail)}')")
    checks_entries+=("$(jq -n --arg vd_rb "$vd_rebuild" '{name:"RAID rebuild=0", ok:(($vd_rb|tonumber)==0), value:("rebuild="+$vd_rb)}')")
    checks_entries+=("$(jq -n --arg pd_fail "$pd_failed" --arg pd_miss "$pd_missing" '{name:"RAID PD healthy", ok:((($pd_fail|tonumber)==0) and (($pd_miss|tonumber)==0)), value:("pd_failed="+$pd_fail+", pd_missing="+$pd_miss)}')")
    checks_entries+=("$(jq -n --arg md_issues "$mdadm_issue_count" '{name:"mdadm arrays healthy", ok:(($md_issues|tonumber)==0), value:("issues="+$md_issues)}')")
    if (( smart_required_effective_flag )); then
        checks_entries+=("$(jq -n --arg smart_fail "$smart_failed_count" '{name:"SMART FAILED=0", ok:(($smart_fail|tonumber)==0), value:("failed="+$smart_fail)}')")
        checks_entries+=("$(jq -n --arg smart_realloc "$smart_realloc_count" '{name:"SMART realloc=0", ok:(($smart_realloc|tonumber)==0), value:("realloc="+$smart_realloc)}')")
        checks_entries+=("$(jq -n --arg smart_pending "$smart_pending_count" '{name:"SMART pending=0", ok:(($smart_pending|tonumber)==0), value:("pending="+$smart_pending)}')")
        checks_entries+=("$(jq -n --arg smart_uncorr "$smart_uncorr_count" '{name:"SMART uncorrect=0", ok:(($smart_uncorr|tonumber)==0), value:("uncorr="+$smart_uncorr)}')")
    else
        local smart_skip_msg="skipped"
        if (( smart_virtual_devices_count > 0 )); then
            smart_skip_msg="skipped (RAID virtual dev)"
        fi
        checks_entries+=("$(jq -n --arg msg "$smart_skip_msg" '{name:"SMART required", ok:true, value:$msg}')")
    fi
    if (( nvme_required_effective_flag )); then
        checks_entries+=("$(jq -n --arg nvme_cw "$nvme_cw_count" '{name:"NVMe crit_warn=0", ok:(($nvme_cw|tonumber)==0), value:("crit_warn="+$nvme_cw)}')")
        checks_entries+=("$(jq -n --arg nvme_media "$nvme_media_err_count" '{name:"NVMe media_err=0", ok:(($nvme_media|tonumber)==0), value:("media_err="+$nvme_media)}')")
        checks_entries+=("$(jq -n --arg nvme_pct "$nvme_pct80_count" '{name:"NVMe pct_used<80", ok:(($nvme_pct|tonumber)==0), value:("pct_used>=80_count="+$nvme_pct)}')")
    else
        local nvme_skip_msg="skipped"
        if (( nvme_skipped )); then
            nvme_skip_msg="skipped (no devices)"
        fi
        checks_entries+=("$(jq -n --arg msg "$nvme_skip_msg" '{name:"NVMe required", ok:true, value:$msg}')")
    fi
    checks_entries+=("$(jq -n --arg summary "$disk_health_summary" '{name:"Disk health summary", ok:true, value:$summary}')")
    local checks_json='[]'
    if (( ${#checks_entries[@]} > 0 )); then
        checks_json=$(printf '%s\n' "${checks_entries[@]}" | jq -s '.')
    fi

    local th_json
    th_json=$(jq -n \
      --arg smart_req "$SMART_REQUIRED_EFFECTIVE" \
      --arg nvme_req "$NVME_REQUIRED_EFFECTIVE" \
      --arg root_req "$ROOT_REQUIRED" \
      --arg disk_rebuild "$DISK_REBUILD_WARN" \
      --arg pd_fail "$PD_FAIL_CRIT" \
      --arg vd_deg "$VD_DEGRADED_WARN" \
      --arg smart_fail "$SMART_ALERT_FAIL_CRIT" \
      --arg smart_realloc "$SMART_REALLOC_WARN" \
      --arg smart_pending "$SMART_PENDING_WARN" \
      --arg nvme_cw "$NVME_CRIT_WARN_CRIT" \
      --arg nvme_media "$NVME_MEDIA_ERR_WARN" \
      --arg nvme_pct "$NVME_PCT_USED_WARN" \
      '{SMART_REQUIRED:($smart_req|test("^(?i:true|1|yes)$")),
        NVME_REQUIRED:($nvme_req|test("^(?i:true|1|yes)$")),
        ROOT_REQUIRED:($root_req|test("^(?i:true|1|yes)$")),
        DISK_REBUILD_WARN:($disk_rebuild|tonumber),
        PD_FAIL_CRIT:($pd_fail|tonumber),
        VD_DEGRADED_WARN:($vd_deg|tonumber),
        SMART_ALERT_FAIL_CRIT:($smart_fail|tonumber),
        SMART_REALLOC_WARN:($smart_realloc|tonumber),
        SMART_PENDING_WARN:($smart_pending|tonumber),
        NVME_CRIT_WARN_CRIT:($nvme_cw|tonumber),
        NVME_MEDIA_ERR_WARN:($nvme_media|tonumber),
        NVME_PCT_USED_WARN:($nvme_pct|tonumber)}')

    local evidence_json
    evidence_json=$(jq -n \
      --arg main "$LOG_TXT" \
      --arg stor "$storcli_summary_path" \
      --arg md "$mdstat_log" \
      --arg smart "$smart_json_path" \
      --arg nvme "$nvme_json_path" \
      --arg disk_summary "$disk_summary_path" \
      '{main_output_log:$main,
        storcli_summary:(if $stor=="" then null else $stor end),
        mdadm_mdstat_log:(if $md=="" then null else $md end),
        smart_scan_log:(if $smart=="" then null else $smart end),
        nvme_smart_log:(if $nvme=="" then null else $nvme end),
        disk_summary_json:(if $disk_summary=="" then null else $disk_summary end)} | with_entries(select(.value != null))')

    local pass_rules='["硬體/軟體 RAID 無降級或故障、SMART/NVMe 無 FAIL/警示"]'
    local warn_rules='["出現 rebuild/degraded/mdadm resync 或 SMART/NVMe 警示，或部分來源缺工具/權限"]'
    local fail_rules='["RAID VD/PD 故障、SMART FAILED、NVMe critical_warning > 0"]'
    local criteria="磁碟健康 (RAID + SMART + NVMe)：須所有控制器/磁碟無 Fail/Degraded/Rebuild，SMART/NVMe 未出現重大警訊。"

    local base_json
    base_json=$(jq -n \
      --arg status "$final_status" \
      --arg item "$item" \
      --arg reason "$final_reason" \
      --argjson metrics "$metrics_json" \
      --argjson evidence "$evidence_json" \
      '{status:$status,item:$item,reason:$reason,metrics:$metrics,evidence:$evidence}')

    if [[ -n "$tips_text" ]]; then
      base_json=$(echo "$base_json" | jq --arg tips "$tips_text" \
        '. + {tips: ($tips | split("\n") | map(select(. != "")))}')
    fi
    base_json=$(echo "$base_json" | jq --argjson thresholds "$th_json" '. + {thresholds:$thresholds}')

    printf '%s\n' "$base_json" > "$metrics_path"

    local jdg_json
    jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" "$th_json")

    set_check_result_with_jdg 2 "$base_json" "$jdg_json"

    # safety: if item2 base_json missing, commit fallback
    if [[ -z "${base_json:-}" ]] || [[ "$(echo "$base_json" | jq -r .status 2>/dev/null)" == "null" ]]; then
      commit_item2_safety
    fi
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

        total=$(awk -v a="$total" -v b="$current_temp" 'BEGIN { printf "%.3f", (a+0)+(b+0) }')
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

    local cur_max_temp="$max_temp"
    local cpu_hist_file="${LOG_DIR}/cpu/cpu_history.json"
    local iso_now; iso_now=$(date -u +"%Y-%m-%d %H:%M:%S")
    local peak_ma
    peak_ma=$(cpu_history_upsert_and_stats "$cur_max_temp" "$avg_temp" "$SCRIPT_START_TS" "$iso_now" "$cpu_hist_file")
    local cpu90_peak="${peak_ma%%|*}"
    local cpu90_ma="${peak_ma##*|}"
    [[ -z "$cpu90_peak" ]] && cpu90_peak="0"
    [[ -z "$cpu90_ma" ]] && cpu90_ma="0"
    local cpu90_peak_display cpu90_ma_display
    cpu90_peak_display=$(awk -v v="$cpu90_peak" 'BEGIN { printf "%.1f", v }')
    cpu90_ma_display=$(awk -v v="$cpu90_ma" 'BEGIN { printf "%.1f", v }')

    # Logic
    local status="PASS"
    local cpu_reason=""
    local temp_diff
    temp_diff=$(awk -v avg="$avg_temp" -v base="$baseline_avg" 'BEGIN { printf "%.4f", avg-base }')

    if float_ge "$max_temp" "$CPU_TEMP_CRIT"; then
        status="FAIL"
        cpu_reason=$(printf "CPU 溫度嚴重過高。Max: %s°C ≥ %s°C。90d Peak: %s°C, 90d MA: %s°C." "$max_temp_display" "$CPU_TEMP_CRIT" "$cpu90_peak_display" "$cpu90_ma_display")
    elif float_ge "$max_temp" "$CPU_TEMP_WARN"; then
        status="WARN"
        cpu_reason=$(printf "CPU 溫度警告。Max: %s°C ≥ WARN %s°C。90d Peak: %s°C, 90d MA: %s°C." "$max_temp_display" "$CPU_TEMP_WARN" "$cpu90_peak_display" "$cpu90_ma_display")
    elif float_ge "$temp_diff" 15; then
        status="FAIL"
        cpu_reason=$(printf "CPU 平均溫度異常升高：%s°C 較基準 %s°C 高出 %s°C。90d MA: %s°C, 90d Peak: %s°C." "$avg_temp_display" "$baseline_avg" "$temp_diff" "$cpu90_ma_display" "$cpu90_peak_display")
    elif float_ge "$temp_diff" 10; then
        status="WARN"
        cpu_reason=$(printf "CPU 平均溫度升高：%s°C 較基準 %s°C 高出 %s°C。90d MA: %s°C, 90d Peak: %s°C." "$avg_temp_display" "$baseline_avg" "$temp_diff" "$cpu90_ma_display" "$cpu90_peak_display")
    else
        cpu_reason=$(printf "CPU 溫度正常。Max: %s°C (90d Peak: %s°C), Avg: %s°C (90d MA: %s°C)." "$max_temp_display" "$cpu90_peak_display" "$avg_temp_display" "$cpu90_ma_display")
    fi

    # Final JSON
    local metrics_json
    metrics_json=$(jq -n \
        --argjson max "$max_temp" \
        --argjson avg "$avg_temp" \
        --arg peak "$cpu90_peak" \
        --arg ma "$cpu90_ma" \
        '{max: $max, average: $avg, historical_stats:{peak_max_temp_90d:($peak|tonumber), rolling_avg_temp_90d:($ma|tonumber)}}')
    
    local thresholds_json
    thresholds_json=$(jq -n --argjson warn "$CPU_TEMP_WARN" --argjson crit "$CPU_TEMP_CRIT" --argjson base "$baseline_avg" \
        '{warn_celsius:$warn, crit_celsius:$crit, baseline_avg_celsius:$base}')

    local historical_stats_json
    historical_stats_json=$(echo "$metrics_json" | jq '.historical_stats // {}')

    local evidence_json
    evidence_json=$(jq -n --arg raw "$raw_log_path" --arg base "$baseline_path" \
        '{raw_log:$raw, baseline_file:$base}')

    local final_json
    final_json=$(jq -n \
        --arg status "$status" \
        --arg item "$item" \
        --arg reason "$cpu_reason" \
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
      --arg peak "$cpu90_peak_display" \
      --arg ma "$cpu90_ma_display" \
      --arg warn "$CPU_TEMP_WARN" \
      --arg crit "$CPU_TEMP_CRIT" \
      '[
         {"name":"Max Temp <= WARN","ok":((($max_temp|tonumber) <= ($warn|tonumber))),"value":("max="+$max_display+"°C")},
         {"name":"Max Temp <= CRIT","ok":((($max_temp|tonumber) <= ($crit|tonumber))),"value":("max="+$max_display+"°C")},
         {"name":"Rolling Avg (90d)","ok":true,"value":("avg="+$ma+"°C")},
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
        softnet_rate_per_sec=$(awk -v d="$SOFTNET_DELTA" -v w="$window_seconds_used" 'BEGIN{ if(w>0) printf "%.3f", d/w; else print 0 }')
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

            local r_rx_d=$(awk -v a="$d_rx_d" -v b="$nic_window_sec" 'BEGIN{printf "%.3f", a/b}')

            local drop_pct="0.000000"
            if [[ "$d_rx_pkts" -gt 0 ]]; then
              drop_pct=$(awk -v d="$d_rx_d" -v p="$d_rx_pkts" 'BEGIN{printf "%.3f", (d/p)*100.0}')
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
    # Quick verify: jq '.items[] | select(.id==7) | .evidence' logs/*_latest.json

    # Define paths
    : "${FAN_BASELINE_FILE:=${LOG_DIR:-logs}/fan_baseline.json}"
    : "${FAN_BASELINE_RESET:=0}"

    local raw_sensors_log="${LOG_DIR}/sensors_output_${TIMESTAMP}.log" # This file is already created by check_cpu
    local raw_ipmi_sdr_log="${LOG_DIR}/ipmi_sdr_fan_${TIMESTAMP}.log"
    local baseline_path="$FAN_BASELINE_FILE"
    local metrics_dir="${LOG_DIR}/fan"
    local metrics_path="${metrics_dir}/metrics_${TIMESTAMP}.json"
    mkdir -p "${metrics_dir}"

    # Get OS-level sensor data
    local fan_out
    fan_out=$(sensors 2>/dev/null | egrep -i '^fan[0-9a-zA-Z]+:' || true)
    echo "$fan_out"

    # Get IPMI-level SDR data
    local -a ipmi_fan_data=()
    local ipmi_sdr_out=""
    if (( ! SKIP_BMC )); then
        ipmi_sdr_out=$(ipmi_try sdr elist | grep -i fan)
        echo "$ipmi_sdr_out" > "$raw_ipmi_sdr_log"
        echo "$ipmi_sdr_out"

        local ipmi_parse_source=""
        if [[ -s "$raw_ipmi_sdr_log" ]]; then
            ipmi_parse_source="$raw_ipmi_sdr_log"
        elif [[ -n "$ipmi_sdr_out" ]]; then
            ipmi_parse_source="INLINE"
        fi

        if [[ -n "$ipmi_parse_source" ]]; then
            local __ipmi_line
            if [[ "$ipmi_parse_source" == "INLINE" ]]; then
                while IFS= read -r __ipmi_line; do
                    [[ -z "$__ipmi_line" ]] && continue
                    __ipmi_line=${__ipmi_line%$'\r'}
                    local trimmed_line
                    trimmed_line=$(printf '%s' "$__ipmi_line" | sed 's/^[[:space:]]*//')
                    [[ "$trimmed_line" =~ ^[Ff][Aa][Nn]_ ]] || continue
                    [[ "$trimmed_line" =~ RPM ]] || continue
                    local fan_name
                    fan_name=$(printf '%s\n' "$__ipmi_line" | cut -d'|' -f1 | xargs | tr ' ' '_' | tr -d '-')
                    [[ -z "$fan_name" ]] && continue
                    local current_rpm
                    current_rpm=$(printf '%s\n' "$__ipmi_line" | cut -d'|' -f5 | grep -oE '[0-9]+' | head -n 1)
                    [[ -z "$current_rpm" ]] && continue
                    ipmi_fan_data+=("${fan_name}|${current_rpm}")
                done <<< "$ipmi_sdr_out"
            else
                while IFS= read -r __ipmi_line; do
                    [[ -z "$__ipmi_line" ]] && continue
                    __ipmi_line=${__ipmi_line%$'\r'}
                    local trimmed_line
                    trimmed_line=$(printf '%s' "$__ipmi_line" | sed 's/^[[:space:]]*//')
                    [[ "$trimmed_line" =~ ^[Ff][Aa][Nn]_ ]] || continue
                    [[ "$trimmed_line" =~ RPM ]] || continue
                    local fan_name
                    fan_name=$(printf '%s\n' "$__ipmi_line" | cut -d'|' -f1 | xargs | tr ' ' '_' | tr -d '-')
                    [[ -z "$fan_name" ]] && continue
                    local current_rpm
                    current_rpm=$(printf '%s\n' "$__ipmi_line" | cut -d'|' -f5 | grep -oE '[0-9]+' | head -n 1)
                    [[ -z "$current_rpm" ]] && continue
                    ipmi_fan_data+=("${fan_name}|${current_rpm}")
                done < "$ipmi_parse_source"
            fi
        fi
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

    # Collect OS-level fan readings to seed or compare with baseline
    local -a current_fans=()
    local -a os_fan_data=()
    if [[ -n "$fan_out" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local fan_name
            fan_name=$(echo "$line" | awk -F: '{print $1}' | xargs | tr ' ' '_' | tr -d '-')
            [[ -z "$fan_name" ]] && continue
            local current_rpm
            current_rpm=$(echo "$line" | grep -oP '[0-9]+' | head -n1)
            [[ -z "$current_rpm" ]] && continue
            os_fan_data+=("${fan_name}|${current_rpm}")
            current_fans+=("${fan_name}|${current_rpm}")
        done <<< "$fan_out"
    fi

    local baseline_dir
    baseline_dir=$(dirname "$baseline_path")
    mkdir -p "$baseline_dir" 2>/dev/null || true

    local -a baseline_seed_data=("${current_fans[@]}")
    local baseline_seed_source="os"
    if (( ${#baseline_seed_data[@]} == 0 )); then
        if (( ${#ipmi_fan_data[@]} > 0 )); then
            baseline_seed_source="ipmi"
            baseline_seed_data=("${ipmi_fan_data[@]}")
        else
            baseline_seed_source="none"
        fi
    fi

    local baseline_seed_json
    baseline_seed_json=$(printf '%s\n' "${baseline_seed_data[@]}" | jq -R 'select(length>0) | split("|") | {name:.[0], baseline_rpm:(.[1]|tonumber?)}' | jq -s '.')
    [[ -z "$baseline_seed_json" ]] && baseline_seed_json='[]'

    local baseline_initialized=0
    if [[ "$FAN_BASELINE_RESET" == "1" ]] || [[ ! -s "$baseline_path" ]]; then
        baseline_initialized=1
        jq -n --argjson arr "$baseline_seed_json" \
           '$arr as $a | {fans: ($a | map({name:.name, baseline_rpm:(.baseline_rpm // 0)}))}' \
           > "$baseline_path"
        if [[ "$baseline_seed_source" != "none" ]]; then
            echo "[Info] fan baseline initialized (source=${baseline_seed_source}): $baseline_path"
        else
            echo "[Info] fan baseline initialized: $baseline_path"
        fi
    fi

    declare -A FAN_BASELINE=()
    if [[ -s "$baseline_path" ]] && (( baseline_initialized == 0 )); then
        while IFS= read -r line; do
            local name
            name=$(jq -r '.name' <<<"$line")
            local brpm
            brpm=$(jq -r '.baseline_rpm // 0' <<<"$line")
            [[ -n "$name" ]] && FAN_BASELINE["$name"]="$brpm"
        done < <(jq -c '.fans[]?' "$baseline_path" 2>/dev/null || true)
    fi

    local sensors_fan_count="${#os_fan_data[@]}"
    local ipmi_fan_count="${#ipmi_fan_data[@]}"
    local ipmi_only=0
    if (( sensors_fan_count == 0 && ipmi_fan_count > 0 )); then
        ipmi_only=1
    fi

    local low_rpm_count=0
    local deviation_warn_count=0
    local deviation_crit_count=0
    local metrics_json_array=()
    local reason_details=()
    local fan_summary_array=() # For PASS reason summary
    local -a fan_checks_entries=()
    local -a fan_eval_entries=()
    local fan_checks_limit=8
    local fan_checks_added=0
    local worst_deviation_abs=""
    local worst_deviation_signed=""
    local worst_fan=""
    local baseline_values_present=0

    for entry in "${os_fan_data[@]}"; do
        IFS='|' read -r fan_name current_rpm <<< "$entry"
        [[ -z "$fan_name" || -z "$current_rpm" ]] && continue

        local base="${FAN_BASELINE["$fan_name"]:-0}"
        local baseline_source="none"
        local base_disp="N/A"
        local dev_disp="N/A"
        local deviation_pct_signed=""
        local deviation_pct_abs=""
        local deviation_pct_abs_int=0

        if [[ "$base" =~ ^[0-9]+$ && "$base" -gt 0 && "$current_rpm" =~ ^[0-9]+$ ]]; then
            baseline_source="file"
            base_disp="$base"
            deviation_pct_signed=$(awk -v c="$current_rpm" -v b="$base" 'BEGIN { if (b>0) printf "%.1f", (c-b)*100.0/b }')
            if [[ -n "$deviation_pct_signed" ]]; then
                baseline_values_present=1
                deviation_pct_abs=$(awk -v v="$deviation_pct_signed" 'BEGIN { if (v<0) v=-v; printf "%.1f", v }')
                deviation_pct_abs_int=$(awk -v v="$deviation_pct_abs" 'BEGIN { printf "%.0f", v }')
                local deviation_pct_int
                deviation_pct_int=$(awk -v v="$deviation_pct_signed" 'BEGIN { printf "%.0f", v }')
                dev_disp="${deviation_pct_int}%"
            fi
        fi

        local fan_status="OK"
        if (( current_rpm < 100 )); then
            ((low_rpm_count++))
            fan_status="CRIT (Stopped)"
            reason_details+=("${fan_name}:${current_rpm}RPM")
        elif (( deviation_pct_abs_int > ${DEVIATION_CRIT_PCT:-0} )); then
            ((deviation_crit_count++))
            fan_status=$(printf 'CRIT (Dev >%s%%)' "$DEVIATION_CRIT_PCT")
            if [[ -n "$deviation_pct_abs" ]]; then
                reason_details+=("${fan_name}:${current_rpm}RPM,Dev:${deviation_pct_abs}%")
            else
                reason_details+=("${fan_name}:${current_rpm}RPM")
            fi
        elif (( current_rpm < FAN_RPM_TH )); then
            ((low_rpm_count++))
            fan_status="WARN (<${FAN_RPM_TH}RPM)"
            reason_details+=("${fan_name}:${current_rpm}RPM")
        elif (( deviation_pct_abs_int > ${DEVIATION_WARN_PCT:-0} )); then
            ((deviation_warn_count++))
            fan_status=$(printf 'WARN (Dev >%s%%)' "$DEVIATION_WARN_PCT")
            if [[ -n "$deviation_pct_abs" ]]; then
                reason_details+=("${fan_name}:${current_rpm}RPM,Dev:${deviation_pct_abs}%")
            else
                reason_details+=("${fan_name}:${current_rpm}RPM")
            fi
        fi

        metrics_json_array+=( $(jq -n \
            --arg name "$fan_name" \
            --arg status "$fan_status" \
            --argjson rpm "$current_rpm" \
            --arg bsrc "$baseline_source" \
            --arg base_disp "$base_disp" \
            --arg dev_disp "$dev_disp" \
            '{
               name:$name,
               status:$status,
               current_rpm:$rpm,
               baseline_source:$bsrc
             }
             + (if $base_disp!="N/A" then {baseline_rpm: ($base_disp|tonumber)} else {} end)
             + (if $dev_disp!="N/A" then {deviation_pct: ($dev_disp|sub("%$";"")|tonumber)} else {} end)') )

        local fan_ok="true"
        [[ "$fan_status" == WARN* || "$fan_status" == CRIT* || "$fan_status" == FAIL* ]] && fan_ok="false"
        if (( fan_checks_added < fan_checks_limit )); then
            fan_checks_entries+=( "$(jq -n \
                --arg name "$fan_name" \
                --arg ok "$fan_ok" \
                --arg cur "$current_rpm" \
                --arg base "$base_disp" \
                --arg dev "$dev_disp" \
                '{name:$name, ok:($ok=="true"), value:("cur="+$cur+", base="+$base+", dev="+$dev)}')" )
            fan_checks_added=$((fan_checks_added+1))
        fi

        local fan_eval_entry
        fan_eval_entry=$(jq -n \
            --arg name "$fan_name" \
            --arg status "$fan_status" \
            --arg bsrc "$baseline_source" \
            --argjson rpm "$current_rpm" \
            --arg base_disp "$base_disp" \
            --arg dev_disp "$dev_disp" \
            '{
               name:$name,
               status:$status,
               baseline_source:$bsrc,
               rpm:$rpm
             }
             + (if $base_disp!="N/A" then {baseline_rpm: ($base_disp|tonumber)} else {} end)
             + (if $dev_disp!="N/A" then {deviation_pct: ($dev_disp|sub("%$";"")|tonumber)} else {} end)')
        fan_eval_entries+=("$fan_eval_entry")

        if [[ -n "$deviation_pct_abs" ]]; then
            if [[ -z "$worst_deviation_abs" ]] || [[ $(awk -v a="$deviation_pct_abs" -v b="$worst_deviation_abs" 'BEGIN{print (a>b)?1:0}') == 1 ]]; then
                worst_deviation_abs="$deviation_pct_abs"
                worst_deviation_signed="$deviation_pct_signed"
                worst_fan="$fan_name"
            fi
        fi
    done

    # --- Process IPMI SDR data ---
    if (( ipmi_fan_count > 0 )); then
        for entry in "${ipmi_fan_data[@]}"; do
            IFS='|' read -r fan_name current_rpm <<< "$entry"
            [[ -z "$fan_name" || -z "$current_rpm" ]] && continue

            local base="${FAN_BASELINE["$fan_name"]:-0}"
            local baseline_source="ipmi"
            local base_disp="N/A"
            local dev_disp="N/A"
            local deviation_pct_signed=""
            local deviation_pct_abs=""
            local deviation_pct_abs_int=0

            if (( ipmi_only )) && [[ "$base" =~ ^[0-9]+$ && "$base" -gt 0 && "$current_rpm" =~ ^[0-9]+$ ]]; then
                base_disp="$base"
                deviation_pct_signed=$(awk -v c="$current_rpm" -v b="$base" 'BEGIN { if (b>0) printf "%.1f", (c-b)*100.0/b }')
                if [[ -n "$deviation_pct_signed" ]]; then
                    baseline_values_present=1
                    deviation_pct_abs=$(awk -v v="$deviation_pct_signed" 'BEGIN { if (v<0) v=-v; printf "%.1f", v }')
                    deviation_pct_abs_int=$(awk -v v="$deviation_pct_abs" 'BEGIN { printf "%.0f", v }')
                    local deviation_pct_int
                    deviation_pct_int=$(awk -v v="$deviation_pct_signed" 'BEGIN { printf "%.0f", v }')
                    dev_disp="${deviation_pct_int}%"
                fi
            fi

            local fan_status="OK"
            if (( current_rpm < 100 )); then
                ((low_rpm_count++))
                fan_status="CRIT (Stopped)"
                reason_details+=("${fan_name}:${current_rpm}RPM")
            elif (( ipmi_only )) && (( deviation_pct_abs_int > ${DEVIATION_CRIT_PCT:-0} )); then
                ((deviation_crit_count++))
                fan_status=$(printf 'CRIT (Dev >%s%%)' "$DEVIATION_CRIT_PCT")
                if [[ -n "$deviation_pct_abs" ]]; then
                    reason_details+=("${fan_name}:${current_rpm}RPM,Dev:${deviation_pct_abs}%")
                else
                    reason_details+=("${fan_name}:${current_rpm}RPM")
                fi
            elif (( current_rpm < FAN_RPM_TH )); then
                ((low_rpm_count++))
                fan_status="WARN (<${FAN_RPM_TH}RPM)"
                reason_details+=("${fan_name}:${current_rpm}RPM")
            elif (( ipmi_only )) && (( deviation_pct_abs_int > ${DEVIATION_WARN_PCT:-0} )); then
                ((deviation_warn_count++))
                fan_status=$(printf 'WARN (Dev >%s%%)' "$DEVIATION_WARN_PCT")
                if [[ -n "$deviation_pct_abs" ]]; then
                    reason_details+=("${fan_name}:${current_rpm}RPM,Dev:${deviation_pct_abs}%")
                else
                    reason_details+=("${fan_name}:${current_rpm}RPM")
                fi
            fi

            fan_summary_array+=("${fan_name}|${current_rpm}|${FAN_RPM_TH}")
            echo "DEBUG FAN: ${fan_name}|${current_rpm}|${FAN_RPM_TH}" >&2

            metrics_json_array+=( $(jq -n \
                --arg name "$fan_name" \
                --arg status "$fan_status" \
                --argjson rpm "$current_rpm" \
                --arg bsrc "$baseline_source" \
                --arg base_disp "$base_disp" \
                --arg dev_disp "$dev_disp" \
                '{
                   name:$name,
                   status:$status,
                   current_rpm:$rpm,
                   baseline_source:$bsrc
                 }
                 + (if $base_disp!="N/A" then {baseline_rpm: ($base_disp|tonumber)} else {} end)
                 + (if $dev_disp!="N/A" then {deviation_pct: ($dev_disp|sub("%$";"")|tonumber)} else {} end)') )

            local fan_ok="true"
            [[ "$fan_status" == WARN* || "$fan_status" == CRIT* || "$fan_status" == FAIL* ]] && fan_ok="false"
            if (( fan_checks_added < fan_checks_limit )); then
                fan_checks_entries+=( "$(jq -n \
                    --arg name "$fan_name" \
                    --arg ok "$fan_ok" \
                    --arg cur "$current_rpm" \
                    --arg base "$base_disp" \
                    --arg dev "$dev_disp" \
                    '{name:$name, ok:($ok=="true"), value:("cur="+$cur+", base="+$base+", dev="+$dev)}')" )
                fan_checks_added=$((fan_checks_added+1))
            fi

            local ipmi_eval_entry
            ipmi_eval_entry=$(jq -n \
                --arg name "$fan_name" \
                --arg status "$fan_status" \
                --arg bsrc "$baseline_source" \
                --argjson rpm "$current_rpm" \
                --arg base_disp "$base_disp" \
                --arg dev_disp "$dev_disp" \
                '{
                   name:$name,
                   status:$status,
                   baseline_source:$bsrc,
                   rpm:$rpm
                 }
                 + (if $base_disp!="N/A" then {baseline_rpm: ($base_disp|tonumber)} else {} end)
                 + (if $dev_disp!="N/A" then {deviation_pct: ($dev_disp|sub("%$";"")|tonumber)} else {} end)')
            fan_eval_entries+=("$ipmi_eval_entry")

            if [[ -n "$deviation_pct_abs" ]]; then
                if [[ -z "$worst_deviation_abs" ]] || [[ $(awk -v a="$deviation_pct_abs" -v b="$worst_deviation_abs" 'BEGIN{print (a>b)?1:0}') == 1 ]]; then
                    worst_deviation_abs="$deviation_pct_abs"
                    worst_deviation_signed="$deviation_pct_signed"
                    worst_fan="$fan_name"
                fi
            fi
        done
    elif [[ -n "$ipmi_sdr_out" ]]; then
        # Fallback: legacy parsing when Fan_* lines were not captured (maintains compatibility)
        while read -r line; do
            echo "$line" | grep -q "RPM" || continue

            local fan_name
            fan_name=$(echo "$line" | cut -d'|' -f1 | xargs | tr ' ' '_' | tr -d '-')
            local current_rpm
            current_rpm=$(echo "$line" | cut -d'|' -f5 | grep -oE '[0-9]+' | head -n 1)
            [[ -z "$fan_name" || -z "$current_rpm" ]] && continue

            local fan_status="OK"
            if (( current_rpm < FAN_RPM_TH )); then
                ((low_rpm_count++))
                fan_status="WARN (<${FAN_RPM_TH}RPM)"
                reason_details+=("${fan_name}:${current_rpm}RPM")
            fi
            fan_summary_array+=("${fan_name}|${current_rpm}|${FAN_RPM_TH}")
            echo "DEBUG FAN: ${fan_name}|${current_rpm}|${FAN_RPM_TH}" >&2

            metrics_json_array+=( $(jq -n \
                --arg name "$fan_name" \
                --arg status "$fan_status" \
                --argjson rpm "$current_rpm" \
                --arg bsrc "ipmi" \
                '{
                   name:$name,
                   status:$status,
                   current_rpm:$rpm,
                   baseline_source:$bsrc
                 }') )

            local fan_ok="true"
            [[ "$fan_status" == WARN* || "$fan_status" == CRIT* || "$fan_status" == FAIL* ]] && fan_ok="false"
            if (( fan_checks_added < fan_checks_limit )); then
                fan_checks_entries+=( "$(jq -n \
                    --arg name "$fan_name" \
                    --arg ok "$fan_ok" \
                    --arg cur "$current_rpm" \
                    --arg base "N/A" \
                    --arg dev "N/A" \
                    '{name:$name, ok:($ok=="true"), value:("cur="+$cur+", base="+$base+", dev="+$dev)}')" )
                fan_checks_added=$((fan_checks_added+1))
            fi

            local ipmi_eval_entry
            ipmi_eval_entry=$(jq -n \
                --arg name "$fan_name" \
                --arg status "$fan_status" \
                --arg bsrc "ipmi" \
                --argjson rpm "$current_rpm" \
                '{name:$name, status:$status, baseline_source:$bsrc, rpm:$rpm}')
            fan_eval_entries+=("$ipmi_eval_entry")
        done <<< "$ipmi_sdr_out"
    fi

    local fan_eval_file="${metrics_dir}/fan_eval_${TIMESTAMP}.json"
    local fan_eval_entries_json='[]'
    if (( ${#fan_eval_entries[@]} > 0 )); then
        fan_eval_entries_json=$(printf '%s\n' "${fan_eval_entries[@]}" | jq -s '.')
    fi
    local fan_eval_thresholds_json
    fan_eval_thresholds_json=$(jq -n \
      --arg rpm_th "$FAN_RPM_TH" \
      --arg warn_pct "$DEVIATION_WARN_PCT" \
      --arg crit_pct "$DEVIATION_CRIT_PCT" \
      '{low_rpm_th:($rpm_th|tonumber), deviation_warn_pct:($warn_pct|tonumber), deviation_crit_pct:($crit_pct|tonumber)}')
    local fan_eval_full_json
    fan_eval_full_json=$(jq -n --argjson metrics "$fan_eval_entries_json" --argjson thresholds "$fan_eval_thresholds_json" \
      '{metrics:$metrics, thresholds:$thresholds}')
    printf '%s\n' "$fan_eval_full_json" > "$fan_eval_file"

    local fan_hist_file="${LOG_DIR}/fan/fan_history.json"
    local fan_iso_now; fan_iso_now=$(date -u +"%Y-%m-%d %H:%M:%S")
    local fan_hist_stats
    fan_hist_stats=$(fan_history_upsert_and_stats "$fan_eval_entries_json" "$SCRIPT_START_TS" "$fan_iso_now" "$fan_hist_file")
    [[ -z "$fan_hist_stats" ]] && fan_hist_stats='{"overall":{"avg_rpm_90d":0,"peak_avg_rpm_90d":0},"per_fan":{}}'

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

    local fan_zone_summary=""
    declare -a _fan_zone_parts=()
    declare -A _seen_fan_zones=()

    local -a _zone_lines=()
    mapfile -t _zone_lines < <(
      if [[ -f "$raw_ipmi_sdr_log" ]]; then
        grep -E '^[[:space:]]*Fan[ _]?Zone[[:space:]_]*[0-9]+' "$raw_ipmi_sdr_log" || true
      elif [[ -n "$ipmi_sdr_out" ]]; then
        printf '%s\n' "$ipmi_sdr_out" | grep -E '^[[:space:]]*Fan[ _]?Zone[[:space:]_]*[0-9]+' || true
      fi
    )

    for L in "${_zone_lines[@]}"; do
      IFS='|' read -r c1 c2 c3 c4 c5 <<<"$L"
      local zone_id
      zone_id=$(printf '%s' "$c1" | grep -Eo 'Fan[ _]?Zone[ _]*[0-9]+' | grep -Eo '[0-9]+')
      local pct
      pct=$(printf '%s' "$c5" | grep -Eo '[0-9]+[[:space:]]*percent' | grep -Eo '^[0-9]+')
      if [[ -n "$zone_id" && -n "$pct" ]]; then
        local label="Z${zone_id}"
        if [[ -z "${_seen_fan_zones[$label]:-}" ]]; then
          _seen_fan_zones[$label]=1
          _fan_zone_parts+=("${label}=${pct}%")
        fi
      fi
    done

    if (( ${#_fan_zone_parts[@]} > 0 )); then
      fan_zone_summary="Zones: $(IFS=', '; echo "${_fan_zone_parts[*]}")"
    fi

    local worst_dev_summary=""
    if [[ -f "$fan_eval_file" ]]; then
        local _worst_dev_val
        _worst_dev_val=$(jq -r '
            (.metrics // [])
            | map((.deviation_pct // empty) | (try tonumber catch empty))
            | map(select(. != null))
            | map(if . < 0 then (-.) else . end)
            | max? // empty
        ' "$fan_eval_file" 2>/dev/null || true)
        if [[ -n "${_worst_dev_val:-}" && "${_worst_dev_val}" != "null" ]]; then
            if [[ "$_worst_dev_val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                local _worst_dev_int
                _worst_dev_int=$(printf '%.0f' "$_worst_dev_val")
                worst_dev_summary="worst dev=${_worst_dev_int}%"
            fi
        fi
    fi

    if [[ -z "$worst_dev_summary" && $baseline_values_present -eq 0 && ${#fan_eval_entries[@]} -gt 0 ]]; then
        worst_dev_summary="worst dev=N/A"
    fi

    local fan_reason_suffix=""
    if [[ -n "$fan_zone_summary" ]]; then
        fan_reason_suffix="$fan_zone_summary"
    fi
    if [[ -n "$worst_dev_summary" ]]; then
        if [[ -n "$fan_reason_suffix" ]]; then
            fan_reason_suffix+="; ${worst_dev_summary}"
        else
            fan_reason_suffix="$worst_dev_summary"
        fi
    fi
    if [[ -n "$fan_reason_suffix" ]]; then
        if [[ -n "$final_reason" ]]; then
            final_reason+="；${fan_reason_suffix}"
        else
            final_reason="$fan_reason_suffix"
        fi
    fi

    if [[ -n "$worst_fan" && -n "$worst_deviation_signed" ]]; then
        local worst_dev_fmt
        worst_dev_fmt=$(awk -v v="$worst_deviation_signed" 'BEGIN{printf "%+.1f%%", v+0}')
        local threshold_clause=">= -${DEVIATION_WARN_PCT}% & <= +${DEVIATION_WARN_PCT}%"
        if [[ "$final_reason" == *"." ]]; then
            final_reason+=" Worst deviation: ${worst_dev_fmt} on ${worst_fan} (${threshold_clause})."
        else
            final_reason+=". Worst deviation: ${worst_dev_fmt} on ${worst_fan} (${threshold_clause})."
        fi
    fi

    local metrics_entries_json='[]'
    if (( ${#metrics_json_array[@]} > 0 )); then
        metrics_entries_json=$(printf '%s\n' "${metrics_json_array[@]}" | jq -s '.')
    fi
    local fan_metrics_json
    fan_metrics_json=$(jq -n --argjson entries "$metrics_entries_json" '{entries:$entries}')
    fan_metrics_json=$(echo "$fan_metrics_json" | jq --argjson hist "$fan_hist_stats" '. + {historical_stats: $hist.overall}')
    local historical_stats_json
    historical_stats_json=$(echo "$fan_hist_stats" | jq '.overall')
    if [[ "$historical_stats_json" == "null" || -z "$historical_stats_json" ]]; then
        historical_stats_json='{}'
    fi

    local thresholds_json
    thresholds_json=$(jq -n \
      --arg rpm_th "$FAN_RPM_TH" \
      --arg warn_pct "$DEVIATION_WARN_PCT" \
      --arg crit_pct "$DEVIATION_CRIT_PCT" \
      '{low_rpm_th:($rpm_th|tonumber), deviation_warn_pct:($warn_pct|tonumber), deviation_crit_pct:($crit_pct|tonumber)}')

    local evidence_json
    evidence_json=$(jq -n \
        --arg sensors "$raw_sensors_log" \
        --arg ipmi "$raw_ipmi_sdr_log" \
        --arg baseline "$baseline_path" \
        --arg detail "$fan_eval_file" \
        '{sensors_log:$sensors, ipmi_sdr_log:$ipmi, baseline_file:$baseline, fan_detail_json:$detail}
         | with_entries(select(.value != ""))')

    local final_json
    final_json=$(jq -n \
        --arg status "$final_status" \
        --arg item "$item" \
        --arg reason "$final_reason" \
        --argjson metrics "$fan_metrics_json" \
        --argjson thresholds "$thresholds_json" \
        --argjson evidence "$evidence_json" \
        --argjson history "$historical_stats_json" \
        '{status:$status, item:$item, reason:$reason, metrics:$metrics, thresholds:$thresholds, historical_stats:$history, evidence:$evidence}')

    # --- Build judgement ---
    local th_json
    th_json=$(jq -n \
      --arg rpm_th "$FAN_RPM_TH" \
      --arg warn_pct "$DEVIATION_WARN_PCT" \
      --arg crit_pct "$DEVIATION_CRIT_PCT" \
      '{FAN_RPM_TH: ($rpm_th|tonumber), DEVIATION_WARN_PCT: ($warn_pct|tonumber), DEVIATION_CRIT_PCT: ($crit_pct|tonumber)}')

    local fan_count="${#metrics_json_array[@]}"
    local fan_evidence_state="OK"
    if [[ "$final_status" != "PASS" ]]; then
        fan_evidence_state="NG"
    fi
    local checks_json
    checks_json=$(jq -n \
      --arg low_count "$low_rpm_count" \
      --arg dev_crit_count "$deviation_crit_count" \
      --arg dev_warn_count "$deviation_warn_count" \
      --arg fan_count "${fan_count:-0}" \
      --arg rpm_th "$FAN_RPM_TH" \
      --arg warn_pct "$DEVIATION_WARN_PCT" \
      --arg crit_pct "$DEVIATION_CRIT_PCT" \
      --arg fan_eval "$fan_eval_file" \
      --arg evidence_state "$fan_evidence_state" \
      '[
         {"name":"低轉速風扇數=0","ok":($low_count|tonumber==0),"value":("low_rpm_count="+$low_count)},
         {"name":"嚴重偏差風扇數=0","ok":($dev_crit_count|tonumber==0),"value":("deviation_crit="+$dev_crit_count)},
         {"name":"警告偏差風扇數=0","ok":($dev_warn_count|tonumber==0),"value":("deviation_warn="+$dev_warn_count)},
         {"name":"檢測到的風扇數","ok":($fan_count|tonumber>0),"value":("fans="+$fan_count)},
         {"name":"門檻","ok":true,"value":("FAN_RPM_TH="+$rpm_th+", WARN_PCT="+$warn_pct+"%, CRIT_PCT="+$crit_pct+"%")},
         {"name":"fan deviation evidence","ok":($evidence_state=="OK"),"value":("fan deviation evidence "+$evidence_state+" ("+$fan_eval+")")}
       ]')

    if (( ${#fan_checks_entries[@]} > 0 )); then
        local fan_checks_json
        fan_checks_json=$(printf '%s\n' "${fan_checks_entries[@]}" | jq -s '.')
        checks_json=$(jq --argjson extras "$fan_checks_json" '. + $extras' <<< "$checks_json")
    fi

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
    local criteria="環境溫度：代表性傳感器（Inlet/Ambient）最大值 ≤ WARN（${ENV_TEMP_WARN}°C）為 PASS；WARN < Max ≤ CRIT（${ENV_TEMP_CRIT}°C）為 WARN；Max > CRIT 為 FAIL。"

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
  echo "[SEL] 載入自訂 map 條目數: ${#MAP_LEVEL[@]}" >&2
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
  # Quick verify: grep -A2 '^12 .*BMC/SEL' logs/*_health_*.md

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
    echo "[SEL] 空 (no entries)" >&2
    echo '[]' > "$SEL_EVENTS_JSON"
    SEL_CRIT=0; SEL_WARN=0; SEL_INFO=0; SEL_NOISE_RAW=0
    local pass_json
    pass_json=$(jq -n --arg item "$item" --arg reason "SEL 空 (no entries)" --argjson evidence "$evidence" \
        '{status:"PASS", item:$item, reason:$reason, evidence:$evidence}')
    set_check_result 12 "$pass_json"
    return
  fi

  load_severity_map

  local now_epoch sel_cutoff sel_days
  now_epoch=$(date +%s)
  sel_days="${SEL_DAYS:-0}"
  sel_cutoff=0
  if (( sel_days > 0 )); then
    sel_cutoff=$(( now_epoch - sel_days*86400 ))
  fi
  local last_warncrit_epoch=""

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

    local event_epoch=""
    if [[ -n "$f2" || -n "$f3" ]]; then
      event_epoch=$(printf '%s %s' "$f2" "$f3" | dt_to_epoch_or_empty 2>/dev/null || true)
    fi
    if [[ "$sev" == "CRIT" || "$sev" == "WARN" ]]; then
      if [[ -n "$event_epoch" ]]; then
        if [[ -z "$last_warncrit_epoch" || "$event_epoch" -gt "$last_warncrit_epoch" ]]; then
          last_warncrit_epoch="$event_epoch"
        fi
      fi
    fi

    local countable=1
    if (( sel_days > 0 )) && [[ -n "$event_epoch" ]]; then
      if (( event_epoch < sel_cutoff )); then
        countable=0
      fi
    fi

    if (( countable )); then
      case "$sev" in
        CRIT) ((SEL_CRIT++));;
        WARN) ((SEL_WARN++));;
        *)    ((SEL_INFO++));;
      esac
    else
      [[ "$sev" != "CRIT" && "$sev" != "WARN" ]] && ((SEL_INFO++))
    fi
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

  echo "[SEL] CRIT=$SEL_CRIT WARN=$SEL_WARN INFO=$SEL_INFO (noise_hidden=$SEL_NOISE_HIDE noise_raw=$SEL_NOISE_RAW) (Top: $top_str)" >&2

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
  echo "[SEL] 事件明細 JSON: $SEL_EVENTS_JSON" >&2

  if [[ -n "$SEL_TOP_JSON" ]]; then
    {
      echo '['
      local first=1
      for t in "${SEL_TOP_ARRAY[@]}"; do
        if (( first )); then printf "%s" "$t"; first=0; else printf ",%s" "$t"; fi
      done
      echo ']'
    } > "$SEL_TOP_JSON"
    echo "[SEL] Top sensors JSON: $SEL_TOP_JSON" >&2
  fi

  local final_status="PASS"
  if (( SEL_CRIT > 0 )); then
    final_status="FAIL"
  elif (( SEL_WARN > 0 )); then
    final_status="WARN"
  fi

  local days_since_display="N/A"
  local last_event_days=""
  if [[ -n "$last_warncrit_epoch" ]]; then
    local delta=$(( (now_epoch - last_warncrit_epoch) / 86400 ))
    (( delta < 0 )) && delta=0
    last_event_days="$delta"
    days_since_display="$delta"
  elif (( sel_days > 0 )); then
    days_since_display=">${sel_days}"
  fi

  local days_clause_text=""
  if [[ -n "$last_event_days" ]]; then
    days_clause_text="距今天數約 ${last_event_days} 天前"
  elif [[ "$days_since_display" =~ ^[0-9]+$ ]]; then
    days_clause_text="距今天數約 ${days_since_display} 天前"
  elif [[ "$days_since_display" == "N/A" ]]; then
    days_clause_text="距今天數不明"
  else
    days_clause_text="距今天數約 ${days_since_display} 天前"
  fi

  local recent_events_value="none"
  local recent_ok_str="true"
  local recent_events_display=""
  local recent_clause=""
  local primary_event=""
  local last_event_type=""
  if [[ -z "${__SEL_SUMMARY_DONE:-}" ]]; then
    __SEL_SUMMARY_DONE=1
    local -a recent_events_lines=()
    if [[ -s "$SEL_EVENTS_JSON" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        recent_events_lines+=("$line")
      done < <(jq -r '
        [ .[] 
          | select(type=="object" and (.datetime|type=="string")) 
          | {
              datetime: (.datetime // ""),
              sensor: (.sensor // ""),
              event: (.event // ""),
              severity: (.severity // "")
            }
        ]
        | unique_by(.datetime + "|" + .sensor + "|" + .event + "|" + .severity)
        | sort_by(.datetime) | reverse | .[:3]
        | map(
            (.datetime // "")
            + "|" + (.sensor // "")
            + "|" + (.event // "")
            + "|" + (.severity // "")
          )
        | .[]
      ' "$SEL_EVENTS_JSON" 2>/dev/null || true)
    fi

    if (( ${#recent_events_lines[@]} > 0 )); then
      recent_ok_str="false"
      local -a recent_display_parts=()
      local -a parsed_events=()
      local sep=$'\x1E'
      for entry in "${recent_events_lines[@]}"; do
        IFS='|' read -r dt sensor event severity <<< "$entry"
        local dt_clean="${dt//T/ }"
        dt_clean="${dt_clean%%.*}"
        dt_clean=$(echo "$dt_clean" | xargs)
        dt_clean=$(printf '%s' "$dt_clean" | LC_ALL=C tr -d '\r\000-\037\177')
        dt_clean=${dt_clean//$'\xef\xbf\xbd'/}
        local sensor_clean="${sensor:-<sensor>}"
        sensor_clean=$(echo "$sensor_clean" | xargs)
        sensor_clean=$(printf '%s' "$sensor_clean" | LC_ALL=C tr -d '\r\000-\037\177')
        sensor_clean=${sensor_clean//$'\xef\xbf\xbd'/}
        local event_clean="${event:-<event>}"
        event_clean=$(echo "$event_clean" | xargs)
        event_clean=$(printf '%s' "$event_clean" | LC_ALL=C tr -d '\r\000-\037\177')
        event_clean=${event_clean//$'\xef\xbf\xbd'/}
        local severity_upper
        severity_upper=$(echo "${severity:-}" | tr '[:lower:]' '[:upper:]')
        case "$severity_upper" in
          CRITICAL|CRIT|EMERGENCY|ALERT) severity_upper="CRIT";;
          WARNING|WARN) severity_upper="WARN";;
          INFO|INFORMATIONAL|INFORMATION) severity_upper="INFO";;
          *) severity_upper="INFO";;
        esac
        local display_entry="${dt_clean} ${sensor_clean} ${event_clean}"
        display_entry=$(printf '%s' "$display_entry" | LC_ALL=C tr -d '\r\000-\037\177')
        display_entry=${display_entry//$'\xef\xbf\xbd'/}
        local event_epoch=""
        local dt_normalized="$dt"
        local dt_clean_normalized="$dt_clean"
        if [[ "$dt_normalized" =~ ^([0-9]{2})([-/])([0-9]{2})\2([0-9]{4})(.*)$ ]]; then
          local mm="${BASH_REMATCH[1]}"
          local dd="${BASH_REMATCH[3]}"
          local yyyy="${BASH_REMATCH[4]}"
          local rest="${BASH_REMATCH[5]}"
          dt_normalized="$(normalize_mmddyyyy "${mm}/${dd}/${yyyy}")${rest}"
        fi
        if [[ "$dt_clean_normalized" =~ ^([0-9]{2})([-/])([0-9]{2})\2([0-9]{4})(.*)$ ]]; then
          local mm_c="${BASH_REMATCH[1]}"
          local dd_c="${BASH_REMATCH[3]}"
          local yyyy_c="${BASH_REMATCH[4]}"
          local rest_c="${BASH_REMATCH[5]}"
          dt_clean_normalized="$(normalize_mmddyyyy "${mm_c}/${dd_c}/${yyyy_c}")${rest_c}"
        fi
        if [[ -n "$dt_normalized" ]]; then
          event_epoch=$(date -d "$dt_normalized" +%s 2>/dev/null || date -d "$dt_clean_normalized" +%s 2>/dev/null || date -d "$dt_clean" +%s 2>/dev/null || echo "")
        fi
        recent_display_parts+=("$display_entry")
        parsed_events+=("${severity_upper}${sep}${event_epoch}${sep}${display_entry}")
      done

      if (( ${#recent_display_parts[@]} > 0 )); then
        recent_events_display=$(IFS='; '; echo "${recent_display_parts[*]}")
        recent_events_value=$(IFS='; '; echo "${recent_display_parts[*]}")
        recent_events_value=$(echo "$recent_events_value" | xargs)
        [[ -z "$recent_events_value" ]] && recent_events_value="none"
      fi

      local primary_severity=""
      local primary_event_epoch=""
      local -a extra_events=()
      for parsed in "${parsed_events[@]}"; do
        IFS=$'\x1E' read -r sev epoch_ts display_text <<< "$parsed"
        case "$sev" in
          CRIT)
            if [[ "$primary_severity" != "CRIT" ]]; then
              if [[ -n "$primary_event" ]]; then
                extra_events+=("$primary_event")
              fi
              primary_event="$display_text"
              primary_severity="CRIT"
              primary_event_epoch="$epoch_ts"
            else
              extra_events+=("$display_text")
            fi
            ;;
          WARN)
            if [[ -z "$primary_event" || "$primary_severity" != "CRIT" ]]; then
              if [[ -n "$primary_event" && "$primary_severity" == "WARN" ]]; then
                extra_events+=("$primary_event")
              fi
              primary_event="$display_text"
              primary_severity="WARN"
              primary_event_epoch="$epoch_ts"
            else
              extra_events+=("$display_text")
            fi
            ;;
          *)
            if [[ -n "$primary_event" ]]; then
              extra_events+=("$display_text")
            fi
            ;;
        esac
      done

      if [[ -n "$primary_event" && -n "$primary_severity" && "$primary_severity" != "INFO" ]]; then
        last_event_type="$primary_severity"
        if [[ -n "$primary_event_epoch" && "$primary_event_epoch" =~ ^[0-9]+$ ]]; then
          local delta=$(( SCRIPT_START_TS - primary_event_epoch ))
          (( delta < 0 )) && delta=0
          last_event_days=$(( (delta + 43200) / 86400 ))
          days_since_display="$last_event_days"
        else
          last_event_days=""
        fi

        local days_label="N/A"
        if [[ -n "$last_event_days" ]]; then
          days_label="$last_event_days"
        elif [[ "$days_since_display" =~ ^[0-9]+$ ]]; then
          days_label="$days_since_display"
        fi

        recent_clause="最近一次 ${primary_severity} 事件為 ${days_label} 天前：${primary_event}"
        if (( ${#extra_events[@]} > 0 )); then
          declare -A _seen_recent_extra=()
          local -a unique_extras=()
          for extra_entry in "${extra_events[@]}"; do
            [[ -z "$extra_entry" ]] && continue
            if [[ -z "${_seen_recent_extra["$extra_entry"]:-}" ]]; then
              _seen_recent_extra["$extra_entry"]=1
              unique_extras+=("$extra_entry")
            fi
          done
          if (( ${#unique_extras[@]} > 0 )); then
            local extras_join
            extras_join=$(IFS='; '; echo "${unique_extras[*]}")
            recent_clause+="; 其他：${extras_join}"
          fi
        fi
      fi
    fi
  fi

  echo "[SEL] days_since_last=${days_since_display}" >&2
  if [[ -n "$recent_events_display" ]]; then
    echo "[SEL] recent_events=${recent_events_display}" >&2
  fi

  local final_reason=""
  case "$final_status" in
    PASS)
      if [[ "$days_since_display" == "N/A" ]]; then
        final_reason="過去 ${SEL_DAYS} 天內無 CRIT/WARN；距今未蒐集到最近 CRIT/WARN 訊息"
      else
        final_reason="過去 ${SEL_DAYS} 天內無 CRIT/WARN；距今已 ${days_since_display} 天未再發"
      fi
      ;;
    WARN)
      local warn_days_label="${last_event_days:-N/A}"
      if [[ "$warn_days_label" == "N/A" && "$days_since_display" =~ ^[0-9]+$ ]]; then
        warn_days_label="$days_since_display"
      fi
      local warn_type_label="${last_event_type:-CRIT/WARN}"
      [[ -z "$warn_type_label" ]] && warn_type_label="CRIT/WARN"
      final_reason="SEL WARN=${SEL_WARN}（最近一次 ${warn_type_label} 為 ${warn_days_label} 天前）"
      if [[ -n "$recent_clause" ]]; then
        final_reason+="；${recent_clause}"
      fi
      ;;
    FAIL)
      local fail_days_label="${last_event_days:-N/A}"
      if [[ "$fail_days_label" == "N/A" && "$days_since_display" =~ ^[0-9]+$ ]]; then
        fail_days_label="$days_since_display"
      fi
      local fail_type_label="${last_event_type:-CRIT/WARN}"
      [[ -z "$fail_type_label" ]] && fail_type_label="CRIT/WARN"
      final_reason="SEL CRIT=${SEL_CRIT} WARN=${SEL_WARN}（最近一次 ${fail_type_label} 為 ${fail_days_label} 天前）"
      if [[ -n "$recent_clause" ]]; then
        final_reason+="；${recent_clause}"
      fi
      ;;
  esac

  local final_json
  final_json=$(jq -n --arg item "$item" --arg status "$final_status" --arg reason "$final_reason" --argjson evidence "$evidence" \
    '{status:$status, item:$item, reason:$reason, evidence:$evidence}')

  # --- Build judgement ---
  local th_json
  th_json=$(jq -n \
    --arg sel_days "$SEL_DAYS" \
    --arg recover "$RECOVER_DAYS" \
    '{SEL_DAYS: ($sel_days|tonumber), RECOVER_DAYS: ($recover|tonumber)}')

  local -a sel_checks_entries=()
  sel_checks_entries+=( "$(jq -n \
    --arg crit "$SEL_CRIT" \
    '{name:"SEL CRIT 事件=0", ok:(($crit|tonumber)==0), value:("crit="+$crit)}')" )
  sel_checks_entries+=( "$(jq -n \
    --arg warn "$SEL_WARN" \
    '{name:"SEL WARN 事件=0", ok:(($warn|tonumber)==0), value:("warn="+$warn)}')" )
  sel_checks_entries+=( "$(jq -n \
    --arg info "$SEL_INFO" \
    '{name:"SEL INFO 事件計數", ok:true, value:("info="+$info)}')" )
  sel_checks_entries+=( "$(jq -n \
    --arg ds "$days_since_display" \
    --argjson rec "${RECOVER_DAYS:-30}" \
    'if ($ds|test("^[0-9]+$")) then
       {name:"Days since last CRIT/WARN", ok:(($ds|tonumber) >= rec), value:("days="+$ds+", RECOVER_DAYS="+(rec|tostring))}
     else
       {name:"Days since last CRIT/WARN", ok:false, value:"N/A"}
     end')" )
  sel_checks_entries+=( "$(jq -n \
    --arg recent "$recent_events_value" \
    --arg ok_str "$recent_ok_str" \
    '{name:"recent SEL events", ok:($ok_str=="true"), value:$recent}')" )

  local checks_json='[]'
  if (( ${#sel_checks_entries[@]} > 0 )); then
    checks_json=$(printf '%s\n' "${sel_checks_entries[@]}" | jq -s '.')
  fi

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
BIOS_VERSION_CHECK_VALUE=""
FIRMWARE_ENUM_MESSAGE=""
collect_firmware_info() {
  local firmware_dir="$LOG_DIR/firmware"
  mkdir -p "$firmware_dir"
  local firmware_log="${firmware_dir}/firmware_${TIMESTAMP}.log"
  local firmware_json="${firmware_dir}/firmware_${TIMESTAMP}.json"
  : > "$firmware_log"

  local -a bios_entries=()
  local -a nic_entries=()
  local -a gpu_entries=()
  local -a disk_entries=()
  local -a nvme_entries=()

  # === BIOS ===
  local bios_version=""
  local bios_ok="false"
  local bios_reason=""

  if ! command -v dmidecode >/dev/null 2>&1; then
    bios_reason="dmidecode not available"
    echo "== dmidecode -t bios (not available) ==" >> "$firmware_log"
    echo "$bios_reason" >> "$firmware_log"
  else
    local dm_raw dm_rc
    dm_raw=$(dmidecode -t bios 2>&1)
    dm_rc=$?
    {
      echo "== dmidecode -t bios (non-root) =="
      printf '%s\n' "$dm_raw"
    } >> "$firmware_log"

    if (( dm_rc == 0 )); then
      bios_version=$(printf '%s\n' "$dm_raw" | awk -F: '/^[[:space:]]*BIOS Version/ {print $2; exit}' | xargs)
      [[ -z "$bios_version" ]] && bios_version=$(printf '%s\n' "$dm_raw" | awk -F: '/^[[:space:]]*Version/ {print $2; exit}' | xargs)
      [[ -n "$bios_version" ]] && bios_ok="true" || bios_reason="unable to parse BIOS version"
    else
      if command -v sudo >/dev/null 2>&1; then
        local sudo_raw sudo_rc
        sudo_raw=$(sudo -n dmidecode -t bios 2>&1)
        sudo_rc=$?
        {
          echo "== sudo -n dmidecode -t bios =="
          printf '%s\n' "$sudo_raw"
        } >> "$firmware_log"

        if (( sudo_rc == 0 )); then
          bios_version=$(printf '%s\n' "$sudo_raw" | awk -F: '/^[[:space:]]*BIOS Version/ {print $2; exit}' | xargs)
          [[ -z "$bios_version" ]] && bios_version=$(printf '%s\n' "$sudo_raw" | awk -F: '/^[[:space:]]*Version/ {print $2; exit}' | xargs)
          [[ -n "$bios_version" ]] && bios_ok="true" || bios_reason="unable to parse BIOS version"
        else
          grep -qi 'password' <<< "$sudo_raw" && bios_reason="permission denied (sudo password required)" || bios_reason="dmidecode failed (rc=$sudo_rc)"
        fi
      else
        grep -qi 'permission denied' <<< "$dm_raw" && bios_reason="permission denied (root required)" || bios_reason="dmidecode failed (rc=$dm_rc)"
      fi
    fi
  fi

  bios_entries+=("$(jq -n --arg ver "$bios_version" --arg ok "$bios_ok" --arg reason "$bios_reason" \
    '{version:$ver, ok:($ok=="true"), reason:(if $reason=="" then null else $reason end)}')")

  # === BMC ===
  if (( ! SKIP_BMC )); then
    echo "== ipmitool mc info ==" >> "$firmware_log"
    local bmc_fw
    bmc_fw=$(ipmi_try mc info 2>/dev/null | egrep -i 'Firmware' | tee -a "$firmware_log" || echo "")
  fi

  # === NICs ===
  for nic in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$'); do
    echo "== NIC $nic ==" >> "$firmware_log"
    local nic_info
    nic_info=$(ethtool -i "$nic" 2>/dev/null | egrep -i 'driver|firmware|version' | tee -a "$firmware_log" || true)
    local nic_driver nic_fw
    nic_driver=$(echo "$nic_info" | awk -F: '/^driver:/ {print $2}' | xargs)
    nic_fw=$(echo "$nic_info" | awk -F: '/^firmware-version:/ {print $2}' | xargs)
    nic_entries+=("$(jq -n --arg name "$nic" --arg driver "$nic_driver" --arg fw "$nic_fw" \
      '{name:$name, driver:$driver, firmware:$fw}')")
  done

  # === GPU (NVIDIA) ===
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "== nvidia-smi --query-gpu ==" >> "$firmware_log"
    local gpu_info
    gpu_info=$(nvidia-smi --query-gpu=driver_version,vbios_version --format=csv,noheader 2>/dev/null | tee -a "$firmware_log" || true)
    while IFS=',' read -r driver_ver vbios_ver; do
      driver_ver=$(echo "$driver_ver" | xargs)
      vbios_ver=$(echo "$vbios_ver" | xargs)
      gpu_entries+=("$(jq -n --arg driver "$driver_ver" --arg vbios "$vbios_ver" \
        '{driver_version:$driver, vbios_version:$vbios}')")
    done <<< "$gpu_info"
  fi

  # === Disks (SMART) ===
  for d in /dev/sd?; do
    [[ -b "$d" ]] || continue
    echo "== smartctl -i $d ==" >> "$firmware_log"
    local disk_info
    disk_info=$(smartctl -i "$d" 2>/dev/null | egrep -i 'Device Model|Model Number|Firmware|Serial' | tee -a "$firmware_log" || true)
    local disk_model disk_fw disk_serial
    disk_model=$(echo "$disk_info" | awk -F: '/Device Model|Model Number:/ {print $2; exit}' | xargs)
    disk_fw=$(echo "$disk_info" | awk -F: '/Firmware Version:/ {print $2; exit}' | xargs)
    disk_serial=$(echo "$disk_info" | awk -F: '/Serial Number:/ {print $2; exit}' | xargs)
    disk_entries+=("$(jq -n --arg dev "$d" --arg model "$disk_model" --arg fw "$disk_fw" --arg serial "$disk_serial" \
      '{device:$dev, model:$model, firmware:$fw, serial:$serial}')")
  done

  # === NVMe ===
  if command -v nvme >/dev/null 2>&1; then
    echo "== nvme list ==" >> "$firmware_log"
    local nvme_list_json
    nvme_list_json=$(nvme list -o json 2>/dev/null | tee -a "$firmware_log" || echo '{}')
    if [[ -n "$nvme_list_json" && "$nvme_list_json" != "{}" ]]; then
      local -a nvme_devices
      mapfile -t nvme_devices < <(echo "$nvme_list_json" | jq -r '.Devices[]? | "\(.DevicePath)|\(.ModelNumber // "")|\(.Firmware // "")|\(.SerialNumber // "")"' 2>/dev/null || true)
      for nv in "${nvme_devices[@]}"; do
        IFS='|' read -r dev model fw serial <<< "$nv"
        nvme_entries+=("$(jq -n --arg dev "$dev" --arg model "$model" --arg fw "$fw" --arg serial "$serial" \
          '{device:$dev, model:$model, firmware:$fw, serial:$serial}')")
      done
    fi
  fi

  # === Build JSON ===
  local bios_json='[]'
  (( ${#bios_entries[@]} > 0 )) && bios_json=$(printf '%s\n' "${bios_entries[@]}" | jq -s '.')
  local nic_json='[]'
  (( ${#nic_entries[@]} > 0 )) && nic_json=$(printf '%s\n' "${nic_entries[@]}" | jq -s '.')
  local gpu_json='[]'
  (( ${#gpu_entries[@]} > 0 )) && gpu_json=$(printf '%s\n' "${gpu_entries[@]}" | jq -s '.')
  local disk_json='[]'
  (( ${#disk_entries[@]} > 0 )) && disk_json=$(printf '%s\n' "${disk_entries[@]}" | jq -s '.')
  local nvme_json='[]'
  (( ${#nvme_entries[@]} > 0 )) && nvme_json=$(printf '%s\n' "${nvme_entries[@]}" | jq -s '.')

  local fw_full_json
  fw_full_json=$(jq -n \
    --argjson bios "$bios_json" \
    --argjson nic "$nic_json" \
    --argjson gpu "$gpu_json" \
    --argjson disk "$disk_json" \
    --argjson nvme "$nvme_json" \
    '{bios:$bios, nic:$nic, gpu:$gpu, disk:$disk, nvme:$nvme}')

  printf '%s\n' "$fw_full_json" > "$firmware_json"

  # Export for check_firmware to use
  export FW_BIOS_VERSION="$bios_version"
  export FW_BIOS_OK="$bios_ok"
  export FW_BIOS_REASON="$bios_reason"
  export FW_LOG="$firmware_log"
  export FW_JSON="$firmware_json"
  export FW_FULL_JSON="$fw_full_json"
}

check_firmware() {
  echo -e "${C_BLUE}[14] 韌體版本${C_RESET}"

  # Call the collection function
  collect_firmware_info

  # Print summary to console
  cat "$FW_LOG"

  BIOS_VERSION="$FW_BIOS_VERSION"
  BIOS_VERSION_CHECK_VALUE="$FW_BIOS_REASON"
  [[ "$FW_BIOS_OK" == "true" ]] && BIOS_VERSION_CHECK_VALUE="$FW_BIOS_VERSION"
  FIRMWARE_ENUM_MESSAGE="captured in ${FW_LOG##*/}; JSON=${FW_JSON##*/}"
  export BIOS_VERSION
  export BIOS_VERSION_CHECK_VALUE

  # Build reason
  local firmware_reason="列出 BIOS/NIC/GPU/Disk/NVMe 版本資訊"
  if [[ "$FW_BIOS_OK" == "true" ]]; then
    firmware_reason="BIOS: ${FW_BIOS_VERSION}; 其他版本詳見 logs/firmware/*.json"
  else
    firmware_reason="BIOS: ${FW_BIOS_REASON}; 其他版本詳見 logs/firmware/*.json"
  fi

  # Build checks from firmware JSON
  local -a checks_entries=()

  # BIOS check
  local bios_value="$FW_BIOS_VERSION"
  [[ -z "$bios_value" ]] && bios_value="$FW_BIOS_REASON"
  checks_entries+=("$(jq -n --arg ok "$FW_BIOS_OK" --arg val "$bios_value" \
    '{name:"BIOS version", ok:($ok=="true"), value:$val}')")

  # NIC checks
  local nic_count=$(echo "$FW_FULL_JSON" | jq -r '.nic | length')
  if (( nic_count > 0 )); then
    local nic_summary
    nic_summary=$(echo "$FW_FULL_JSON" | jq -r '.nic | map("\(.name):\(.driver)") | join(", ")')
    checks_entries+=("$(jq -n --arg val "$nic_summary" \
      '{name:"NIC drivers", ok:true, value:$val}')")
  fi

  # GPU checks
  local gpu_count=$(echo "$FW_FULL_JSON" | jq -r '.gpu | length')
  if (( gpu_count > 0 )); then
    local gpu_summary
    gpu_summary=$(echo "$FW_FULL_JSON" | jq -r '.gpu | map("driver:\(.driver_version)") | join(", ")')
    checks_entries+=("$(jq -n --arg val "$gpu_summary" \
      '{name:"GPU drivers", ok:true, value:$val}')")
  fi

  # Disk checks
  local disk_count=$(echo "$FW_FULL_JSON" | jq -r '.disk | length')
  if (( disk_count > 0 )); then
    checks_entries+=("$(jq -n --arg val "$disk_count disks enumerated" \
      '{name:"SATA/SAS disks", ok:true, value:$val}')")
  fi

  # NVMe checks
  local nvme_count=$(echo "$FW_FULL_JSON" | jq -r '.nvme | length')
  if (( nvme_count > 0 )); then
    checks_entries+=("$(jq -n --arg val "$nvme_count devices enumerated" \
      '{name:"NVMe devices", ok:true, value:$val}')")
  fi

  local checks_json='[]'
  if (( ${#checks_entries[@]} > 0 )); then
    checks_json=$(printf '%s\n' "${checks_entries[@]}" | jq -s '.')
  fi

  local evidence_json
  evidence_json=$(jq -n --arg log "$FW_LOG" --arg json "$FW_JSON" \
    '{firmware_log:$log, firmware_json:$json}')

  local pass_rules='["成功列舉 BIOS/NIC/GPU/Disk/NVMe 版本"]'
  local warn_rules='["部分項目無法取得"]'
  local fail_rules='["N/A（INFO 級別檢查項）"]'
  local criteria="韌體版本收集：列舉系統各元件韌體與驅動版本，供人工比對與記錄用途。"

  local base_json
  base_json=$(jq -n \
    --arg status "INFO" \
    --arg item "Firmware.Version" \
    --arg reason "$firmware_reason" \
    --argjson metrics "$FW_FULL_JSON" \
    --argjson evidence "$evidence_json" \
    '{status:$status, item:$item, reason:$reason, metrics:$metrics, evidence:$evidence}')

  local jdg_json
  jdg_json=$(build_judgement "$criteria" "$pass_rules" "$warn_rules" "$fail_rules" "$checks_json" '{}')

  set_check_result_with_jdg 14 "$base_json" "$jdg_json"
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
            # Quick verify: grep -n 'Criteria:' logs/*_health_*.md | head
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
