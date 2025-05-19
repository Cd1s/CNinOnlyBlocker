#!/bin/bash
# allow-cn-inbound-interactive.sh - 中国IP入站控制工具
# 支持IPv4/IPv6，支持端口放行管理，以及完整的卸载功能

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 系统信息
OS_TYPE=""
PKG_MANAGER=""
SERVICE_MANAGER=""

# 函数：检测系统类型
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE=$ID
        case $ID in
            debian|ubuntu)
                PKG_MANAGER="apt"
                SERVICE_MANAGER="systemctl"
                ;;
            centos|rhel|fedora)
                PKG_MANAGER="yum"
                SERVICE_MANAGER="systemctl"
                ;;
            alpine)
                PKG_MANAGER="apk"
                SERVICE_MANAGER="rc-update"
                ;;
            *)
                echo -e "${RED}不支持的操作系统: $ID${NC}"
                exit 1
                ;;
        esac
    else
        echo -e "${RED}无法检测操作系统类型${NC}"
        exit 1
    fi
}

# 函数：检查是否为root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请使用root权限运行此脚本。${NC}" >&2
        exit 1
    fi
}

# 函数：检查IPv6支持
check_ipv6_support() {
    # 强制返回true，始终启用IPv6支持
    return 0
    
    # 原始代码注释掉但保留，以便将来需要时可以恢复
    # if [ -f /proc/net/if_inet6 ]; then
    #     if ip -6 route show | grep -q "default"; then
    #         return 0
    #     fi
    # fi
    # return 1
}

# 函数：检查防火墙冲突
check_firewall_conflicts() {
    local conflicts=()
    
    # 检查ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        conflicts+=("ufw")
    fi
    
    # 检查firewalld
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        conflicts+=("firewalld")
    fi
    
    # 检查nftables
    if command -v nft &>/dev/null && nft list ruleset &>/dev/null; then
        conflicts+=("nftables")
    fi
    
    if [ ${#conflicts[@]} -gt 0 ]; then
        echo -e "${YELLOW}检测到以下防火墙可能造成冲突:${NC}"
        for fw in "${conflicts[@]}"; do
            echo -e "${RED}- $fw${NC}"
        done
        
        echo -e "${BLUE}请选择处理方式:${NC}"
        echo "1) 自动禁用冲突的防火墙"
        echo "2) 手动处理（退出脚本）"
        echo "3) 继续安装（不推荐）"
        
        read -p "请选择 [1-3]: " choice
        case $choice in
            1)
                for fw in "${conflicts[@]}"; do
                    case $fw in
                        ufw)
                            ufw disable
                            systemctl disable ufw
                            ;;
                        firewalld)
                            systemctl stop firewalld
                            systemctl disable firewalld
                            ;;
                        nftables)
                            systemctl stop nftables
                            systemctl disable nftables
                            ;;
                    esac
                done
                ;;
            2)
                echo -e "${YELLOW}请先处理防火墙冲突后再运行此脚本${NC}"
                exit 1
                ;;
            3)
                echo -e "${RED}警告: 继续安装可能导致防火墙规则冲突${NC}"
                ;;
        esac
    fi
}

# 函数：检查依赖
check_dependencies() {
    echo -e "${BLUE}检查依赖...${NC}"
    local pkgs=("ipset" "iptables" "curl" "wget")
    
    case $PKG_MANAGER in
        apt)
            apt update -qq
            for pkg in "${pkgs[@]}"; do
                if ! command -v $pkg &>/dev/null; then
                    echo -e "${YELLOW}安装缺失的依赖：$pkg${NC}"
                    apt install -y $pkg
                fi
            done
            ;;
        yum)
            yum makecache -q
            for pkg in "${pkgs[@]}"; do
                if ! command -v $pkg &>/dev/null; then
                    echo -e "${YELLOW}安装缺失的依赖：$pkg${NC}"
                    yum install -y $pkg
                fi
            done
            ;;
        apk)
            apk update -q
            for pkg in "${pkgs[@]}"; do
                if ! command -v $pkg &>/dev/null; then
                    echo -e "${YELLOW}安装缺失的依赖：$pkg${NC}"
                    apk add $pkg
                fi
            done
            ;;
    esac
    
    # 检查ip6tables
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${YELLOW}安装缺失的依赖：ip6tables${NC}"
        case $PKG_MANAGER in
            apt) apt install -y ip6tables || apt install -y iptables ;;
            yum) yum install -y ip6tables ;;
            apk) apk add ip6tables ;;
        esac
    fi
    
    echo -e "${GREEN}依赖检查完成${NC}"
}

# 函数：下载中国IP列表 (IPv4)
download_cn_ipv4_list() {
    echo -e "${BLUE}📥 正在下载中国IPv4列表...${NC}"
    wget -q -O /tmp/cn_ipv4.zone https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone
    if [ $? -ne 0 ] || [ ! -s /tmp/cn_ipv4.zone ]; then
        echo -e "${YELLOW}主源失败，尝试备用 APNIC 来源...${NC}"
        wget -q -O- 'http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest' | \
        awk -F\| '/CN\|ipv4/ {print $4"/"32-log($5)/log(2)}' > /tmp/cn_ipv4.zone
    fi
    
    if [ ! -s /tmp/cn_ipv4.zone ]; then
        echo -e "${RED}无法获取中国IPv4列表，请检查网络连接${NC}"
        return 1
    fi
    
    echo -e "${GREEN}成功下载中国IPv4列表${NC}"
    return 0
}

# 函数：下载中国IP列表 (IPv6)
download_cn_ipv6_list() {
    echo -e "${BLUE}📥 正在下载中国IPv6列表...${NC}"
    wget -q -O /tmp/cn_ipv6.zone https://www.ipdeny.com/ipv6/ipaddresses/blocks/cn.zone
    if [ $? -ne 0 ] || [ ! -s /tmp/cn_ipv6.zone ]; then
        echo -e "${YELLOW}主源失败，尝试备用 APNIC 来源...${NC}"
        wget -q -O- 'http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest' | \
        awk -F\| '/CN\|ipv6/ {print $4"/"$5}' > /tmp/cn_ipv6.zone
    fi
    
    if [ ! -s /tmp/cn_ipv6.zone ]; then
        echo -e "${RED}无法获取中国IPv6列表，请检查网络连接${NC}"
        return 1
    fi
    
    echo -e "${GREEN}成功下载中国IPv6列表${NC}"
    return 0
}

# 函数：验证端口格式
validate_port() {
    local port=$1
    # 支持单个端口、端口范围、多个端口
    if [[ "$port" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
        # 检查每个端口是否在有效范围内
        IFS=',' read -ra PORTS <<< "$port"
        for p in "${PORTS[@]}"; do
            if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
                local start=${p%-*}
                local end=${p#*-}
                if [ "$start" -gt "$end" ] || [ "$start" -lt 1 ] || [ "$end" -gt 65535 ]; then
                    return 1
                fi
            else
                if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
                    return 1
                fi
            fi
        done
        return 0
    fi
    return 1
}

# 函数：配置IPv4防火墙
configure_ipv4_firewall() {
    echo -e "${BLUE}📦 创建并填充 ipset 集合 (IPv4)...${NC}"
    ipset destroy cnipv4 2>/dev/null || true
    ipset create cnipv4 hash:net family inet hashsize 4096 maxelem 65536
    
    # 使用更高效的批量添加方式
    echo -e "${BLUE}使用批量添加提高性能...${NC}"
    cat /tmp/cn_ipv4.zone | while read -r line; do
        echo "add cnipv4 $line"
    done | ipset restore -!
    
    echo -e "${BLUE}🛡️ 应用iptables规则：仅允许中国IPv4...${NC}"
    iptables -F
    iptables -X
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p icmp -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -m set --match-set cnipv4 src -j ACCEPT
    
    # 添加已保存的端口规则（如果有）
    if [ -f /etc/cnblocker/allowed_ports.conf ]; then
        while read port; do
            if [[ "$port" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
                echo -e "${BLUE}添加已保存的放行端口: $port${NC}"
                IFS=',' read -ra PORTS <<< "$port"
                for p in "${PORTS[@]}"; do
                    if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
                        iptables -I INPUT -p tcp --match multiport --dports $p -j ACCEPT
                        iptables -I INPUT -p udp --match multiport --dports $p -j ACCEPT
                    else
                        iptables -I INPUT -p tcp --dport $p -j ACCEPT
                        iptables -I INPUT -p udp --dport $p -j ACCEPT
                    fi
                done
            fi
        done < /etc/cnblocker/allowed_ports.conf
    fi
    
    iptables -A INPUT -j DROP

    # 保存规则
    echo -e "${BLUE}💾 保存ipset和iptables配置...${NC}"
    mkdir -p /etc/ipset /etc/iptables /etc/cnblocker
    ipset save > /etc/ipset/ipset_v4.conf
    
    # 根据系统类型使用不同的保存方式
    case $SERVICE_MANAGER in
        systemctl)
            iptables-save > /etc/iptables/rules.v4
            ;;
        rc-update)
            # Alpine使用不同的路径
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
            ;;
    esac
    
    echo -e "${GREEN}IPv4防火墙配置完成${NC}"
}

# 函数：配置IPv6防火墙
configure_ipv6_firewall() {
    echo -e "${BLUE}📦 创建并填充 ipset 集合 (IPv6)...${NC}"
    ipset destroy cnipv6 2>/dev/null || true
    ipset create cnipv6 hash:net family inet6 hashsize 4096 maxelem 65536
    
    # 使用更高效的批量添加方式
    echo -e "${BLUE}使用批量添加提高性能...${NC}"
    cat /tmp/cn_ipv6.zone | while read -r line; do
        echo "add cnipv6 $line"
    done | ipset restore -!
    
    echo -e "${BLUE}🛡️ 应用ip6tables规则：仅允许中国IPv6...${NC}"
    ip6tables -F
    ip6tables -X
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -m set --match-set cnipv6 src -j ACCEPT
    
    # 添加已保存的端口规则（如果有）
    if [ -f /etc/cnblocker/allowed_ports.conf ]; then
        while read port; do
            if [[ "$port" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
                echo -e "${BLUE}添加已保存的放行端口: $port (IPv6)${NC}"
                IFS=',' read -ra PORTS <<< "$port"
                for p in "${PORTS[@]}"; do
                    if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
                        ip6tables -I INPUT -p tcp --match multiport --dports $p -j ACCEPT
                        ip6tables -I INPUT -p udp --match multiport --dports $p -j ACCEPT
                    else
                        ip6tables -I INPUT -p tcp --dport $p -j ACCEPT
                        ip6tables -I INPUT -p udp --dport $p -j ACCEPT
                    fi
                done
            fi
        done < /etc/cnblocker/allowed_ports.conf
    fi
    
    ip6tables -A INPUT -j DROP

    # 保存规则
    echo -e "${BLUE}💾 保存ipset和ip6tables配置...${NC}"
    mkdir -p /etc/ipset /etc/iptables /etc/cnblocker
    ipset save > /etc/ipset/ipset_v6.conf
    
    # 根据系统类型使用不同的保存方式
    case $SERVICE_MANAGER in
        systemctl)
            ip6tables-save > /etc/iptables/rules.v6
            ;;
        rc-update)
            # Alpine使用不同的路径
            mkdir -p /etc/iptables
            ip6tables-save > /etc/iptables/rules.v6
            ;;
    esac
    
    echo -e "${GREEN}IPv6防火墙配置完成${NC}"
}

# 函数：设置systemd服务
setup_systemd_service() {
    echo -e "${BLUE}🛠️ 设置自动还原服务...${NC}"
    
    case $SERVICE_MANAGER in
        systemctl)
            # IPv4规则恢复服务
            cat > /etc/systemd/system/ipset-restore-ipv4.service <<EOF
[Unit]
Description=Restore ipset and iptables IPv4 rules
Before=network-pre.target
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "ipset restore < /etc/ipset/ipset_v4.conf || true"
ExecStart=/bin/bash -c "iptables-restore < /etc/iptables/rules.v4 || true"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

            # IPv6规则恢复服务 - 在网络完全启动后运行
            cat > /etc/systemd/system/ipset-restore-ipv6.service <<EOF
[Unit]
Description=Restore ipset and iptables IPv6 rules
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/bin/bash -c "modprobe ip6_tables || true"
ExecStart=/bin/bash -c "modprobe ip6table_filter || true"
ExecStart=/bin/bash -c "ipset restore < /etc/ipset/ipset_v6.conf || true" 
ExecStart=/bin/bash -c "ip6tables-restore < /etc/iptables/rules.v6 || true"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

            # 创建一个cron任务脚本作为额外保障
            cat > /etc/cron.d/restore-ipv6-rules <<EOF
@reboot root sleep 60 && modprobe ip6_tables && ipset restore < /etc/ipset/ipset_v6.conf || true && ip6tables-restore < /etc/iptables/rules.v6 || true
EOF
            chmod 644 /etc/cron.d/restore-ipv6-rules

            # 创建一个新的启动脚本作为额外备份
            cat > /etc/init.d/restore-ipv6-rules <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          restore-ipv6-rules
# Required-Start:    \$network \$remote_fs \$syslog
# Required-Stop:     \$network \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Restore IPv6 firewall rules
# Description:       Restore IPv6 firewall rules after network is fully up
### END INIT INFO

case "\$1" in
  start)
    echo "Loading IPv6 firewall rules"
    sleep 15
    modprobe ip6_tables || true
    modprobe ip6table_filter || true
    ipset restore < /etc/ipset/ipset_v6.conf || true
    ip6tables-restore < /etc/iptables/rules.v6 || true
    ;;
  stop|restart|reload|force-reload)
    # Nothing to do
    ;;
  *)
    echo "Usage: \$0 start|stop" >&2
    exit 3
    ;;
esac
exit 0
EOF
            chmod +x /etc/init.d/restore-ipv6-rules
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d restore-ipv6-rules defaults
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig --add restore-ipv6-rules
            fi

            systemctl daemon-reload
            systemctl enable ipset-restore-ipv4.service
            systemctl enable ipset-restore-ipv6.service
            ;;
        rc-update)
            # Alpine Linux处理
            cat > /etc/local.d/ipset-restore-ipv4.start <<EOF
#!/bin/sh
# 恢复IPv4规则
ipset restore < /etc/ipset/ipset_v4.conf || true
iptables-restore < /etc/iptables/rules.v4 || true
EOF
            chmod +x /etc/local.d/ipset-restore-ipv4.start
            
            # 创建一个延迟的IPv6恢复启动脚本
            cat > /etc/local.d/ipset-restore-ipv6.start <<EOF
#!/bin/sh
# 等待网络完全启动
sleep 15
# 确保必要的内核模块已加载
modprobe ip6_tables || true
modprobe ip6table_filter || true
# 恢复IPv6规则
ipset restore < /etc/ipset/ipset_v6.conf || true
ip6tables-restore < /etc/iptables/rules.v6 || true
EOF
            chmod +x /etc/local.d/ipset-restore-ipv6.start
            
            # 设置在后台循环检查和恢复IPv6规则的脚本
            cat > /etc/local.d/check-ipv6-rules.start <<EOF
#!/bin/sh
(
  # 等待系统完全启动
  sleep 30
  
  # 检查IPv6规则是否加载，如果没有则重新加载
  if ! ip6tables -L INPUT -n | grep -q "match-set cnipv6"; then
    echo "IPv6 rules not found, restoring..."
    modprobe ip6_tables || true
    modprobe ip6table_filter || true
    ipset restore < /etc/ipset/ipset_v6.conf || true
    ip6tables-restore < /etc/iptables/rules.v6 || true
  fi
) &
EOF
            chmod +x /etc/local.d/check-ipv6-rules.start
            
            rc-update add local default
            ;;
    esac

    echo -e "${GREEN}自启动服务配置完成${NC}"
}

# 函数：卸载IPv4规则
uninstall_ipv4() {
    echo -e "${BLUE}🧹 正在卸载IPv4规则并还原防火墙...${NC}"
    iptables -F
    iptables -X
    ipset destroy cnipv4 2>/dev/null || true
    rm -f /etc/ipset/ipset_v4.conf
    rm -f /etc/iptables/rules.v4
    echo -e "${GREEN}✅ 已卸载：IPv4规则已清除${NC}"
}

# 函数：卸载IPv6规则
uninstall_ipv6() {
    echo -e "${BLUE}🧹 正在卸载IPv6规则并还原防火墙...${NC}"
    ip6tables -F
    ip6tables -X
    ipset destroy cnipv6 2>/dev/null || true
    rm -f /etc/ipset/ipset_v6.conf
    rm -f /etc/iptables/rules.v6
    echo -e "${GREEN}✅ 已卸载：IPv6规则已清除${NC}"
}

# 函数：完全卸载
uninstall_all() {
    uninstall_ipv4
    uninstall_ipv6
    
    case $SERVICE_MANAGER in
        systemctl)
            systemctl disable ipset-restore-ipv4.service 2>/dev/null
            systemctl disable ipset-restore-ipv6.service 2>/dev/null
            rm -f /etc/systemd/system/ipset-restore-ipv4.service
            rm -f /etc/systemd/system/ipset-restore-ipv6.service
            # 删除cron任务和init.d脚本
            rm -f /etc/cron.d/restore-ipv6-rules
            rm -f /etc/init.d/restore-ipv6-rules
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d restore-ipv6-rules remove 2>/dev/null || true
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig --del restore-ipv6-rules 2>/dev/null || true
            fi
            systemctl daemon-reload
            ;;
        rc-update)
            rc-update del local default 2>/dev/null
            rm -f /etc/local.d/ipset-restore-ipv4.start
            rm -f /etc/local.d/ipset-restore-ipv6.start
            rm -f /etc/local.d/check-ipv6-rules.start
            ;;
    esac
    
    # 删除端口配置
    rm -f /etc/cnblocker/allowed_ports.conf
    rmdir /etc/cnblocker 2>/dev/null || true
    
    echo -e "${GREEN}✅ 已完全卸载：所有规则与服务已清除${NC}"
}

# 函数：添加放行端口
add_allowed_port() {
    echo -e "${BLUE}请输入要放行的端口 (支持格式: 80,443,8000-9000):${NC}"
    read port
    
    if ! validate_port "$port"; then
        echo -e "${RED}错误: 无效的端口格式${NC}"
        return 1
    fi
    
    # 检查端口是否已经放行
    if [ -f /etc/cnblocker/allowed_ports.conf ] && grep -q "^$port$" /etc/cnblocker/allowed_ports.conf; then
        echo -e "${YELLOW}端口 $port 已经放行，无需重复操作${NC}"
        return 0
    fi
    
    # 添加到配置文件
    mkdir -p /etc/cnblocker
    echo "$port" >> /etc/cnblocker/allowed_ports.conf
    
    # 应用到防火墙规则
    if ipset list cnipv4 &>/dev/null; then
        echo -e "${BLUE}应用到IPv4防火墙...${NC}"
        IFS=',' read -ra PORTS <<< "$port"
        for p in "${PORTS[@]}"; do
            if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
                iptables -I INPUT -p tcp --match multiport --dports $p -j ACCEPT
                iptables -I INPUT -p udp --match multiport --dports $p -j ACCEPT
            else
                iptables -I INPUT -p tcp --dport $p -j ACCEPT
                iptables -I INPUT -p udp --dport $p -j ACCEPT
            fi
        done
        iptables-save > /etc/iptables/rules.v4
    fi
    
    if ipset list cnipv6 &>/dev/null; then
        echo -e "${BLUE}应用到IPv6防火墙...${NC}"
        for p in "${PORTS[@]}"; do
            if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
                ip6tables -I INPUT -p tcp --match multiport --dports $p -j ACCEPT
                ip6tables -I INPUT -p udp --match multiport --dports $p -j ACCEPT
            else
                ip6tables -I INPUT -p tcp --dport $p -j ACCEPT
                ip6tables -I INPUT -p udp --dport $p -j ACCEPT
            fi
        done
        ip6tables-save > /etc/iptables/rules.v6
    fi
    
    echo -e "${GREEN}✅ 成功放行端口 $port${NC}"
}

# 函数：删除放行端口
delete_allowed_port() {
    if [ ! -f /etc/cnblocker/allowed_ports.conf ] || [ ! -s /etc/cnblocker/allowed_ports.conf ]; then
        echo -e "${YELLOW}当前没有放行的端口${NC}"
        return 0
    fi
    
    echo -e "${BLUE}当前放行的端口:${NC}"
    cat /etc/cnblocker/allowed_ports.conf
    
    echo -e "${BLUE}请输入要删除放行的端口 (支持格式: 80,443,8000-9000):${NC}"
    read port
    
    if ! validate_port "$port"; then
        echo -e "${RED}错误: 无效的端口格式${NC}"
        return 1
    fi
    
    # 检查端口是否存在
    if ! grep -q "^$port$" /etc/cnblocker/allowed_ports.conf; then
        echo -e "${YELLOW}端口 $port 未放行，无需删除${NC}"
        return 0
    fi
    
    # 从配置文件中删除
    sed -i "/^$port$/d" /etc/cnblocker/allowed_ports.conf
    
    # 应用到防火墙规则 - 使用检查规则是否存在再删除的方式
    if ipset list cnipv4 &>/dev/null; then
        echo -e "${BLUE}从IPv4防火墙移除...${NC}"
        IFS=',' read -ra PORTS <<< "$port"
        for p in "${PORTS[@]}"; do
            if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
                iptables -C INPUT -p tcp --match multiport --dports $p -j ACCEPT 2>/dev/null && \
                    iptables -D INPUT -p tcp --match multiport --dports $p -j ACCEPT
                iptables -C INPUT -p udp --match multiport --dports $p -j ACCEPT 2>/dev/null && \
                    iptables -D INPUT -p udp --match multiport --dports $p -j ACCEPT
            else
                iptables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null && \
                    iptables -D INPUT -p tcp --dport $p -j ACCEPT
                iptables -C INPUT -p udp --dport $p -j ACCEPT 2>/dev/null && \
                    iptables -D INPUT -p udp --dport $p -j ACCEPT
            fi
        done
        iptables-save > /etc/iptables/rules.v4
    fi
    
    if ipset list cnipv6 &>/dev/null; then
        echo -e "${BLUE}从IPv6防火墙移除...${NC}"
        for p in "${PORTS[@]}"; do
            if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
                ip6tables -C INPUT -p tcp --match multiport --dports $p -j ACCEPT 2>/dev/null && \
                    ip6tables -D INPUT -p tcp --match multiport --dports $p -j ACCEPT
                ip6tables -C INPUT -p udp --match multiport --dports $p -j ACCEPT 2>/dev/null && \
                    ip6tables -D INPUT -p udp --match multiport --dports $p -j ACCEPT
            else
                ip6tables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null && \
                    ip6tables -D INPUT -p tcp --dport $p -j ACCEPT
                ip6tables -C INPUT -p udp --dport $p -j ACCEPT 2>/dev/null && \
                    ip6tables -D INPUT -p udp --dport $p -j ACCEPT
            fi
        done
        ip6tables-save > /etc/iptables/rules.v6
    fi
    
    echo -e "${GREEN}✅ 成功删除端口 $port 的放行规则${NC}"
}

# 函数：查看放行端口
view_allowed_ports() {
    if [ ! -f /etc/cnblocker/allowed_ports.conf ] || [ ! -s /etc/cnblocker/allowed_ports.conf ]; then
        echo -e "${YELLOW}当前没有放行的端口${NC}"
        return 0
    fi
    
    echo -e "${GREEN}当前已放行的端口:${NC}"
    echo -e "${BLUE}--------------------${NC}"
    while read port; do
        echo -e "${GREEN}端口 $port${NC}"
    done < /etc/cnblocker/allowed_ports.conf
    echo -e "${BLUE}--------------------${NC}"
}

# 函数：验证防火墙规则
verify_firewall_rules() {
    echo -e "${BLUE}验证防火墙规则...${NC}"
    
    # 检查IPv4规则
    if ipset list cnipv4 &>/dev/null; then
        echo -e "${GREEN}IPv4规则状态:${NC}"
        iptables -L INPUT -n -v | grep -E "ACCEPT|DROP"
    else
        echo -e "${RED}未发现IPv4规则，请尝试重新安装${NC}"
    fi
    
    # 检查IPv6规则
    if ipset list cnipv6 &>/dev/null; then
        echo -e "${GREEN}IPv6规则状态:${NC}"
        ip6tables -L INPUT -n -v | grep -E "ACCEPT|DROP"
    else
        echo -e "${RED}未发现IPv6规则，请尝试重新安装${NC}"
        
        echo -e "${YELLOW}尝试手动恢复IPv6规则...${NC}"
        echo -e "${BLUE}这可能需要一些时间，请稍候...${NC}"
        
        # 尝试手动恢复IPv6规则
        modprobe ip6_tables 2>/dev/null
        modprobe ip6table_filter 2>/dev/null
        
        if [ -f /etc/ipset/ipset_v6.conf ] && [ -f /etc/iptables/rules.v6 ]; then
            ipset restore < /etc/ipset/ipset_v6.conf 2>/dev/null
            ip6tables-restore < /etc/iptables/rules.v6 2>/dev/null
            
            # 再次检查是否成功
            if ipset list cnipv6 &>/dev/null; then
                echo -e "${GREEN}成功手动恢复IPv6规则！${NC}"
                ip6tables -L INPUT -n -v | grep -E "ACCEPT|DROP"
            else
                echo -e "${RED}无法手动恢复IPv6规则，请检查系统IPv6支持${NC}"
            fi
        else
            echo -e "${RED}缺少IPv6规则配置文件，请先安装IPv6规则${NC}"
        fi
    fi
    
    # 检查端口规则
    if [ -f /etc/cnblocker/allowed_ports.conf ]; then
        echo -e "${GREEN}已放行端口:${NC}"
        cat /etc/cnblocker/allowed_ports.conf
    fi
}

# 函数：检查服务状态
check_service_status() {
    echo -e "${BLUE}检查服务状态...${NC}"
    
    case $SERVICE_MANAGER in
        systemctl)
            systemctl status ipset-restore-ipv4.service
            systemctl status ipset-restore-ipv6.service
            ;;
        rc-update)
            rc-status | grep local
            ;;
    esac
    
    # 检查规则是否已加载
    if ipset list cnipv4 &>/dev/null; then
        echo -e "${GREEN}IPv4规则已加载${NC}"
    else
        echo -e "${RED}IPv4规则未加载${NC}"
    fi
    
    if ipset list cnipv6 &>/dev/null; then
        echo -e "${GREEN}IPv6规则已加载${NC}"
    else
        echo -e "${RED}IPv6规则未加载${NC}"
    fi
}

# 函数：测试端口连通性
test_port_connectivity() {
    if [ ! -f /etc/cnblocker/allowed_ports.conf ]; then
        echo -e "${YELLOW}没有配置放行端口${NC}"
        return
    fi
    
    # 检查是否安装了nc
    if ! command -v nc &>/dev/null; then
        echo -e "${YELLOW}未安装netcat，无法进行端口测试${NC}"
        echo -e "${BLUE}可以使用以下命令安装：${NC}"
        case $PKG_MANAGER in
            apt)
                echo -e "${BLUE}apt install -y netcat${NC}"
                ;;
            yum)
                echo -e "${BLUE}yum install -y nc${NC}"
                ;;
            apk)
                echo -e "${BLUE}apk add netcat-openbsd${NC}"
                ;;
        esac
        return
    fi
    
    echo -e "${BLUE}测试端口连通性...${NC}"
    while read port; do
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            if nc -z localhost $port &>/dev/null; then
                echo -e "${GREEN}端口 $port 可访问${NC}"
            else
                echo -e "${RED}端口 $port 无法访问${NC}"
            fi
        fi
    done < /etc/cnblocker/allowed_ports.conf
}

# 主菜单
show_menu() {
    clear
    echo -e "${BLUE}=================================================${NC}"
    echo -e "${GREEN}       中国IP入站控制工具 - 交互式菜单${NC}"
    echo -e "${BLUE}=================================================${NC}"
    echo -e "${YELLOW}1.${NC} 安装IPv4仅国内入站"
    echo -e "${YELLOW}2.${NC} 安装IPv6仅国内入站"
    echo -e "${YELLOW}3.${NC} 查看放行端口"
    echo -e "${YELLOW}4.${NC} 添加放行端口"
    echo -e "${YELLOW}5.${NC} 删除放行端口"
    echo -e "${YELLOW}6.${NC} 删除IPv4仅国内入站"
    echo -e "${YELLOW}7.${NC} 删除IPv6仅国内入站"
    echo -e "${YELLOW}8.${NC} 删除并卸载，放行全部端口"
    echo -e "${YELLOW}9.${NC} 验证防火墙规则"
    echo -e "${YELLOW}10.${NC} 检查服务状态"
    echo -e "${YELLOW}11.${NC} 测试放行端口是否监听"
    echo -e "${YELLOW}0.${NC} 退出"
    echo -e "${BLUE}=================================================${NC}"
    echo -e "请输入选项 [0-11]: "
}

# 主程序
main() {
    check_root
    detect_system
    check_firewall_conflicts
    
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                check_dependencies
                download_cn_ipv4_list && configure_ipv4_firewall
                setup_systemd_service
                echo -e "${GREEN}✅ 配置完成：所有非中国IP的入站连接已封禁 (IPv4)，出站不限制。${NC}"
                read -p "按Enter键继续..."
                ;;
            2)
                check_dependencies
                download_cn_ipv6_list && configure_ipv6_firewall
                setup_systemd_service
                echo -e "${GREEN}✅ 配置完成：所有非中国IP的入站连接已封禁 (IPv6)，出站不限制。${NC}"
                read -p "按Enter键继续..."
                ;;
            3)
                view_allowed_ports
                read -p "按Enter键继续..."
                ;;
            4)
                add_allowed_port
                read -p "按Enter键继续..."
                ;;
            5)
                delete_allowed_port
                read -p "按Enter键继续..."
                ;;
            6)
                uninstall_ipv4
                read -p "按Enter键继续..."
                ;;
            7)
                uninstall_ipv6
                read -p "按Enter键继续..."
                ;;
            8)
                uninstall_all
                read -p "按Enter键继续..."
                ;;
            9)
                verify_firewall_rules
                read -p "按Enter键继续..."
                ;;
            10)
                check_service_status
                read -p "按Enter键继续..."
                ;;
            11)
                test_port_connectivity
                read -p "按Enter键继续..."
                ;;
            0)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重试${NC}"
                sleep 2
                ;;
        esac
    done
}

# 启动主程序
main
