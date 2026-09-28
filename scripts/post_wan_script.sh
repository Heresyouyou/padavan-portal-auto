#!/bin/sh
# ============================================================
# Padavan WAN 上行后调优钩子
# 放置路径: /etc/storage/post_wan_script.sh
# 部署后必须执行: /sbin/mtd_storage.sh save
# 说明: rc 会在 WAN 拿到 IP 后调用本脚本
#
# ⚠️ 使用前请先实测真实路径 MTU，再修改下面的 MTU / MSS 数值!
#     路径MTU = ping -D -s <N> 能稳定通过的最大 N + 28
#     MSS     = 路径MTU - 40
#
# 本脚本实测参数: 路径MTU=1492 → MSS=1452
# ============================================================

WAN_IF="eth3"          # ← 按实际 WAN 接口名修改
MTU_VALUE="1492"       # ← 按实测路径 MTU 修改
MSS_VALUE="1452"       # ← 必须 = MTU_VALUE - 40

# ① 下调 WAN 接口 MTU
ip link set "$WAN_IF" mtu "$MTU_VALUE" 2>/dev/null

# ② MSS 钳制（先删后加，保证幂等 —— 脚本可能被多次调用）
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$MSS_VALUE"

exit 0
