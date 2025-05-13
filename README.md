CNinOnlyBlocker

🚫 拒绝所有非中国 IP 入站连接｜✅ 仅允许中国 IP 访问（入站方向）

这是一个一键脚本，专为服务器用户设计，通过 ipset + iptables 实现仅允许中国大陆 IP 地址访问服务器，封锁所有其他国家的入站连接，不限制出站连接。

⸻

📦 功能特点
	
 
•	✅ 仅允许中国 IP 入站连接（如 SSH、HTTP、HTTPS）
 
•	❌ 阻止所有非中国 IP 的入站访问
 
•	✅ 出站流量不做限制
 
•	⚡ 使用 ipset 实现高速 IP 匹配
 
•	💾 自动保存防火墙规则
 
•	🔁 开机自动还原（基于 systemd 服务）
 
•	🧹 一键卸载，恢复原始防火墙状态
 

⸻

🚀 使用方法

 ```
curl -O https://raw.githubusercontent.com/Cd1s/CNinOnlyBlocker/refs/heads/main/allow-cn-inbound.sh
chmod +x allow-cn-inbound.sh
sudo ./allow-cn-inbound.sh
``` 

运行后，将自动完成以下步骤：
•	下载中国 IP 列表
 
•	创建 ipset 集合并填充
 
•	配置 iptables 规则
 
•	保存并启用 systemd 自动还原服务
 

⸻

🧯 卸载方式

若需还原所有规则并卸载服务，请执行：

``` 
sudo ./allow-cn-inbound.sh uninstall
``` 


📂 配置文件路径
•	ipset 规则文件：/etc/ipset/ipset.conf
 
•	iptables 规则文件：/etc/iptables/rules.v4
 
•	systemd 服务文件：/etc/systemd/system/ipset-restore.service
 

⸻

🔧 系统要求
•	Linux 系统（推荐 Debian/Ubuntu）
 
•	Root 管理权限
 
•	已安装或自动安装以下工具：ipset、iptables、curl、wget
 

⸻

🙋 常见问题

Q：这个脚本会影响服务器主动访问外网吗？

不会。它只控制入站连接。

Q：可以修改 IP 数据来源吗？

可以，在脚本中修改 wget 下载链接即可。

Q：支持 IPv6 吗？

当前仅支持 IPv4。如需支持 IPv6，可另行扩展。

⸻
