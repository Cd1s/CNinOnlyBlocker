# 🛡️ CNinOnlyBlocker 交互增强版

🚫 拒绝所有非中国 IP 入站连接｜✅ 仅允许中国 IP 入站｜🌐 支持 IPv4 + IPv6｜🎯 自定义放行端口

这是一个增强版的交互式一键脚本，专为服务器用户设计，基于 `ipset` + `iptables` + `ip6tables`，实现**仅允许中国大陆 IP 地址访问服务器入站服务**，同时允许自定义端口放行，支持 IPv6 策略控制，**不限制出站连接**，并支持**开机自动恢复配置**。

---

## 📦 功能特点

- ✅ **仅允许中国 IP 入站连接（IPv4 / IPv6）**
- ❌ **拒绝所有非中国 IP 入站连接**
- 🎛️ **支持自定义放行端口（国内外都可访问）**
- 🌐 **支持 IPv6 入站限制（可选）**
- ⚡ 使用 `ipset` 实现高速匹配，大规模 IP 过滤无压力
- 💾 自动保存防火墙规则
- 🔁 开机自动还原规则（基于 `systemd` 服务）
- 🧹 一键卸载，恢复原始防火墙状态

---

## 🚀 使用方法

```bash
curl -O https://raw.githubusercontent.com/Cd1s/CNinOnlyBlocker/refs/heads/main/allow-cn-inbound.sh
chmod +x allow-cn-inbound.sh
sudo ./allow-cn-inbound.sh
```

运行后可进入交互菜单，支持：

```
1. 安装 IPv4 仅中国入站
2. 安装 IPv6 仅中国入站（可选）
3. 查看已放行端口
4. 添加放行端口（支持 TCP / UDP）
5. 删除放行端口
6. 卸载 IPv4 规则
7. 卸载 IPv6 规则
8. 完全卸载并清除所有规则
```

---

## 🧯 卸载方式

若需完全还原所有规则并卸载服务，请选择菜单：

```
8. 删除并卸载，放行全部端口
```

或执行：

```bash
sudo ./allow-cn-inbound.sh uninstall
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
| systemd 服务 | `/etc/systemd/system/ipset-restore.service` |

---

## 🔧 系统要求

- Linux 系统（建议 Debian / Ubuntu）
- Root 权限
- 自动安装以下依赖：
  - `ipset`、`iptables`、`ip6tables`、`curl`、`wget`

---

## 🙋 常见问题

> **Q：这个脚本会影响服务器主动访问外网吗？**  
> A：不会。此脚本**仅限制入站连接**，**出站流量不受影响**。

> **Q：可以只配置 IPv4 或 IPv6 吗？**  
> A：可以，分别在菜单中选择即可。

> **Q：放行端口能保留吗？**  
> A：能，脚本会自动记录并在下次运行中重新应用。

> **Q：数据源可以更换吗？**  
> A：可以，在脚本内修改 `wget` 或 `curl` 的下载地址即可。

---

如果你有更复杂的场景需求，也欢迎提交 PR 或 issue！
