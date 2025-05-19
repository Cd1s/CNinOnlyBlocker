# 🛡️ CNinOnlyBlocker 交互增强版 2.0

🚫 拒绝所有非中国 IP 入站连接｜✅ 仅允许中国 IP 入站｜🌐 支持 IPv4 + IPv6｜🎯 支持端口范围放行｜🔍 智能系统适配

这是一个全面增强的交互式一键脚本，专为服务器用户设计，基于 `ipset` + `iptables` + `ip6tables`，实现**仅允许中国大陆 IP 地址访问服务器入站服务**，同时允许自定义端口放行（支持单端口、多端口、端口范围），支持IPv6策略控制，**不限制出站连接**，并支持**开机自动恢复配置**。

---

## 📦 功能特点

- ✅ **仅允许中国 IP 入站连接（IPv4 / IPv6）**
- ❌ **拒绝所有非中国 IP 入站连接**
- 🎛️ **支持灵活端口放行（支持格式: 80,443,8000-9000）**
- 🌐 **自动检测并支持 IPv6 入站限制（仅在系统支持时启用）**
- ⚙️ **自动适配多种Linux系统**（Debian/Ubuntu, CentOS/RHEL, Alpine）
- 🔍 **智能检测防火墙冲突**（ufw, firewalld, nftables）并提供处理方案
- ⚡ **性能优化**，使用高效批量添加与哈希表优化
- �� **验证防火墙规则**功能，确保规则被正确应用并提供自动修复
- 📊 **检查服务状态**，监控防火墙服务运行情况
- 🧪 **测试端口监听状态**，验证服务可用性
- 💾 自动保存防火墙规则
- 🔁 **多重保障**开机自动还原规则（使用多种启动机制确保可靠恢复）
- 🧹 一键卸载，恢复原始防火墙状态

---

## 🚀 使用方法

```bash
curl -O https://raw.githubusercontent.com/Cd1s/CNinOnlyBlocker/refs/heads/main/allow-cn-inbound.sh && chmod +x allow-cn-inbound.sh && sudo ./allow-cn-inbound.sh
```

运行后可进入交互菜单，支持：

```
1. 安装 IPv4 仅中国入站
2. 安装 IPv6 仅中国入站
3. 查看放行端口
4. 添加放行端口（支持端口范围）
5. 删除放行端口
6. 删除 IPv4 仅国内入站
7. 删除 IPv6 仅国内入站
8. 删除并卸载，放行全部端口
9. 验证防火墙规则
10. 检查服务状态
11. 测试放行端口是否监听
0. 退出
```

---

## 🌟 新增功能说明

### 多系统支持
自动检测并适配不同的Linux发行版，支持：
- Debian/Ubuntu（使用apt包管理器）
- CentOS/RHEL/Fedora（使用yum包管理器）
- Alpine Linux（使用apk包管理器）

### 防火墙冲突检测
启动时自动检测是否存在可能冲突的防火墙服务：
- UFW
- Firewalld
- NFTables
提供三种处理方案：自动禁用、手动处理或继续安装

### 多重启动保障
采用多种机制确保IPv6规则在系统重启后可靠生效：
- 独立的IPv4和IPv6系统服务
- 带延迟的IPv6规则加载策略
- cron启动任务作为备份机制
- 传统init.d脚本支持
- 自动检测和修复机制

### IPv6自动检测与修复
- 只在系统实际支持并启用IPv6时才提供IPv6防护功能
- 验证功能可自动检测并修复未加载的IPv6规则
- 系统启动后自动监测IPv6规则状态

### 灵活端口放行
支持复杂的端口放行格式：
- 单个端口：`80`
- 多个端口：`80,443,8080`
- 端口范围：`8000-9000`
- 混合格式：`80,443,8000-9000,1234`

### 防火墙规则验证与修复
提供功能查看当前应用的防火墙规则状态，并在发现问题时自动尝试修复

### 服务状态监控
检查防火墙规则恢复服务是否正常运行，确保系统重启后规则能自动恢复

### 端口监听测试
检测放行的端口是否有服务在监听，便于排查服务可用性问题

---

## 🧯 卸载方式

若需完全还原所有规则并卸载服务，请选择菜单：

```
8. 删除并卸载，放行全部端口
```

---

## 📂 配置文件路径

| 类型 | 路径 |
|------|------|
| IPv4 ipset | `/etc/ipset/ipset_v4.conf` |
| IPv6 ipset | `/etc/ipset/ipset_v6.conf` |
| IPv4 iptables | `/etc/iptables/rules.v4` |
| IPv6 ip6tables | `/etc/iptables/rules.v6` |
| 放行端口列表 | `/etc/cnblocker/allowed_ports.conf` |
| IPv4服务 | `/etc/systemd/system/ipset-restore-ipv4.service` |
| IPv6服务 | `/etc/systemd/system/ipset-restore-ipv6.service` |
| IPv6重启任务 | `/etc/cron.d/restore-ipv6-rules` |
| IPv6备份脚本 | `/etc/init.d/restore-ipv6-rules` |
| Alpine IPv4启动脚本 | `/etc/local.d/ipset-restore-ipv4.start` |
| Alpine IPv6启动脚本 | `/etc/local.d/ipset-restore-ipv6.start` |
| Alpine IPv6监控脚本 | `/etc/local.d/check-ipv6-rules.start` |

---

## 🔧 系统要求

- 支持的Linux发行版：
  - Debian/Ubuntu 系列
  - CentOS/RHEL/Fedora 系列
  - Alpine Linux
- Root 权限
- 自动安装以下依赖：
  - `ipset`、`iptables`、`ip6tables`、`curl`、`wget`

---

## 🙋 常见问题

> **Q：这个脚本会影响服务器主动访问外网吗？**  
> A：不会。此脚本**仅限制入站连接**，**出站流量不受影响**。

> **Q：可以只配置 IPv4 或 IPv6 吗？**  
> A：可以，分别在菜单中选择即可。如果系统不支持IPv6，脚本会自动跳过IPv6配置。

> **Q：放行端口能保留吗？**  
> A：能，脚本会自动记录并在下次运行中重新应用。

> **Q：如果有其他防火墙软件会冲突吗？**  
> A：脚本会自动检测常见的防火墙软件（ufw、firewalld、nftables）并提供处理方案。

> **Q：如何确认防火墙规则已经生效？**  
> A：可以使用菜单项 "9. 验证防火墙规则" 查看当前应用的规则。如发现IPv6规则未加载，该功能会自动尝试修复。

> **Q：重启后IPv6规则不生效怎么办？**  
> A：2.0版本采用了多重保障机制，包括专用IPv6服务、延迟加载、cron任务和自动修复功能，大幅提高了IPv6规则在重启后的可靠性。如仍有问题，可使用"9. 验证防火墙规则"进行手动修复。

> **Q：为什么端口监听测试显示无法访问，但实际可以访问？**  
> A：端口监听测试只检查本机是否有服务在监听该端口，与防火墙放行无关。如果端口已放行但没有服务监听，会显示无法访问。

---

## 🌐 数据源说明

**IPv4 主源：**  
`https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone`

**IPv6 主源：**  
`https://www.ipdeny.com/ipv6/ipaddresses/blocks/cn.zone`

**备用源（IPv4/IPv6）：**  
`http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest`

---

如需进一步定制或有其他需求，欢迎提出！ 
