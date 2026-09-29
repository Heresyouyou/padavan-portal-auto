# 06 · ★ UDP 硬件卸载导致游戏断连的根因与修复

> 📎 本文属**进阶附录**，与锐捷 Portal 认证插件无直接关联，按需查阅。
> 返回 [README](../../README.md) ｜ [Portal 自动认证](../portal-auth.md)

> **本仓库最重要的一章。** 症状典型、伪装极强，曾在多轮排查中被反复漏掉。
> 遇到「网页秒开但游戏卡/掉线」，直接跳到 [修复命令](#5-修复命令)。

---

## 1. 症状

- **其他设备**（非管理机）上游戏延迟极高、**抖动 > 5000ms**、频繁**断连重连**
- 同时 **TCP 业务完全正常**：网页秒开、视频流畅、测速正常
- 从管理机 ping 路由器 1.9–7ms 完美；路由器 ping 上游 0% 丢包
- 唯独 **AP ↔ 其他终端**的空口 RTT 出现荒谬数值（实测 avg 888ms / max 3034ms）

### 典型误判方向（都会浪费大量时间）

| 误判方向 | 为什么不是它 |
|---|---|
| 宽带/运营商问题 | 路由器直连上游 0% 丢包、延迟 5–19ms |
| DNS 问题 | 优化 DNS 后解析 20/20，问题依旧 |
| 弱信号被踢 | 实测各终端 RSSI 全在 −40 ~ −58，信号极好 |
| 信道干扰 | 扫描确认所在信道干净；换信道无效 |
| 终端 WiFi 省电 | 省电只造成 ~100ms 尖峰，不是 5000ms |
| 透明代理/劫持 | 进程列表干净、NAT PREROUTING 无 REDIRECT/TPROXY |

---

## 2. 根因

Padavan 默认 `hw_nat_mode=4` + `sfe_enable=1` 时，启动日志会打印：

```
K2P: Hardware NAT/Routing: Enabled, IPoE/PPPoE offload [WAN]<->[LAN/WLAN]
K2P: Hardware NAT/Routing: IPv4 UDP flow offload - ON      ← 游戏流量全走这条
kernel: fast_classifier: Unknown symbol fast_nat_recv (err 0)   ← 卸载子模块加载失败
```

**机理**：

1. MTK **FoE（Fast Path offload Engine）把 IPv4 UDP 流整体卸载**到硬件快路径
2. 该 build 的 `fast_classifier` 子模块**加载失败**
3. 游戏以 **UDP 为主** → 被塞进这条有问题的快路径 → 延迟飙升、连接表失同步 → 掉线重连
4. **TCP 走另一条路径** → 网页/测速表现正常

→ 这就是「**网页快但游戏卡**」的完整解释。

---

## 3. ★★ 为什么此前多轮排查都漏掉了它（方法论教训）

> **ICMP 测试测不到这条路径。**

`ping` 各 LAN 设备走的是 **LAN↔LAN 桥接转发**，
**根本不进 NAT / FoE 卸载路径**。

所以「**ping 一切正常**」与「**游戏完全不可用**」可以**同时成立**，互不矛盾。

### 由此得出的铁律

1. **验证 NAT 卸载问题，必须走「终端 → WAN」的真实转发路径**，
   不能只看 LAN 内 ping，也不能只看路由器自身的 ping。
2. **`iptables -L`、conntrack 列表在卸载生效时都不可信** ——
   被卸载的流根本不进 netfilter，你看不到它们。
3. 判断依据要选**会经过卸载路径**的指标：
   `/tmp/syslog.log` 里的 `IPv4 UDP flow offload - ON/OFF` 是**最直接的判据**。

---

## 4. 关键鉴别测试

### 测试 A：发包节奏对比（区分「省电休眠」vs「真实丢包/拥塞」）

```sh
# 慢速 1 秒/包
ping -c 8  -i 1   <目标IP>
# 突发 0.1 秒/包
ping -c 20 -i 0.1 <目标IP>
```

| 节奏 | avg | max | 结论 |
|---|---|---|---|
| 1 秒/包 | 888 ms | 3034 ms | 终端休眠，路由器缓冲待发 |
| 0.1 秒/包 | 7.2 ms | 11.6 ms | **链路本身良好** |

**读法**：

- 慢速差、快速好 → **不是拥塞**（否则密集发包会更差），也不是链路损坏
- 典型原因是**终端 WiFi 省电休眠（PSM）**：空闲时终端睡着，AP 把帧压在缓冲区，
  等终端在 DTIM 周期醒来才下发 → 产生 RTT 尖峰

> ⚠️ 这条测试能证明「空口不是坏的」，**但不能替代 NAT 路径验证**。
> 它只排除，不定位。

### 测试 B：主判据 —— 直接看启动日志的卸载开关（一眼定案）

```sh
ssh admin@192.168.123.1 "grep -iE 'Hardware NAT|flow offload|fast_classifier' /tmp/syslog.log" < /dev/null
```

- 出现 **`IPv4 UDP flow offload - ON`** → **就是它**，直接去修复
- 出现 `IPv4 UDP flow offload - OFF` → 不是这个根因，转 [07-diagnostics-playbook.md](07-diagnostics-playbook.md)

### 测试 C：确认 WAN 侧无辜

```sh
ssh admin@192.168.123.1 "ping -c 30 -i 1 <游戏服务器IP或上游DNS>" < /dev/null
```

实测案例：路由器 → 游戏服务器 `5.281/5.712/6.124 ms`、**0% 丢包** →
WAN 完全正常，问题在 **AP ↔ 终端**这一段。

---

## 5. 修复命令

### 5.1 记录原值（便于回滚）

```sh
ssh admin@192.168.123.1 "/usr/sbin/nvram get hw_nat_mode; \
  /usr/sbin/nvram get sfe_enable; \
  /usr/sbin/nvram get udp_offload; \
  /usr/sbin/nvram get wifi_offload" < /dev/null
```

**默认原值通常是**：`hw_nat_mode=4`、`sfe_enable=1`、`udp_offload=`（空）、`wifi_offload=`（空）

### 5.2 关闭全部硬件卸载

```sh
ssh admin@192.168.123.1 "/usr/sbin/nvram set hw_nat_mode=0; \
  /usr/sbin/nvram set sfe_enable=0; \
  /usr/sbin/nvram set udp_offload=0; \
  /usr/sbin/nvram set wifi_offload=0; \
  /usr/sbin/nvram commit" < /dev/null
```

### 5.3 重启（★ 必须全路径 `/sbin/reboot`）

```sh
ssh admin@192.168.123.1 "(sleep 1; /sbin/reboot) >/dev/null 2>&1 &" < /dev/null
```

- **必须用 `/sbin/reboot`**：裸 `reboot` 不在 PATH，会**静默失败**
- 重启后约 **110 秒**恢复 SSH / 网络，脚本里要等够

### 5.4 其他平台的等价开关

| 平台 | 硬件 NAT 卸载 | 软件快速转发 |
|---|---|---|
| **Padavan** | `nvram set hw_nat_mode=0` | `nvram set sfe_enable=0` |
| **OpenWrt** | `uci set firewall.@defaults[0].flow_offloading_hw='0'` | `uci set firewall.@defaults[0].flow_offloading='0'` |
| **OpenWrt（提交）** | `uci commit firewall && /etc/init.d/firewall restart` | 同上 |

---

## 6. 验证

```sh
ssh admin@192.168.123.1 "/usr/sbin/nvram get hw_nat_mode; \
  /usr/sbin/nvram get sfe_enable; \
  grep -iE 'flow offload' /tmp/syslog.log; \
  uptime" < /dev/null
```

**通过标准**：

| 检查 | 预期 |
|---|---|
| `hw_nat_mode` | `0` |
| `sfe_enable` | `0` |
| 启动日志 | **`IPv4 UDP flow offload - OFF`** |
| `uptime` 负载 | `0.00`（软件转发未造成压力） |
| 其他配置自恢复 | `eth3 mtu 1492` + MSS 规则存在且计数增长 |
| dnsmasq | `pidof dnsmasq` 有输出 |

> **注意**：`hw_nat` 内核模块**仍会出现在 `/proc/modules`** 里，这是正常的。
> `mode=0` 时它不参与卸载。**以日志里的 `flow offload - OFF` 为准**，不要看模块列表。

---

## 7. 修复效果（实测）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 延迟抖动 | **> 5000 ms** | **4.22 ms** |
| 网络延迟 | 极高、不可用 | **48.4 ms** |
| 下载 | 波动大 | **95.1 Mbps** |
| 上传 | 波动大 | **96.4 Mbps** |

游戏掉线重连现象消失。

**性能顾虑解答**：关闭卸载后是软件转发。在 ~70Mbps 的账号带宽下，
MT7621 软件转发**毫无压力**（实测仍跑满 95/96 Mbps，负载 0.00）。

> 只有当你的带宽接近 **千兆** 时，关闭硬件卸载才可能成为瓶颈。
> 此时应先确认是否真的命中此 bug（大部分家庭/校园带宽不会）。

---

## 8. 附带优化（可选，可运行时热改）

终端 WiFi 省电休眠会造成残留 **~100ms 尖峰**（DTIM=1 的固有醒周期）。
以下三项可**运行时热改**，立即生效：

```sh
ssh admin@192.168.123.1 "for i in ra0 rax0; do \
  iwpriv \$i set PktAggregate=0; \
  iwpriv \$i set TxBurst=0; \
  iwpriv \$i set IgmpSnEnable=0; done" < /dev/null
```

- 关闭后延迟由 3s 级尖峰回落至 **2–8ms**
- **持久化**需同步 `nvram set wl_PktAggregate=0` / `wl_TxBurst=0` / `wl_IgmpSnEnable=0`
  （2.4G 用 `rt_` 前缀）+ `nvram commit`
- ⚠️ 忘记 commit → 重启后复原

**不可热改的参数**（改了会报错，必须 nvram + 重启）：

| 参数 | 报错 |
|---|---|
| `wifi_offload` / `udp_offload` | `set (8BE2): Invalid argument` |
| `APSDCapable` / `PSM` / `BcnReq` | `Interface doesn't accept private ioctl` |

---

## 9. 回滚

```sh
ssh admin@192.168.123.1 "/usr/sbin/nvram set hw_nat_mode=4; \
  /usr/sbin/nvram set sfe_enable=1; \
  /usr/sbin/nvram commit" < /dev/null
ssh admin@192.168.123.1 "(sleep 1; /sbin/reboot) >/dev/null 2>&1 &" < /dev/null
```

---

## 10. 排查顺序建议（下次直接照做）

1. `grep -iE 'flow offload' /tmp/syslog.log`
   → 若 `ON`，**先关卸载**，八成就是它
2. 若已是 `OFF` 仍卡 →
   `grep -A 8 'MAC  *MODE' /tmp/syslog.log` 看各终端 RSSI / `psm`，
   判断是否弱信号或休眠
3. 区分省电 vs 真丢包 → 用 **1s vs 0.1s 发包节奏对比**
4. 只有在 1) 2) 3) 都排除后，才去查信道干扰、Portal、DNS

> **顺序很重要**：把第 1 步放最前面，因为它出现频率最高、
> 修复成本最低（两条 `nvram` + 一次重启），且判据是**一条日志**。
