# aggregate_metrics.py
import argparse
import pandas as pd
import numpy as np
import yaml
from datetime import datetime, timedelta

def load_config(config_path='rules.yaml'):
    """載入 YAML 配置文件"""
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        print(f"警告: 配置文件 '{config_path}' 未找到，將使用預設權重。")
        return {
            'weights': {
                'RAID_FW': 40,
                'FSCRYPT_EXT4': 20,
                'CIFS_SMB': 15,
                'SUDO_AUTH': 10,
                'FWUPD': 5,
                'SMARTD_NOTIFY': 5,
                'NET_IFACE_MISSING': 5,
                'OTHER': 0
            }
        }

def calculate_health_score(df, weights):
    """
    計算每日健康分數。
    分數 = 100 - sum(weight * normalized_count) for each category
    正規化方式: log(1 + count)
    """
    if df.empty:
        return pd.DataFrame(columns=['date', 'health_score'])

    # 確保 date 是 datetime object
    df['date'] = pd.to_datetime(df['date'])

    # 計算每日各類別的事件總數
    daily_counts = df.groupby(['date', 'category']).size().unstack(fill_value=0)
    
    #正規化 (log(1+x))
    normalized_counts = np.log1p(daily_counts)
    
    # 計算每日的加權扣分
    deduction = pd.Series(0, index=daily_counts.index, dtype=float)
    for category, weight in weights.items():
        if category in normalized_counts.columns:
            deduction += normalized_counts[category] * weight
            
    # 分數範圍 0-100
    health_score = 100 - deduction
    health_score.clip(0, 100, inplace=True)
    
    health_df = health_score.reset_index()
    health_df.columns = ['date', 'health_score']
    health_df['date'] = health_df['date'].dt.strftime('%Y-%m-%d')
    return health_df

def main():
    parser = argparse.ArgumentParser(description='從 parsed.csv 聚合指標。')
    parser.add_argument('--top-k', type=int, default=20, help='Top K 訊息排名的 K 值')
    parser.add_argument('--window-days', type=int, default=7, help='報告摘要聚焦的最近天數')
    parser.add_argument('--rules', default='rules.yaml', help='分類規則與權重的 YAML 配置文件')
    parser.add_argument('--io_dir', default='.', help='輸入與輸出目錄')
    args = parser.parse_args()

    input_csv = f"{args.io_dir}/parsed.csv"
    try:
        df = pd.read_csv(input_csv)
    except FileNotFoundError:
        print(f"錯誤: '{input_csv}' 未找到。請先執行 parse_journal.py。")
        return

    config = load_config(args.rules)
    weights = config.get('weights', {})

    # 1. 每日指標
    metrics_daily = df.groupby(['date', 'category']).size().reset_index(name='count')
    metrics_daily.to_csv(f"{args.io_dir}/metrics_daily.csv", index=False)

    # 2. 每小時指標
    metrics_hourly = df.groupby(['hour', 'category']).size().reset_index(name='count')
    metrics_hourly.to_csv(f"{args.io_dir}/metrics_hourly.csv", index=False)

    # 3. Top K 訊息
    df['message_key'] = df['message'].str.slice(0, 120)
    top_messages = df.groupby('message_key').agg(
        count=('message_key', 'size'),
        first_seen=('ts_utc', 'min'),
        last_seen=('ts_utc', 'max'),
        categories=('category', lambda x: list(x.unique()))
    ).sort_values(by='count', ascending=False).head(args.top_k)
    top_messages.to_csv(f"{args.io_dir}/top_messages.csv")

    # 4. 共現矩陣
    df['date_hour'] = pd.to_datetime(df['ts_utc']).dt.strftime('%Y-%m-%d %H')
    hourly_presence = df.groupby(['date_hour', 'category']).size().unstack(fill_value=0)
    hourly_presence[hourly_presence > 0] = 1
    co_occurrence = hourly_presence.T.dot(hourly_presence)
    co_occurrence.to_csv(f"{args.io_dir}/co_occurrence_hourly.csv")

    # 5. 健康分數
    health_df = calculate_health_score(df, weights)
    health_df.to_csv(f"{args.io_dir}/health_score.csv", index=False)

    # 6. 關鍵指標摘要
    df['date'] = pd.to_datetime(df['date'])
    end_date = df['date'].max()
    start_date = end_date - timedelta(days=args.window_days - 1)
    summary_df = df[df['date'] >= start_date]

    key_metrics = {
        'raid_fw_fault_count': summary_df[summary_df['category'] == 'RAID_FW'].shape[0],
        'fscrypt_error_count': summary_df[summary_df['category'] == 'FSCRYPT_EXT4'].shape[0],
        'cifs_error_95_count': summary_df[summary_df['message'].str.contains('return code = -95', na=False)].shape[0],
        'cifs_error_101_count': summary_df[summary_df['message'].str.contains('return code = -101', na=False)].shape[0],
        'fwupd_fail_count': summary_df[summary_df['category'] == 'FWUPD'].shape[0],
        'smartd_mail_missing_count': summary_df[summary_df['category'] == 'SMARTD_NOTIFY'].shape[0],
        'sudo_auth_warn_count': summary_df[summary_df['category'] == 'SUDO_AUTH'].shape[0],
        'net_iface_missing_count': summary_df[summary_df['category'] == 'NET_IFACE_MISSING'].shape[0],
    }
    summary_report = pd.DataFrame([key_metrics]).T.reset_index()
    summary_report.columns = ['metric', 'value']
    summary_report.to_csv(f"{args.io_dir}/summary_last_days.csv", index=False)

    print("指標聚合完成。輸出文件已儲存至 " + args.io_dir)
    print("正規化方式: log(1 + count)")

if __name__ == '__main__':
    main()