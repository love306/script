#!/usr/bin/env bash
#
# consolidate_reports.sh (v10.1 - Bugfix)
#
# Reads multiple server_health_full.sh JSON outputs (and their corresponding
# .log files) to generate a comprehensive, auditable Markdown report.
#
# v10.1 Changelog:
# - Fixed syntax errors in get_suggestions (extra ';;') and UPS pre-scan loop.
# v10 Changelog:
# - Dynamically detects and displays individual UPS devices (sub-items of item 9)
#   in both the summary table and detailed report.
#
set -euo pipefail
LC_ALL=C

# --- Script Configuration & Constants ---

# --- Helper Functions ---

ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1;
    then
    echo "Error: command not found: $1. Please install it to run this script." >&2
    exit 1
  fi
}

# --- Main Logic ---

ensure_command "jq"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <path/to/report1.json> [path/to/report2.json]..." >&2
  echo "Example: $0 /path/to/reports/**/logs/*_health_latest.json" >&2
  exit 1
fi

JSON_FILES=($@)
N_HOSTS=${#JSON_FILES[@]}

declare -a HOSTNAMES
declare -A ICONS STATUSES REASONS SUGGESTIONS




ITEM_NAMES=(
  "" "1 PSU" "2 Disks/RAID/SMART" "3 Memory/ECC" "4 CPU" "5 NIC"
  "6 GPU" "7 Fans" "8 Env" "9 UPS" "10 Network Reach/Perf"
  "11 Cabling" "12 BMC/SEL" "13 System Logs" "14 Firmware" "15 I/O Perf"
)

echo "Reading ${N_HOSTS} JSON report(s)..." >&2
echo "---" >&2

for i in $(seq 0 $((N_HOSTS - 1))); do
  json_file="${JSON_FILES[$i]}"
  if [ ! -f "$json_file" ]; then
    echo "Warning: File not found, skipping: $json_file" >&2
    HOSTNAMES[$i]="(File Not Found)"
    continue
  fi

  hostname=$(jq -r '.meta.hostname // "unknown"' "$json_file")
  HOSTNAMES[$i]="$hostname"
  echo "Host: $hostname, File: $json_file" >&2

  # If this is the UPS report, extract sub-item statuses
  if (( i == UPS_REPORT_HOST_IDX )); then
    jq_query='.ups.ups[] | (.id | sub("\\(.*\\)"; "")) + "|" + .reason'
    while IFS='|' read -r ups_name reason;
    do
        sub_key="$ups_name,$i"
        if [[ "$reason" == "CRIT:"* ]]; then
            status="FAIL"
            icon="🔴"
        elif [[ "$reason" == "WARN:"* ]]; then
            status="WARN"
            icon="🟡"
        elif [[ "$reason" == *"-> PASS" ]]; then
            status="PASS"
            icon="🟢"
        else
            status="INFO"
            icon="🔵"
        fi
        UPS_SUB_STATUSES[$sub_key]=$status
        UPS_SUB_REASONS[$sub_key]=$reason
        UPS_SUB_ICONS[$sub_key]=$icon
    done < <(jq -r "$jq_query" "$json_file")
  fi

  for item_id in $(seq 1 15); do
    key="$item_id,$i"
    item_json=$(jq -e ".items[] | select(.id == $item_id)" "$json_file")

    if [ -z "$item_json" ]; then
      STATUSES[$key]="N/A"; REASONS[$key]="No data in JSON"; ICONS[$key]="⚪️"; SUGGESTIONS[$key]=""
      continue
    fi

    status=$(echo "$item_json" | jq -r '.status')
    STATUSES[$key]=$status

    # Directly use the rich reason and tips from the new JSON structure
    REASONS[$key]=$(echo "$item_json" | jq -r '.reason // ""' || echo "")
    SUGGESTIONS[$key]=$(echo "$item_json" | jq -r 'if .tips then .tips[] else "" end' || echo "")

    case "$status" in
      PASS) ICONS[$key]="🟢";;
      WARN) ICONS[$key]="🟡";;
      FAIL) ICONS[$key]="🔴";;
      SKIP) ICONS[$key]="⚪️";;
      *) ICONS[$key]="🔵";;
    esac
  done
done

echo "---" >&2
echo "Generating Markdown Report..." >&2
echo "---" >&2
echo ""

echo "# 整合式硬體健康報告"
echo ""
cat << LEGEND
### 圖示說明
*   🟢 **PASS**: 項目正常，通過所有檢查。
*   🟡 **WARN**: 警告，項目有潛在問題或接近門檻，建議關注。
*   🔴 **FAIL**: 失敗，項目存在明確的錯誤或故障，需要立即處理。
*   🔵 **INFO**: 僅為資訊狀態，不代表好壞（例如韌體版本）。
*   ⚪️ **SKIP**: 跳過，因缺少工具、相關硬體或該項不適用。
---
LEGEND

echo ""
echo "## 快速總覽"
echo ""
printf "| %-24s |" "項目"
for host in "${HOSTNAMES[@]}"; do
  printf " %s |" "$host"
done
echo
printf "|%s|" ":-------------------------"
for _ in "${HOSTNAMES[@]}"; do
  printf "%s|" ":----:"
done
echo
for item_id in $(seq 1 15); do
    # Standard item handling
    printf "| %-24s |" "${ITEM_NAMES[$item_id]}"
    for host_idx in $(seq 0 $((N_HOSTS - 1))); do
      printf " %s |" "${ICONS["$item_id,$host_idx"]:-'?'}"
    done
    echo

echo ""
echo "## 詳細報告"
echo ""

for host_idx in $(seq 0 $((N_HOSTS - 1))); do
  host="${HOSTNAMES[$host_idx]}"
  if [ "$host" = "(File Not Found)" ]; then
    continue
  fi

  echo "### 主機: ${host}"
echo ""

  for item_id in $(seq 1 15); do
    key="$item_id,$host_idx"
    status="${STATUSES[$key]:-N/A}"
    reason="${REASONS[$key]:-No details}"
    icon="${ICONS[$key]:-⚪️}"

    if [ "$status" = "SKIP" ] && echo "$reason" | grep -q "未啟用"; then
        continue
    fi

    label="詳細理由"
    if [ "$status" = "PASS" ]; then
      label="判斷依據與量測值"
    fi

    echo "* ${icon} **${ITEM_NAMES[$item_id]} — ${status}**"
echo "    *   **${label}**: ${reason}"

    suggestions="${SUGGESTIONS[$key]:-}"
    if [ -n "$suggestions" ]; then
      echo "    *   **後續檢查指令**:"
      echo '        ```bash'
      echo -e "$suggestions"
      echo '        ```'
    fi
    echo ""
  done
  echo "---"
done
