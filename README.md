# JFCRH report scripts
Audit hardening: NIC window/rationale, SEL recency, ENV key unification, GPU SKIP judgement
## 概要
將 server_health_full.sh 的 NIC/SEL/ENV/GPU 進一步提升到可審計層級：修正 per-IF 視窗計算、改善 reason 可讀性、提供 SEL 距上次事件天數、統一 ENV 鍵名、重寫 GPU SKIP 判斷與 checks。

## 變更明細
1) NIC 視窗
- 每介面使用 nic_window_sec = NOW_TS - nic_prev_ts
- write_nic_baseline/ load_nic_baseline 加入/讀取 timestamp
- Summary 顯示視窗秒數，便於追蹤
- 效果：長視窗時 rate 降至 ~0.5/s，避免 30s 視窗誤報
Refs: 1999-2027,2146-2173

2) NIC 文案與分隔
- IFS='; ' 輸出 reason_details，避免黏在一起
- Criteria（任一成立即 WARN）：
  ① Δrx_dropped ≥ ${NIC_WARN_MIN_DELTA}
  ② 丟包率 ≥ ${NIC_WARN_MIN_PCT}%
  ③ 丟包速率 ≥ ${NIC_WARN_MIN_RX_DROP_RATE}/s
  ④ link=no
Refs: 2204-2207,2254-2257

3) SEL 趨勢提示
- days_since_last = (now - last_ts) / 86400
- PASS: "過去 ${SEL_DAYS} 天內無 CRIT/WARN；距今已 X 天未再發"
- WARN/FAIL: "SEL CRIT=… WARN=… (最近一次 CRIT/WARN 為 X 天前)"
- checks 增加：「距上次 CRIT/WARN 天數」
Refs: 3012-3045

4) ENV 鍵名統一
- 門檻鍵統一為 ENV_TEMP_WARN / ENV_TEMP_CRIT（與 CLI 名稱一致）
- thresholds JSON 更新；Criteria 文案同步
Refs: 2660-2661,2675

5) GPU/SKIP judgement
- 重寫 check_gpu()，統一 set_check_result_with_jdg
- checks 的 ok 值語意正確：nvidia-smi unavailable → ok:false（非 FAIL）
- 完整 criteria + thresholds: {"GPU_TEMP_WARN":85,"GPU_TEMP_CRIT":92,"GPU_POWER_WATCH":0}
Refs: 2266-2324

## 對照
| 項目 | 改進前 | 改進後 |
|---|---|---|
| NIC rate | 1155/s（誤報） | 0.5/s（21465s） |
| NIC reason | 字串黏在一起 | `…; …; …` |
| SEL | 只顯示數量 | 顯示距上次事件 X 天 |
| ENV | 鍵名不一致 | ENV_TEMP_WARN/CRIT 統一 |
| GPU SKIP | 舊 set_status、誤導的 [✗] | 統一 judgement、ok 值語意正確 |

## 測試
- 實機重跑 Item 5/8/12/6，核對預期輸出
- rate 於長視窗下降；reason 分隔清楚；SEL 顯示 X 天；ENV 鍵名一致；GPU SKIP 無誤導

