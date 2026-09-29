# 08 · ★ 交给 AI 复现的分步 Runbook

> 📎 本文属**进阶附录**，与锐捷 Portal 认证插件无直接关联，按需查阅。
> 返回 [README](../../README.md) ｜ [Portal 自动认证](../portal-auth.md)

> **用法**：把本文件整份交给另一个 AI（连同仓库其余文档作为按需参考），
> 让它按 **Phase 顺序**执行。每步都有**期望输出**与**失败处理**，
> 遇到 **STOP 条件必须停下来问人**，不要自行猜测继续。

---

## 0. 给 AI 的执行契约（先读这段）

### 你必须遵守的规则

1. **严格按 Phase 顺序执行**，不要跳步。Phase 之间存在依赖。
2. **每步执行后必须验证**再进入下一步。验证不通过 → 走「失败处理」。
3. **遇到 STOP 条件必须停下来问人**，不要自行猜测继续。
4. **改任何配置前，先执行对应的「记录原值」命令**并保存输出（否则无法回滚）。
5. **不要用 ping 判断链路健康**（见 [07-diagnostics-playbook.md](07-diagnostics-playbook.md)）。
6. **一次只改一个变量**，改完立即验证，便于归因。
7. **禁止在无人确认的情况下修改用户客户端设备（手机/电脑）的系统设置。**
8. 所有 SSH 命令**用单行 + `;` 分隔 + `< /dev/null`**，**不要用 heredoc**（会挂起）。

### 全局 STOP 条件（满足任一即停）

| 条件 | 处理 |
|---|---|
| 无法 SSH 登录路由器 | 停止，报告；请人确认 IP/密钥/SSH 是否开启 |
| 无法物理接触路由器 | **停止**；任何需要重启的操作都不要做 |
| `dnsmasq --test` 未输出 `syntax check OK` | **停止**，不要重启 dnsmasq（会全家断网） |
| 修改后管理界面/网络不可达 | 立即回滚上一变更 |
| 带宽 > 500Mbps 且依赖硬件卸载跑满 | 先与人确认再关卸载 |

### 变量表（执行前先填写）

| 变量 | 含义 | 示例 |
|---|---|---|
| `ROUTER_IP` | 路由器管理地址 | `192.168.123.1` |
| `SSH_KEY` | SSH 私钥路径 | `~/.ssh/router_key` |
| `WAN_IF` | WAN 接口名 | `eth3` |
| `IF_5G` / `IF_24G` | 5G / 2.4G 接口名 | `ra0` / `rax0` |
| `NVRAM` | nvram 可执行文件路径 | `/usr/sbin/nvram` |
| `MSS_VALUE` | 钳制后的 MSS 值 | `1452`（= MTU − 40） |

> **接口名务必先用 `iwconfig` 确认**，不要照抄。
> 不同固件的 WAN/PREFIX 命名差异很大。

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "iwconfig 2>&1 | grep -E 'ESSID|Mode'" < /dev/null
```

---

## Phase 0 · 环境识别

**目的**：搞清楚这是什么设备、什么固件、什么命名。

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "
  echo '--- 固件 ---'; cat /etc/issue 2>/dev/null; uname -a
  echo '--- 接口 ---'; iwconfig 2>&1 | grep -E 'ESSID|Mode|Channel'
  echo '--- WAN ---'; ip addr show | grep -E '^[0-9]+:|inet '
  echo '--- nvram ---'; which nvram; ls -l /usr/sbin/nvram
  echo '--- 可写区 ---'; df -h | grep -E 'storage|tmp|etc'
" < /dev/null
```

**期望输出**：

- 能看到固件标识（Padavan / OpenWrt）
- 能识别出 5G/2.4G/WAN 接口名
- `/etc/storage` 存在且可写（Padavan）

**失败处理**：

- 若为 OpenWrt（`/etc/openwrt_release` 存在）→ 命令须换成 UCI 等价写法，
  参考 [06](06-hardware-offload-fix.md) 第 5.4 节的平台对照表
- 若无法识别 → **STOP**，报告

---

## Phase 1 · 建立基线（只读，不改任何东西）

**目的**：先知道「坏成什么样」，改完才有对比。

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "
  echo '=== 1. 卸载开关（最高优先级）==='
  grep -iE 'Hardware NAT|flow offload|fast_classifier' /tmp/syslog.log
  echo '=== 2. 上负载 ==='; uptime
  echo '=== 3. 双频状态 ==='; iwconfig $IF_5G 2>&1 | head -4; iwconfig $IF_24G 2>&1 | head -4
  echo '=== 4. 每终端空口 ==='; grep -A 8 'MAC                MODE' /tmp/syslog.log | tail -40
  echo '=== 5. WAN MTU / MSS ==='
  ip link show $WAN_IF | head -1
  iptables -t mangle -L FORWARD -n -v | grep -i tcpmss
  echo '=== 6. DNS ==='; pidof dnsmasq
  echo '=== 7. 设备清单 ==='; cat /tmp/dnsmasq.leases
  echo '=== 8. conntrack ==='
  cat /proc/sys/net/netfilter/nf_conntrack_udp_timeout
  wc -l /proc/net/nf_conntrack
" < /dev/null
```

**记录到报告里**（后续对比用）：

| 项 | 本次实测值 |
|---|---|
| `flow offload` | ON / OFF |
| 各终端 RSSI | |
| `eth3 mtu` | |
| MSS 规则计数 | |
| `pidof dnsmasq` | |

**期望输出**：能完整打印以上 8 组信息。

### 判据分流（关键决策点）

```
grep 结果含 'IPv4 UDP flow offload - ON' ？
├── 是 → 症状若为「网页正常但游戏卡/掉线」→ 直接进 Phase 2（关卸载）
└── 否 → 进 Phase 3（做完整体检，找其他根因）
```

### 补充测试：确认 WAN 侧是否无辜

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "ping -c 30 -i 1 <上游IP>" < /dev/null
```

- 0% 丢包、延迟稳定 → WAN 正常，问题在 AP↔终端
- 有丢包 → 先排查上游/运营商，**不要继续调路由器**

---

## Phase 2 · 修复硬件卸载（命中根因时执行）

> 前置：Phase 1 已确认 `flow offload - ON`，且症状为「网页正常但游戏卡/掉线」。
> 完整原理见 [06-hardware-offload-fix.md](06-hardware-offload-fix.md)。

### 2.1 记录原值（★ 必须先做，否则无法回滚）

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "$NVRAM get hw_nat_mode; $NVRAM get sfe_enable; \
  $NVRAM get udp_offload; $NVRAM get wifi_offload" < /dev/null
```

**记录**：默认通常为 `hw_nat_mode=4`、`sfe_enable=1`、`udp_offload=`（空）、`wifi_offload=`（空）。

### 2.2 关闭卸载

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "$NVRAM set hw_nat_mode=0; \
  $NVRAM set sfe_enable=0; \
  $NVRAM set udp_offload=0; \
  $NVRAM set wifi_offload=0; \
  $NVRAM commit" < /dev/null
```

**验证写入**：

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "$NVRAM get hw_nat_mode; $NVRAM get sfe_enable" < /dev/null
# 期望：0 和 0
```

### 2.3 STOP 检查点

**在重启前必须确认**：

- [ ] 原值已记录
- [ ] 已确认能物理接触路由器（或已确认远端可恢复）
- [ ] 已告知人「即将重启，约 110 秒断网」

**不满足任一项 → STOP，先问人。**

### 2.4 重启

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "(sleep 1; /sbin/reboot) >/dev/null 2>&1 &" < /dev/null
```

⚠️ **必须用全路径 `/sbin/reboot`**。裸 `reboot` 不在 PATH 里，会**静默失败**。

**等待约 110 秒**后验证。

### 2.5 验证（逐项核对）

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "
  echo '--- 开关 ---'; $NVRAM get hw_nat_mode; $NVRAM get sfe_enable
  echo '--- 日志 ---'; grep -iE 'flow offload' /tmp/syslog.log
  echo '--- 负载 ---'; uptime
  echo '--- MTU/MSS ---'; ip link show $WAN_IF | head -1
  iptables -t mangle -L FORWARD -n -v | grep -i tcpmss
  echo '--- DNS ---'; pidof dnsmasq
" < /dev/null
```

**通过标准**：

| 检查 | 预期 |
|---|---|
| `hw_nat_mode` | `0` |
| `sfe_enable` | `0` |
| 日志 | **`IPv4 UDP flow offload - OFF`** |
| `uptime` 负载 | 接近 `0.00` |
| `eth3 mtu` | `1492`（若已做 Phase 4） |
| MSS 规则 | 存在且计数 > 0 |
| `pidof dnsmasq` | 有输出 |

> ⚠️ `hw_nat` 模块**仍会出现在 `/proc/modules`**，这是正常的。
> **以日志 `flow offload - OFF` 为准**，不要看模块列表。

**失败处理**：

- 日志仍是 `ON` → `nvram commit` 未生效或没重启成功；重做 2.2–2.4
- dnsmasq 没起来 → **立即**排查（见 [05](05-mtu-mss-dns.md) 第 4 节），必要时裸跑 `/usr/sbin/dnsmasq` 救援
- 完全不可达 → 物理断电重启

---

## Phase 3 · 完整体检（未命中 Phase 2 时执行）

按 [07-diagnostics-playbook.md](07-diagnostics-playbook.md) 的三、四节逐项排查。

**重点排查顺序**：

1. **卸载开关** —— 已排除
2. **每终端 RSSI / `psm`** —— 判断是否弱信号或休眠
3. **发包节奏对比**（1s vs 0.1s）—— 区分省电 vs 真丢包
4. **MTU 黑洞** —— `ping -D -s` 递减试探
5. **DNS 成功率** —— 20 次解析统计
6. **信道干扰** —— 扫频看邻居

**注意**：只有在 1–3 排除后，才去查 4–6。

---

## Phase 4 · 加固项（按需，可独立执行）

### 4.1 MTU / MSS 钳制

详见 [05](05-mtu-mss-dns.md)。**先测出真实路径 MTU，再设值**：

```sh
# 递减试探，找到能稳定通过的最大值；路径MTU = 该值 + 28
ssh -i $SSH_KEY admin@$ROUTER_IP "ping -D -s 1464 <上游IP>" < /dev/null
```

部署（脚本见 [../../scripts/post_wan_script.sh](../../scripts/post_wan_script.sh)）：

```sh
scp -i $SSH_KEY scripts/post_wan_script.sh admin@$ROUTER_IP:/etc/storage/
ssh -i $SSH_KEY admin@$ROUTER_IP "chmod +x /etc/storage/post_wan_script.sh; \
  /sbin/mtd_storage.sh save" < /dev/null
```

### 4.2 DNS / dnsmasq 优化

详见 [05](05-mtu-mss-dns.md)。

**★ 安全红线（必须遵守）**：

1. 自定义 conf **绝不要写 `cache-size`**（主配置已有 → 重复关键字 → dnsmasq 启动失败 → **全家断网**）
2. 改完**必须先校验**：

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "/usr/sbin/dnsmasq --test -C /etc/dnsmasq.conf" < /dev/null
# 必须输出 'syntax check OK'  ← 否则 STOP，不要重启
```

3. 校验通过才重启：

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "/sbin/rc restart_dns; sleep 2; pidof dnsmasq" < /dev/null
```

### 4.3 无线调参

详见 [04](04-wireless-tuning.md)。**原则**：

- 信道用**扫频结果**决定，不要猜
- 频宽按**账号/宽带上限**决定，不要追 PHY 峰值
- 弱信号踢除阈值**先取证再动**
- SSID / 信道 / 频宽改动**必须重启**才落地（`rc restart_wifi` 不生效）

---

## Phase 5 · 收敛与交付

1. **复测并对比 Phase 1 基线**，把前后数值列成表
2. **确认所有持久化已保存**：

```sh
ssh -i $SSH_KEY admin@$ROUTER_IP "/sbin/mtd_storage.sh save; echo SAVED" < /dev/null
```

3. **再做一次完整重启**，确认所有配置**开机自恢复**（这是最容易漏的一步）
4. 输出交付报告，格式：

```markdown
## 变更清单
| 项 | 原值 | 新值 | 是否持久化 |

## 效果对比
| 指标 | 修复前 | 修复后 |

## 回滚方法
<逐条给出>

## 遗留问题
```

---

## 附：Phase 依赖图

```
Phase 0 环境识别
    │
    ▼
Phase 1 基线 ──(flow offload = ON)──► Phase 2 关卸载 ──► Phase 5 收敛
    │                                     ▲
    └──(flow offload = OFF)──► Phase 3 完整体检 ──┘
                                     │
                                     └──► Phase 4 加固（可独立）
```
