# parse_journal.py
import argparse
import json
import re
from datetime import datetime, timezone
import pandas as pd
import pytz
import yaml

def load_config(config_path='rules.yaml'):
    """載入 YAML 配置文件"""
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        print(f"警告: 配置文件 '{config_path}' 未找到，將使用預設規則。")
        return {
            'categories': {
                'RAID_FW': ['megasas|megaraid_sas|FW in FAULT|storcli'],
                'FSCRYPT_EXT4': ['fscrypt', 'ext4_bio_write_folio'],
                'CIFS_SMB': ['CIFS: VFS', 'cifs_mount', 'Dialect not supported', 'return code = -95', 'return code = -101'],
                'FWUPD': ['Failed to start Refresh fwupd metadata'],
                'SMARTD_NOTIFY': ['smartd.*(10mail|/usr/bin/mail|mailutils)'],
                'NET_IFACE_MISSING': ['networkctl.*not found', 'docker0 not found', 'veth.*not found', 'br-.* not found'],
                'SUDO_AUTH': ['incorrect password', 'pam_unix.*auth'],
                'OTHER': ['.*']
            }
        }

def classify_message(message, categories):
    """根據規則對訊息進行分類"""
    for category, patterns in categories.items():
        for pattern in patterns:
            if re.search(pattern, message, re.IGNORECASE):
                return category
    return 'OTHER'

def parse_log_line(line, tz_offset_str):
    """
    解析單行日誌。
    範例: 2025-07-05T10:28:40+0900 jfcrh-strg kernel: megaraid_sas ...
    """
    # 正則表達式，用於解析日誌行
    # (timestamp) (host) (unit[pid]: | unit:) (message)
    log_pattern = re.compile(
        r'^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})'  # Timestamp
        r'(?P<tz>[\+\-]\d{4})\s+'                       # Timezone
        r'(?P<host>[\w\.-]+)\s+'                         # Host
        r'(?P<unit>[\w\.-]+)(?:\[(?P<pid>\d+)\])?:\s*' # Unit and optional PID
        r'(?P<message>.*)$'                               # Message
    )
    
    match = log_pattern.match(line)
    if not match:
        # 針對 kernel log 的特殊格式
        kernel_pattern = re.compile(
            r'^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\s*'
            r'(?P<tz>[\+\-]\d{4})\s+'
            r'(?P<host>[\w\.-]+)\s+'
            r'(?P<unit>kernel):\s*'
            r'(?P<message>.*)$'
        )
        match = kernel_pattern.match(line)

    if match:
        data = match.groupdict()
        
        # 處理時區
        try:
            local_dt = datetime.strptime(data['ts'] + data['tz'], '%Y-%m-%dT%H:%M:%S%z')
            utc_dt = local_dt.astimezone(timezone.utc)
        except ValueError:
            # 如果時區轉換失敗，退回到手動指定
            local_dt = datetime.strptime(data['ts'], '%Y-%m-%dT%H:%M:%S')
            source_tz = pytz.timezone(f'Etc/GMT{-int(tz_offset_str[:3])}')
            local_dt = source_tz.localize(local_dt)
            utc_dt = local_dt.astimezone(pytz.utc)

        return {
            'ts_utc': utc_dt.isoformat(),
            'ts_local': local_dt.isoformat(),
            'tz_offset': data['tz'],
            'host': data.get('host'),
            'unit': data.get('unit'),
            'pid': data.get('pid'),
            'message': data.get('message', '').strip(),
            'raw': line.strip(),
            'date': utc_dt.strftime('%Y-%m-%d'),
            'hour': utc_dt.hour,
            'weekday': utc_dt.strftime('%A'),
        }
    return None

def main():
    parser = argparse.ArgumentParser(description='解析 systemd journal 日誌文件。')
    parser.add_argument('logfile', help='要解析的日誌文件名')
    parser.add_argument('--tz', default='+0900', help='日誌的時區偏移, e.g., +0800')
    parser.add_argument('--rules', default='rules.yaml', help='分類規則的 YAML 配置文件')
    parser.add_argument('--output_dir', default='.', help='輸出目錄')
    args = parser.parse_args()

    config = load_config(args.rules)
    categories = config.get('categories', {})

    parsed_data = []
    skipped_count = 0
    boot_seq = 0
    last_log_entry = None
    repeat_count = 1

    try:
        with open(args.logfile, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    skipped_count += 1
                    continue

                if '-- Boot ' in line:
                    boot_seq += 1
                    continue

                log_entry = parse_log_line(line, args.tz)

                if not log_entry:
                    skipped_count += 1
                    continue
                
                log_entry['boot_seq'] = boot_seq
                log_entry['category'] = classify_message(log_entry['message'], categories)

                # 合併重複日誌
                if last_log_entry:
                    # 檢查時間戳(秒)、unit 和 message 前綴是否相同
                    is_same_ts = last_log_entry['ts_utc'][:19] == log_entry['ts_utc'][:19]
                    is_same_unit = last_log_entry['unit'] == log_entry['unit']
                    is_same_msg_prefix = last_log_entry['message'][:120] == log_entry['message'][:120]

                    if is_same_ts and is_same_unit and is_same_msg_prefix:
                        repeat_count += 1
                        continue
                    else:
                        last_log_entry['repeat_count'] = repeat_count
                        parsed_data.append(last_log_entry)
                        repeat_count = 1
                
                last_log_entry = log_entry

            # 添加最後一筆日誌
            if last_log_entry:
                last_log_entry['repeat_count'] = repeat_count
                parsed_data.append(last_log_entry)

    except FileNotFoundError:
        print(f"錯誤: 找不到日誌文件 '{args.logfile}'")
        return
    except Exception as e:
        print(f"處理文件時發生錯誤: {e}")
        return

    if not parsed_data:
        print("錯誤: 未能從日誌文件中解析出任何數據。請檢查文件格式與時區設定。")
        return

    # 輸出 parsed.jsonl
    jsonl_path = f"{args.output_dir}/parsed.jsonl"
    with open(jsonl_path, 'w', encoding='utf-8') as f:
        for entry in parsed_data:
            f.write(json.dumps(entry) + '\n')

    # 輸出 parsed.csv
    csv_path = f"{args.output_dir}/parsed.csv"
    df = pd.DataFrame(parsed_data)
    df.to_csv(csv_path, index=False, encoding='utf-8')

    print(f"解析完成。共處理 {len(parsed_data)} 筆日誌，跳過 {skipped_count} 行。")
    print(f"輸出文件: {jsonl_path}, {csv_path}")

if __name__ == '__main__':
    main()