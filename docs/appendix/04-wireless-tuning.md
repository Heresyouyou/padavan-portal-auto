# 04 · 无线调优

> 📎 本文属**进阶附录**，与锐捷 Portal 认证插件无直接关联，按需查阅。
> 返回 [README](../../README.md) ｜ [Portal 自动认证](../portal-auth.md)

> 平台相关：接口命名与 `iwpriv`/`nvram` 为 Padavan 特有；调优思路通用。

## 1. 接口命名（先记牢，否则后面所有命令都用错）

| 频段 | 接口 | nvram 前缀 |
|---|---|---|
| **5GHz** | `ra0` | `wl_*` |
| **2.4GHz** | `rax0` | `rt_*` |
| 网桥 | `br0`（成员 eth2 / ra0 / rax0） | — |
| WAN | `eth3` | — |

> 与 Intel/OpenWrt 的 `wlan0/wlan1` 直觉相反，**不要猜**：先 `iwconfig` 确认。

## 2. 信道选择：用扫频结果决定，不要猜

### 5GHz

- **非 DFS 信道只有两组**：`36–48` 与 `149–165`
- `52–144` 属 DFS，需避让雷达，可能触发信道切换

### 2.4GHz

- **只有 1 / 6 / 11 三个非重叠信道**
- 其余信道（2–5、7–10）会与相邻信道重叠

### 怎么扫

**macOS**（`airport` CLI 在新系统中已移除，改用）：

```sh
system_profiler SPAirPortDataType | grep -A 3 -i 'channel'
networksetup -getairportnetwork en0
```

**Linux / OpenWrt**：

```sh
iw dev <iface> scan | grep -E 'freq|signal|SSID'
```

把结果当**频谱仪**用：选邻居最少、信号最弱的信道。

> 实测案例：ch36 上有 −49dBm 的强信号 AP（最挤）；ch157 邻居仅 −89dBm（最干净）。
> 2.4G 侧 ch6 挤了 4 个 AP（含 −63dBm），ch11 空闲 → 2.4G 从 ch6 迁到 ch11。

## 3. 频宽：40MHz vs 80MHz

| 对比项 | 40MHz | 80MHz |
|---|---|---|
| 2×2 11ac PHY 速率 | 400 Mbps | 867 Mbps |
| 占用 5GHz 信道数 | 2 | 4 |
| 抗干扰能力 | **强**（每子载波 SNR 高约 3dB，占用窄） | 弱 |
| 可用非重叠信道 | 多 | 少 |
| 单设备实测 TCP | > 200 Mbps | > 400 Mbps |

**选择依据：先看账号/宽带上限，而不是看 PHY 峰值。**

实测案例：校园网账号硬顶约 **70Mbps**（单连接 71Mbps，4 并发 68.7Mbps）。
此时 867Mbps 完全是浪费，**40MHz 的 >200Mbps 已有 3 倍余量，且在拥挤环境明显更稳**。

> ⚠️ **改 40MHz 不会导致变慢。** 若变慢，去查客户端无线链路、MTU、DNS，
> 而不是把频宽改回去。

## 4. 统一 SSID（双频同名）

### 做法

把 5G 与 2.4G 的 SSID 设成**完全相同**（去掉 `_5G` 后缀）：

| 项 | 值 |
|---|---|
| `wl_ssid` | 同一名称 |
| `rt_ssid` | 同一名称 |
| `wl_HT_BW` | `1`（40MHz） |
| `rt_HT_BW` | `0`（20MHz） |

### 收益与代价

- ✅ 客户端自动就近优先 5G，隔墙回退 2.4G，无需手动切网
- ✅ 若 2.4G 本来就叫这个名字，改完**客户端几乎无需重新配网**
- ⚠️ 需要与**弱信号踢除阈值**配合，否则边缘设备可能在两频段间来回抖动

```sh
# 查看当前
/usr/sbin/nvram get wl_ssid; /usr/sbin/nvram get rt_ssid
/usr/sbin/nvram get wl_HT_BW; /usr/sbin/nvram get rt_HT_BW
```

## 5. 弱信号踢除阈值

```sh
/usr/sbin/nvram get wl_KickStaRssiLow      # 5G 踢除门限
/usr/sbin/nvram get wl_AssocReqRssiThres   # 5G 关联门限
/usr/sbin/nvram get rt_KickStaRssiLow      # 2.4G
/usr/sbin/nvram get rt_AssocReqRssiThres
```

- 设得过严（如 −70）→ 边缘设备被反复踢掉、重连
- 设得过松（如 −80）→ 慢速弱信号客户端占用空口，拖慢全场
- 实测经验值：**5G 用 −72 平衡较好**

### ★ 但是：先确认问题真的是弱信号，再动这个阈值

**实测教训**：某次「其他设备游戏频繁断连」疑似弱信号踢除所致，
但抓取每终端状态后发现有 **4 台设备 RSSI 全在 −40 ~ −58（信号极好）**，
**直接排除**了弱信号踢除这条嫌疑。真因是 UDP 硬件卸载（见第 06 章）。

> **不要凭症状猜参数，先取证。**

## 6. 如何获取每终端的真实空口状态

`iwpriv` 的多数查询命令在 MT7615 闭源驱动上**无效**：

| 命令 | 结果 |
|---|---|
| `iwpriv ra0 show mac` | ❌ `Invalid argument` |
| `iwpriv ra0 get_stainfo` | ❌ 无效 |
| `iwpriv ra0 get_mac_table` | ❌ 无效 |
| `iwpriv ra0 stat` | ⚠️ 可用但**不可信**（双频上报完全相同计数器，是共享/全局值） |

**可用替代：驱动会把 MacTable 定期 dump 进 syslog**

```sh
grep -A 8 'MAC                MODE' /tmp/syslog.log | tail -40
```

输出字段：

```
MAC                MODE  AID  BSS psm ipsm iipsmWMM  MIMOPS RSSI0/1/2/3   PhMd(T/R) BW(T/R) MCS(T/R) ...  Idle  Rate(T/R)
FE:66:5A:26:1D:1C  ...   psm=1/0 ...  -44/-40/-127/-127  VHT/OFDM  20M/20M  2S-M8/0  ...
```

关注：

- `RSSI0/1/2/3` — 每根天线的信号强度
- `psm` / `ipsm` / `iipsm` — **省电模式标志**（1 = 该终端处于休眠省电）
- `BW(T/R)` — 收发频宽；`MCS(T/R)` — 收发调制阶数
- `Idle` — 空闲时长；`wdev0` / `wdev2` — **所属频段**

## 7. 参数热改边界（省大量重启时间）

| 参数 | 运行时热改 | 说明 |
|---|---|---|
| `PktAggregate` | ✅ | `iwpriv ra0 set PktAggregate=0` 立即生效 |
| `TxBurst` | ✅ | `iwpriv ra0 set TxBurst=0` |
| `IgmpSnEnable` | ✅ | `iwpriv ra0 set IgmpSnEnable=0` |
| `Channel` | ✅ | `iwpriv ra0 set Channel=157` |
| `VHT_BW` / `HtBw` | ❌ | 报 `set (8BE2): Invalid argument` |
| `APSDCapable` / `PSM` / `BcnReq` | ❌ | 报 `Interface doesn't accept private ioctl` |
| `wifi_offload` / `udp_offload` | ❌ | 必须 `nvram` + **重启** |
| 信道 / 频宽 / SSID | ❌ | `nvram` + **重启** |

> **热改 ≠ 持久**：`iwpriv` 设的值重启即失效。
> 要持久必须同时写 `nvram set wl_<ParamName>=<val>`（2.4G 用 `rt_` 前缀）并 `nvram commit`。

### 帧聚合/突发/IGMP 侦听 的取舍

关闭 `PktAggregate` / `TxBurst` / `IgmpSnEnable` 可降低**延迟尖峰**，
但会略微降低峰值吞吐。**游戏/实时优先**时建议关闭；**大文件吞吐优先**时保持开启。

## 8. 无线参数生效的两个大坑

1. **`rc restart_wifi` 不会应用** `wl_channel` / `wl_HT_BW` / SSID
   必须 `/sbin/reboot`（**全路径**）才落地。
   > 曾遇到 `wl_HT_BW=1` 已 commit，但运行时仍是 80MHz —— 就是没重启。

2. **重启耗时约 110 秒**才恢复 SSH/网络，脚本里需等待足够久。

## 9. MT7615 双频共射频的注意点

`DBDC_MODE=1` 下，5G 与 2.4G **共用一个射频芯片**，
2.4G 重载会**拖累 5G**。因此：

- 尽量减少不必要的 BSS（如关闭未使用的访客网络）
- 访客 AP 若不用，务必关闭：

```sh
/usr/sbin/nvram get wl_guest_enable; /usr/sbin/nvram get rt_guest_enable
# 应均为 0；对应接口 ra1 / rax1 应为 down
```
