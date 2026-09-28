# 03 · 校园网 Portal 自动认证

> 本章以**锐捷 ePortal** 为原型。多数高校 Portal 流程同构，替换端点与参数即可复用。
> **本章不含真实凭据**，所有敏感值均为占位符。

## 1. 先判断你的校园网用哪种认证

| 场景 | 认证方式 | 本手册支持 |
|---|---|---|
| 宿舍区有线 / 自助 WiFi | **Portal 网页认证**（锐捷 ePortal） | ✅ 脚本 + 守护 |
| 教学区 WiFi（如 `XXX-Auto`） | 802.1X（PEAP + MSCHAPv2） | ❌ Padavan 不支持 |
| 锐捷客户端认证 | MentoHUST（锐捷私有协议） | ⚠️ 视服务端是否部署 |

**判断方法**：不认证直接访问 `http://<任意外网站点>`，若被重定向到一个登录页 → Portal。
若浏览器弹出「输入用户名密码」的系统级弹窗 → 802.1X。

## 2. 方案 A：MentoHUST（优先尝试，配置最简单）

```
扩展功能 → MentoHUST
├── ✅ 启用 MentoHUST
├── 网卡接口：WAN 口（不要选 br0）
├── 认证模式：锐捷 v2（不行换 v3）
├── 用户名：<YOUR_STUDENT_ID>
├── 密码：<YOUR_PASSWORD>
├── MAC 地址：自动获取，或按需克隆
├── 客户端版本：4.96（较通用）
├── 心跳间隔：15 秒
├── 守护进程：✅ 勾（掉线自动重连）
├── ❌ 关闭「超级转发」（★ 与 MentoHUST 冲突，必关）
└── ✅ 开机自启
```

**验证**：应用后等 30 秒 → 状态页显示「认证成功」且能上网。

> ⚠️ **MentoHUST 与「超级转发」冲突**，两者同开会互相干扰导致认证反复掉线。

不行 → 用方案 B。

## 3. 方案 B：Portal 脚本 + 守护（最稳，推荐）

优点：对外只是普通 HTTP，特征最小，不怕防检测。

### 3.1 需要向学校/抓包获取的信息

| 变量 | 说明 | 获取方式 |
|---|---|---|
| `AUTH_HOST` | Portal 服务器地址 | 被重定向后看浏览器地址栏 |
| `LOGIN_PATH` | 登录页路径，如 `/zportal/loginForWeb` | 同上 |
| `SUBMIT_PATH` | 表单提交路径，如 `/zportal/login/do` | 看登录页 `<form action>` |
| `USER` / `PASS` | 校园网账号密码 | 学校提供 |
| `SERVICE_ID` | 计费/服务类型 ID | 登录页 form 里的隐藏字段 |
| `DNS1` / `DNS2` | 校内 DNS | WAN 状态页或 DHCP 下发 |
| `PROBE_URL` | 探测外网可达性的 URL | 自选，建议校内可达的 http 资源 |

### 3.2 认证流程（脚本核心逻辑）

```
每 60 秒循环：
  1. 探测外网
     curl -o resp -w "%{http_code}" --connect-timeout 5 --max-time 10 "$PROBE_URL"
  2. HTTP=000（连不上）→ WAN 未就绪，等 20 秒，continue
  3. 检查响应体是否含 Portal 特征串（如 "zportal"）
        ├── 不含 → ✅ 已认证，continue
        └── 含   → 🔐 被拦截，进入认证
  4. 拿动态参数（关键：这些参数每次会话都不同）
     ├── 优先：从 302 的 Location 头解析（wlanuserip / wlanacname / mac / nasip ...）
     └── 兜底：抓登录页 HTML 用正则提取隐藏字段
  5. POST 到 $SUBMIT_PATH 提交认证
  6. 校验响应含成功标志（如 "result":"success"）
        ├── 成功 → 记日志，continue
        └── 失败 → 记日志，下轮重试
```

### 3.3 必须处理的两个坑

1. **响应体可能是 gzip**
   探测响应先尝试解压，失败再当纯文本处理：
   ```sh
   gunzip -c resp.bin > resp.txt 2>/dev/null || cp resp.bin resp.txt
   ```

2. **302 重定向与 200 页面两种拦截形态都要判**
   ```sh
   # 同时检查 Location 头 与 响应体关键字
   ```
   只判一种会漏掉部分场景。

3. **User-Agent 必须伪装成常见浏览器**，否则可能被拒：
   ```
   Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/142.0.7444.235 Safari/537.36
   ```

### 3.4 部署

脚本模板见 [../scripts/portal-auth.sh.template](../scripts/portal-auth.sh.template)。

```sh
# 1) 填入自己的凭据（不要提交到 git）
cp scripts/portal-auth.sh.template /tmp/portal-auth.sh
vi /tmp/portal-auth.sh

# 2) 上传到路由器持久区
scp /tmp/portal-auth.sh admin@192.168.123.1:/etc/storage/

# 3) SSH 登录后赋权 + 持久化
ssh admin@192.168.123.1 "chmod +x /etc/storage/portal-auth.sh; /sbin/mtd_storage.sh save" < /dev/null
```

### 3.5 开机自启（双保险）

**必须同时加在两个位置**，任一失效仍能认证：

1. `管理 → 自定义脚本 → 开机启动`
2. `管理 → 自定义脚本 → WAN 上行/下行启动后执行`

各加一行：

```sh
sleep 10 && /bin/sh /etc/storage/portal-auth.sh --guard &
```

`sleep 10` 用于等 DHCP 拿完 IP。

### 3.6 crontab 守护（推荐）

Padavan 的 crontab 文件在 `/etc/storage/cron/crontabs/admin`：

```
* * * * * /bin/sh /etc/storage/portal-auth.sh
@reboot /bin/sh /etc/storage/setup.sh &
```

> **注意**：写入 crontab 后同样要 `mtd_storage.sh save` 持久化。

### 3.7 验证

```sh
# 看认证日志
ssh admin@192.168.123.1 "tail -30 /tmp/syslog.log" < /dev/null
# 预期每分钟出现一条，形如：
#   Portal: probe: HTTP=200
#   Portal: ✅ 已通 HTTP 200
```

## 4. 常见问题

| 问题 | 原因 | 解决 |
|---|---|---|
| 认证服务器无响应 | 该校区未部署锐捷 | 改用 Portal 脚本方案 |
| 认证成功但上不了网 | DHCP 冲突 / IP 未刷新 | 重插 WAN 或重启 WAN |
| 脚本报参数为空 | WAN 还没拿到 IP | 脚本内加 `sleep` 等 DHCP 稳定 |
| 认证状态每隔几分钟掉一次 | 双保险只配了一处 / 守护没起 | 检查两个自启位置 + crontab |
| 部署后一段时间没人救 | 纯软件守护也可能挂 | ★ 加**智能插座**，远程断电重启 |

> **智能插座是最实在的兜底**：守护进程挂了、路由器假死，都能远程一键断电恢复。
