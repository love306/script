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

# Thresholds from server_health_full.sh (v2.2-consolidated)
CPU_TEMP_WARN=80
CPU_TEMP_CRIT=90
FAN_RPM_TH=300
NET_IPERF_MIN=100   # Mbps
IO_READ_MIN=300     # MB/s
IO_WRITE_MIN=200    # MB/s
SINCE_DAYS=90
RECOVER_DAYS=30

# --- Helper Functions ---

ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1;
    then
    echo "Error: command not found: $1. Please install it to run this script." >&2
    exit 1
  fi
}

to_mbps() {
  local val="$1" unit="$2"
  case "$unit" in
    G|g) awk -v v="$val" 'BEGIN{printf "%.1f", v*1000}' ;;
    M|m) awk -v v="$val" 'BEGIN{printf "%.1f", v}' ;;
    K|k) awk -v v="$val" 'BEGIN{printf "%.3f", v/1000}' ;;
    *) echo "0.0" ;;
  esac
}

# --- Reason & Suggestion Generation ---

get_item_sel_regex() {
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

sel_is_noise() {
  local line_lower="$1"
  case "$line_lower" in
    *"pef action"*|*"drive present"*|*"power button pressed"*|*"001c4c"*) 
      return 0 # Success (true for an if statement)
      ;; 
    *) 
      return 1 # Failure (false for an if statement)
      ;; 
  esac
}

get_last_sel_event_epoch() {
  local sel_log="$1" since_days="$2" regex="$3"
  if [ -z "$sel_log" ] || [ ! -f "$sel_log" ] || [ -z "$regex" ]; then
      echo ""
      return
  fi

  local now_epoch; now_epoch=$(date +%s)
  local cutoff_epoch=$(( now_epoch - since_days * 86400 ))
  local last_epoch=0

  # OPTIMIZATION: Pre-filter the log file with a single grep pipeline.
  # This is orders of magnitude faster than a shell `while read` loop.
  local candidate_lines
  candidate_lines=$(grep -E "$regex" "$sel_log" | grep -vEi 'Deasserted|pef action|drive present|power button pressed|001c4c')

  # Now, loop over the much smaller set of candidate lines.
  while IFS= read -r line; do
    if ! (echo "$line" | grep -q "|"); then continue; fi

    local date_str; date_str=$(echo "$line" | cut -d'|' -f2-3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    local event_epoch; event_epoch=$(date -d "$date_str" +%s 2>/dev/null || echo "")
    
    if [ -z "$event_epoch" ] || [ "$event_epoch" -lt "$cutoff_epoch" ]; then
        continue
    fi

    if [ "$event_epoch" -gt "$last_epoch" ]; then
        last_epoch=$event_epoch
    fi
  done <<< "$candidate_lines"

  if [ "$last_epoch" -gt 0 ]; then
      echo "$last_epoch"
  fi
}

get_rich_pass_reason() {
    local item_id="$1" log_file="$2" json_reason="$3"

    case "$item_id" in
        1) # PSU
            echo "Chassis Status 正常，SEL 無 PSU 相關嚴重事件 → PASS"
            ;; 
        2) # Disks/RAID/SMART
            local raid_summary; raid_summary=$(echo "$json_reason" | sed -e 's/RAID_ctrl=//' -e 's/ rebuild_ops=0//' -e 's/;/; /g')
            echo "所有 VD 狀態為 Optimal，PD 無 predictive failure 或 rebuild；SMART 健康。($raid_summary) → PASS"
            ;; 
        4) # CPU
            local max_temp; max_temp=$(grep -E 'Core [0-9]+' "$log_file" | grep -Eo '\+[0-9]+\.[0-9]' | tr -d '+' | sort -rn | head -n1 || echo "")
            if [ -n "$max_temp" ]; then
                echo "最高核心溫度 ${max_temp}°C < 門檻 (warn=${CPU_TEMP_WARN}, crit=${CPU_TEMP_CRIT})，無 thermal throttle 事件 → PASS"
            else
                echo "CPU 溫度正常，無 thermal throttle 事件 → PASS"
            fi
            ;; 
        5) # NIC
            if grep -q "異常計數:" "$log_file"; then
                 echo "$json_reason" # Should be WARN, but as a fallback
            else
                 echo "與 baseline 相比，rx_dropped/tx_errors 等計數器無增量 → PASS"
            fi
            ;; 
        7) # Fans
            local min_rpm; min_rpm=$(grep 'RPM' "$log_file" | grep -Eo '[0-9]+ RPM' | awk '{print $1}' | sort -n | head -n1 || echo "")
            if [ -n "$min_rpm" ]; then
                echo "所有風扇 RPM (最低 ${min_rpm}) > 門檻 ${FAN_RPM_TH} RPM → PASS"
            else
                echo "所有風扇轉速均高於門檻 ${FAN_RPM_TH} RPM → PASS"
            fi
            ;; 
        10) # Network Reach/Perf
            local iperf_line; iperf_line=$(grep -E 'bits/sec.*receiver' "$log_file" | tail -n1 || true)
            if [ -n "$iperf_line" ]; then
                local bw unit iperf_mbps
                bw=$(echo "$iperf_line" | grep -Eo '([0-9]+(\.[0-9]+)?) *[KMG]bits/sec' | awk '{print $1}')
                unit=$(echo "$iperf_line" | grep -Eo '[KMG]bits/sec' | head -c 1)
                iperf_mbps=$(to_mbps "$bw" "$unit")
                echo "ping 成功, iperf 實測 ${iperf_mbps} Mbps ≥ 門檻 ${NET_IPERF_MIN} Mbps → PASS"
            else
                echo "ping 成功，網路連通性正常 → PASS"
            fi
            ;; 
        11) # Cabling
            local uplinks; uplinks=$(grep "Uplinks OK:" "$log_file" | sed 's/.*Uplinks OK: //' || echo "狀態正常")
            echo "Uplink 介面狀態正常 (${uplinks}) → PASS"
            ;; 
        12) # BMC/SEL
            echo "最近 ${SINCE_DAYS} 天內 SEL 無新增嚴重事件 (已過濾噪音與 Deasserted) → PASS"
            ;; 
        15) # I/O Perf
            local r_line w_line r_mbs w_mbs
            r_line=$(grep -E '^[[:space:]]*READ: bw=' "$log_file" | tail -n1 || true)
            w_line=$(grep -E '^[[:space:]]*WRITE: bw=' "$log_file" | tail -n1 || true)
            if [ -n "$r_line" ] && [ -n "$w_line" ]; then
                r_mbs=$(echo "$r_line" | grep -Eo '\([0-9]+MB/s\)' | tr -d '()MB/s')
                w_mbs=$(echo "$w_line" | grep -Eo '\([0-9]+MB/s\)' | tr -d '()MB/s')
                if [ -n "$r_mbs" ] && [ -n "$w_mbs" ]; then
                    echo "fio read=${r_mbs}MB/s ≥ ${IO_READ_MIN}MB/s, write=${w_mbs}MB/s ≥ ${IO_WRITE_MIN}MB/s → PASS"
                else
                    echo "I/O 效能測試通過 (無法解析詳細數值) → PASS"
                fi
            else
                echo "I/O 效能測試通過 → PASS"
            fi
            ;; 
        *) # Default
            echo "$json_reason → PASS"
            ;; 
    esac
}

get_suggestions() {
  local item_id="$1"
  case "$item_id" in
    1) cat <<TIPS
ipmitool -I lanplus -H <bmc_ip> -U <user> -E sel list | grep -Ei 'psu|power|volt'
ipmitool -I lanplus -H <bmc_ip> -U <user> -E sdr elist | grep -Ei 'Power|PSU|Volt'
TIPS
    ;; 
    2) cat <<TIPS
/opt/MegaRAID/storcli/storcli64 show all | less
sudo smartctl -H -A /dev/sdX  # Replace sdX with the correct device
TIPS
    ;; 
    3) cat <<TIPS
sudo dmesg | grep -Ei 'mce|edac|ecc'
sudo journalctl -k | grep -Ei 'mce|edac|ecc'
TIPS
    ;; 
    4) cat <<TIPS
sensors | grep -Ei 'cpu|core|temp'
sudo journalctl -k | grep -Ei 'thermal|throttle'
TIPS
    ;; 
    5) cat <<TIPS
ip -s link show
ethtool -S <iface> | egrep 'err|drop|crc' # Replace <iface>
TIPS
    ;; 
    7) cat <<TIPS
sensors | grep -Ei 'fan'
ipmitool -I lanplus -H <bmc_ip> -U <user> -E sdr elist | grep -i fan
TIPS
    ;; 
    10) cat <<TIPS
ping -c 5 <ping_host>
iperf3 -c <iperf_target> -t 10
TIPS
    ;; 
    11) cat <<TIPS
ethtool <iface> | egrep 'Speed|Duplex|Link detected' # Replace <iface>
sudo dmesg | grep -i 'link down' | tail
TIPS
    ;; 
    12) cat <<TIPS
ipmitool -I lanplus -H <bmc_ip> -U <user> -E sel elist
ipmitool -I lanplus -H <bmc_ip> -U <user> -E sensor
TIPS
    ;; 
    13) cat <<TIPS
sudo journalctl -p 3 -xb --since "1 day ago"
sudo dmesg -T | tail -n 200
TIPS
    ;; 
    15) cat <<TIPS
iostat -x 1 5
sudo fio --filename=/tmp/fio.bin --name=read --rw=read --bs=1M --size=1G --direct=1 --group_reporting
TIPS
    ;; 
    *) echo "No specific commands for this item." ;; 
  esac
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

# For dynamic UPS sub-items
declare -a UPS_SUB_ITEMS=()
declare -A UPS_SUB_STATUSES
declare -A UPS_SUB_REASONS
declare -A UPS_SUB_ICONS
UPS_REPORT_HOST_IDX=-1


ITEM_NAMES=(
  "" "1 PSU" "2 Disks/RAID/SMART" "3 Memory/ECC" "4 CPU" "5 NIC"
  "6 GPU" "7 Fans" "8 Env" "9 UPS" "10 Network Reach/Perf"
  "11 Cabling" "12 BMC/SEL" "13 System Logs" "14 Firmware" "15 I/O Perf"
)

# Pre-scan for UPS sub-items from reports
echo "---" >&2
echo "Pre-scanning ${N_HOSTS} report(s) for UPS sub-items..." >&2
declare UPS_SUB_ITEMS_STRING="|" # Use a separator for portable existence check
for i in $(seq 0 $((N_HOSTS - 1))); do
  json_file="${JSON_FILES[$i]}"
  if [ ! -f "$json_file" ]; then continue; fi

  # Check if this JSON has our special UPS object structure
  if jq -e '.ups.ups | (type == "array" and length > 0)' "$json_file" >/dev/null 2>&1; then
    UPS_REPORT_HOST_IDX=$i # Assume only one host provides this
    
    # Read UPS names (sub-items)
    while IFS= read -r ups_name; do
        # Use a simple string and grep to check for existence for portability
        if ! echo "$UPS_SUB_ITEMS_STRING" | grep -q "|${ups_name}|"; then
            UPS_SUB_ITEMS+=("$ups_name")
            UPS_SUB_ITEMS_STRING+="${ups_name}|"
        fi
    done < <(jq -r '.ups.ups[].id | sub("\\(.*\\)"; "")' "$json_file")
  fi
done
if ((${#UPS_SUB_ITEMS[@]} > 0)); then
    echo "Found UPS sub-items: ${UPS_SUB_ITEMS[*]}" >&2
fi
echo "---" >&2


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

  # Get log file paths from the JSON itself for accuracy
  json_dir=$(dirname "$json_file")
  
  log_filename=""
  log_filepath_from_json=$(jq -r '.files.log_txt // ""' "$json_file")
  if [ -n "$log_filepath_from_json" ]; then
      log_filename=$(basename "$log_filepath_from_json")
  fi

  sel_events_filename=""
  sel_events_filepath_from_json=$(jq -r '.sel.events_file // ""' "$json_file")
  if [ -n "$sel_events_filepath_from_json" ]; then
      sel_events_filename=$(basename "$sel_events_filepath_from_json")
  fi

  log_file=""
  if [ -n "$log_filename" ]; then
      log_file="${json_dir}/${log_filename}"
  fi

  sel_log_file=""
  if [ -n "$sel_events_filename" ]; then
      # The sel_detail log has the same base name as the sel_events json
      sel_log_basename="${sel_events_filename%_sel_events.json}"
      sel_log_file="${json_dir}/${sel_log_basename}_sel_detail.log"
  fi

  for item_id in $(seq 1 15); do
    key="$item_id,$i"
    item_json=$(jq -e ".items[] | select(.id == $item_id)" "$json_file")

    if [ -z "$item_json" ]; then
      STATUSES[$key]="N/A"; REASONS[$key]="No data in JSON"; ICONS[$key]="⚪️"; SUGGESTIONS[$key]=""
      continue
    fi

    status=$(echo "$item_json" | jq -r '.status')
    reason_from_json=$(echo "$item_json" | jq -r '.reason // ""')
    STATUSES[$key]=$status

    case "$status" in
      PASS) ICONS[$key]="🟢";;
      WARN) ICONS[$key]="🟡";;
      FAIL) ICONS[$key]="🔴";;
      SKIP) ICONS[$key]="⚪️";;
      *) ICONS[$key]="🔵";;
    esac

    if [ "$status" = "PASS" ] && [ -f "$log_file" ]; then
      rich_reason=$(get_rich_pass_reason "$item_id" "$log_file" "$reason_from_json")
      
      sel_regex=$(get_item_sel_regex "$item_id")
      if [ -n "$sel_regex" ] && [ -f "$sel_log_file" ]; then
        last_event=$(get_last_sel_event_epoch "$sel_log_file" "$SINCE_DAYS" "$sel_regex")
        if [ -n "$last_event" ]; then
            recovery_cutoff=$(( $(date +%s) - RECOVER_DAYS * 86400 ))
            if [ "$last_event" -lt "$recovery_cutoff" ]; then
                rich_reason+=" (可能已恢復)"
            fi
        fi
      fi
      REASONS[$key]=$rich_reason
      SUGGESTIONS[$key]=""
    else
      REASONS[$key]="$reason_from_json"
      if [ "$status" = "WARN" ] || [ "$status" = "FAIL" ]; then
        SUGGESTIONS[$key]=$(get_suggestions "$item_id")
      else
        SUGGESTIONS[$key]=""
      fi
    fi
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
  if [[ $item_id -eq 9 && ${#UPS_SUB_ITEMS[@]} -gt 0 ]]; then
    # Loop through discovered UPS sub-items
    for sub_idx in $(seq 0 $((${#UPS_SUB_ITEMS[@]} - 1))); do
      ups_name="${UPS_SUB_ITEMS[$sub_idx]}"
      printf "| 9.%d %-20s |" "$((sub_idx + 1))" "$ups_name"
      
      for host_idx in $(seq 0 $((N_HOSTS - 1))); do
        if (( host_idx == UPS_REPORT_HOST_IDX )); then
          sub_key="$ups_name,$host_idx"
          printf " %s |" "${UPS_SUB_ICONS[$sub_key]:-⚪️}"
        else
          # Other hosts don't have this sub-item, so they skip it.
          printf " %s |" "⚪️"
        fi
      done
      echo
    done
  else
    # Standard item handling
    printf "| %-24s |" "${ITEM_NAMES[$item_id]}"
    for host_idx in $(seq 0 $((N_HOSTS - 1))); do
      printf " %s |" "${ICONS["$item_id,$host_idx"]:-'?'}"
    done
    echo
  fi
done

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

    # If it's item 9 AND it's the UPS host, add sub-item details
    if [[ $item_id -eq 9 && $host_idx -eq $UPS_REPORT_HOST_IDX && ${#UPS_SUB_ITEMS[@]} -gt 0 ]]; then
        for sub_idx in $(seq 0 $((${#UPS_SUB_ITEMS[@]} - 1))); do
            ups_name="${UPS_SUB_ITEMS[$sub_idx]}"
            sub_key="$ups_name,$host_idx"
            sub_status="${UPS_SUB_STATUSES[$sub_key]:-N/A}"
            sub_reason="${UPS_SUB_REASONS[$sub_key]:-No details}"
            sub_icon="${UPS_SUB_ICONS[$sub_key]:-⚪️}"
            sub_label_detail="詳細理由"
            if [ "${UPS_SUB_STATUSES[$sub_key]:-PASS}" = "PASS" ]; then sub_label_detail="判斷依據"; fi
            
            echo "    * ${sub_icon} **9.$((sub_idx + 1)) ${ups_name} — ${sub_status}**"
echo "        *   **${sub_label_detail}**: ${sub_reason}"
        done
    fi

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
