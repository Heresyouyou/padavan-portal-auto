# 验证配置快照 —— 2026-10-02-good

一份**已验证可用**的 K2P（Padavan）路由器配置，供日后一键恢复。

## 这一版改了什么（相对 2026-09-30）

- **5GHz 信道 `157` → `149`（40MHz 不变）**，其余全部不变。
- 原因：楼上宿舍路由器占用 157 信道形成**共道干扰**，傍晚开始劣化；
  表现为评论区半天打不开（TCP 握手卡 SYN 重传）、游戏不断断线重连，
  且**整机重启路由器无效**。换到干净的 149 后网络立即恢复正常。

## 验收证据

| 项 | 结果 |
|---|---|
| 上游核验 | 路由器→WAN网关 `10.100.255.254` 0% 丢包 / 0.5ms；路由器→校园门户 `222.197.192.59` 0% 丢包 / 2.1ms |
| 空闲延迟 | 网关 1.5/2.7/10.8ms（stddev 1.4ms）；公网 25ms（stddev 8.3ms） |
| 负载延迟 | 下行 ~48Mbps 时 网关→9.3ms、公网→49ms（max 158ms）—— 路由器无 tc，存在 bufferbloat |
| 5GHz | 信道 149 / 40MHz / 400Mbps |

## 关键配置

见 [nvram-keys.txt](nvram-keys.txt)。要点：

- 5G 信道**变量名是 `wl_channel`（小写）**，不是 `wl_Channel`
- `wl_TxPower=40`（100% 会因 PA 非线性导致下行重传率飙到 41%）
- 硬件卸载**全关**：`hw_nat_mode=0` / `sfe_enable=0` / `udp_offload` 空 / `wifi_offload` 空
- 开机钩子必须继续关闭这 9 项（见下）

## 文件

| 文件 | 说明 |
|---|---|
| [started_script.sh](started_script.sh) | 开机钩子（**已脱敏**，账号密码为占位符） |
| [dnsmasq.conf](dnsmasq.conf) | dnsmasq 优化片段（缓存 + filter-AAAA） |
| [nvram-keys.txt](nvram-keys.txt) | 关键 nvram 键值（已脱敏） |
| [restore.sh](restore.sh) | 一键恢复脚本 |

## 恢复方法

```sh
# ① 传到路由器
scp -r snapshots/2026-10-02-good admin@192.168.123.1:/etc/storage/snapshots/
# ② 跑恢复脚本
ssh admin@192.168.123.1 "sh /etc/storage/snapshots/2026-10-02-good/restore.sh"
# ③ ★ 填回校园网账号密码（快照里是占位符）
ssh admin@192.168.123.1 "vi /etc/storage/started_script.sh"   # 改 USER / PASS 两行
# ④ 重启路由器（钩子只在开机时执行一次）
```

## ⚠️ 脱敏说明

本快照**不含任何真实凭据**：校园网账号/密码、认证链接会话令牌均已替换为占位符。
恢复后**必须手工填回**，否则 Portal 认证会失败（表现为连上 WiFi 但一直弹认证页）。

## 钩子内必须保留的 9 项

```sh
for kv in TxPower=40 HtAutoBA=0 HtBaWinSize=0 ITxBfEn=0 ETxBfEnCond=0 PktAggregate=0 TxBurst=0 HtStbc=0 VhtStbc=0; do
```

把这 9 项（尤其后 6 项）从钩子里删掉会导致延迟与抖动爆炸。
钩子 md5（脱敏前）= `7d1a8bef1f97ffee83ab093bfe31228a`。
