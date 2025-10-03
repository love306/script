# plot_reports.py
import argparse
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import seaborn as sns
import yaml
import os
from datetime import datetime, timedelta

def load_config(config_path='rules.yaml'):
    print("Loading config...")
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        return {}

def plot_daily_stacked_events(df, order, palette, output_dir):
    print("Plotting daily stacked events...")
    if df.empty:
        return
    pivot_df = df.pivot(index='date', columns='category', values='count').fillna(0)
    for col in order:
        if col not in pivot_df.columns:
            pivot_df[col] = 0
    pivot_df = pivot_df[order]

    plt.style.use('seaborn-v0_8-whitegrid')
    fig, ax = plt.subplots(figsize=(16, 8))
    pivot_df.plot(kind='bar', stacked=True, ax=ax, colormap=palette)
    
    ax.set_title('Daily Event Counts by Category', fontsize=18)
    ax.set_xlabel('Date', fontsize=12)
    ax.set_ylabel('Event Count', fontsize=12)
    ax.tick_params(axis='x', labelrotation=45)
    ax.legend(title='Category', bbox_to_anchor=(1.02, 1), loc='upper left')
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'events_daily_stacked.png'))
    plt.close(fig)

def plot_hourly_heatmap(df, order, palette, output_dir):
    print("Plotting hourly heatmap...")
    if df.empty:
        return
    pivot_df = df.pivot_table(index='category', columns='hour', values='count', aggfunc='sum').fillna(0)
    pivot_df = pivot_df.reindex(order).dropna()

    plt.style.use('default')
    fig, ax = plt.subplots(figsize=(16, 8))
    sns.heatmap(pivot_df, cmap=palette or 'rocket_r', annot=True, fmt='.0f', linewidths=.5, ax=ax)
    
    ax.set_title('Hourly Event Heatmap', fontsize=18)
    ax.set_xlabel('Hour of Day (UTC)', fontsize=12)
    ax.set_ylabel('Category', fontsize=12)
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'events_hourly_heatmap.png'))
    plt.close(fig)

def plot_cifs_error_breakdown(df, output_dir):
    print("Plotting CIFS error breakdown...")
    cifs_df = df[df['category'] == 'CIFS_SMB'].copy()
    if cifs_df.empty:
        return

    cifs_df['error_type'] = 'OTHER_CIFS'
    cifs_df.loc[cifs_df['message'].str.contains('return code = -95'), 'error_type'] = '-95 (Dialect)'
    cifs_df.loc[cifs_df['message'].str.contains('return code = -101'), 'error_type'] = '-101 (Network)'

    daily_breakdown = cifs_df.groupby(['date', 'error_type']).size().unstack(fill_value=0)

    fig, ax = plt.subplots(figsize=(12, 7))
    daily_breakdown.plot(kind='bar', stacked=True, ax=ax, colormap='coolwarm')
    ax.set_title('CIFS Error Breakdown (-95 vs -101)', fontsize=16)
    ax.set_xlabel('Date')
    ax.set_ylabel('Count')
    ax.tick_params(axis='x', labelrotation=45)
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'cifs_error_breakdown.png'))
    plt.close(fig)

def plot_critical_timeline(df, output_dir):
    print("Plotting critical timeline...")
    critical_df = df[df['category'].isin(['RAID_FW', 'FSCRYPT_EXT4'])].copy()
    if critical_df.empty:
        return

    critical_df['ts_utc'] = pd.to_datetime(critical_df['ts_utc'])
    
    fig, ax = plt.subplots(figsize=(16, 6))
    colors = {'RAID_FW': 'red', 'FSCRYPT_EXT4': 'orange'}
    
    for category, color in colors.items():
        cat_df = critical_df[critical_df['category'] == category]
        if not cat_df.empty:
            ax.plot(cat_df['ts_utc'], [category]*len(cat_df), 'o', color=color, label=category, markersize=8)

    ax.set_title('Critical Events Timeline (RAID_FW, FSCRYPT_EXT4)', fontsize=16)
    ax.set_xlabel('Timestamp (UTC)')
    ax.set_ylabel('')
    ax.legend()
    ax.grid(axis='x', linestyle='--', alpha=0.7)
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'critical_timeline.png'))
    plt.close(fig)

def plot_top_messages_bar(df, output_dir):
    print("Plotting top messages bar...")
    if df.empty:
        return
    df = df.sort_values(by='count', ascending=True)
    
    fig, ax = plt.subplots(figsize=(12, 10))
    ax.barh(df.index.astype(str), df['count'], color='skyblue')
    ax.set_title(f'Top {len(df)} Messages', fontsize=16)
    ax.set_xlabel('Count')
    ax.set_ylabel('Message Prefix')
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'top_messages_bar.png'))
    plt.close(fig)

def plot_health_score(df, parsed_df, output_dir):
    print("Plotting health score...")
    if df.empty:
        return
    df['date'] = pd.to_datetime(df['date'])
    df = df.sort_values(by='date')

    parsed_df['date'] = pd.to_datetime(parsed_df['date'])
    boot_dates = parsed_df.groupby('boot_seq')['date'].min().unique()

    fig, ax = plt.subplots(figsize=(16, 6))
    ax.plot(df['date'], df['health_score'], marker='o', linestyle='-', color='#2E86C1')
    ax.set_title('Daily Health Score (0-100)', fontsize=18)
    ax.set_xlabel('Date')
    ax.set_ylabel('Score')
    ax.set_ylim(0, 105)
    ax.grid(True, which='both', linestyle='--', linewidth=0.5)

    for boot_date in boot_dates:
        ax.axvline(x=boot_date, color='#E74C3C', linestyle='--', linewidth=1, label='Boot')
    
    handles, labels = ax.get_legend_handles_labels()
    by_label = dict(zip(labels, handles))
    if by_label:
        ax.legend(by_label.values(), by_label.keys())

    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'health_score.png'))
    plt.close(fig)

def generate_report(summary_df, window_days, parsed_df, output_dir):
    print("Generating dynamic report...")
    report_parts = []
    report_parts.append("# Log Analysis Report")
    report_parts.append(f"Report generated on: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}")

    report_parts.append(f"## 1. Summary (Last {window_days} Days)")
    if summary_df.empty:
        report_parts.append("No data available for the last {window_days} days.")
    else:
        report_parts.append(summary_df.to_markdown(index=False))

    report_parts.append("## 2. Key Observations & Interpretations")
    
    # Interpretation for RAID_FW
    raid_events = parsed_df[parsed_df['category'] == 'RAID_FW']
    if not raid_events.empty:
        report_parts.append("### RAID/FW: Critical Hardware Alert")
        report_parts.append("- **What was observed**: The log contains entries related to RAID controller firmware entering a 'FAULT' state.")
        raid_dates = raid_events['date'].value_counts().sort_index()
        date_summary = ", ".join([f"{date.strftime('%Y-%m-%d')} ({count} time(s))" for date, count in raid_dates.items()])
        report_parts.append(f"  - **Occurrences**: Detected on the following dates: {date_summary}.")
        report_parts.append("- **Interpretation**: This is a **critical** alert. A RAID firmware fault can lead to storage performance degradation, data corruption, or complete data loss. It requires immediate investigation.")
        report_parts.append("- **Where to look**: Review the `critical_timeline.png` to see the exact time of each fault. The `health_score.png` should also show a significant drop on these dates due to the high weight of this category.")

    # Interpretation for FSCRYPT_EXT4
    fscrypt_events = parsed_df[parsed_df['category'] == 'FSCRYPT_EXT4']
    if not fscrypt_events.empty:
        report_parts.append("### FSCRYPT/EXT4: Filesystem Errors")
        report_parts.append("- **What was observed**: Multiple filesystem encryption/decryption errors (`ret = -22`) were logged.")
        peak_hour = fscrypt_events['hour'].mode()[0]
        report_parts.append(f"  - **Pattern**: These errors appear frequently and peak around **{peak_hour}:00 UTC**, suggesting a potential link to scheduled tasks.")
        report_parts.append("- **Interpretation**: These errors indicate a problem at the filesystem level. The `-22` error code (EINVAL) suggests that an invalid argument was provided to a system call. This could be due to a kernel bug, an issue with the underlying storage, or an incorrect encryption policy.")
        report_parts.append("- **Where to look**: The `events_hourly_heatmap.png` shows the concentration of these errors during specific hours. The `top_messages_bar.png` lists the most common fscrypt error messages.")

    # Interpretation for CIFS_SMB
    cifs_df = parsed_df[parsed_df['category'] == 'CIFS_SMB']
    if not cifs_df.empty:
        cifs_95_count = cifs_df[cifs_df['message'].str.contains('return code = -95', na=False)].shape[0]
        cifs_101_count = cifs_df[cifs_df['message'].str.contains('return code = -101', na=False)].shape[0]
        if cifs_95_count > 0 or cifs_101_count > 0:
            report_parts.append("### CIFS/SMB: Network Share Connectivity Issues")
            report_parts.append("- **What was observed**: The system logged errors while trying to connect to CIFS/SMB network shares.")
            if cifs_95_count > 0:
                report_parts.append(f"  - **Type 1**: {cifs_95_count} errors with code `-95` (Operation not supported). This points to a **protocol dialect mismatch** between the client and the server. The client might be trying to use a newer SMB version that the server doesn't support.")
            if cifs_101_count > 0:
                report_parts.append(f"  - **Type 2**: {cifs_101_count} errors with code `-101` (Network is unreachable). This indicates a **network connectivity problem**. The client could not reach the server at the network level.")
            report_parts.append("- **Interpretation**: These two error types point to different root causes. The `-95` errors require configuration changes (e.g., specifying `vers=2.0` in mount options), while the `-101` errors suggest network infrastructure problems (e.g., firewall, routing, or the server being offline).")
            report_parts.append("- **Where to look**: The `cifs_error_breakdown.png` chart visualizes the daily distribution of these two error types.")

    # Interpretation for SMARTD_NOTIFY
    smartd_events = parsed_df[parsed_df['category'] == 'SMARTD_NOTIFY']
    if not smartd_events.empty:
        report_parts.append("### SMARTD Notify: Informational Noise")
        report_parts.append("- **What was observed**: The `smartd` service, which monitors disk health, is continuously failing to send email notifications.")
        report_parts.append("- **Interpretation**: This is a **low-risk, informational** issue. It does **not** indicate a problem with the disks themselves. The monitoring is active, but the notification mechanism is broken because the `mailutils` package is not installed. This creates a lot of noise in the logs.")
        report_parts.append("- **Recommendation**: To fix the notifications, install the required package (`sudo apt install mailutils`). If email notifications are not needed, this alert can be safely ignored or the `smartd` configuration can be adjusted to disable mail.")

    # Interpretation for other categories
    fwupd_events = parsed_df[parsed_df['category'] == 'FWUPD']
    if not fwupd_events.empty:
        report_parts.append("### FWUPD: Low-Risk Service Failure")
        report_parts.append("- **What was observed**: The `fwupd` service (firmware update daemon) failed to start or refresh its metadata frequently.")
        report_parts.append("- **Interpretation**: In environments without consistent internet access or specific hardware, this service often fails. It is generally considered a **low-risk** issue and can be safely ignored or the service can be disabled (`sudo systemctl disable fwupd.service`) to reduce log noise.")

    net_events = parsed_df[parsed_df['category'] == 'NET_IFACE_MISSING']
    if not net_events.empty:
        report_parts.append("### Network Interfaces: Informational")
        report_parts.append("- **What was observed**: `networkctl` reported that various virtual interfaces (`veth*`, `docker0`, etc.) were not found.")
        report_parts.append("- **Interpretation**: This is common in systems running containers (like Docker). These messages are typically generated during the startup or shutdown of containers and are **not a cause for concern** unless they are associated with a specific application failure.")

    sudo_events = parsed_df[parsed_df['category'] == 'SUDO_AUTH']
    if not sudo_events.empty:
        report_parts.append("### SUDO Authentication: Security Note")
        report_parts.append("- **What was observed**: Multiple failed `sudo` password attempts were logged.")
        report_parts.append("- **Interpretation**: This is a security-relevant event. While it could be due to user typos, repeated failures from unexpected sources or at odd hours may indicate an unauthorized access attempt. It is recommended to review the source TTY and user from the log messages.")
        report_parts.append("- **Where to look**: The `top_messages.csv` file provides more context for each of these messages, including the user and command.")

    report_parts.append("\n## 3. Visualizations")
    report_parts.append("### Daily Health Score")
    report_parts.append("![Daily Health Score](health_score.png)")
    report_parts.append("### Daily Event Volume (Stacked)")
    report_parts.append("![Daily Events](events_daily_stacked.png)")
    report_parts.append("### Hourly Event Heatmap")
    report_parts.append("![Hourly Heatmap](events_hourly_heatmap.png)")
    report_parts.append("### Critical Events Timeline")
    report_parts.append("![Critical Timeline](critical_timeline.png)")
    report_parts.append("### CIFS Error Breakdown")
    report_parts.append("![CIFS Breakdown](cifs_error_breakdown.png)")
    report_parts.append("### Top Messages")
    report_parts.append("![Top Messages](top_messages_bar.png)")

    with open(os.path.join(output_dir, 'report.md'), 'w', encoding='utf-8') as f:
        f.write('\n\n'.join(report_parts))

def main():
    print("Starting plot_reports.py...")
    parser = argparse.ArgumentParser(description='從聚合指標產生圖表與報告。')
    parser.add_argument('--rules', default='rules.yaml', help='YAML 配置文件路徑')
    parser.add_argument('--window-days', type=int, default=7, help='報告摘要天數')
    parser.add_argument('--io_dir', default='.', help='輸入與輸出目錄')
    args = parser.parse_args()

    print(f"I/O directory: {args.io_dir}")
    config = load_config(args.rules)
    heatmap_order = config.get('heatmap_order', [])
    heatmap_palette = config.get('heatmap_palette')

    try:
        print("Loading CSV files...")
        metrics_daily_df = pd.read_csv(os.path.join(args.io_dir, 'metrics_daily.csv'))
        metrics_hourly_df = pd.read_csv(os.path.join(args.io_dir, 'metrics_hourly.csv'))
        top_messages_df = pd.read_csv(os.path.join(args.io_dir, 'top_messages.csv'), index_col=0)
        health_score_df = pd.read_csv(os.path.join(args.io_dir, 'health_score.csv'))
        summary_df = pd.read_csv(os.path.join(args.io_dir, 'summary_last_days.csv'))
        parsed_df = pd.read_csv(os.path.join(args.io_dir, 'parsed.csv'), low_memory=False)
        print("CSV files loaded successfully.")
    except FileNotFoundError as e:
        print(f"錯誤: 找不到輸入文件 {e.filename}。請先執行 aggregate_metrics.py。")
        return

    if not heatmap_order:
        heatmap_order = metrics_daily_df.groupby('category')['count'].sum().sort_values(ascending=False).index.tolist()

    plot_daily_stacked_events(metrics_daily_df, heatmap_order, heatmap_palette, args.io_dir)
    plot_hourly_heatmap(metrics_hourly_df, heatmap_order, heatmap_palette, args.io_dir)
    plot_cifs_error_breakdown(parsed_df, args.io_dir)
    plot_critical_timeline(parsed_df, args.io_dir)
    plot_top_messages_bar(top_messages_df, args.io_dir)
    plot_health_score(health_score_df, parsed_df, args.io_dir)

    generate_report(summary_df, args.window_days, parsed_df, args.io_dir)

    print("圖表與報告產生完成。")
    print(f"- 檔案已儲存至: {args.io_dir}/")

if __name__ == '__main__':
    main()