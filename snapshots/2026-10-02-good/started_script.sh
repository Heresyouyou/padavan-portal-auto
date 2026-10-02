#!/bin/sh
cat > /etc/storage/kmust_auth.sh << 'K1'
#!/bin/sh
AUTH="http://222.197.192.59:9090"
USER="<你的校园网账号/学号>"
PASS="<你的校园网密码>"
SID="e25d67dd0cc84693905d8ce564f3ac03"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/142.0.7444.235 Safari/537.36"
PROBE="http://www.baidu.com/favicon.ico"
LOGF="/tmp/k_auth.log"
HARD_URL="<认证登录页完整链接，含本次会话参数；留空则脚本运行时自动抓取>"

log() { echo "[$(date '+%H:%M:%S')] $*" >> $LOGF; logger -t Kmust "$*"; }

log "v6 start"

# Step 1: 探测外网
STATUS=$(curl -s -o /tmp/k_resp.bin -w "%{http_code}" --connect-timeout 5 --max-time 10 --max-redirs 0 -H "User-Agent: $UA" "$PROBE" 2>/dev/null)
log "probe: HTTP=$STATUS"

if [ -z "$STATUS" ] || [ "$STATUS" = "000" ]; then
  log "WAN未就绪"; sleep 20; exit 0
fi

# Step 2: 解压响应体
if ! gunzip -c /tmp/k_resp.bin > /tmp/k_resp.txt 2>/dev/null; then
  cp /tmp/k_resp.bin /tmp/k_resp.txt
fi

# Step 3: 检查是否被Portal拦截
if grep -qi "zportal" /tmp/k_resp.txt 2>/dev/null; then
  log "🔐 Portal拦截"
else
  log "✅ 已通HTTP $STATUS"
  rm -f /tmp/k_resp.bin /tmp/k_resp.txt
  exit 0
fi

# Step 4: 尝试从拦截页面提取Portal URL（busybox兼容）
PORTAL_URL=""
# 方法1: 直接匹配完整URL
PORTAL_URL=$(grep -oiE "loginForWeb\?[a-zA-Z0-9=&%_-]+" /tmp/k_resp.txt 2>/dev/null | head -1)
if [ -n "$PORTAL_URL" ]; then
  PORTAL_URL="http://222.197.192.59:9090/zportal/$PORTAL_URL"
fi
K1
cat >> /etc/storage/kmust_auth.sh << 'K2'
log "grep提取: ${PORTAL_URL:0:100}"

# 把拦截页面存日志供调试
echo "=== 拦截HTML ===" >> $LOGF
cat /tmp/k_resp.txt >> $LOGF
echo "" >> $LOGF

if [ -z "$PORTAL_URL" ]; then
  PORTAL_URL="$HARD_URL"
  log "硬编码兜底"
fi

log "使用URL: ${PORTAL_URL:0:100}"

# Step 5: 解析参数
qval() { echo "$PORTAL_URL" | grep -oE "$1=[^&]*" | cut -d= -f2; }
WIP=$(qval wlanuserip)
WAC=$(qval wlanacname)
NAS=$(qval nasip)
MAC=$(qval mac)
URL_P=$(qval url)
T=$(qval t)
[ -z "$T" ] && T="wireless-v2"
log "参数: WIP=$WIP T=$T"

# Step 6: POST认证
PURL="$AUTH/zportal/login/do"
BODY="qrCodeId=%E8%AF%B7%E8%BE%93%E5%85%A5%E7%BC%96%E5%8F%B7&username=$USER&pwd=$PASS&validCode=%E9%AA%8C%E8%AF%81%E7%A0%81&validCodeFlag=false&serviceId=$SID&ssid=&mac=$MAC&t=$T&wlanacname=$WAC&url=$URL_P&nasip=$NAS&wlanuserip=$WIP"

RESP=$(curl -s --connect-timeout 5 --max-time 15 -X POST -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" -H "User-Agent: $UA" -H "Accept: */*" -H "X-Requested-With: XMLHttpRequest" -H "Origin: $AUTH" -H "Referer: $PORTAL_URL" -H "Cache-Control: no-cache" -d "$BODY" "$PURL" 2>/dev/null)
log "POST: $RESP"

sleep 2

# Step 7: 验证
FINAL=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 --max-redirs 0 -H "User-Agent: $UA" "$PROBE" 2>/dev/null)
if [ "$FINAL" = "200" ]; then
  curl -s --connect-timeout 5 --max-time 10 -H "User-Agent: $UA" "$PROBE" 2>/dev/null | grep -qi "zportal" || { log "🎉 成功"; rm -f /tmp/k_*; exit 0; }
fi
log "⚠️ 失败 FINAL=$FINAL"
rm -f /tmp/k_*
exit 1

K2
chmod +x /etc/storage/kmust_auth.sh
logger -t Kmust "v6 deployed $(wc -c < /etc/storage/kmust_auth.sh) bytes"
# ---- WiFi 固化（一次性）：Padavan 不下发这些键，开机后强制下发一次 ----
(
  [ -f /tmp/wifi_fix.pid ] && kill -0 $(cat /tmp/wifi_fix.pid) 2>/dev/null && exit 0
  echo $$ > /tmp/wifi_fix.pid
  n=0
  while [ $n -lt 60 ]; do
    /bin/iwpriv ra0 stat >/dev/null 2>&1 && break
    n=$((n+1)); sleep 2
  done
  sleep 30
  for kv in TxPower=40 HtAutoBA=0 HtBaWinSize=0 ITxBfEn=0 ETxBfEnCond=0 PktAggregate=0 TxBurst=0 HtStbc=0 VhtStbc=0; do
    /bin/iwpriv ra0 set $kv 2>/dev/null
  done
  echo "$(date +%Y%m%d-%H:%M:%S) applied loop=$n lines=$(/bin/iwpriv ra0 stat 2>/dev/null | grep -c .)" >> /tmp/wifi_fix.log
) &
exit 0
