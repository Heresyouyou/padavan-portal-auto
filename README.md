# Padavan 路由器调优与排障手册

面向 **MT7621 / MT7615 平台 + 老毛子(Padavan)固件** 的路由器配置、性能调优与故障排查手册。
所有结论均来自真机实测，每条都附**可复现命令**与**验收判据**。

> 本手册的编排目标是：**可以整份交给另一个 AI，让它按步骤复现同一套配置与修复流程。**

---

## 头条结论（先看这条，能省几小时）

> **症状**：网页秒开、测速正常，但**游戏（王者荣耀/洛克王国等）延迟极高、抖动 >5000ms、频繁断连重连**。
>
> **根因**：Padavan 默认开启的 **硬件 NAT 卸载** 把 IPv4 **UDP** 流整体旁路到 MTK FoE 快路径，
> 且该快路径的 `fast_classifier` 子模块加载失败（`Unknown symbol fast_nat_recv`）。
> 游戏以 UDP 为主 → 走这条坏路径 → 断连；网页走 TCP → 另一条路径 → 正常。
>
> **修复**：关闭硬件卸载（`hw_nat_mode=0` + `sfe_enable=0`）+ 全路径重启。
>
> **实测效果**：延迟抖动 **>5000ms → 4.22ms**，延迟 **48.4ms**，下载 **95.1Mbps** / 上传 **96.4Mbps**。
>
> 详见 [docs/06-hardware-offload-fix.md](docs/06-hardware-offload-fix.md)

**为什么这个问题难查**：`ping` 各 LAN 设备走的是 **LAN↔LAN 桥接转发**，根本不进 NAT/卸载路径。
所以「ping 全部正常」与「游戏完全不可用」可以同时成立。**用 ping 排查这类问题会一直查不出来。**

---

## 快速开始

### 如果你只是想复现修复（最常见）

```sh
# 1) 先确认是不是这个根因（一眼定案）
ssh admin@192.168.123.1 "grep -iE 'flow offload|fast_classifier' /tmp/syslog.log" < /dev/null
# 出现 'IPv4 UDP flow offload - ON' → 就是它

# 2) 关闭全部硬件卸载
ssh admin@192.168.123.1 "/usr/sbin/nvram set hw_nat_mode=0; \
  /usr/sbin/nvram set sfe_enable=0; \
  /usr/sbin/nvram set udp_offload=0; \
  /usr/sbin/nvram set wifi_offload=0; \
  /usr/sbin/nvram commit" < /dev/null

# 3) 重启（必须全路径 /sbin/reboot，约 110 秒恢复）
ssh admin@192.168.123.1 "(sleep 1; /sbin/reboot) >/dev/null 2>&1 &" < /dev/null

# 4) 验证（应显示 flow offload - OFF）
ssh admin@192.168.123.1 "/usr/sbin/nvram get hw_nat_mode; /usr/sbin/nvram get sfe_enable; \
  grep -iE 'flow offload' /tmp/syslog.log" < /dev/null
```

回滚：`hw_nat_mode=4` + `sfe_enable=1` 后 commit 并重启。

### 如果你要把整套配置交给 AI 执行

直接把它指向 **[docs/08-ai-runbook.md](docs/08-ai-runbook.md)**。
那是一个分阶段、带**验收判据**与**STOP 条件**的机器可执行 runbook。

---

## 仓库结构

| 文件 | 内容 |
|---|---|
| [docs/01-hardware-firmware-flash.md](docs/01-hardware-firmware-flash.md) | 硬件选型、固件选择、Breed 刷机流程 |
| [docs/02-initial-config.md](docs/02-initial-config.md) | 初始配置（先配 WiFi、后插 WAN 的顺序原则） |
| [docs/03-campus-portal-auth.md](docs/03-campus-portal-auth.md) | 校园网 Portal(锐捷 ePortal) 自动认证（**通用化模板**） |
| [docs/04-wireless-tuning.md](docs/04-wireless-tuning.md) | 无线调优：信道、频宽、SSID、踢除阈值、参数热改边界 |
| [docs/05-mtu-mss-dns.md](docs/05-mtu-mss-dns.md) | MTU/MSS 钳制、DNS(dnsmasq) 优化 |
| [docs/06-hardware-offload-fix.md](docs/06-hardware-offload-fix.md) | ★ **UDP 硬件卸载导致游戏断连的根因与修复** |
| [docs/07-diagnostics-playbook.md](docs/07-diagnostics-playbook.md) | 排障手册与判据铁律（含 **localhost 对照组法**） |
| [docs/08-ai-runbook.md](docs/08-ai-runbook.md) | ★ **交给 AI 复现的分步 runbook** |
| [scripts/post_wan_script.sh](scripts/post_wan_script.sh) | MTU/MSS 开机自恢复钩子 |
| [scripts/dnsmasq-optimize.conf](scripts/dnsmasq-optimize.conf) | dnsmasq 持久化优化片段 |
| [scripts/portal-auth.sh.template](scripts/portal-auth.sh.template) | Portal 认证脚本模板（**已脱敏**，需填自己的凭据） |
| [scripts/verify.sh](scripts/verify.sh) | 一键验收脚本 |
| [templates/credentials.env.example](templates/credentials.env.example) | 凭据占位文件 |

---

## 适用与移植

### 本手册直接适用的环境

| 项 | 值 |
|---|---|
| 平台 | MT7621A（本案例：斐讯 K2P A2） |
| 无线 | MT7615（闭源驱动，`DBDC_MODE=1` 双频共射频） |
| 固件 | 老毛子 Padavan（hiboy 版），内核 3.4.113，BusyBox 1.38 |
| 接口命名 | **5G = `ra0`/`wl_*`；2.4G = `rax0`/`rt_*`** |
| 默认管理地址 | `192.168.123.1` |
| 认证 | 校园网 锐捷 ePortal（Portal 网页认证） |

### 移植到其他路由器

**核心结论（第 06 章）是平台无关的**，只要设备用了 MTK 硬件卸载/快速转发就会命中。
不同固件的开关名对照：

| 平台 | 硬件 NAT 卸载 | 软件快速转发(SFE) |
|---|---|---|
| Padavan（本手册） | `nvram set hw_nat_mode=0` | `nvram set sfe_enable=0` |
| OpenWrt / ImmortalWrt | `uci set firewall.@defaults[0].flow_offloading_hw='0'` | `uci set firewall.@defaults[0].flow_offloading='0'` |
| 华硕 Merlin | 关闭 `Runner` / `Flow Cache`（部分机型无此开关） | — |

> OpenWrt 侧改完执行 `uci commit firewall && /etc/init.d/firewall restart`。

其余章节（无线调参、MTU/MSS、DNS、排障方法）思路通用，但**具体参数名与路径需按固件调整**。
凡是依赖 Padavan 特有路径（`/etc/storage/`、`/sbin/rc`、`/usr/sbin/nvram`）的地方，本手册均已显式标注。

### 平台通用 VS 平台特有（给 AI 的提示）

- **平台通用**：排障方法论（第 07 章）、硬件卸载根因（第 06 章）、MTU/MSS 原理与判据、DNS 缓存策略
- **平台特有**：所有 `nvram`/`rc`/`/etc/storage` 命令、接口命名、固件下载地址
- 移植时**先跑第 07 章的体检清单**建立基线，再决定改什么；**不要照抄参数**。

---

## 安全与合规

- 本仓库**不含任何真实凭据**。所有账号、密码、SID、MAC 均为占位符，请填入自己的。
- 校园网使用请遵守所属学校的网络管理规定。
- 排障命令以**只读**为主；凡涉及 `nvram commit` 或重启的步骤，手册均给出**原值与回滚方法**。
- 改任何配置前，先确认你有**物理接触路由器的能力**（否则改错会失联）。

---

## 许可

MIT，见 [LICENSE](LICENSE)。
