#!/bin/bash

# make_report.sh
# 一鍵執行日誌分析工具鏈

# -e: 當命令失敗時，立即退出腳本
# -u: 當使用未定義的變數時，視為錯誤並退出
# -o pipefail: 如果管道中的任何命令失敗，則整個管道的返回碼為失敗
set -euo pipefail

# --- 變數定義 ---
LOG_FILE="${1:?}"
RULES_FILE="${2:-rules.yaml}" # Use second argument or default to rules.yaml
# 從日誌檔名提取報告基礎名稱，例如 jfcrh_strg
REPORT_BASENAME=$(basename "$LOG_FILE" | cut -d'_' -f1-2)
OUTPUT_DIR="$(pwd)/${REPORT_BASENAME}_report"
VENV_DIR=".venv"

# --- 函數定義 ---

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

main() {
    echo "日誌分析工具鏈啟動..."
    echo "分析目標: $LOG_FILE"
    echo "報告將輸出至: $OUTPUT_DIR/"

    # 1. 檢查環境依賴
    echo "[1/5] 正在檢查環境依賴..."
    if ! command_exists python3; then
        echo "錯誤: 找不到 python3。請先安裝 Python 3。" >&2
        exit 1
    fi
    if ! command_exists pip3; then
        if ! python3 -m pip --version >/dev/null 2>&1; then
            echo "錯誤: 找不到 pip3 或 python3 -m pip。請先安裝 pip。" >&2
            exit 1
        fi
        PIP_CMD="python3 -m pip"
    else
        PIP_CMD="pip3"
    fi
    echo "環境檢查通過。"

    # 2. 建立並啟用虛擬環境
    echo "[2/5] 正在設定 Python 虛擬環境..."
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
        echo "虛擬環境 '$VENV_DIR' 已建立。"
    fi
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"
    echo "虛擬環境已啟用。"

    # 3. 安裝依賴套件
    echo "[3/5] 正在安裝/更新依賴套件..."
    $PIP_CMD install -q --upgrade pip
    $PIP_CMD install -q pandas seaborn matplotlib pytz pyyaml tabulate
    echo "依賴套件安裝完成。"

    # 4. 建立輸出目錄並執行分析
    echo "[4/5] 正在建立輸出目錄並執行分析..."
    mkdir -p "$OUTPUT_DIR"
    
    echo "--- (a) 解析日誌 ---"
    python3 parse_journal.py "$LOG_FILE" --output_dir "$OUTPUT_DIR" --rules "$RULES_FILE"
    
    echo "--- (b) 聚合指標 ---"
    python3 aggregate_metrics.py --io_dir "$OUTPUT_DIR" --rules "$RULES_FILE"
    
    echo "--- (c) 產生圖表與報告 ---"
    python3 plot_reports.py --io_dir "$OUTPUT_DIR" --rules "$RULES_FILE"

    # 5. 完成
    echo "[5/5] 分析流程全部完成！"
    echo ""
    echo "--- 產出檔案列表 ---"
    ls -l "$OUTPUT_DIR"
    echo "----------------------"
    echo ""
    echo "報告已產生: $OUTPUT_DIR/report.md"
    echo ""
}

# --- 腳本執行入口 ---
main "$@"