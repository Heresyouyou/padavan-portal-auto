#!/bin/sh
# ============================================================
#  portal-auth.sh — 锐捷 ePortal 校园网自动认证 / 断线守护
#  A Padavan (老毛子) plugin script.
#
#  适配固件: 老毛子 Padavan (BusyBox ash) / OpenWrt 亦可直接运行
#  依赖命令: curl  gunzip  logger  (Padavan 固件均自带)
#
#  ── 用法 ──────────────────────────────────────────────
#    portal-auth.sh            单次认证（crontab 每分钟调一次）
#    portal-auth.sh --guard    守护模式，每 GUARD_INTERVAL 秒检测一次
#    portal-auth.sh --show     打印当前生效配置（排障用，不显示密码）
#
#  ── 配置 ──────────────────────────────────────────────
#    外部配置（可选，可覆盖下列任何一项）:
#        /etc/storage/portal-auth.conf
#    模板见 templates/portal-auth.conf.example
#
#  ── 部署（Padavan）───────────────────────────────────
#    1) 填好凭据 → scp 到 /etc/storage/portal-auth.sh
#    2) chmod +x /etc/storage/portal-auth.sh
#    3) /sbin/mtd_storage.sh save            # 持久化，否则重启丢失
#    4) 开机自启（双保险，两处都要加）:
#         管理 → 自定义脚本 → 开机启动
#         管理 → 自定义脚本 → WAN 上行/下行启动后执行
#       各加一行:
#         sleep 10 && /bin/sh /etc/storage/portal-auth.sh --guard &
#    5) crontab 兜底 (/etc/storage/cron/crontabs/admin):
#         * * * * * /bin/sh /etc/storage/portal-auth.sh
#
#  其他学校请见 README「把认证网址交给 AI」一节。
# ============================================================

CONF_FILE="/etc/storage/portal-auth.conf"
LOG_FILE="/tmp/portal_auth.log"

PROFILE="kmust"                 # kmust = 昆明理工大学内置预设；other = 自行提供全部参数

# ── 1) 读取外部配置（可覆盖下面任何一项）──────────────
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
fi

# ── 2) 内置预设：昆明理工大学 ─────────────────────────
#    以下为昆工宿舍区锐捷 ePortal 的真实端点（仅账号/密码需自行填写）
if [ "$PROFILE" = "kmust" ]; then
    [ -z "$AUTH_HOST" ]     && AUTH_HOST="http://222.197.192.59:9090"
    [ -z "$LOGIN_PATH" ]    && LOGIN_PATH="/zportal/loginForWeb"
    [ -z "$SUBMIT_PATH" ]   && SUBMIT_PATH="/zportal/login/do"
    [ -z "$SERVICE_ID" ]    && SERVICE_ID="8687c29b51c1471f9a31eb34eeb7e187"  # 内网免费
    [ -z "$INTERCEPT_KEY" ] && INTERCEPT_KEY="zportal"
fi
#   ※ 昆工外网计费套餐的 SERVICE_ID 为 e25d67dd0cc84693905d8ce564f3ac03

# ── 3) 通用默认值 ─────────────────────────────────────
[ -z "$LOGIN_PATH" ]    && LOGIN_PATH="/zportal/loginForWeb"
[ -z "$SUBMIT_PATH" ]   && SUBMIT_PATH="/zportal/login/do"
[ -z "$INTERCEPT_KEY" ] && INTERCEPT_KEY="zportal"
[ -z "$SUCCESS_KEY" ]   && SUCCESS_KEY='"result":"success"'
[ -z "$PROBE_URL" ]     && PROBE_URL="http://www.baidu.com/favicon.ico"
[ -z "$GUARD_INTERVAL" ] && GUARD_INTERVAL=60
[ -z "$UA" ] && UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/142.0.7444.235 Safari/537.36"

# ── 4) 若已粘贴「认证登录页完整链接」，从它推导端点与参数 ──
#    ★ 这是适配其他学校最省事的方式：把浏览器地址栏那条完整链接粘进 CONF 的
#      PORTAL_LOGIN_URL 即可，无需手工拆解 wlanuserip / nasip 等参数名。
if [ -n "$PORTAL_LOGIN_URL" ]; then
    _rest="${PORTAL_LOGIN_URL#*://}"          # host:port/path?query
    _hostport="${_rest%%/*}"
    _pathqs="${_rest#*/}"
    _path="${_pathqs%%\?*}"                   # zportal/loginForWeb
    _qs="$PORTAL_LOGIN_URL"
    case "$PORTAL_LOGIN_URL" in
        *\?*) _qs="${PORTAL_LOGIN_URL#*\?}" ;;   # 取 ? 之后的全部内容
        *)    _qs="" ;;
    esac
    [ -z "$AUTH_HOST" ] && AUTH_HOST="http://$_hostport"
    LOGIN_PATH="/$_path"
    FIXED_QS="$_qs"
fi

# ── 5) 校验必填项 ─────────────────────────────────────
case "$USER" in
    ""|"<"*) echo "ERROR: 未配置校园网账号 USER（见 $CONF_FILE）"; exit 2 ;;
esac
case "$PASS" in
    ""|"<"*) echo "ERROR: 未配置校园网密码 PASS（见 $CONF_FILE）"; exit 2 ;;
esac

# ── 日志 ──────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    logger -t Portal "$*"          # 同时进 syslog，方便 tail /tmp/syslog.log
}

TMP_BODY="/tmp/pa_resp.bin"
TMP_TEXT="/tmp/pa_resp.txt"

# ── 从拦截响应 / 登录页里取「认证登录页完整链接」 ──────
find_login_url() {
    # ① 已配置的完整链接优先
    if [ -n "$PORTAL_LOGIN_URL" ]; then
        echo "$PORTAL_LOGIN_URL"; return 0
    fi
    # ② 探测响应体里直接带完整链接
    _u=$(grep -oiE 'https?://[^"'"'"'<> ]*loginForWeb\?[^"'"'"'<> ]*' "$TMP_TEXT" 2>/dev/null | head -1)
    [ -n "$_u" ] && { echo "$_u"; return 0; }
    # ③ 相对路径形态：loginForWeb?xxx
    _u=$(grep -oiE 'loginForWeb\?[^"'"'"'<> ]*' "$TMP_TEXT" 2>/dev/null | head -1)
    [ -n "$_u" ] && { echo "$AUTH_HOST/$_u"; return 0; }
    # ④ 兜底：直接抓登录页
    curl -s --connect-timeout 5 --max-time 10 -H "User-Agent: $UA" \
        -o /tmp/pa_login.html "$AUTH_HOST$LOGIN_PATH" 2>/dev/null
    _u=$(grep -oiE 'https?://[^"'"'"'<> ]*loginForWeb\?[^"'"'"'<> ]*' /tmp/pa_login.html 2>/dev/null | head -1)
    [ -z "$_u" ] && _u=$(grep -oiE 'loginForWeb\?[^"'"'"'<> ]*' /tmp/pa_login.html 2>/dev/null | head -1)
    [ -n "$_u" ] && { echo "$_u"; return 0; }
    return 1
}

# ── 单次认证 ──────────────────────────────────────────
do_auth() {
    # Step 1: 探测外网是否可达
    STATUS=$(curl -s -o "$TMP_BODY" -D /tmp/pa_hdr.txt -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 --max-redirs 0 \
        -H "User-Agent: $UA" "$PROBE_URL" 2>/dev/null)

    if [ -z "$STATUS" ] || [ "$STATUS" = "000" ]; then
        log "probe WAN 未就绪 (HTTP=$STATUS)"
        return 1
    fi

    # Step 2: 解压响应体（可能被 gzip 压缩）
    if ! gunzip -c "$TMP_BODY" > "$TMP_TEXT" 2>/dev/null; then
        cp "$TMP_BODY" "$TMP_TEXT"
    fi

    # Step 3: 判断是否被 Portal 拦截（302 Location 与 200 页面两种形态都判）
    INTERCEPTED=0
    grep -qi "$INTERCEPT_KEY" "$TMP_TEXT" 2>/dev/null && INTERCEPTED=1
    grep -qi "$INTERCEPT_KEY" /tmp/pa_hdr.txt 2>/dev/null && INTERCEPTED=1
    [ "$STATUS" = "302" ] && INTERCEPTED=1

    if [ "$INTERCEPTED" = "0" ]; then
        log "OK 已认证，外网可达 (HTTP=$STATUS)"
        rm -f "$TMP_BODY" "$TMP_TEXT" /tmp/pa_hdr.txt
        return 0
    fi

    log "被 Portal 拦截 (HTTP=$STATUS)，开始认证"

    # Step 4: 取「认证登录页完整链接」→ 拆出查询串
    LOGIN_URL=$(find_login_url)
    if [ -z "$LOGIN_URL" ]; then
        log "ERR 未取到认证链接（WAN 可能尚未拿到 IP）"
        return 1
    fi

    QS="$FIXED_QS"
    if [ -z "$QS" ]; then
        case "$LOGIN_URL" in
            *\?*) QS="${LOGIN_URL#*\?}" ;;
        esac
    fi

    # 若完整链接指向另一台主机，以它为准
    case "$LOGIN_URL" in
        http://*/*|https://*/*)
            _h="${LOGIN_URL#*://}"; _h="${_h%%/*}"
            case "$LOGIN_URL" in
                https://*) [ "$_h" != "${AUTH_HOST#*://}" ] && AUTH_HOST="https://$_h" ;;
                *)         [ "$_h" != "${AUTH_HOST#*://}" ] && AUTH_HOST="http://$_h" ;;
            esac
            ;;
    esac

    SUBMIT_URL="$AUTH_HOST$SUBMIT_PATH"
    [ -n "$QS" ] && SUBMIT_URL="$SUBMIT_URL?$QS"

    log "submit 参数 ${#QS} 字节 → $SUBMIT_PATH"

    # Step 5: 提交认证
    curl -s --connect-timeout 5 --max-time 15 \
        -H "User-Agent: $UA" \
        -H "Referer: $LOGIN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "userId=$USER" \
        --data-urlencode "password=$PASS" \
        --data-urlencode "serviceId=$SERVICE_ID" \
        -o /tmp/pa_result.txt \
        "$SUBMIT_URL" 2>/dev/null

    # Step 6: 校验结果
    if grep -q "$SUCCESS_KEY" /tmp/pa_result.txt 2>/dev/null; then
        log "SUCCESS 认证成功"
        rm -f "$TMP_BODY" "$TMP_TEXT" /tmp/pa_hdr.txt /tmp/pa_login.html /tmp/pa_result.txt
        return 0
    fi

    log "FAIL 认证失败，下轮重试（原始返回见 /tmp/pa_result.txt）"
    return 1
}

# ── 打印生效配置（排障用，不打印密码）────────────────
show_conf() {
    echo "PROFILE      = $PROFILE"
    echo "AUTH_HOST    = $AUTH_HOST"
    echo "LOGIN_PATH   = $LOGIN_PATH"
    echo "SUBMIT_PATH  = $SUBMIT_PATH"
    echo "SERVICE_ID   = $SERVICE_ID"
    echo "PORTAL_LOGIN_URL = ${PORTAL_LOGIN_URL:-（未设置，将自动抓取）}"
    echo "PROBE_URL    = $PROBE_URL"
    echo "USER         = $USER"
    echo "PASS         = ${PASS:+已设置(长度 ${#PASS})}"
    echo "GUARD_INTERVAL = $GUARD_INTERVAL"
    echo "CONF_FILE    = $CONF_FILE $([ -f "$CONF_FILE" ] && echo '(已加载)' || echo '(不存在)')"
}

# ── 主流程 ────────────────────────────────────────────
case "$1" in
    --show)
        show_conf
        ;;
    --guard)
        log "guard 模式启动（每 ${GUARD_INTERVAL}s 检测一次）"
        while true; do
            do_auth
            sleep "$GUARD_INTERVAL"
        done
        ;;
    *)
        do_auth
        ;;
esac
