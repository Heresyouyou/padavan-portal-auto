#!/bin/sh
# 一键恢复 2026-10-02-good 验证配置
# 注意：本快照的 started_script.sh 已脱敏（账号/密码为占位符），
#       恢复后必须手工填回你的校园网账号密码，否则 Portal 认证会失败。
export PATH=$PATH:/usr/sbin:/sbin:/usr/bin
V=/etc/storage/snapshots/2026-10-02-good
[ -d "$V" ] || { echo "快照目录不存在"; exit 1; }

# 覆盖前先备份现有钩子
[ -f /etc/storage/started_script.sh ] && cp -f /etc/storage/started_script.sh /etc/storage/started_script.sh.prebak
cp -f "$V/started_script.sh" /etc/storage/started_script.sh
chmod +x /etc/storage/started_script.sh
[ -f "$V/dnsmasq.conf" ] && cp -f "$V/dnsmasq.conf" /etc/storage/dnsmasq/dnsmasq.conf

while read -r line; do
  case "$line" in ''|'#'*) continue ;; *=*) k=${line%%=*}; v=${line#*=}; nvram set "$k" "$v" ;; esac
done < "$V/nvram-keys.txt"

nvram commit
mtd_storage.sh save
echo "已恢复 2026-10-02-good。"
echo "★ 请编辑 /etc/storage/started_script.sh 填回校园网账号密码（USER / PASS），然后重启路由器。"
