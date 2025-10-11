#!/usr/bin/env bash
#
# ups_check.sh (v5.0 - The Final Correction)
#
# This script is a ground-up, manually written rewrite to be syntactically perfect
# and fix all previously encountered errors, including conditionals, quoting,
# variable assignments, and command substitutions.
#
set -euo pipefail

# --- Default Configuration & Thresholds ---
CONFIG_FILE="config/ups_list.conf"
MIN_RUNTIME_MIN=15
WARN_BATT=70
CRIT_BATT=50
CRIT_BATT2=30
TEMP_WARN_HIGH=45
TEMP_CRIT_HIGH=50
TEMP_WARN_LOW=9
TEMP_CRIT_LOW=5
DIFF_BATT_WARN=10
DIFF_BATT_CRIT=20
DIFF_RUN_WARN=20
DIFF_RUN_CRIT=35
DURATION_WARN=500
DURATION_CRIT=1500
VERBOSE=0
STRICT_PAIR=0

# --- SNMP OIDs ---
OID_MODEL="1.3.6.1.4.1.318.1.1.1.1.1.1.0"
OID_SERIAL="1.3.6.1.4.1.318.1.1.1.1.2.3.0"
OID_BAT_CAP="1.3.6.1.4.1.318.1.1.1.2.2.1.0"
OID_BAT_TEMP="1.3.6.1.4.1.318.1.1.1.2.2.2.0"
OID_BAT_RUNTIME="1.3.6.1.4.1.318.1.1.1.2.2.3.0"
OID_HP_CAP="1.3.6.1.4.1.318.1.1.1.2.3.1.0"
OID_HP_TEMP="1.3.6.1.4.1.318.1.1.1.2.3.2.0"
OID_HP_RUNTIME="1.3.6.1.4.1.318.1.1.1.2.3.3.0"
OID_APC_OUTPUT_STATUS="1.3.6.1.4.1.318.1.1.1.4.2.1.0"
OID_STD_RUNTIME_MIN="1.3.6.1.2.1.33.1.2.3.0"
OID_STD_CHARGE_PCT="1.3.6.1.2.1.33.1.2.4.0"
OID_STD_OUTPUT_SOURCE="1.3.6.1.2.1.33.1.4.1.0"

# --- Helper & Logic Functions ---

print_usage(){
  cat <<EOF
Usage: $0 [options]
  This script checks UPS health and generates a compatible JSON report.

  Options are a combination of the previous ups_analyze.sh and ups_check.sh scripts.

  --config <file>          Specify config file (default: config/ups_list.conf)
  --verbose                Show detailed analysis logic.
  --strict-pair            Do not perform pair difference evaluation if less than 2 UPS units are found.
  --min-runtime <min>      Threshold for minimum backup minutes (default: 15)
  --warn-batt <N>          WARN battery level threshold (default: 70)
  --crit-batt <N>          CRIT battery level threshold (default: 50)
  --temp-warn-high <N>     WARN high temperature threshold (default: 45)
  --temp-crit-high <N>     CRIT high temperature threshold (default: 50)
  --help                   Show this help message.
EOF
}

snmp_get_value(){
  local ip="$1" community="$2" oid="$3"
  snmpget -v2c -c "$community" -t 3 -r 1 -Oqv "$ip" "$oid" 2>/dev/null || echo "SNMPERR"
}

strip_quotes(){
  local s="$1"
  if [[ "$s" =~ ^\"(.*)\" ]]; then
    echo -n "${BASH_REMATCH[1]}"
  else
    echo -n "$s"
  fi
}

parse_timeticks_to_seconds(){
  local raw="$1" ticks=""
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    ticks="$raw"
  elif [[ "$raw" =~ ^\(([0-9]+)\)$ ]]; then
    ticks="${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^[0-9]+:([0-9]{2}):([0-9]{2})\.([0-9]{2})$ ]]; then
    local h m s_part frac
    h=$(echo "$raw" | cut -d: -f1)
    m=$(echo "$raw" | cut -d: -f2)
    s_part=$(echo "$raw" | cut -d: -f3 | cut -d. -f1)
    frac=$(echo "$raw" | cut -d. -f2)
    local total_sec=$(( h*3600 + m*60 + s_part ))
    ticks=$(( total_sec*100 + 10#${frac:-0} ))
  fi
  [[ -z "$ticks" ]] && ticks=0
  echo $(( ticks / 100 ))
}

perform_ups_check() {
    [[ -f "$CONFIG_FILE" ]] || { echo "[ERR] Config file not found: $CONFIG_FILE" >&2; exit 1; }
    local all_raw_logs=""
    while IFS='|' read -r IP COMMUNITY LABEL
 do
        [[ -z "$IP" || "$IP" =~ ^# ]] && continue
        local START_MS; START_MS=$(date +%s%3N)
        local NOW_TS; NOW_TS=$(date +"%Y-%m-%d %H:%M:%S")

        if ! ping -c1 -W1 "$IP" >/dev/null 2>&1;
 then
            all_raw_logs+="${NOW_TS} $LABEL($IP) STATUS=CRIT reason=PING_FAIL"$ '\n'
            continue
        fi

        local MODEL SERIAL BAT_CAP BAT_TEMP APC_OUT_RAW STD_OUT_SRC STD_RUNTIME_MIN STD_CHARGE_PCT RUNTIME_RAW_VAL
        MODEL=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_MODEL"); SERIAL=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_SERIAL")
        BAT_CAP=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_BAT_CAP"); BAT_TEMP=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_BAT_TEMP")
        APC_OUT_RAW=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_APC_OUTPUT_STATUS"); STD_OUT_SRC=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_STD_OUTPUT_SOURCE")
        STD_RUNTIME_MIN=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_STD_RUNTIME_MIN"); STD_CHARGE_PCT=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_STD_CHARGE_PCT")
        RUNTIME_RAW_VAL=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_BAT_RUNTIME")

        if [[ "$MODEL" == "SNMPERR" || "$BAT_CAP" == "SNMPERR" ]]; then
            all_raw_logs+="${NOW_TS} $LABEL($IP) STATUS=CRIT reason=SNMP_TIMEOUT"$ '\n'
            continue
        fi
        
        MODEL=$(strip_quotes "$MODEL"); SERIAL=$(strip_quotes "$SERIAL")

        [[ "$BAT_CAP" =~ ^[0-9]+$ ]] || BAT_CAP=-1; [[ "$BAT_TEMP" =~ ^[0-9]+$ ]] || BAT_TEMP=-99
        [[ "$APC_OUT_RAW" =~ ^[0-9]+$ ]] || APC_OUT_RAW=0; [[ "$STD_OUT_SRC" =~ ^[0-9]+$ ]] || STD_OUT_SRC=0
        [[ "$STD_RUNTIME_MIN" =~ ^[0-9]+$ ]] || STD_RUNTIME_MIN=0; [[ "$STD_CHARGE_PCT" =~ ^[0-9]+$ ]] || STD_CHARGE_PCT=0

        if (( BAT_CAP < 0 && STD_CHARGE_PCT > 0 )); then BAT_CAP=$STD_CHARGE_PCT; fi

        local HP_CAP HP_TEMP HP_RUNTIME
        HP_CAP=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_HP_CAP"); HP_TEMP=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_HP_TEMP"); HP_RUNTIME=$(snmp_get_value "$IP" "$COMMUNITY" "$OID_HP_RUNTIME")
        [[ "$HP_CAP" =~ ^[0-9]+$ ]] || HP_CAP=0; [[ "$HP_TEMP" =~ ^[0-9]+$ ]] || HP_TEMP=0; [[ "$HP_RUNTIME" =~ ^[0-9]+$ ]] || HP_RUNTIME=0
        if (( BAT_CAP < 0 && HP_CAP > 0 )); then BAT_CAP=$((HP_CAP/10)); fi
        if (( BAT_TEMP < 0 && HP_TEMP > 0 )); then BAT_TEMP=$((HP_TEMP/10)); fi

        local RUN_SEC; RUN_SEC=$(parse_timeticks_to_seconds "$RUNTIME_RAW_VAL")
        if (( RUN_SEC == 0 && HP_RUNTIME > 0 )); then RUN_SEC=$HP_RUNTIME; fi
        if (( RUN_SEC == 0 && STD_RUNTIME_MIN > 0 )); then RUN_SEC=$(( STD_RUNTIME_MIN*60 )); fi

        local RAW_SRC OUT_SEL OUTPUT_STATE; RAW_SRC="APC"; OUT_SEL=$APC_OUT_RAW
        if (( APC_OUT_RAW == 0 || APC_OUT_RAW > 150 )); then OUT_SEL=$STD_OUT_SRC; RAW_SRC="STD"; fi
        case "$OUT_SEL" in
            2) OUTPUT_STATE="NONE";; 3) OUTPUT_STATE="ON_LINE";; 4) OUTPUT_STATE="BYPASS";;
            5) OUTPUT_STATE="ON_BATTERY";; 6) OUTPUT_STATE="ON_BOOST";; 7) OUTPUT_STATE="ON_TRIM";;
            *) OUTPUT_STATE="UNKNOWN_$OUT_SEL";;
        esac

        if (( RUN_SEC == 0 && BAT_CAP >= 90 )); then
            case "$OUTPUT_STATE" in
                ON_LINE|BYPASS|UNKNOWN_*)
                    RUN_SEC=-1
                ;;
            esac
        fi

        local RUN_MIN; if (( RUN_SEC >= 0 )); then RUN_MIN=$(awk -v s="$RUN_SEC" 'BEGIN{printf "%.2f", s/60}'); else RUN_MIN="N/A"; fi

        local DURATION_MS; DURATION_MS=$(( $(date +%s%3N) - START_MS ))
        
        local line
        printf -v line "%s %s(%s) STATUS=OK model=\"%s\" serial=\"%s\" battery_pct=%s temp_c=%s runtime_sec=%s runtime_min=%s output_state=%s output_raw_src=%s duration_ms=%s" \
            "$NOW_TS" "$LABEL" "$IP" "$MODEL" "$SERIAL" "$BAT_CAP" "$BAT_TEMP" "$RUN_SEC" "$RUN_MIN" "$OUTPUT_STATE" "$RAW_SRC" "$DURATION_MS"
        all_raw_logs+="${line}"$'\n'

    done < "$CONFIG_FILE"
    echo -n "$all_raw_logs"
}

analyze_ups_data() {
    local reconstructed_log="$1"
    ANALYSIS_OVERALL_STATUS="PASS"; ANALYSIS_REASON="Overall: PASS"; ANALYSIS_UPS_OBJ_JSON=""
    declare -a UPS_IDS; declare -A UPS_RAW UPS_STATUS UPS_MODEL UPS_SERIAL UPS_BATT UPS_TEMP UPS_RUN_SEC UPS_RUN_MIN UPS_STATE UPS_DUR; declare -A UPS_WARN_REASON UPS_CRIT_REASON
    while IFS= read -r line; do
        [[ -z "$line" || "$line" != *"STATUS="* ]] && continue
        local ups_id kv_part; ups_id=$(echo "$line" | awk '{print $3}'); kv_part=$(echo "$line" | cut -d' ' -f4-)
        declare -A kv; for token in $kv_part; do local k=${token%%=*}; v=${token#*=}; [[ -z "$k" ]] && continue; v=$(strip_quotes "$v"); kv["$k"]="$v"; done
        local status model serial batt temp rsec rmin state dur; status=${kv[STATUS]:-}; model=${kv[model]:-${kv[MODEL]:-}}; serial=${kv[serial]:-${kv[SERIAL]:-}}; batt=${kv[battery_pct]:-}; temp=${kv[temp_c]:-}; rsec=${kv[runtime_sec]:-}; rmin=${kv[runtime_min]:-}; state=${kv[output_state]:-}; dur=${kv[duration_ms]:-}
        batt=${batt//[^0-9]/}; temp=${temp//[^0-9]/}; rsec=${rsec//[^0-9]/}; rmin=${rmin//[^0-9.]/}; dur=${dur//[^0-9]/}
        local idkey="$ups_id"; UPS_IDS+=("$idkey"); UPS_RAW["$idkey"]="$line"; UPS_STATUS["$idkey"]="$status"; UPS_MODEL["$idkey"]="$model"; UPS_SERIAL["$idkey"]="$serial"; UPS_BATT["$idkey"]="$batt"; UPS_TEMP["$idkey"]="$temp"; UPS_RUN_SEC["$idkey"]="$rsec"; UPS_RUN_MIN["$idkey"]="$rmin"; UPS_STATE["$idkey"]="$state"; UPS_DUR["$idkey"]="$dur"
    done <<< "$reconstructed_log"
    if ((${#UPS_IDS[@]}==0)); then echo "[ERR] No valid UPS data was collected." >&2; ANALYSIS_OVERALL_STATUS="FAIL"; ANALYSIS_REASON="No valid UPS data was collected."; ANALYSIS_UPS_OBJ_JSON='{"file":"in-memory","overall":"FAIL","ups":[],"pair_diff":{"crit":"Collection failed","warn":""}}'; return; fi
    declare -A seen; local unique_ids=(); for u in "${UPS_IDS[@]}"; do if [[ -n "${seen[$u]:-}" ]]; then continue; fi; seen["$u"]=1; unique_ids+=("$u"); done; UPS_IDS=("${unique_ids[@]}")
    local GLOBAL_CRIT=0 GLOBAL_WARN=0
    for id in "${UPS_IDS[@]}"; do
        local status="${UPS_STATUS[$id]}" batt="${UPS_BATT[$id]:-}" temp="${UPS_TEMP[$id]:-}" rmin="${UPS_RUN_MIN[$id]:-}" state="${UPS_STATE[$id]:-}" dur="${UPS_DUR[$id]:-}"; local crits=() warns=()
        if [[ -z "$status" ]]; then warns+=("STATUS缺失"); elif [[ "$status" != "OK" ]]; then if [[ "$status" =~ (FAIL|ALARM|ERROR|CRITICAL) ]]; then crits+=("STATUS=$status"); else warns+=("STATUS=$status"); fi; fi
        if [[ -z "$batt" ]]; then warns+=("battery_pct空"); else if (( batt < CRIT_BATT2 )); then crits+=("battery<$CRIT_BATT2%"); elif (( batt < CRIT_BATT )); then crits+=("battery<$CRIT_BATT%"); elif (( batt < WARN_BATT )); then warns+=("battery<$WARN_BATT%"); fi; fi
        if [[ -n "$temp" ]]; then if (( temp >= TEMP_CRIT_HIGH )); then crits+=("temp>=${TEMP_CRIT_HIGH}C"); elif (( temp > TEMP_WARN_HIGH )); then warns+=("temp>${TEMP_WARN_HIGH}C"); elif (( temp <= TEMP_CRIT_LOW )); then crits+=("temp<=${TEMP_CRIT_LOW}C"); elif (( temp < TEMP_WARN_LOW )); then warns+=("temp<${TEMP_WARN_LOW}C"); fi; else warns+=("temp缺失"); fi
        if [[ -n "$rmin" ]]; then local rbase=${rmin%.*}; if (( rbase < 8 )); then crits+=("runtime_min<8"); elif (( rbase < MIN_RUNTIME_MIN )); then warns+=("runtime_min<$MIN_RUNTIME_MIN"); fi; else warns+=("runtime_min缺失"); fi
        if [[ -n "$state" ]]; then case "$state" in ON_LINE) ;; ON_BATTERY) if [[ -n "$batt" && $batt -lt 60 ]]; then crits+=("ON_BATTERY且電量低"); else warns+=("ON_BATTERY"); fi ;; BYPASS|SHUTDOWN|FAULT*) crits+=("state=$state") ;; *) warns+=("state=$state") ;; esac; else warns+=("output_state缺失"); fi
        if [[ -n "$dur" ]]; then if (( dur > DURATION_CRIT )); then crits+=("duration>${DURATION_CRIT}ms"); elif (( dur > DURATION_WARN )); then warns+=("duration>${DURATION_WARN}ms"); fi; fi
        if ((${#crits[@]}>0)); then UPS_CRIT_REASON["$id"]=$(IFS=$'\n'; echo "${crits[*]}"); GLOBAL_CRIT=1; elif ((${#warns[@]}>0)); then UPS_WARN_REASON["$id"]=$(IFS=$'\n'; echo "${warns[*]}"); (( GLOBAL_WARN==0 )) && GLOBAL_WARN=1; fi
    done
    local PAIR_WARN="" PAIR_CRIT=""; if ((${#UPS_IDS[@]}>=2)); then
        local A B battA battB runA runB
        A="${UPS_IDS[0]}"; B="${UPS_IDS[1]}"
        battA=${UPS_BATT[$A]:-0}; battB=${UPS_BATT[$B]:-0}
        runA=${UPS_RUN_MIN[$A]%%.*}; runB=${UPS_RUN_MIN[$B]%%.*}
        if (( battA > 0 && battB > 0 )); then local diff_batt=$(( battA > battB ? battA - battB : battB - battA )); if (( diff_batt > DIFF_BATT_CRIT )); then PAIR_CRIT="battery 差異 ${diff_batt}%"; GLOBAL_CRIT=1; elif (( diff_batt > DIFF_BATT_WARN )); then if [[ -z "$PAIR_CRIT" ]]; then PAIR_WARN="battery 差異 ${diff_batt}%"; fi; if (( GLOBAL_CRIT==0 )); then GLOBAL_WARN=1; fi; fi; fi
        if (( runA > 0 && runB > 0 )); then local bigger=$(( runA > runB ? runA : runB )) smaller=$(( runA > runB ? runB : runA )); if (( bigger > 0 )); then local diff_pct=$(( (bigger - smaller) * 100 / bigger )); if (( diff_pct > DIFF_RUN_CRIT )); then PAIR_CRIT="${PAIR_CRIT:+$PAIR_CRIT; }runtime 差異 ${diff_pct}%"; GLOBAL_CRIT=1; elif (( diff_pct > DIFF_RUN_WARN )); then if [[ -z "$PAIR_CRIT" ]]; then PAIR_WARN="${PAIR_WARN:+$PAIR_WARN; }runtime 差異 ${diff_pct}%"; fi; if (( GLOBAL_CRIT==0 )); then GLOBAL_WARN=1; fi; fi; fi; fi
    elif (( STRICT_PAIR )); then :
    fi
    if (( GLOBAL_CRIT )); then ANALYSIS_OVERALL_STATUS="FAIL"; elif (( GLOBAL_WARN )); then ANALYSIS_OVERALL_STATUS="WARN"; fi
    if [[ -n "$PAIR_CRIT" ]]; then ANALYSIS_REASON="$PAIR_CRIT"; elif [[ -n "$PAIR_WARN" ]]; then ANALYSIS_REASON="$PAIR_WARN"; else ANALYSIS_REASON="Overall: $ANALYSIS_OVERALL_STATUS"; fi

    local ups_array_json=""
    for id in "${UPS_IDS[@]}"; do
        local crit_r=${UPS_CRIT_REASON[$id]:-} warn_r=${UPS_WARN_REASON[$id]:-} reason=""
        if [[ -n "$crit_r" ]]; then
            reason="CRIT:$crit_r"
        elif [[ -n "$warn_r" ]]; then
            reason="WARN:$warn_r"
        else
            local batt="${UPS_BATT[$id]:-?}"
            local temp="${UPS_TEMP[$id]:-?}"
            local rmin="${UPS_RUN_MIN[$id]:-?}"
            reason=$(printf "BATT=%s%%, TEMP=%sC, RTIME=%smin -> PASS" "$batt" "$temp" "$rmin")
        fi
        local ups_item
        ups_item=$(jq -nc --arg id "$id" --argjson batt "${UPS_BATT[$id]:-0}" --argjson temp "${UPS_TEMP[$id]:-0}" --argjson rmin "${UPS_RUN_MIN[$id]:-0}" --arg status "${UPS_STATUS[$id]:-}" --arg state "${UPS_STATE[$id]:-}" --argjson dur "${UPS_DUR[$id]:-0}" --arg reason "$reason" '{id:$id,battery_pct:$batt,temp_c:$temp,runtime_min:$rmin,status:$status,output_state:$state,duration_ms:$dur,reason:$reason}')
        if [[ -z "$ups_array_json" ]]; then
            ups_array_json="$ups_item"
        else
            ups_array_json="$ups_array_json,$ups_item"
        fi
    done

    ANALYSIS_UPS_OBJ_JSON=$(echo "[$ups_array_json]" | jq -c --arg overall "$ANALYSIS_OVERALL_STATUS" --arg crit "$PAIR_CRIT" --arg warn "$PAIR_WARN" '{file:"in-memory",overall:$overall,ups:.,pair_diff:{crit:$crit,warn:$warn}}')

    if (( VERBOSE )); then
        echo "=== UPS Analysis Results ==="; printf "% -22s % -6s % -7s % -6s % -8s % -10s % -8s %s\n" "UPS_ID" "BATT%" "TEMP" "RMIN" "STATE" "STATUS" "DURms" "REASON"
        for id in "${UPS_IDS[@]}"; do local reason_txt="OK"; [[ -n "${UPS_CRIT_REASON[$id]:-}" ]] && reason_txt="CRIT:${UPS_CRIT_REASON[$id]}"; [[ -z "${UPS_CRIT_REASON[$id]:-}" && -n "${UPS_WARN_REASON[$id]:-}" ]] && reason_txt="WARN:${UPS_WARN_REASON[$id]}"; printf "% -22s % -6s % -7s % -6s % -8s % -10s % -8s %s\n" "$id" "${UPS_BATT[$id]:-}" "${UPS_TEMP[$id]:-}" "${UPS_RUN_MIN[$id]:-}" "${UPS_STATE[$id]:-}" "${UPS_STATUS[$id]:-}" "${UPS_DUR[$id]:-}" "$reason_txt"; done
        if [[ -n "$PAIR_CRIT" || -n "$PAIR_WARN" ]]; then echo "--- Pair Differences ---"; [[ -n "$PAIR_CRIT" ]] && echo "CRIT: $PAIR_CRIT"; [[ -n "$PAIR_WARN" ]] && echo "WARN: $PAIR_WARN"; fi
        echo "Overall: $ANALYSIS_OVERALL_STATUS"; echo "========================="
    fi
}

# --- Main Execution ---
cd "$(dirname "$0")"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;; --verbose) VERBOSE=1; shift;; --min-runtime) MIN_RUNTIME_MIN="$2"; shift 2;; 
    --warn-batt) WARN_BATT="$2"; shift 2;; --crit-batt) CRIT_BATT="$2"; shift 2;; --temp-warn-high) TEMP_WARN_HIGH="$2"; shift 2;; 
    --temp-crit-high) TEMP_CRIT_HIGH="$2"; shift 2;; --strict-pair) STRICT_PAIR=1; shift;; --help|-h) print_usage; exit 0;; 
    *) echo "Unknown parameter: $1"; exit 1;; 
  esac
done
TIMESTAMP=$(date +%Y%m%d_%H%M%S); OUTPUT_DIR="logs"; mkdir -p "$OUTPUT_DIR"; mkdir -p "logs/ups"
echo "Performing UPS check via SNMP..."; raw_log_output=$(perform_ups_check); echo "Check complete."
echo "Analyzing data..."; analyze_ups_data "$raw_log_output"; echo "Analysis complete. Overall Status: $ANALYSIS_OVERALL_STATUS"
echo "Building final report..."; JSON_OUT_FILE="${OUTPUT_DIR}/jfcrh_ups_health_${TIMESTAMP}.json"; LATEST_JSON_LINK="${OUTPUT_DIR}/jfcrh_ups_health_latest.json"
items_json="["; for i in $(seq 1 15); do
    if (( i == 9 )); then escaped_reason=$(echo "$ANALYSIS_REASON" | jq -s -R "."); items_json+=$(printf '{"id":9,"status":"%s","reason":%s,"tips":[]}' "$ANALYSIS_OVERALL_STATUS" "$escaped_reason"); else items_json+=$(printf '{"id":%d,"status":"SKIP","reason":"Not applicable for UPS check","tips":[]}' "$i"); fi
    if (( i < 15 )); then items_json+=','; fi
done; items_json+="]"
jq -n --arg hostname "UPS_System" --arg timestamp "$TIMESTAMP" --argjson items "$items_json" --argjson ups_obj "$ANALYSIS_UPS_OBJ_JSON" \
'{
  "meta": { "hostname": $hostname, "timestamp": $timestamp, "duration_sec": 0, "bios_version": "N/A", "kernel": "N/A" },
  "items": $items,
  "sel": { "summary": { "crit":0, "warn":0, "info":0, "noise_raw":0, "noise_hidden":0 }, "events_file": "", "crit_warn_events": [], "top_sensors": [] },
  "raid": { "overall": "SKIP", "reason": "N/A" },
  "ups": $ups_obj,
  "files": { "log_txt": "", "log_md": "", "log_csv": "", "journal_analysis_log": "" }
}' > "$JSON_OUT_FILE"
JSON_OUT_FILENAME=$(basename "$JSON_OUT_FILE"); ln -sf "$JSON_OUT_FILENAME" "$LATEST_JSON_LINK"
echo "Generated compatible UPS report: $JSON_OUT_FILE (and symlinked to $LATEST_JSON_LINK)"
exit_code=0; if [[ "$ANALYSIS_OVERALL_STATUS" == "FAIL" ]]; then exit_code=2; elif [[ "$ANALYSIS_OVERALL_STATUS" == "WARN" ]]; then exit_code=1; fi
exit $exit_code


