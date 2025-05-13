#!/bin/bash
set -e
source ./config.sh

echo "📦 下载 cnblock.sh（中国 IP iptables规则脚本）..."
curl -s "$CNBLOCK_SOURCE_URL" -o /tmp/cnblock_raw.sh

echo "🧹 清理现有 iptables（如开启）..."
$FLUSH_EXISTING && iptables -F && iptables -X

$ALLOW_LOOPBACK && iptables -A INPUT -i lo -j ACCEPT
$ALLOW_PING && iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "🔧 应用中国 IP 规则（ALLOW）..."
chmod +x /tmp/cnblock_raw.sh
/tmp/cnblock_raw.sh

echo "🚫 添加默认DROP规则（除中国IP外全拒）..."
iptables -A INPUT -j DROP

if $AUTO_SAVE; then
  echo "💾 保存iptables规则..."
  iptables-save > /etc/iptables/rules.v4
fi

echo "✅ 完成：仅允许中国IP入站，出站不限制。"
