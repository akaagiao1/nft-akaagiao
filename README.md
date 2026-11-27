# nft-akaagiao — 高性能内核态 nftables 端口转发管理脚本

> 灵感源自 [zywe03/realm-xwPF](https://github.com/zywe03/realm-xwPF)，针对 Linux 内核态 `nftables` 深度重构优化：零用户态拷贝、零断流原子热重载、原生内核流量统计、DDNS 自动刷新、内核加权负载均衡与故障转移，以及一键无缝替代 Realm。

## 快速开始

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/akaagiao1/nft-akaagiao/main/nftPF.sh | sudo bash -s install
```

### 网络受限时使用加速源安装

```bash
NFTPF_GH_PROXY="https://v6.gh-proxy.org" curl -fsSL https://v6.gh-proxy.org/https://raw.githubusercontent.com/akaagiao1/nft-akaagiao/main/nftPF.sh | sudo bash -s install
```

安装完成后，随时输入快捷命令 **`zz`** 打开交互式管理界面：

```bash
sudo zz
```

### 一键将现有 Realm 无缝迁移为 nftables

如果你的中转机正在运行 `realm`（无论是 `realm-xwPF` 的 `/etc/realm/rules/` 还是原生 `config.json` / `config.toml`），安装后只需一条命令即可自动导入全部规则、停用 Realm、应用内核转发优化并由 `nftables` 原子接管：

```bash
sudo zz switch-from-realm
```

---

## 核心特性与优化亮点

相比用户态转发工具（如 `realm`）或传统的 `iptables` 脚本，`nft-akaagiao` 具备以下工程优势：

- **独立隔离表 + 零断流原子重载**
  - 仅操作专属表 `table ip nftpf_v4` 与 `table ip6 nftpf_v6`，**绝不执行 `flush ruleset`**，与 Docker / UFW / firewalld / Fail2Ban / 端口流量狗完全和平共处。
  - 每次变更前先执行 `nft -c -f` 严格语法预校验，校验失败绝不触碰线上规则；校验通过后以单一 Netlink 事务原子替换，**已建立连接不断流**。
- **纯内核态全功能 NAT 转发**
  - 支持 `TCP+UDP` 双栈 / 纯 `TCP` / 纯 `UDP`。
  - 支持单端口、逗号批量端口（`80,443`）以及 **端口段 1:1 透传**（`10000-10100`）或端口段汇聚到单端口。
  - 支持自定义入口监听 IP 或网卡名，以及自定义出口 SNAT IP / 网卡名（默认自动 `masquerade`，完美适配 NAT VPS 和动态 IP）。
- **原生内核端口流量统计（重启/重载不丢数据）**
  - 在 `prerouting` 打上每条规则专属 `ct mark`，在 `forward` 链按 `ct direction original / reply` 精确统计每条规则的实时上下行字节数与包数。
  - 重载规则或重启机器前自动保存计数器快照，下次加载直接回填初始值，**零额外守护进程开销**。
- **域名 / DDNS 目标自动跟踪**
  - 原生支持填写落地机域名，内置解析缓存（DNS 临时波动时自动兜底），通过 `systemd timer` / `cron` 定期检测，仅在解析 IP 真正变化时触发原子热重载。
- **内核态加权负载均衡 + 故障转移**
  - 使用 `nftables` 原生 `numgen inc`（加权轮询）与 `jhash`（源 IP 哈希）在内核直接完成多目标分流。
  - 轻量化健康检查定时器支持失败阈值、恢复阈值、冷却期防抖动、全节点故障兜底保留首节点，并内置 **Telegram Bot / 飞书 / 钉钉 / 企微 Webhook** 告警。
- **一键中转内核调优**
  - 自动配置 `ip_forward`（IPv4/IPv6）、按内存自动匹配的 `nf_conntrack_max` 与超时参数、`rp_filter=2`、TCP MSS 钳制（防 PPPoE/NAT 链路 MTU 黑洞）、`BBR + FQ`，以及可选的 **Flowtable 极速转发卸载** 与 **Hairpin NAT**。
- **多发行版与双 Init 支持**
  - 自动适配 Debian / Ubuntu、Alpine、CentOS / RHEL / Rocky / AlmaLinux / Fedora，同时兼容 `systemd` 与 `OpenRC`。

> **架构边界说明**：`nftables` 属于纯 L3/L4 内核态 NAT 转发，性能与延迟极佳，但不支持 L7 隧道加解密（如 `ws`/`wss`/`tls`、`Proxy Protocol`），也不支持直接 IPv6 ↔ IPv4 跨栈转换（仅支持 v4→v4 与 v6→v6）。迁移 Realm 时脚本会自动识别并明确提示。

---

## 常用 CLI 命令

| 命令 | 说明 |
| :--- | :--- |
| `sudo zz` | 打开交互式管理主菜单 |
| `sudo zz status` | 查看运行状态、规则概览与实时流量 |
| `sudo zz list` | 查看全部规则详细信息 |
| `sudo zz apply` / `zz reload` | 重新编译校验并原子热重载规则（不断流） |
| `sudo zz stop` | 停止转发并清空 `nftpf` 独立表（自动保留流量快照） |
| `sudo zz ruleset` | 查看当前内核生效的 `nftables` 规则集 |
| `sudo zz traffic` | 查看所有规则上下行实时流量面板 |
| `sudo zz traffic reset` | 清零所有规则流量计数器 |
| `sudo zz ddns` | 立即检测所有域名目标并在 IP 变化时热更新 |
| `sudo zz failover status` | 查看故障转移节点健康状态 |
| `sudo zz sysctl` | 一键应用内核中转调优参数 |
| `sudo zz migrate [路径]` | 仅导入 Realm 配置（不停止 Realm，适合预览） |
| `sudo zz switch-from-realm` | 一键导入 Realm 规则、停用 Realm 并由 nftables 接管 |
| `sudo zz export [路径]` | 导出全部规则、设置与流量数据（`.tar.gz`） |
| `sudo zz import <压缩包>` | 导入配置备份包并立即原子生效 |
| `sudo zz update` | 从 GitHub 拉取更新至最新版脚本 |
| `sudo zz uninstall` | 分阶段无残留彻底卸载 |

---

## 目录结构

```text
/usr/local/bin/
├── nftPF.sh                # 主入口与 bootstrap 引导器
├── zz -> nftPF.sh          # 快捷命令
└── nftpf-lib/              # 模块库
    ├── core.sh             # 核心常量、系统检测、校验、DNS缓存
    ├── sysctl.sh           # 内核转发与网络调优
    ├── nft.sh              # nftables 规则编译、预校验、原子重载与持久化
    ├── rules.sh            # 规则 CRUD、负载均衡与备份迁移
    ├── ddns.sh             # 域名目标自动刷新
    ├── failover.sh         # 健康检查、故障转移与告警通知
    ├── migrate.sh          # Realm 配置识别与一键切换
    └── ui.sh               # 交互式 TUI 与 CLI 分发

/etc/nftpf/
├── settings.conf           # 全局高级选项（MSS钳制/Flowtable/DDNS间隔等）
├── notify.conf             # Telegram / Webhook 通知配置
├── ruleset.nft             # 最近一次通过校验的完整 nftables 规则集
├── rules/                  # 单规则配置文件（rule-1.conf, ...）
└── state/                  # 运行态数据（流量计数器快照、DNS缓存、健康状态）
```

## License

[MIT](LICENSE)
