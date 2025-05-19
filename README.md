# CNinOnlyBlocker 交互增强版 2.0

![版本](https://img.shields.io/badge/版本-2.0-blue)
![平台](https://img.shields.io/badge/平台-Linux-green)
![语言](https://img.shields.io/badge/语言-Bash-yellow)

## 📝 简介

CNinOnlyBlocker 是一个专为服务器用户设计的防火墙增强工具，通过 ipset + iptables + ip6tables 实现**仅允许中国大陆 IP 地址访问服务器入站服务**，有效防止境外 IP 的恶意访问和攻击。

🚫 拒绝所有非中国 IP 入站连接｜✅ 仅允许中国 IP 入站｜🌐 支持 IPv4 + IPv6｜🎯 支持端口范围放行｜🔍 智能系统适配

## ✨ 特性

- **仅允许中国 IP 入站**：屏蔽所有非中国大陆 IP 的入站连接
- **IPv4 + IPv6 双支持**：完整支持 IPv4 和 IPv6 地址过滤
- **端口自定义放行**：支持单端口、多端口和端口范围放行
- **智能适配**：自动检测并适配多种 Linux 发行版（Debian/Ubuntu、CentOS、RHEL 等）
- **交互式界面**：直观的菜单操作，无需记忆复杂命令
- **开机自启动**：系统重启后自动恢复防火墙规则
- **不限制出站连接**：服务器出站连接不受影响，保持正常访问外网
- **多重备用源**：中国 IP 列表支持多个备用数据源，保证可靠性

## 📋 系统要求

- Linux 操作系统（支持 Debian/Ubuntu、CentOS、RHEL 等主流发行版）
- root 权限
- 以下软件包：
  - `iptables`
  - `ipset`
  - `wget`

## 🚀 安装与使用

### 一键安装

复制以下命令一键下载、安装并运行脚本：

```bash
curl -O https://raw.githubusercontent.com/Cd1s/CNinOnlyBlocker/refs/heads/main/allow-cn-inbound.sh && chmod +x allow-cn-inbound.sh && sudo ./allow-cn-inbound.sh
```


### 功能菜单

脚本提供以下功能：

1. **安装 IPv4 仅中国入站**：配置 IPv4 防火墙，仅允许中国 IP 入站
2. **安装 IPv6 仅中国入站**：配置 IPv6 防火墙，仅允许中国 IP 入站
3. **查看放行端口**：查看当前已放行的端口列表
4. **添加放行端口**：添加需要放行的端口（支持端口范围）
5. **删除放行端口**：删除已放行的端口
6. **删除 IPv4 仅国内入站**：移除 IPv4 过滤规则，恢复正常访问
7. **删除 IPv6 仅国内入站**：移除 IPv6 过滤规则，恢复正常访问
8. **删除并卸载，放行全部端口**：完全卸载 CNinOnlyBlocker，恢复系统默认设置
9. **验证防火墙规则**：查看当前防火墙规则和 IP 集合
10. **检查服务状态**：查看 CNinOnlyBlocker 服务状态
11. **测试放行端口是否监听**：检查放行端口是否正常监听

## 📊 配置说明

### 默认配置

- 默认放行端口：22 (SSH)
- 防火墙规则存储路径：`/etc/cninonly_blocker/`
- 开机自启服务：`cninonly_blocker.service`

### 中国 IP 列表来源

脚本自动从以下来源获取最新的中国 IP 列表：

- 主要来源：ipdeny.com
- 备用来源：APNIC 官方 IP 分配数据

## ⚠️ 注意事项

1. 请确保在安装前已开启 SSH 端口，否则可能导致自己无法访问服务器
2. 建议在安装前将自己的 IP 地址或公司 IP 地址段放行（如果不是中国 IP）
3. 在首次安装完成后应该立即测试连接是否正常
4. 如果在安装过程中出现问题，可以通过【删除并卸载，放行全部端口】选项恢复系统默认设置

## 🔧 故障排除

- **问题**：安装后无法访问服务器
  **解决**：通过 VPS 供应商的控制台/救援模式执行以下命令：
  ```bash
  iptables -F
  iptables -P INPUT ACCEPT
  ipset destroy cn_ipv4
  ipset destroy cn_ipv6
  ```

- **问题**：开机后规则未自动加载
  **解决**：检查服务状态并重新启用：
  ```bash
  systemctl status cninonly_blocker.service
  systemctl enable cninonly_blocker.service
  systemctl start cninonly_blocker.service
  ```

## 📜 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件 
