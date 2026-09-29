# 07 · 排障手册与判据铁律

> 📎 本文属**进阶附录**，与锐捷 Portal 认证插件无直接关联，按需查阅。
> 返回 [README](../../README.md) ｜ [Portal 自动认证](../portal-auth.md)

## 一、★ 判据铁律：不要用 ping 判断链路健康

### 坑 1：ICMP 限速造成「假丢包」

Padavan 默认 `icmp_ratelimit=1000` —— 对同一目标**每 1000ms 只回 1 个 ICMP**。
以 0.2s 间隔 ping 必然显示「丢包 70–85%」，**纯属假象**。

实测同一时刻：

| 指标 | 数值 |
|---|---|
| ping 丢包率 | 68–88% |
| TCP:80 握手 | **30/30 成功** |
| DNS 解析 | **20/20 成功** |
| 下载吞吐 | 66 Mbps 正常 |

### 坑 2：LAN 内 ping 绕过 NAT/卸载路径

`ping` LAN 设备走**桥接转发**，不进 NAT / FoE 卸载路径。
所以它测不出「UDP 硬件卸载」这类问题（详见 [06](06-hardware-offload-fix.md)）。

### 坑 3：空闲终端的省电休眠

空闲手机进入 WiFi 省电（PSM），AP 把帧压在缓冲区等 DTIM 周期 → RTT 出现百毫秒级尖峰。
**这是正常现象，不是故障。**

### 结论：只看这四项

| 判据 | 说明 |
|---|---|
| **TCP 握手成功率** | 最接近真实业务可用性 |
| **DNS 解析成功率** | 直接影响「打得开/连得上」 |
| **吞吐** | 用下载实测，不看 ping |
| **RTT 抖动 (stddev)** | 看**抖动**而非**丢包率** |

---

## 二、关键方法：localhost 对照组

**目的**：区分「客户端无线链路问题」vs「路由器 CPU 卡顿」。

用脚本同时探测三个目标，每 250–300ms 一轮：

| 目标 | 含义 |
|---|---|
| `127.0.0.1:9` | 纯 CPU / 进程调度对照组（立即 RST，不过网卡） |
| `192.168.123.1:80` | LAN 一跳（只过无线链路） |
| `<上游IP>:80` | WAN |

**判读**：

- localhost 全部 <1ms，而 **LAN 也出现 1000–2000ms 卡顿**
  → 问题在**客户端无线链路**，与 CPU、上游无关
- localhost 也卡 → 问题在**路由器 CPU/进程调度**

实测：localhost **0 次**卡顿（max 0.6ms）/ LAN **16 次**卡顿（max 2002ms）→ **铁证**。

---

## 三、体检清单（逐项可复现）

| # | 检查项 | 命令 / 方法 |
|---|---|---|
| 1 | 出口质量 | `ping` 外网 RTT 抖动；TCP 握手 15 次成功率；DNS 解析成功率 |
| 2 | bufferbloat | 带载 vs 空载 RTT 对比 |
| 3 | 无线空口 | `iwconfig ra0` / `iwconfig rax0` |
| 4 | 客户端电台 | localhost 对照组（见上） |
| 5 | 路由器自身 | `uptime`；`free`；`cat /proc/sys/net/netfilter/nf_conntrack_count` |
| 6 | **卸载开关** | `grep -iE 'flow offload' /tmp/syslog.log` ← **必查** |
| 7 | 每终端空口 | `grep -A 8 'MAC  *MODE' /tmp/syslog.log` |
| 8 | Portal 守护 | `tail /tmp/syslog.log`，确认每分钟有 `HTTP=200` |
| 9 | 接口队列表 | `ip link show eth3`；`cat /proc/net/softnet_stat` |
| 10 | conntrack 超时 | `cat /proc/sys/net/netfilter/nf_conntrack_udp_timeout` |

---

## 四、按症状快速定位

| 症状 | 首选检查 | 指向 |
|---|---|---|
| **网页秒开但游戏卡/掉线** | `grep -iE 'flow offload' /tmp/syslog.log` | → [06 UDP 硬件卸载](06-hardware-offload-fix.md) |
| 网页都打不开 / 极慢 | DNS 成功率；MTU/MSS 计数 | → [05](05-mtu-mss-dns.md) |
| 网页能开但部分站点白屏 | MTU 黑洞（`ping -D -s`） | → [05](05-mtu-mss-dns.md) |
| 大面积 ping 丢包但业务正常 | ICMP 限速假象 | 判据铁律（本章一） |
| 空闲设备 ping 几百 ms | 终端省电休眠 | 正常，非故障 |
| 某台设备独卡 | 该终端 RSSI / `psm` | → [04](04-wireless-tuning.md) |
| 每隔几分钟全体掉线 | Portal 守护是否在跑 | → [Portal 认证](../portal-auth.md) |
| 远程桌面时断开 | Portal 防共享检测 | 用 P2P 工具（见下） |

---

## 五、Portal 防检测：远程桌面选用建议

Portal 会检测「NAT 后单设备产生异常多的连接」。

| 工具 | 连接模式 | Portal 风险 | 推荐 |
|---|---|---|---|
| **ToDesk（P2P 模式）** | 单条加密 TCP 通道 | ✅ 极低 | ⭐⭐⭐⭐⭐ |
| **RustDesk（P2P）** | P2P 直连 | ✅ 极低 | ⭐⭐⭐⭐⭐ |
| AnyDesk | 中继/直连混合 | ✅ 低 | ⭐⭐⭐⭐ |
| 向日葵（P2P） | P2P 优先 | ⚠️ 中等 | ⭐⭐⭐ |
| 系统自带远程桌面（MSTSC/RDP） | 3389 端口监听 | 🔴 很高 | ❌ |

**核心原则**：让路由器对外只产生 **1 条长连接**，特征接近普通 HTTPS。

路由器侧辅助：限制 NAT 会话数，给 Portal 心跳留空间。

---

## 六、常用诊断命令速查

```sh
# ── SSH（Padavan）────────────────────────────────
ssh -i ~/.ssh/<key> -o StrictHostKeyChecking=no -o ConnectTimeout=8 admin@192.168.123.1
# ⚠️ 批量执行时不要用 heredoc（会挂起），用单行 + ';' 分隔 + '< /dev/null'

# ── 卸载开关（最高优先级）────────────────────────
grep -iE 'flow offload|fast_classifier|Hardware NAT' /tmp/syslog.log

# ── 每终端空口状态 ──────────────────────────────
grep -A 8 'MAC                MODE' /tmp/syslog.log | tail -40

# ── 双频状态 ────────────────────────────────────
iwconfig ra0    # 5G
iwconfig rax0   # 2.4G

# ── WAN 接口与 MSS ──────────────────────────────
ip link show eth3 | head -1
iptables -t mangle -L FORWARD -n -v | grep -i tcpmss

# ── 设备清单 ────────────────────────────────────
cat /tmp/dnsmasq.leases
cat /proc/net/arp

# ── conntrack ───────────────────────────────────
cat /proc/sys/net/netfilter/nf_conntrack_udp_timeout
cat /proc/sys/net/netfilter/nf_conntrack_count

# ── 系统负载 ────────────────────────────────────
uptime
cat /proc/net/softnet_stat

# ── 持久化（/etc/storage 是 tmpfs 覆盖，必须 save 才落 mtd5）─
/sbin/mtd_storage.sh save
```

### macOS 侧（客户端）

```sh
# 当前连接的 AP / 信道
system_profiler SPAirPortDataType | grep -A 3 -i channel
networksetup -getairportnetwork en0
# ⚠️ macOS 15 已移除 airport CLI，不要再用
```

---

## 七、环境噪音辨识（避免误判为故障）

| 现象 | 说明 | 是否故障 |
|---|---|---|
| ping 大面积丢包 | ICMP 限速假象 | ❌ 否 |
| 空闲设备 ping 数百 ms | 终端省电休眠 | ❌ 否 |
| `awdl0` 处于 `status: active` | 即使关了 AirDrop，接力/隔空播放/iPhone 镜像 任一开启就会拉起 | ❌ 否（但会占空口） |
| `iwpriv ra0 stat` 双频报完全相同数值 | 共享/全局计数器 | ❌ 数据不可信 |
| `iwpriv` 多数查询报 `Invalid argument` | 闭源驱动未实现 | ❌ 非故障，换 syslog 取数 |

---

## 八、方法论总结（给 AI 的元规则）

1. **先取证，再改配置** —— 不要凭症状猜参数
2. **判据要选会经过问题路径的指标** —— LAN ping 测不出 NAT 卸载问题
3. **一次只改一个变量，改完立即验证** —— 便于归因
4. **改任何东西前先记录原值** —— 否则无法回滚
5. **`nvram commit` / `mtd_storage.sh save` / 重启** 三件事缺一不可
6. **重启必须全路径 `/sbin/reboot`** —— 裸 `reboot` 静默失败
7. **优先查「一条日志就能定案」的根因** —— 如 `flow offload - ON/OFF`
