
20251012 10:32待重構
先修上面的問題，再重構 `check_disks()`。理由很簡單：

* 目前你看到的「CPU/FAN 數值沒露出」「SEL 沒帶出 X 天」「NIC 門檻/短窗誤報」會直接影響**所有報表**的可信度；而且這些改動和磁碟邏輯**幾乎沒有交集**，先收斂可觀測度最划算。
* `check_disks()` v2.3 是一個「大手術」（多資料源聚合 + 報表語意重設），獨立一個 commit/PR 做、風險小也好回滾。

下面給你**可直接丟給 Claude Code** 的「`check_disks()` v2.3 judgement 重構」提示詞。建議：先把上個回合的 SEL/CPU/FAN/NIC 修完、驗證 OK，再把這段丟給它。

---

# 🔧 Claude Code 提示詞：重構 `check_disks()` 為 v2.3 judgement

你是資深 SRE/Bash 工程師。請在 `server_health_full.sh` 中**只重構** `check_disks()`，改成 v2.3 judgement 規格。**保留既有 CLI/日誌結構**，盡量最小侵入；若有舊版 `check_disks()` 定義多份，請**保留最後一個**、刪除前面的舊版（或在第一行 `return`）。

## 目標

* 融合三路資料源（RAID、SMART、NVMe）→ 產出**一致的 metrics / checks / reason / thresholds**。
* 可在 **無 root/無工具** 情境降級為 INFO/WARN（不 FAIL），並清楚標示「跳過原因」。
* PASS 時也要有**可審計**的 Key Checks（包含數值）。

---

## 1) 輸入來源與探測

### 1.1 RAID 探測（優先順序）

* 優先 `storcli`（CLI 由 `--storcli-bin` 傳入，可能是 `sudo /opt/MegaRAID/storcli/storcli64`），fallback：無法執行或非 LSI/Avago/BBU 則**標記為 not_available**。
* Linux mdadm（如偵測到 `/proc/mdstat` 有 active 陣列）→ 解析陣列、狀態、重建、遺失磁碟。
* 結果整合為統一欄位（見 §2 指標結構）。

### 1.2 SMART（SATA/SAS）

* 以 `smartctl -H -A /dev/sdX` 掃描 `lsblk -ndo NAME,TYPE | grep 'disk'` 得到的 `sd*`。
* 收集：

  * `overall_status`（PASSED/FAILED/UNKNOWN）、`reallocated_sector_ct`、`current_pending_sector`、`offline_uncorrectable`、`power_on_hours`、`temperature`。
* 無 root 或無權限→ 標記 `smart_scanned=false` 並加入 checks 說明。

### 1.3 NVMe

* `nvme list` 取得裝置清單；`nvme smart-log /dev/nvmeX` 收集：

  * `critical_warning`（>0 異常）、`media_errors`、`num_err_log_entries`、`temperature`、`percentage_used`。
* 無 nvme 工具→ 標記 `nvme_scanned=false`，同樣加入 checks 說明。

---

## 2) 指標（metrics JSON）結構（寫入 master JSON 的 `.items[]` → `metrics`）

```json
{
  "raid": {
    "driver": "storcli|mdadm|none",
    "controllers": [
      {
        "id": "c0",
        "model": "LSI xxxx",
        "virtual_drives": {"total":N,"optimal":N,"degraded":N,"failed":N,"rebuild":N},
        "physical_disks": {"total":N,"online":N,"failed":N,"missing":N,"foreign":N,"pred_fail":N}
      }
    ],
    "mdadm": {
      "arrays": [
        {"name":"md0","level":"raid1","state":"clean|degraded|recovering","recovery_pct": "12.3"}
      ]
    }
  },
  "smart": {
    "scanned": true,
    "devices": [
      {"dev":"/dev/sda","model":"xxx","status":"PASSED|FAILED|UNKNOWN","realloc":N,"pending":N,"uncorrect":N,"temp":N,"poh":N}
    ],
    "alerts": {
      "failed": ["sdb"],
      "realloc_gt0": ["sdc"],
      "pending_gt0": [],
      "uncorr_gt0": []
    }
  },
  "nvme": {
    "scanned": true,
    "devices": [
      {"dev":"/dev/nvme0","model":"xxx","crit_warn":N,"media_err":N,"err_log":N,"temp":N,"pct_used":N}
    ],
    "alerts": {
      "crit_warn_gt0":["nvme0"],
      "media_err_gt0":["nvme1"],
      "pct_used_ge80":["nvme2"]
    }
  }
}
```

> 若無對應來源，`controllers/devices/arrays` 可為空陣列；`scanned=false` 表示跳過（缺權限/缺工具）。

---

## 3) 門檻（thresholds）與預設值

在 `check_disks()` 區域內確保有預設並寫回 thresholds（沿用原有輸出行為）：

```bash
: "${SMART_REQUIRED:=true}"          # 嚴格模式：需要 SMART & NVMe
: "${NVME_REQUIRED:=true}"
: "${ROOT_REQUIRED:=true}"           # 需要 root 或免密碼 sudo
: "${DISK_REBUILD_WARN:=1}"          # rebuild 中 >=1 → WARN
: "${PD_FAIL_CRIT:=1}"               # 任何實體磁碟 failure → FAIL
: "${VD_DEGRADED_WARN:=1}"           # 任一 VD degraded → WARN
: "${SMART_ALERT_FAIL_CRIT:=1}"      # 有 smart FAILED → FAIL
: "${SMART_REALLOC_WARN:=1}"         # 有 realloc >0 → WARN
: "${SMART_PENDING_WARN:=1}"         # pending >0 → WARN
: "${NVME_CRIT_WARN_CRIT:=1}"        # critical_warning >0 → FAIL
: "${NVME_MEDIA_ERR_WARN:=1}"        # media_errors >0 → WARN
: "${NVME_PCT_USED_WARN:=80}"        # percentage_used >=80 → WARN
```

將以上值寫入 thresholds 行與 master JSON（沿用你現有的 `thresholds_latest.json` 更新方式）。

---

## 4) 判斷（judgement）

### 4.1 狀態優先序

* **FAIL**（任一命中即 FAIL）

  * RAID：`pd.failed >= PD_FAIL_CRIT`
  * SMART：有 `status=FAILED`
  * NVMe：`critical_warning > 0`
* **WARN**（若未 FAIL 且任一命中）

  * RAID：`vd.degraded >= VD_DEGRADED_WARN` 或 `rebuild >= DISK_REBUILD_WARN` 或 mdadm array `state=degraded|recovering`
  * SMART：`realloc>0` 或 `pending>0` 或 `uncorrect>0`
  * NVMe：`media_errors>0` 或 `percentage_used >= NVME_PCT_USED_WARN`
* **SKIP/WARN（環境不足）**

  * 若 `ROOT_REQUIRED=true` 但非 root/無 sudo：**不直接 FAIL**；將 RAID/SMART/NVMe 掃描標記為 `scanned=false`，整體 **WARN**，Reason 指出「權限不足，僅進行部分檢查」。
* **PASS**

  * 以上皆不命中且可掃描。

### 4.2 Reason（人類可讀）

* PASS：

  * `RAID 正常（VD: X optimal, 0 degraded, 0 failed）；SMART/NVMe 無異常屬性。`
* WARN：

  * 聚合最關鍵的 1–3 個點（例如 `md0 recovering 12%`、`sdc realloc=8`、`nvme0 media_err=3`）。
* FAIL：

  * `sdb SMART: FAILED` 或 `RAID: PD failed=1 on controller c0` 或 `nvme1 critical_warning=1`。

### 4.3 Key Checks（一定要帶數值）

以 jq 產出陣列，例：

```bash
checks_json=$(jq -n \
  --arg raid_driver "$raid_driver" \
  --arg vd_deg "$vd_degraded" --arg vd_fail "$vd_failed" --arg vd_rebuild "$vd_rebuild" \
  --arg pd_fail "$pd_failed" --arg pd_missing "$pd_missing" \
  --arg smart_failed "$smart_failed" --arg smart_realloc "$smart_realloc" --arg smart_pending "$smart_pending" --arg smart_uncorr "$smart_uncorr" \
  --arg nvme_cw "$nvme_cw" --arg nvme_media_err "$nvme_media_err" --arg nvme_pct80 "$nvme_pct80" \
  '[
    {"name":"RAID driver","ok":($raid_driver!="none"),"value":$raid_driver},
    {"name":"VD degraded=0","ok":(($vd_deg|tonumber)==0),"value":("degraded="+$vd_deg)},
    {"name":"VD failed=0","ok":(($vd_fail|tonumber)==0),"value":("failed="+$vd_fail)},
    {"name":"VD rebuilding=0","ok":(($vd_rebuild|tonumber)==0),"value":("rebuild="+$vd_rebuild)},
    {"name":"PD failed=0","ok":(($pd_fail|tonumber)==0),"value":("pd_failed="+$pd_fail)},
    {"name":"PD missing=0","ok":(($pd_missing|tonumber)==0),"value":("pd_missing="+$pd_missing)},
    {"name":"SMART FAILED=0","ok":(($smart_failed|tonumber)==0),"value":("failed="+$smart_failed)},
    {"name":"SMART realloc=0","ok":(($smart_realloc|tonumber)==0),"value":("realloc="+$smart_realloc)},
    {"name":"SMART pending=0","ok":(($smart_pending|tonumber)==0),"value":("pending="+$smart_pending)},
    {"name":"SMART uncorrect=0","ok":(($smart_uncorr|tonumber)==0),"value":("uncorr="+$smart_uncorr)},
    {"name":"NVMe crit_warn=0","ok":(($nvme_cw|tonumber)==0),"value":("crit_warn="+$nvme_cw)},
    {"name":"NVMe media_err=0","ok":(($nvme_media_err|tonumber)==0),"value":("media_err="+$nvme_media_err)},
    {"name":"NVMe pct_used<80","ok":(($nvme_pct80|tonumber)==0),"value":("pct_used>=80_count="+$nvme_pct80)}
  ]')
```

---

## 5) 失敗/缺工具處理（降級）

* `storcli`/`smartctl`/`nvme` 任一缺少時：

  * 在 `checks_json` 追加 `{"name":"<tool> available","ok":false,"value":"not found"}`。
  * 若 `SMART_REQUIRED/NVME_REQUIRED/ROOT_REQUIRED=true`，整體狀態**WARN**，Reason 加入「權限/工具不足，部分檢查跳過」。
  * **不要**因為工具缺失直接 FAIL（除非你已有既定政策要這麼做）。

---

## 6) 輸出與日誌

* `Reason`：簡短一句總結 + 若 WARN/FAIL，括號列 1–3 個最關鍵點。
* `TIPS`：保留既有指令示例；若缺工具，提示安裝方式（簡短）。
* `LOGS`：

  * `main_output_log`（沿用你現有路徑），新增：

    * `storcli_raw_log`（若有）、`mdstat_log`、`smart_scan_log`（彙總一份）、`nvme_smart_log`（彙總一份）。
* `Thresholds`：把 §3 的鍵都 echo 出來，並同步更新 `thresholds_latest.json`（沿用你的寫法）。

---

## 7) 測試與驗證（請一併執行並回傳片段）

1. **工具缺失情境**（不 sudo）

   * 預期：整體 WARN；Reason 內有「權限不足/工具缺失」字樣；Key Checks 有 `<tool> available=false`。
2. **正常情境**（有 storcli/smartctl/nvme）

   * PASS：Reason 短句、Key Checks 含數值；Thresholds 行帶齊。
3. **故障情境（可模擬）**

   * 手動回寫一段 smartctl JSON 解析出 `FAILED` 或 NVMe `critical_warning=1`，預期 FAIL，Reason 指出來源與裝置。

---

## 8) 風險控管

* 僅修改 `check_disks()`；不動其他項目。
* 若解析失败，請不要 `set -e` 影響整體；以 `ok:false, value:"parse error"` 呈現。

---

## 交付

* 請回傳：

  1. 差異摘要（變更檔案/函式與關鍵行）
  2. 新的 `checks_json` 片段
  3. 一段 PASS 與一段 FAIL/WARN 的示例 Reason
  4. 實測輸出（Key Checks & Thresholds 節選）

---

照這份做，`Disks/RAID/SMART` 就會升級到 v2.3：

* 有指標、有門檻、有可審計的 checks（數值必露出），
* 權限不足不亂 FAIL，
* 真有壞盤 / 陣列降級 / NVMe 告警纔會 WARN/FAIL。
