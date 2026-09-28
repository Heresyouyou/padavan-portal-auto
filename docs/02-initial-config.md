# 02 · 初始配置

## ★ 顺序原则：先配 WiFi，再插 WAN

**配置 WiFi 和管理路由器时，WAN 口不要插网线。**

原因：校园网墙插通电后，WAN 一旦拿到 IP 就会触发 Portal **302 重定向**，
干扰管理界面操作（页面被劫持跳转、会话丢失）。

> 这是新手最容易踩的坑，务必先配完再插 WAN。

## 1. 无线配置

### 通用 2.4GHz

| 参数 | 值 | 说明 |
|---|---|---|
| 无线模式 | AP 模式 | |
| ESSID | 纯英文无空格，如 `MyRouter-2.4G` | 避免兼容问题 |
| 频道 | **1 / 6 / 11**（手动） | 不要 Auto，避免干扰 |
| 频道带宽 | **20MHz** | 2.4G 用 20MHz 最稳 |
| 传输功率 | 100% / Maximum | |
| 加密 | **WPA2-Personal (AES)** | 不要 Mixed / WPA3 |
| WPA 密钥 | ≥ 8 位 | |
| Country/Region | **United States (US)** | 比 CN 允许的功率高 |
| Enable WMM | ✅ 勾 | |
| 隐藏 SSID | ❌ 不勾 | |

### 通用 5GHz

| 参数 | 值 | 说明 |
|---|---|---|
| ESSID | 如 `MyRouter-5G` | |
| 频道 | **36/40/44/48** 或 **149/157/161/165** | ❌ 不要 52–144（DFS，需避让雷达） |
| 频道带宽 | 先设 **80MHz** 再按第 04 章实测下调 | |
| Country/Region | **United States (US)** | |
| Enable 256-QAM | ✅ 勾 | |
| Enable MU-MIMO | 视需求 | 双流设备少时可关 |

> **双频命名建议**：见 [04-wireless-tuning.md](04-wireless-tuning.md) 的「统一 SSID」一节。
> 统一 SSID 让客户端自动就近优选，但需注意与弱信号踢除阈值的配合。

### 验证

手机搜 WiFi，能搜到即说明 MT7615 驱动正常。

## 2. 插入 WAN 并确认上网

```
WAN 口 → 校园网墙插
等约 10 秒 → 路由器自动 DHCP 获取 IP
```

验证：管理界面 → 状态 → WAN 口信息，应显示分配的 IP + DNS。

此时若还不能上网，说明需要**校园网认证**，见 [03-campus-portal-auth.md](03-campus-portal-auth.md)。

## 3. 开启 SSH（后续所有运维的前提）

Padavan 的**后台控制台在部分版本里是坏的**
（实测：`apply.cgi` 返回空、`console_response.asp` 无输出、jQuery 回调异常）。

> **结论：把 SSH 作为唯一可信的运维通道。** 本手册后续命令全部基于 SSH。

配置：`系统管理 → 服务 → 启用 SSH 服务`
推荐设为**仅公钥**模式，并把公钥写入路由器。

登录：

```sh
ssh -i ~/.ssh/<你的私钥> -o StrictHostKeyChecking=no -o ConnectTimeout=8 admin@192.168.123.1
```

> **⚠️ 执行注意**：通过 SSH 批量执行命令时，**不要用 heredoc**（多行 `<< 'EOF'` 容易挂起不返回）。
> 改用**单行命令 + `;` 分隔**，并加 `< /dev/null` 防止 stdin 被占用。

## 4. 持久化路径认知（Padavan 特有，很重要）

| 路径 | 性质 | 是否持久 |
|---|---|---|
| `/` | squashfs 只读，100% 满 | — |
| `/tmp` | tmpfs，约 40MB | ❌ 重启丢失 |
| `/etc` | tmpfs，约 5.6MB | ❌ 重启丢失 |
| **`/etc/storage/`** | mtd5 持久区，约 720KB | ✅ **持久** |

**要持久化的东西一律放 `/etc/storage/`**，并且写入后必须执行：

```sh
/sbin/mtd_storage.sh save
```

## 5. rc 认可的开机钩子

Padavan 的 `rc` 会调用以下脚本（放在 `/etc/storage/`）：

| 脚本 | 执行时机 |
|---|---|
| `start_script.sh` | 开机早期（网络起来前） |
| `post_iptables_script.sh` | 防火墙规则建立后 |
| **`post_wan_script.sh`** | **WAN 拿到 IP 后** ← 做 WAN 相关调优用这个 |
| `inet_state_script.sh` | 网络状态变化时 |
| `crontabs_script.sh` | crontab 初始化 |

所有钩子脚本**结尾必须写 `exit 0`**，否则可能影响启动流程。

## 6. ⚠️ 两个高危操作规范

1. **重启必须用全路径 `/sbin/reboot`**
   裸 `reboot` 不在 PATH 里，会**静默失败**——你会以为重启了，实际没有。
   （`/sbin/reboot` 是 `rc` 的符号链接。）

2. **配置改完不等于生效**
   无线类参数（信道/频宽/SSID）**必须重启**才落地，`rc restart_wifi` 不生效。
   详见 [04-wireless-tuning.md](04-wireless-tuning.md)。
