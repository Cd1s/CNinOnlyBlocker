#!/bin/bash
# allow-cn-inbound-interactive.sh - 中国IP入站控制工具
# 支持IPv4/IPv6，支持端口放行管理，以及完整的卸载功能

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否为root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用root权限运行此脚本。${NC}" >&2
    exit 1
fi

# 函数：检查依赖
check_dependencies() {
    echo -e "${BLUE}检查依赖...${NC}"
    for pkg in ipset iptables curl wget; do
        if ! command -v $pkg &>/dev/null; then
            echo -e "${YELLOW}安装缺失的依赖：$pkg${NC}"
            apt update -qq
            apt install -y $pkg
        fi
    done
    
    # 检查ip6tables
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${YELLOW}安装缺失的依赖：ip6tables${NC}"
        apt update -qq
        apt install -y ip6tables || apt install -y iptables
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
    wget -q -O /tmp/cn_ipv6.zone https://www.ipdeny.com/ipblocks/data/countries/cn-ipv6.zone
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

# 函数：配置IPv4防火墙
configure_ipv4_firewall() {
    echo -e "${BLUE}📦 创建并填充 ipset 集合 (IPv4)...${NC}"
    ipset destroy cnipv4 2>/dev/null || true
    ipset create cnipv4 hash:net family inet
    for ip in $(cat /tmp/cn_ipv4.zone); do
        ipset add cnipv4 $ip
    done

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
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                echo -e "${BLUE}添加已保存的放行端口: $port${NC}"
                iptables -I INPUT -p tcp --dport $port -j ACCEPT
                iptables -I INPUT -p udp --dport $port -j ACCEPT
            fi
        done < /etc/cnblocker/allowed_ports.conf
    fi
    
    iptables -A INPUT -j DROP

    # 保存规则
    echo -e "${BLUE}💾 保存ipset和iptables配置...${NC}"
    mkdir -p /etc/ipset /etc/iptables /etc/cnblocker
    ipset save > /etc/ipset/ipset_v4.conf
    iptables-save > /etc/iptables/rules.v4
    
    echo -e "${GREEN}IPv4防火墙配置完成${NC}"
}

# 函数：配置IPv6防火墙
configure_ipv6_firewall() {
    echo -e "${BLUE}📦 创建并填充 ipset 集合 (IPv6)...${NC}"
    ipset destroy cnipv6 2>/dev/null || true
    ipset create cnipv6 hash:net family inet6
    for ip in $(cat /tmp/cn_ipv6.zone); do
        ipset add cnipv6 $ip
    done

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
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                echo -e "${BLUE}添加已保存的放行端口: $port (IPv6)${NC}"
                ip6tables -I INPUT -p tcp --dport $port -j ACCEPT
                ip6tables -I INPUT -p udp --dport $port -j ACCEPT
            fi
        done < /etc/cnblocker/allowed_ports.conf
    fi
    
    ip6tables -A INPUT -j DROP

    # 保存规则
    echo -e "${BLUE}💾 保存ipset和ip6tables配置...${NC}"
    mkdir -p /etc/ipset /etc/iptables /etc/cnblocker
    ipset save > /etc/ipset/ipset_v6.conf
    ip6tables-save > /etc/iptables/rules.v6
    
    echo -e "${GREEN}IPv6防火墙配置完成${NC}"
}

# 函数：设置systemd服务
setup_systemd_service() {
    echo -e "${BLUE}🛠️ 设置 systemd 自动还原服务...${NC}"
    
    cat > /etc/systemd/system/ipset-restore.service <<EOF
[Unit]
Description=Restore ipset and iptables rules
Before=network-pre.target
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "ipset restore < /etc/ipset/ipset_v4.conf || true"
ExecStart=/bin/bash -c "ipset restore < /etc/ipset/ipset_v6.conf || true"
ExecStart=/bin/bash -c "iptables-restore < /etc/iptables/rules.v4 || true"
ExecStart=/bin/bash -c "ip6tables-restore < /etc/iptables/rules.v6 || true"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ipset-restore.service
    echo -e "${GREEN}systemd服务配置完成${NC}"
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
    
    systemctl disable ipset-restore.service 2>/dev/null
    rm -f /etc/systemd/system/ipset-restore.service
    systemctl daemon-reload
    
    # 删除端口配置
    rm -f /etc/cnblocker/allowed_ports.conf
    rmdir /etc/cnblocker 2>/dev/null || true
    
    echo -e "${GREEN}✅ 已完全卸载：所有规则与服务已清除${NC}"
}

# 函数：添加放行端口
add_allowed_port() {
    echo -e "${BLUE}请输入要放行的端口号:${NC}"
    read port
    
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 请输入有效的端口号${NC}"
        return 1
    fi
    
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}错误: 端口号必须在1-65535之间${NC}"
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
        iptables -I INPUT -p tcp --dport $port -j ACCEPT
        iptables -I INPUT -p udp --dport $port -j ACCEPT
        iptables-save > /etc/iptables/rules.v4
    fi
    
    if ipset list cnipv6 &>/dev/null; then
        echo -e "${BLUE}应用到IPv6防火墙...${NC}"
        ip6tables -I INPUT -p tcp --dport $port -j ACCEPT
        ip6tables -I INPUT -p udp --dport $port -j ACCEPT
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
    
    echo -e "${BLUE}请输入要删除放行的端口号:${NC}"
    read port
    
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 请输入有效的端口号${NC}"
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
        iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null && iptables -D INPUT -p tcp --dport $port -j ACCEPT
        iptables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null && iptables -D INPUT -p udp --dport $port -j ACCEPT
        iptables-save > /etc/iptables/rules.v4
    fi
    
    if ipset list cnipv6 &>/dev/null; then
        echo -e "${BLUE}从IPv6防火墙移除...${NC}"
        ip6tables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null && ip6tables -D INPUT -p tcp --dport $port -j ACCEPT
        ip6tables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null && ip6tables -D INPUT -p udp --dport $port -j ACCEPT
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
    echo -e "${YELLOW}0.${NC} 退出"
    echo -e "${BLUE}=================================================${NC}"
    echo -e "请输入选项 [0-8]: "
}

# 主程序
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
