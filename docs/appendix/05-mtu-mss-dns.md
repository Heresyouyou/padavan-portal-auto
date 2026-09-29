# 05 · MTU / MSS 与 DNS 优化

> 📎 本文属**进阶附录**，与锐捷 Portal 认证插件无直接关联，按需查阅。
> 返回 [README](../../README.md) ｜ [Portal 自动认证](../portal-auth.md)

> 原理通用；命令为 Padavan 特有。

## 一、MTU 黑洞与 MSS 钳制

### 1. 症状

- 网页能打开但**很慢**、部分网站白屏
- 能 ping 通但**大包丢失**
- 某些应用（游戏、VPN、大文件下载）**连不上**

### 2. 原理

WAN 侧真实路径 MTU 小于路由器接口 MTU（常见于 PPPoE / 校园网隧道）。
路由器发出的 1500 字节大包在链路上被丢弃，且 ICMP `fragmentation needed` 被过滤 →
**PMTUD（路径 MTU 发现）失效** → 大包静默丢失。

### 3. 怎么测出真实路径 MTU

```sh
# -D 置 DF 位（不允许分片）；-s N 是 ICMP 数据长度，IP 总长 = N + 28
ping -D -s 1472 <目标IP>     # IP 总长 1500
ping -D -s 1464 <目标IP>     # IP 总长 1492
```

递减试探，**能稳定通过的最大值 + 28 就是路径 MTU**。

> 实测案例：总长 1500 通过率 1/5，**1492 通过 5/5** → 路径 MTU = **1492**。

### 4. 修复（两步，缺一不可）

```sh
# ① 下调 WAN 接口 MTU
ip link set eth3 mtu 1492

# ② MSS 钳制（比只改 MTU 更可靠，能管住转发流量）
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1452
```

**MSS = MTU − 40**（IPv4 TCP 头 20 + IP 头 20）：
`1492 − 40 = 1452`

> **为什么要钳制 MSS**：只改接口 MTU 管不到客户端自己声明的大 MSS，
> 钳制后路由器会主动改写 SYN 报文里的 MSS 值，从源头避免大包。

### 5. 持久化（开机自恢复）

放到 `/etc/storage/post_wan_script.sh`（WAN 拿到 IP 后执行）：

见 [../../scripts/post_wan_script.sh](../../scripts/post_wan_script.sh)

```sh
scp scripts/post_wan_script.sh admin@192.168.123.1:/etc/storage/
ssh admin@192.168.123.1 "chmod +x /etc/storage/post_wan_script.sh; /sbin/mtd_storage.sh save" < /dev/null
```

### 6. 验证

```sh
ssh admin@192.168.123.1 "ip link show eth3 | head -1; \
  iptables -t mangle -L FORWARD -n -v | grep -i tcpmss" < /dev/null
```

预期：

```
2: eth3: <...> mtu 1492 ...
  <pkts> <bytes> TCPMSS  tcp -- 0.0.0.0/0 0.0.0.0/0 tcp flags:0x06/0x02 TCPMSS set 1452
```

> **关键**：`pkts` 计数**必须 > 0**，且重启后仍存在。
> 若计数为 0，说明规则位置不对或流量没走 FORWARD。

### 7. 坑

| 坑 | 说明 |
|---|---|
| `nvram wan_mtu` 无效 | 实测设了也不生效，**不要依赖**，用 `ip link set` |
| 忘记 `save` | 不执行 `mtd_storage.sh save`，重启即丢 |
| 只改 MTU 不钳 MSS | 客户端仍会发大包，问题依旧 |

---

## 二、DNS 优化（dnsmasq）

### 1. 先确认哪些 DNS 真的可达

校园网通常**只放行校内 DNS**，公共 DNS 全部不可达：

```sh
for s in 223.5.5.5 1.1.1.1 8.8.8.8 114.114.114.114; do
  ping -c 2 -W 1 $s >/dev/null 2>&1 && echo "$s OK" || echo "$s UNREACHABLE"
done
```

> 实测案例：只有 `222.197.198.33`、`222.172.200.68` 可达，
> 其余（含 223.5.5.5 / 1.1.1.1 / 8.8.8.8）**全部不可达**。
> **结论：换公共 DNS 是无效的努力，别浪费时间。**

### 2. 找到可持久化的注入点（Padavan 特有）

Padavan 的 `/etc/dnsmasq.conf` 由 `rc` **自动生成**（重启会重写），直接改无效。

正确做法：生成的主配置末尾会有引入行，往**被引入的文件**里写：

```
# 主配置 /etc/dnsmasq.conf 里通常有：
conf-file=/etc/storage/dnsmasq/dnsmasq.conf
conf-dir=/etc/storage/dnsmasq/dnsmasq.d
```

→ **要持久化就写 `/etc/storage/dnsmasq/dnsmasq.conf`**

### 3. 有效参数

见 [../../scripts/dnsmasq-optimize.conf](../../scripts/dnsmasq-optimize.conf)

```
min-cache-ttl=1800     # 实测 TTL 由 53/298 → ~1789，大幅减少上游查询
max-cache-ttl=86400
filter-AAAA            # 若网络无 IPv6，过滤 AAAA 可让每个域名少一次查询
```

> `filter-AAAA` 仅在**确认本机/链路无 IPv6**时使用。
> 检查：`ip -6 addr show` 无 `inet6`、无 IPv6 默认路由。

### 4. ★★ 血的教训：改 dnsmasq 一定会踩的坑

**坑 1：`cache-size` 不能重复定义 → 全家断网**

主配置已有 `cache-size=1024`，若自定义 conf 再写一次：

```
dnsmasq: illegal repeated keyword at line N
```

→ **dnsmasq 拒绝启动 → DNS 全断 → 全家无法上网**

> 这是真实踩到的故障。**自定义 conf 里绝不要写 `cache-size`**
> （要改缓存大小请用 `nvram set dnsmasq_cache_size=<N>`）。

**坑 2：改完必须先校验，再重启**

```sh
# ① 语法校验 —— 必须输出 "syntax check OK"
/usr/sbin/dnsmasq --test -C /etc/dnsmasq.conf

# ② 校验通过才重启
/sbin/rc restart_dns
```

> **顺序错误 = 断网。** 任何时候都不要跳过 `--test`。

**坑 3：`rc restart_dns` 是有效的**

若重启后 `pidof dnsmasq` 为空，**99% 是配置非法导致进程退出**，不是命令无效。
用 `--test` 定位。

**坑 4：`rc restart_dns` 不会重写 `/etc/dnsmasq.conf`**

改了 `nvram dnsmasq_cache_size` 这类由 rc 生成的配置项，**必须重启路由器**才生效。

**坑 5：手动救援命令**

rc 挂了时的救命命令（读默认 `/etc/dnsmasq.conf`，无需参数）：

```sh
/usr/sbin/dnsmasq
```

**坑 6：客户端要指向正确的监听地址**

`nvram listen-address` 通常是 `192.168.123.1`，**`127.0.0.1` 不是监听地址**：

```sh
dig game.qq.com @192.168.123.1      # ✅
dig game.qq.com @127.0.0.1          # ❌ 会失败
```

### 5. 验证

```sh
# 1) 进程在否
pidof dnsmasq

# 2) 缓存驻留是否生效（应显示 ~1800 的 TTL）
dig game.qq.com @192.168.123.1 +noall +answer

# 3) AAAA 是否被过滤（ANSWER 里不应出现 IPv6 地址）
dig AAAA game.qq.com @192.168.123.1 +noall +answer

# 4) 成功率（应接近 20/20）
for i in $(seq 1 20); do
  dig +time=2 +tries=1 game.qq.com @192.168.123.1 | grep -q NOERROR && echo ok
done | wc -l
```

> **判读注意**：过滤 CNAME-only 答案时，不要用 `grep -E '^[0-9]'` 判成功/失败，
> 会误判。应检查 `status: NOERROR`。

### 6. 效果基线（实测）

| 指标 | 优化前 | 优化后 |
|---|---|---|
| DNS 成功率 | 18/20 | **20/20** |
| TTFB `game.qq.com` | — | 0.17s |
| TTFB `lol.qq.com` | — | 0.10s |
| TTFB `www.qq.com` | 7.5s | **0.22s** |

---

## 三、其他网络栈参数（可选）

```sh
echo 0  > /proc/sys/net/ipv4/tcp_slow_start_after_idle
echo 1  > /proc/sys/net/ipv4/tcp_mtu_probing
echo 1  > /proc/sys/net/ipv4/tcp_tw_reuse
echo 30 > /proc/sys/net/ipv4/tcp_fin_timeout
echo 3000 > /proc/sys/net/core/netdev_max_backlog
echo 1024 > /proc/sys/net/core/somaxconn
```

> ⚠️ Padavan **没有 `sysctl` 命令**，必须直接 `echo` 到 `/proc/sys/`。
> 另外该内核常**只编译了 cubic/reno**，没有 BBR 模块 —— 不要尝试开 BBR。

持久化：放进 `/etc/storage/start_script.sh` 并 `mtd_storage.sh save`。
