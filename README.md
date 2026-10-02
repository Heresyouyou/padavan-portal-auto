# padavan-portal-auto

### 老毛子 (Padavan) 路由器插件 —— 锐捷 ePortal 校园网自动认证

**装一次，路由器自己登录校园网。** 手机、电脑、电视、游戏机连上 WiFi 就能上网，
不用再逐个设备点认证，也不怕半夜掉线。

|  |  |
|---|---|
| **它做什么** | 定时探测外网 → 一旦被校园网 Portal 拦截，自动用你的账号完成认证 → 掉线自动重连 |
| **它不是什么** | 不是破解工具，不绕过计费；用的就是你自己的账号密码，只是把「手动点登录」变成自动 |
| **跑在哪** | 刷了老毛子 Padavan 的路由器（MT7621 等平台）；OpenWrt 也能直接跑这个脚本 |
| **需要什么** | 路由器已刷 Padavan + 一台能 SSH 的电脑 + 你的校园网账号密码 |
| **昆明理工大学** | ✅ **开箱即用**：认证端点、`serviceId` 已内置，你只需填账号密码 |
| **其他学校** | ✅ **把认证网址粘给 AI**，2 分钟生成适配你学校的脚本（见 [§3](#3-其他学校把你的认证网址交给-ai-)） |

```
        ┌──────────────────────────────┐
        │  未认证的校园网（会被拦截）    │
        └───────────────┬──────────────┘
                        │ ① 每 60 秒探测一次外网
        ┌───────────────▼──────────────┐
        │  portal-auth.sh              │
        │  ─ 响应里有 zportal？         │
        │  ─ 有 → 取认证链接 → 提交认证 │
        │  ─ 没有 → 已经通了，继续睡    │
        └───────────────┬──────────────┘
                        │ ② 用你的账号密码 POST 认证
        ┌───────────────▼──────────────┐
        │  认证成功 → 全家设备正常上网   │
        │  失败 → 记日志，60 秒后重试   │
        └──────────────────────────────┘
```

---

## 1. 最快路径：把认证网址交给 AI ✨

> **这一步只需要你做一件事：拿到那条完整链接。**

1. **先让浏览器被拦截**：在**未认证**的网络下，用手机或电脑浏览器打开任意一个 `http://` 网站
   （例如 `http://neverssl.com`），页面会自动跳到**校园网认证登录页**。
2. **复制地址栏里的那条完整链接** —— ⚠️ **必须包含 `?` 后面的全部参数**。
3. 打开任意 AI（含本仓库的 Trae / ChatGPT / Claude 均可），把下面这段**连同链接**一起发给它。

### 现成的提示词（复制即用）

```text
我在用一台刷了老毛子(Padavan)固件的路由器，需要自动完成校园网认证。
请先阅读这个仓库的 portal-auth.sh 与 docs/portal-auth.md：
https://github.com/Heresyouyou/padavan-portal-auto

下面是我从浏览器地址栏复制的【认证登录页完整链接】：

<<把完整链接粘到这里>>

请帮我：
1. 判断这是不是锐捷 ePortal（含 /zportal/loginForWeb 基本即可确认）；
2. 从链接里提取 AUTH_HOST、LOGIN_PATH，并推断 SUBMIT_PATH；
3. 输出一份可直接用的 /etc/storage/portal-auth.conf（账号密码留占位符，
   我会自己填；其中 PORTAL_LOGIN_URL 就填我上面给的这条完整链接）；
4. 告诉我这所学校有没有需要特别注意的地方（参数名差异、serviceId 怎么找、是否需要 MAC 克隆）；
5. 不要直接修改我的路由器，只把文件内容和部署命令给我。
```

AI 给出的内容填进 `portal-auth.conf`，再按 [§4 部署](#4-部署到路由器) 传上路由器即可。

### 为什么一定要「完整链接」而不是只给域名

锐捷 ePortal 的登录必须带上**这一次会话的上下文参数**，缺一个都会认证失败或立刻掉线：

```
http://222.197.192.59:9090/zportal/loginForWeb?wlanuserip=10.100.1.23&wlanacname=XXX&ssid=XXX&nasip=222.197.192.59&mac=aa:bb:cc:dd:ee:ff&t=1699999999
└──────── AUTH_HOST ───────┘└──── LOGIN_PATH ──┘└──────────────── 必须一起带上 ────────────────┘
```

- `wlanuserip` / `mac` / `t` 这些**每次都不同**，所以不能写死，只能让脚本运行时抓取；
- 只给「服务器地址 + 账号密码」的脚本，会在提交时缺少上下文 → 服务端不知道你在认证哪台设备；
- 把完整链接给 AI，它就能知道**参数叫什么名字、有几个**，从而生成参数提取逻辑正确的脚本。

> 脚本已内置这种能力：只要在 `portal-auth.conf` 里设了 `PORTAL_LOGIN_URL`，
> 它就会自动拆出查询串、自动修正端点，无需手工拆参数。

**如果 AI 需要更多信息**（例如 `serviceId` 抓不到），让它告诉你怎么用浏览器 F12 →
Network 面板抓一次真实的登录请求，把请求 URL + 表单内容贴给它即可。

---

## 2. 昆明理工大学用户：开箱即用

端点、路径、`serviceId`、UA 已全部内置（`PROFILE=kmust` 为默认值），**你只需要填账号密码**。

```sh
# ① 下载主脚本 + 配置模板
curl -O https://raw.githubusercontent.com/Heresyouyou/padavan-portal-auto/main/portal-auth.sh
curl -O https://raw.githubusercontent.com/Heresyouyou/padavan-portal-auto/main/templates/portal-auth.conf.example

# ② 编辑配置：只改 USER / PASS 两行
cp portal-auth.conf.example portal-auth.conf
vi portal-auth.conf

# ③ 传到路由器并持久化（★ mtd_storage.sh save 必须执行，否则重启丢）
scp portal-auth.sh portal-auth.conf admin@192.168.123.1:/etc/storage/
ssh admin@192.168.123.1 "chmod +x /etc/storage/portal-auth.sh; /sbin/mtd_storage.sh save" < /dev/null

# ④ 立刻手动认证一次，看结果
ssh admin@192.168.123.1 "sh /etc/storage/portal-auth.sh; tail -5 /tmp/portal_auth.log" < /dev/null
# 预期看到: SUCCESS 认证成功
```

内置的昆工参数（如与你的校区不符，在 `portal-auth.conf` 里覆盖即可）：

| 项 | 值 |
|---|---|
| Portal 服务器 | `http://222.197.192.59:9090` |
| 登录页 | `/zportal/loginForWeb` |
| 提交接口 | `/zportal/login/do` |
| `SERVICE_ID`（内网免费） | `8687c29b51c1471f9a31eb34eeb7e187` |
| `SERVICE_ID`（外网计费） | `e25d67dd0cc84693905d8ce564f3ac03` |
| 校内 DNS | `222.197.198.33` / `222.172.200.68` |

> ⚠️ 仓库内**不含任何真实账号密码**。请不要把自己的学号密码提交到公开仓库。

---

## 3. 其他学校：把你的认证网址交给 AI ✨

本仓库的脚本刻意写成**通用骨架**：锐捷 ePortal 的流程各校几乎同构，
差异只在 **端点地址**、**参数名**、**`serviceId`** 这三处（见 [§1 提示词](#现成的提示词复制即用)）。
所以适配别的学校不需要改代码，只需要把那条完整链接交给 AI 生成配置。

适配完成后，如果你愿意，欢迎把**脱敏后的配置**（去掉账号密码、MAC）
以 issue 或 PR 的形式分享回来，让同校的同学直接复用。

---

## 4. 部署到路由器

### 4.1 必做：开机自启「双保险」

两处都要加，任一处失效仍能认证：

1. 管理 → 自定义脚本 → **开机启动**
2. 管理 → 自定义脚本 → **WAN 上行/下行启动后执行**

各加一行：

```sh
sleep 10 && /bin/sh /etc/storage/portal-auth.sh --guard &
```

`sleep 10` 用于等 DHCP 拿到 IP。

### 4.2 推荐：crontab 兜底

编辑 `/etc/storage/cron/crontabs/admin`：

```
* * * * * /bin/sh /etc/storage/portal-auth.sh
```

改完同样要 `/sbin/mtd_storage.sh save` 持久化。

### 4.3 常用命令

```sh
sh /etc/storage/portal-auth.sh --show     # 看当前生效配置（不显示密码）
sh /etc/storage/portal-auth.sh            # 单次认证
tail -f /tmp/portal_auth.log              # 看认证日志
grep Portal /tmp/syslog.log | tail -20    # 从 syslog 看
```

> **最实在的兜底是智能插座**：守护进程挂了、路由器假死，都能远程一键断电恢复。

---

## 5. 认证失败怎么查

| 现象 | 原因 | 处理 |
|---|---|---|
| `ERR 未配置校园网账号` | `portal-auth.conf` 没放对位置或没改 | 确认路径是 `/etc/storage/portal-auth.conf` |
| `probe WAN 未就绪` | WAN 还没拿到 IP | 正常，等下一轮；若一直如此查 WAN 口 |
| `ERR 未取到认证链接` | 参数抓不到 / 不是 ePortal | 把完整链接填进 `PORTAL_LOGIN_URL` 再试 |
| `FAIL 认证失败` | `serviceId` 或参数名不对 | 看 `/tmp/pa_result.txt`，用 F12 抓真实请求比对 |
| 认证成功后每隔几分钟又掉 | 自启只配了一处 | 检查 §4.1 两个位置 + §4.2 crontab |
| 一直失败且账号密码确认无误 | 学校用的是 802.1X 而非 Portal | 见 [docs/portal-auth.md](docs/portal-auth.md) §1 认证方式判断 |
| 想换回手动认证 | —— | 删掉两处自启行 + crontab，重启 |

更多原理、参数表、手动适配步骤见 **[docs/portal-auth.md](docs/portal-auth.md)**。

---

## 6. 仓库结构

| 文件 | 说明 |
|---|---|
| [portal-auth.sh](portal-auth.sh) | ★ **主脚本**：认证 + 断线守护，含昆工预设 |
| [templates/portal-auth.conf.example](templates/portal-auth.conf.example) | ★ 配置模板（凭据 + 自定义端点） |
| [docs/portal-auth.md](docs/portal-auth.md) | ★ 原理、参数表、手动适配、排障详解 |
| [scripts/verify.sh](scripts/verify.sh) | 一键验收脚本（连通性/DNS/无线/负载） |
| [docs/appendix/](docs/appendix/) | 附录：路由器刷机、调优与排障（非必需，进阶看） |
| [snapshots/2026-10-02-good/](snapshots/2026-10-02-good/) | ★ **已验证配置快照**：一键恢复到可用状态（含 5G 信道 149 定案） |

---

## 7. 安全与合规

- 本仓库**不含任何真实凭据**：账号、密码、MAC 均为占位符，请填自己的。
- 本插件**不绕过计费、不破解认证**，只是把你自己的账号密码自动提交给学校官方认证页。
- 校园网使用请遵守所属学校的网络管理规定；由使用行为产生的后果由使用者自负。
- 部署前请确认你有**物理接触路由器的能力**，否则配置出错会导致失联。

---

## 8. 附录：路由器调优与排障（进阶，可选）

以下内容与认证插件无关，是同一台路由器上踩过的坑，按需取用：

| 文档 | 内容 |
|---|---|
| [06-hardware-offload-fix.md](docs/appendix/06-hardware-offload-fix.md) | ★ **网页秒开但游戏卡/掉线** → UDP 硬件卸载根因与修复 |
| [07-diagnostics-playbook.md](docs/appendix/07-diagnostics-playbook.md) | 排障手册与判据铁律（**不要用 ping 判断链路健康**） |
| [05-mtu-mss-dns.md](docs/appendix/05-mtu-mss-dns.md) | MTU/MSS 钳制、DNS 优化 |
| [04-wireless-tuning.md](docs/appendix/04-wireless-tuning.md) | 无线调优：信道、频宽、弱信号踢除 |
| [02-initial-config.md](docs/appendix/02-initial-config.md) | 初始配置（先配 WiFi、后插 WAN） |
| [01-hardware-firmware-flash.md](docs/appendix/01-hardware-firmware-flash.md) | 硬件选型、固件选择、Breed 刷机 |
| [08-ai-runbook.md](docs/appendix/08-ai-runbook.md) | 交给 AI 复现的分步 runbook |
| [scripts/post_wan_script.sh](scripts/post_wan_script.sh) | MTU/MSS 开机自恢复钩子 |
| [scripts/dnsmasq-optimize.conf](scripts/dnsmasq-optimize.conf) | dnsmasq 持久化优化片段 |

---

## 许可

MIT，见 [LICENSE](LICENSE)。
