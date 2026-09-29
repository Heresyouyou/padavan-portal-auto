# 锐捷 ePortal 自动认证 —— 原理与适配详解

> 主脚本：[portal-auth.sh](../portal-auth.sh) ｜ 配置模板：[templates/portal-auth.conf.example](../templates/portal-auth.conf.example)
>
> 只想快点用起来？直接看 [README 的「把认证网址交给 AI」](../README.md#1-最快路径把认证网址交给-ai-)。
> 本文档解释**为什么这样做**，以及自动适配失败时怎么手工排。
>
> ⚠️ 本文不含任何真实凭据，所有账号/密码/MAC 均为占位符。

---

## 1. 先判断你的校园网用哪种认证

| 场景 | 认证方式 | 本插件支持 |
|---|---|---|
| 宿舍区有线 / 自助 WiFi | **Portal 网页认证**（锐捷 ePortal） | ✅ 就是本插件 |
| 教学区 WiFi（如 `XXX-Auto`） | 802.1X（PEAP + MSCHAPv2） | ❌ Padavan 不支持 |
| 锐捷客户端认证 | MentoHUST（锐捷私有协议） | ⚠️ 视服务端是否部署，见 §6 |

**判断方法**：不认证直接访问一个 `http://` 网站（如 `http://neverssl.com`）

- 被**重定向到一个登录网页** → Portal，本插件适用 ✅
- 浏览器弹出**系统级「输入用户名密码」弹窗** → 802.1X，本插件不适用 ❌

> 用 `http://` 而不是 `https://`：被 Portal 拦截时，HTTP 请求会直接返回登录页或 302，最容易被观察到。

---

## 2. 锐捷 ePortal 的认证流程

```
① 未认证时，任意 HTTP 请求被拦截
     └─ 形态 A：302 重定向，Location 指向认证登录页
       形态 B：200，但返回的是登录页 HTML（含 zportal 特征）

② 登录页地址形如：
     http://<host>:<port>/zportal/loginForWeb?wlanuserip=..&wlanacname=..&ssid=..&nasip=..&mac=..&t=..

③ 表单提交到：
     POST http://<host>:<port>/zportal/login/do?<上面那串同样的查询参数>
     body: userId=<账号>&password=<密码>&serviceId=<计费ID>

④ 返回 JSON，成功时含 "result":"success"
```

### 2.1 为什么查询参数必须带上

查询串是**服务端识别「你在给哪台设备认证」的唯一依据**，且**每次会话都不同**：

| 参数 | 含义 | 是否固定 |
|---|---|---|
| `wlanuserip` | 你的 WAN 口被分配的校园网 IP | ❌ 每次不同 |
| `mac` | 你的 WAN 口 MAC | ⚠️ 换设备/克隆时变 |
| `t` | 时间戳 | ❌ 每次不同 |
| `nasip` | 接入交换机地址 | ✅ 一般固定 |
| `wlanacname` | 接入控制器名 | ✅ 一般固定 |
| `ssid` | 无线名（有线时可能为空） | ✅ 一般固定 |

**所以参数不能写死，必须运行时抓取**，这就是 [§1 提示词](../README.md#1-最快路径把认证网址交给-ai-)里要求提供「完整链接」的原因——
只有拿到完整链接，才知道你这所学校**参数叫什么名字、有几个**（有的学校叫 `wlanuserip`，有的叫 `userip`）。

### 2.2 脚本怎么拿到这些参数

`portal-auth.sh` 按优先级取「认证登录页完整链接」：

```
① 配置里的 PORTAL_LOGIN_URL（你粘贴的那条）      ← 最稳，推荐
② 探测响应的 302 Location 头
③ 探测响应体里的 loginForWeb?... 链接
④ 直接 GET /zportal/loginForWeb，从返回的 HTML 里正则提取
```

拿到链接后，`?` 之后的全部内容会被原样带到提交请求上，同时自动修正端点主机与路径。
—— 这就是「粘一条链接就能适配多场景」的实现方式。

---

## 3. 配置项速查

配置文件 `/etc/storage/portal-auth.conf`（模板见 [templates/portal-auth.conf.example](../templates/portal-auth.conf.example)）：

| 变量 | 必填 | 说明 |
|---|---|---|
| `USER` / `PASS` | ✅ | 校园网账号 / 密码 |
| `PORTAL_LOGIN_URL` | 其他学校推荐 | 认证登录页**完整链接**（含 `?` 后参数） |
| `PROFILE` | — | `kmust`=昆明理工大学内置预设（默认）；`other`=自行提供 |
| `AUTH_HOST` | 其他学校 | 如 `http://10.10.10.10:8080` |
| `LOGIN_PATH` | 其他学校 | 默认 `/zportal/loginForWeb` |
| `SUBMIT_PATH` | 其他学校 | 默认 `/zportal/login/do`（多数学校就是把 `loginForWeb` 换成 `login/do`） |
| `SERVICE_ID` | ✅ | 计费/服务类型 ID，见 §4 |
| `INTERCEPT_KEY` | — | 被拦截时响应体特征串，默认 `zportal` |
| `SUCCESS_KEY` | — | 成功标志，默认 `"result":"success"` |
| `PROBE_URL` | — | 探测外网可达性，默认百度 favicon |
| `GUARD_INTERVAL` | — | 守护轮询秒数，默认 60 |

### 3.1 昆明理工大学内置预设

`PROFILE="kmust"`（默认值）时自动填入下表，**你只需要填账号密码**：

| 项 | 值 |
|---|---|
| `AUTH_HOST` | `http://222.197.192.59:9090` |
| `LOGIN_PATH` | `/zportal/loginForWeb` |
| `SUBMIT_PATH` | `/zportal/login/do` |
| `SERVICE_ID`（内网免费） | `8687c29b51c1471f9a31eb34eeb7e187` |
| `SERVICE_ID`（外网计费） | `e25d67dd0cc84693905d8ce564f3ac03` |
| 校内 DNS | `222.197.198.33` / `222.172.200.68` |

> 昆工不同校区的接入控制器可能不同，若认证失败，把浏览器里复制的完整链接填进 `PORTAL_LOGIN_URL` 即可，
> 它会覆盖上面的预设。

---

## 4. 怎么找 `SERVICE_ID`

`serviceId` 决定你要走「内网免费」还是「外网计费」套餐，通常**不出现在地址栏**，要找出来：

1. 浏览器打开认证登录页，按 `F12` → **Network** 面板
2. 正常输入账号密码点登录，抓那个 `login/do` 的 **POST 请求**
3. 看 **Payload / 表单数据**：`serviceId` 就在里面
4. 或者：登录页源码里搜 `serviceId`，常见于隐藏 `<input>` 或内联 JS 的套餐列表

拿到后填进 `portal-auth.conf`。

---

## 5. 必须处理的两个坑（脚本已内置）

1. **响应体可能是 gzip 压缩** —— 先尝试解压再判断特征串：
   ```sh
   gunzip -c resp.bin > resp.txt 2>/dev/null || cp resp.bin resp.txt
   ```
   直接 `grep` 压缩流会永远匹配不到 `zportal` → **误判为「已认证」而实际没认证**。

2. **302 与 200 两种拦截形态都要判** —— 只判一种会漏掉部分学校。
   脚本同时检查：`Location` 头、响应体特征串、状态码是否为 302。

3. **User-Agent 必须伪装成常见浏览器**，部分学校对空 UA / curl UA 直接拒绝：
   ```
   Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/142.0.7444.235 Safari/537.36
   ```

---

## 6. 备选方案：MentoHUST（仅在 Portal 不可用时尝试）

```
扩展功能 → MentoHUST
├── ✅ 启用 MentoHUST
├── 网卡接口：WAN 口（不要选 br0）
├── 认证模式：锐捷 v2（不行换 v3）
├── 用户名 / 密码：<YOUR_STUDENT_ID> / <YOUR_PASSWORD>
├── MAC 地址：自动获取，或按需克隆
├── 客户端版本：4.96（较通用）
├── 心跳间隔：15 秒
├── 守护进程：✅ 勾（掉线自动重连）
├── ❌ 关闭「超级转发」（★ 与 MentoHUST 冲突，必关）
└── ✅ 开机自启
```

> ⚠️ **MentoHUST 与「超级转发」冲突**，两者同开会互相干扰导致认证反复掉线。

MentoHUST 走锐捷私有协议，特征明显，被防共享检测针对的概率高于纯 HTTP 的 Portal 方案。
**Portal 脚本是本仓库推荐方案。**

---

## 7. 部署与自启

```sh
# 上传
scp portal-auth.sh admin@192.168.123.1:/etc/storage/
scp portal-auth.conf admin@192.168.123.1:/etc/storage/
ssh admin@192.168.123.1 "chmod +x /etc/storage/portal-auth.sh; /sbin/mtd_storage.sh save" < /dev/null
```

**开机自启（双保险，两处都要加）**：

1. 管理 → 自定义脚本 → **开机启动**
2. 管理 → 自定义脚本 → **WAN 上行/下行启动后执行**

各加一行：

```sh
sleep 10 && /bin/sh /etc/storage/portal-auth.sh --guard &
```

**crontab 兜底**（`/etc/storage/cron/crontabs/admin`）：

```
* * * * * /bin/sh /etc/storage/portal-auth.sh
```

> Padavan 的 `/etc/storage/` 是唯一持久区（mtd5），改完必须 `/sbin/mtd_storage.sh save`。
> 忘记保存 → 重启后脚本消失 → 半夜断网没人管。

---

## 8. 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| `ERR 未配置校园网账号` | 配置文件没到位 / 没改 | 确认 `/etc/storage/portal-auth.conf` 存在且已填 |
| `probe WAN 未就绪` | WAN 还没拿到 IP | 等下一轮；持续如此查 WAN 口与网线 |
| `ERR 未取到认证链接` | 参数抓不到，或不是 ePortal | 把完整链接填进 `PORTAL_LOGIN_URL` |
| `FAIL 认证失败` | `serviceId` / 参数名不对 | `cat /tmp/pa_result.txt`；按 §4 重新抓 `serviceId` |
| 认证成功后几分钟又掉 | 自启只配了一处；或账号在别处登录 | 检查双保险两处 + crontab；确认账号没被别的设备挤下线 |
| 一直失败，账号密码无误 | 学校用的 802.1X | 见 §1，本插件不适用 |
| 想临时停用 | —— | 删掉两处自启行与 crontab，重启 |

**查看日志**：

```sh
tail -30 /tmp/portal_auth.log          # 脚本自己的日志
grep Portal /tmp/syslog.log | tail -20 # 走 logger 的那份
```

正常运行时每分钟一条，形如：

```
[2026-09-29 01:12:03] probe: HTTP=200
[2026-09-29 01:12:03] OK 已认证，外网可达 (HTTP=200)
```

### 远程桌面导致掉线的额外处理

部分学校的 Portal 防共享检测，看到 NAT 后某设备产生异常多连接会强制下线。
对策是让对外只保留**一条类 HTTPS 的长连接**：

| 远程工具 | 连接模式 | Portal 风险 | 推荐 |
|---|---|---|---|
| **ToDesk（P2P 模式）** | 单条加密 TCP 通道 | ✅ 极低 | ⭐⭐⭐⭐⭐ |
| **RustDesk（P2P）** | P2P 直连 | ✅ 极低 | ⭐⭐⭐⭐⭐ |
| AnyDesk | 中继/直连混合 | ✅ 低 | ⭐⭐⭐⭐ |
| 向日葵（P2P 模式） | P2P 优先 | ⚠️ 中等 | ⭐⭐⭐ |
| **MSTSC 原生 3389** | 端口监听 | 🔴 很高 | ❌ |

---

## 9. 相关文档

- [README](../README.md) —— 快速开始与「把认证网址交给 AI」
- [appendix/02-initial-config.md](appendix/02-initial-config.md) —— 刷完固件的初始配置（**先配 WiFi 再插 WAN**）
- [appendix/07-diagnostics-playbook.md](appendix/07-diagnostics-playbook.md) —— 网络体检与排障方法论
- [scripts/verify.sh](../scripts/verify.sh) —— 一键验收
