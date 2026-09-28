#!/bin/sh
# ============================================================
# 一键验收脚本（在本机运行，通过 SSH 查路由器）
#
# 用法:
#   ./verify.sh                       # 用默认值
#   ROUTER_IP=192.168.1.1 ./verify.sh
#   SSH_KEY=~/.ssh/mykey ./verify.sh
#
# 输出: 逐项 PASS / FAIL / WARN，并给出通过率
# ============================================================

ROUTER_IP="${ROUTER_IP:-192.168.123.1}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_USER="${SSH_USER:-admin}"
WAN_IF="${WAN_IF:-eth3}"
NVRAM="${NVRAM:-/usr/sbin/nvram}"

SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes $SSH_USER@$ROUTER_IP"

pass=0; fail=0; warn=0

chk() { # chk <名称> <实际值> <期望值>
    if [ "$2" = "$3" ]; then
        printf '  [PASS] %-28s = %s\n' "$1" "$2"; pass=$((pass+1))
    else
        printf '  [FAIL] %-28s = %s  (期望 %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

echo "=============================================="
echo " 路由器验收检查: $SSH_USER@$ROUTER_IP"
echo "=============================================="

echo
echo "── 1. 连通性 ─────────────────────────────────"
if ! $SSH "echo ok" < /dev/null >/dev/null 2>&1; then
    echo "  [FAIL] 无法 SSH 登录，后续检查无法进行"
    echo
    echo "  请检查: ROUTER_IP / SSH_KEY / SSH 服务是否开启"
    exit 1
fi
echo "  [PASS] SSH 登录成功"; pass=$((pass+1))

echo
echo "── 2. ★ 硬件卸载（核心）───────────────────────"
chk "hw_nat_mode" "$($SSH "$NVRAM get hw_nat_mode" < /dev/null)" "0"
chk "sfe_enable"  "$($SSH "$NVRAM get sfe_enable"  < /dev/null)" "0"

flow=$($SSH "grep -iE 'flow offload' /tmp/syslog.log | grep -oE '(ON|OFF)\$' | tail -1" < /dev/null)
chk "IPv4 UDP flow offload" "$flow" "OFF"

echo
echo "── 3. MTU / MSS ──────────────────────────────"
mtu=$($SSH "ip link show $WAN_IF | head -1 | grep -oE 'mtu [0-9]+' | awk '{print \$2}'" < /dev/null)
if [ -n "$mtu" ] && [ "$mtu" -lt 1500 ] 2>/dev/null; then
    printf '  [PASS] %-28s = %s (已下调)\n' "$WAN_IF mtu" "$mtu"; pass=$((pass+1))
elif [ "$mtu" = "1500" ]; then
    printf '  [WARN] %-28s = 1500 (未做 MTU 优化)\n' "$WAN_IF mtu"; warn=$((warn+1))
else
    printf '  [WARN] %-28s = %s\n' "$WAN_IF mtu" "${mtu:-读取失败}"; warn=$((warn+1))
fi

mss=$($SSH "iptables -t mangle -L FORWARD -n -v | grep -i tcpmss | awk '{print \$1}'" < /dev/null)
if [ -n "$mss" ]; then
    if [ "$mss" -gt 0 ] 2>/dev/null; then
        printf '  [PASS] %-28s = %s 包已钳制\n' "MSS 规则命中数" "$mss"; pass=$((pass+1))
    else
        printf '  [WARN] %-28s 规则存在但计数为 0\n' "MSS 规则"; warn=$((warn+1))
    fi
else
    printf '  [WARN] %-28s 规则不存在\n' "MSS 钳制"; warn=$((warn+1))
fi

echo
echo "── 4. DNS ────────────────────────────────────"
pid=$($SSH "pidof dnsmasq" < /dev/null)
if [ -n "$pid" ]; then
    printf '  [PASS] %-28s = %s\n' "dnsmasq pid" "$pid"; pass=$((pass+1))
else
    printf '  [FAIL] %-28s 未运行！\n' "dnsmasq"; fail=$((fail+1))
fi

echo
echo "── 5. 无线 ───────────────────────────────────"
for i in ra0 rax0; do
    c=$($SSH "iwconfig $i 2>/dev/null | grep -oE 'Channel=[0-9]+' | head -1" < /dev/null)
    if [ -n "$c" ]; then
        printf '  [PASS] %-28s = %s\n' "$i $c" "$c"; pass=$((pass+1))
    else
        printf '  [WARN] %-28s 读取失败（接口名可能不同）\n' "$i"; warn=$((warn+1))
    fi
done

echo
echo "── 6. 系统负载 ───────────────────────────────"
$SSH "uptime" < /dev/null | sed 's/^/  /'

echo
echo "=============================================="
printf ' 结果: PASS=%d  FAIL=%d  WARN=%d\n' "$pass" "$fail" "$warn"
if [ "$fail" -eq 0 ]; then
    echo " 状态: 核心检查全部通过"
else
    echo " 状态: 存在 $fail 项未通过，请检查上方 [FAIL]"
fi
echo "=============================================="
echo
echo "提示: WARN 项多为可选优化，不影响核心可用性。"
echo "      FAIL 项需处理，详见 docs/06-hardware-offload-fix.md"
exit "$fail"
