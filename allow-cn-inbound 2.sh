#!/bin/bash
# allow-cn-inbound.sh - 仅允许中国IP的入站连接，封禁海外（不区分端口），出站不限制，支持卸载

# 检查是否为root
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行此脚本。" >&2
    exit 1
fi

# 如果用户传入 uninstall 参数，执行卸载
if [[ "$1" == "uninstall" ]]; then
    echo "🧹 正在卸载规则并还原防火墙..."
    iptables -F
    iptables -X
    ipset destroy cnlist 2>/dev/null || true
    rm -f /etc/ipset/ipset.conf
    rm -f /etc/iptables/rules.v4
    systemctl disable ipset-restore.service 2>/dev/null
    rm -f /etc/systemd/system/ipset-restore.service
    systemctl daemon-reload
    echo "✅ 已卸载：所有规则与服务已清除"
    exit 0
fi

# 检查依赖
for pkg in ipset iptables curl wget; do
    if ! command -v $pkg &>/dev/null; then
        echo "安装缺失的依赖：$pkg"
        apt update -qq
        apt install -y $pkg
    fi
done

# 下载中国IP列表
echo "📥 正在下载中国IP列表..."
wget -q -O /tmp/cn.zone https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone
if [ $? -ne 0 ] || [ ! -s /tmp/cn.zone ]; then
    echo "主源失败，尝试备用 APNIC 来源..."
    wget -q -O- 'http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest' | \
    awk -F\| '/CN\|ipv4/ {print $4"/"32-log($5)/log(2)}' > /tmp/cn.zone
fi

# 创建ipset集合
echo "📦 创建并填充 ipset 集合..."
ipset destroy cnlist 2>/dev/null || true
ipset create cnlist hash:net

for ip in $(cat /tmp/cn.zone); do
    ipset add cnlist $ip
done

# 设置iptables规则（只允许中国IP）
echo "🛡️ 应用iptables规则：仅允许中国IP..."
iptables -F
iptables -X
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m set --match-set cnlist src -j ACCEPT
iptables -A INPUT -j DROP

# 保存规则
echo "💾 保存ipset和iptables配置..."
mkdir -p /etc/ipset /etc/iptables
ipset save > /etc/ipset/ipset.conf
iptables-save > /etc/iptables/rules.v4

# 设置systemd服务
echo "🛠️ 设置 systemd 自动还原服务..."
cat > /etc/systemd/system/ipset-restore.service <<EOF
[Unit]
Description=Restore ipset and iptables rules
Before=network-pre.target
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "ipset restore < /etc/ipset/ipset.conf"
ExecStart=/bin/bash -c "iptables-restore < /etc/iptables/rules.v4"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ipset-restore.service

echo "✅ 配置完成：所有非中国IP的入站连接已封禁，出站不限制。"
echo "🧯 若需卸载，请运行：sudo ./allow-cn-inbound.sh uninstall"
