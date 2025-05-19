#!/bin/bash
# allow-cn-inbound-interactive.sh - 中国IP入站控制工具
# 支持IPv4/IPv6，支持端口和端口范围放行管理，以及完整的卸载功能

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_CONF_DIR="/etc/cnblocker"
ALLOWED_PORTS_CONF="$SCRIPT_CONF_DIR/allowed_ports.conf"
IPSET_V4_CONF="/etc/ipset/ipset_v4.conf"
IPSET_V6_CONF="/etc/ipset/ipset_v6.conf"
IPTABLES_RULES_V4="/etc/iptables/rules.v4"
IP6TABLES_RULES_V6="/etc/iptables/rules.v6"
SYSTEMD_SERVICE_NAME="ipset-restore.service"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/$SYSTEMD_SERVICE_NAME"
WRAPPER_SCRIPT_PATH="/usr/local/sbin/cnblocker-restore-rules.sh" # 包装脚本路径

# --- Helper Functions ---

detect_pkg_manager() {
    if command -v apt &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL_CMD="apt install -y"
        PKG_UPDATE_CMD="apt update -qq"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL_CMD="yum install -y"
        PKG_UPDATE_CMD="yum makecache fast -q"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL_CMD="dnf install -y -q"
        PKG_UPDATE_CMD="dnf makecache -q"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
        PKG_INSTALL_CMD="apk add --no-cache"
        PKG_UPDATE_CMD="apk update -q"
    else
        echo -e "${RED}无法检测到支持的包管理器 (apt, yum, dnf, apk)。请手动安装依赖。${NC}" >&2
        return 1
    fi
    return 0
}

check_and_install_pkg() {
    local pkg_name="$1"
    local pkg_cmd_check="$2"
    [[ -z "$pkg_cmd_check" ]] && pkg_cmd_check="$pkg_name"

    if ! command -v "$pkg_cmd_check" &>/dev/null; then
        echo -e "${YELLOW}安装缺失的依赖：$pkg_name${NC}"
        $PKG_UPDATE_CMD
        if [[ "$PKG_MANAGER" == "apk" && "$pkg_name" == "iptables-legacy" ]]; then
             # On Alpine, iptables might provide ip6tables, or iptables-legacy might be needed for certain functionalities
            $PKG_INSTALL_CMD iptables ip6tables || $PKG_INSTALL_CMD iptables-legacy
        elif [[ "$PKG_MANAGER" == "apk" && "$pkg_name" == "ipset" ]]; then
            $PKG_INSTALL_CMD ipset
        else
            $PKG_INSTALL_CMD "$pkg_name"
        fi

        if ! command -v "$pkg_cmd_check" &>/dev/null; then
            echo -e "${RED}安装 $pkg_name 失败。请手动安装后重试。${NC}"
            return 1
        fi
    fi
    return 0
}

# --- Core Functions ---

# 检查是否为root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请使用root权限运行此脚本。${NC}" >&2
        exit 1
    fi
}

# 函数：检查依赖
check_dependencies() {
    echo -e "${BLUE}检查依赖...${NC}"
    if ! detect_pkg_manager; then
        exit 1
    fi

    local dependencies=("ipset" "iptables" "curl" "wget")
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        # On Alpine, iptables package usually includes ip6tables. ipset is separate.
        dependencies=("ipset" "iptables" "curl" "wget") # ip6tables is part of iptables
    fi


    for pkg in "${dependencies[@]}"; do
        check_and_install_pkg "$pkg"
    done

    # Explicitly check for ip6tables, some minimal installs might miss it or need a different package
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${YELLOW}尝试安装 ip6tables...${NC}"
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            check_and_install_pkg "iptables" "ip6tables" # On Debian/Ubuntu, iptables package provides ip6tables
        elif [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
            check_and_install_pkg "iptables-ipv6" "ip6tables" # Legacy name on RHEL based
            if ! command -v ip6tables &>/dev/null; then
                 check_and_install_pkg "iptables-nft" "ip6tables" # Newer RHEL based
            fi
             if ! command -v ip6tables &>/dev/null; then
                 check_and_install_pkg "iptables" "ip6tables" # General fallback
            fi
        elif [[ "$PKG_MANAGER" == "apk" ]]; then
            check_and_install_pkg "iptables" "ip6tables" # Already handled mostly
        fi
    fi
     if ! command -v ip6tables &>/dev/null; then
        echo -e "${RED}ip6tables 未找到或无法安装。IPv6功能可能受限。${NC}"
    fi


    # Check for tools to save rules (persistence)
    case $PKG_MANAGER in
        apt)
            check_and_install_pkg "iptables-persistent" "iptables-save"
            check_and_install_pkg "netfilter-persistent" "netfilter-persistent"
            ;;
        yum|dnf)
            check_and_install_pkg "iptables-services" "iptables-save"
            check_and_install_pkg "ipset-service" "ipset"
            ;;
        apk)
            # Alpine often uses openrc or custom scripts; systemd service is a good generic approach
            # Ensure iptables-save/restore are available from the iptables package
            if ! command -v iptables-save &>/dev/null; then
                echo -e "${YELLOW}iptables-save 未找到，可能需要额外配置规则持久化。${NC}"
            fi
            ;;
    esac

    echo -e "${GREEN}依赖检查完成${NC}"
}

check_firewall_conflicts() {
    echo -e "${BLUE}检查防火墙冲突...${NC}"
    local conflicting_firewalls=""
    if command -v systemctl &>/dev/null && systemctl is-active --quiet firewalld; then
        conflicting_firewalls+="firewalld "
    fi
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        conflicting_firewalls+="ufw "
    fi

    if [ -n "$conflicting_firewalls" ]; then
        echo -e "${YELLOW}警告：检测到以下活动的防火墙服务: $conflicting_firewalls${NC}"
        echo -e "${YELLOW}这些服务可能会与此脚本的iptables规则冲突。${NC}"
        echo -e "${YELLOW}建议处理方式:${NC}"
        echo -e "${YELLOW}1. 禁用冲突的防火墙服务 (例如: sudo systemctl stop $conflicting_firewalls && sudo systemctl disable $conflicting_firewalls)。${NC}"
        echo -e "${YELLOW}2. 如果您希望保留现有防火墙并集成规则，请手动操作，此脚本可能不适用。${NC}"
        read -p "您想继续吗? (y/N): " confirm_continue
        if [[ "$confirm_continue" != "y" && "$confirm_continue" != "Y" ]]; then
            echo -e "${RED}操作已取消。${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}未检测到主流防火墙服务冲突。${NC}"
    fi
}


# 函数：下载中国IP列表 (IPv4)
download_cn_ipv4_list() {
    echo -e "${BLUE}📥 正在下载中国IPv4列表...${NC}"
    # Primary source: ipdeny.com
    wget -q -O /tmp/cn_ipv4.zone https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone
    if [ $? -ne 0 ] || [ ! -s /tmp/cn_ipv4.zone ]; then
        echo -e "${YELLOW}主源 (ipdeny.com) 失败，尝试备用 APNIC 来源...${NC}"
        # Alternative source: APNIC
        wget -q -O- 'http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest' | \
        awk -F\| '/CN\|ipv4/ {print $4"/"32-log($5)/log(2)}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' > /tmp/cn_ipv4.zone
    fi

    if [ ! -s /tmp/cn_ipv4.zone ]; then
        echo -e "${RED}无法获取中国IPv4列表，请检查网络连接或手动提供列表到 /tmp/cn_ipv4.zone ${NC}"
        return 1
    fi

    echo -e "${GREEN}成功下载中国IPv4列表${NC}"
    return 0
}

# 函数：下载中国IP列表 (IPv6)
download_cn_ipv6_list() {
    echo -e "${BLUE}📥 正在下载中国IPv6列表...${NC}"
    # Primary source: ipdeny.com
    wget -q -O /tmp/cn_ipv6.zone https://www.ipdeny.com/ipv6/ipaddresses/blocks/cn.zone
     if [ $? -ne 0 ] || [ ! -s /tmp/cn_ipv6.zone ]; then
        echo -e "${YELLOW}主源 (ipdeny.com) 失败，尝试备用 APNIC 来源...${NC}"
        # Alternative source: APNIC
        wget -q -O- 'http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest' | \
        awk -F\| '/CN\|ipv6/ {print $4"/"$5}' | grep -Eo '([0-9a-fA-F:]+)/[0-9]{1,3}' > /tmp/cn_ipv6.zone
    fi

    if [ ! -s /tmp/cn_ipv6.zone ]; then
        echo -e "${RED}无法获取中国IPv6列表，请检查网络连接或手动提供列表到 /tmp/cn_ipv6.zone ${NC}"
        return 1
    fi

    echo -e "${GREEN}成功下载中国IPv6列表${NC}"
    return 0
}

# 函数：配置IPv4防火墙
configure_ipv4_firewall() {
    echo -e "${BLUE}📦 创建并填充 ipset 集合 (IPv4)...${NC}"
    ipset destroy cnipv4 2>/dev/null || true
    ipset create cnipv4 hash:net family inet maxelem 1000000 # Increased maxelem for potentially large lists
    # Use -exist to avoid errors if an entry already exists (though destroy should handle this)
    while IFS= read -r ip; do
        ipset add cnipv4 "$ip" -exist
    done < /tmp/cn_ipv4.zone

    echo -e "${BLUE}🛡️ 应用iptables规则：仅允许中国IPv4...${NC}"
    iptables -P INPUT ACCEPT # Temporarily accept to avoid lockout if rules are bad
    iptables -F INPUT
    iptables -X # Delete non-default chains

    # Base rules
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT # Allow ping
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Allow CN IPs
    iptables -A INPUT -m set --match-set cnipv4 src -j ACCEPT

    # Add allowed ports (re-read from config)
    if [ -f "$ALLOWED_PORTS_CONF" ]; then
        while IFS= read -r port_entry; do
            apply_port_rule "iptables" "$port_entry" "ACCEPT" "INPUT" "I" # Use new function
        done < "$ALLOWED_PORTS_CONF"
    fi

    # Default drop for anything else
    iptables -P INPUT DROP

    # Save rules
    echo -e "${BLUE}💾 保存ipset和iptables配置...${NC}"
    mkdir -p /etc/ipset /etc/iptables "$SCRIPT_CONF_DIR"
    ipset save cnipv4 > "$IPSET_V4_CONF"
    iptables-save > "$IPTABLES_RULES_V4"

    echo -e "${GREEN}IPv4防火墙配置完成${NC}"
    verify_firewall_status "ipv4"
}

# 函数：配置IPv6防火墙
configure_ipv6_firewall() {
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${YELLOW}ip6tables 命令未找到。跳过IPv6防火墙配置。${NC}"
        return 1
    fi
    echo -e "${BLUE}📦 创建并填充 ipset 集合 (IPv6)...${NC}"
    ipset destroy cnipv6 2>/dev/null || true
    ipset create cnipv6 hash:net family inet6 maxelem 1000000
    while IFS= read -r ip; do
        ipset add cnipv6 "$ip" -exist
    done < /tmp/cn_ipv6.zone

    echo -e "${BLUE}🛡️ 应用ip6tables规则：仅允许中国IPv6...${NC}"
    ip6tables -P INPUT ACCEPT
    ip6tables -F INPUT
    ip6tables -X

    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A INPUT -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT # Allow ping
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -m set --match-set cnipv6 src -j ACCEPT

    if [ -f "$ALLOWED_PORTS_CONF" ]; then
        while IFS= read -r port_entry; do
             apply_port_rule "ip6tables" "$port_entry" "ACCEPT" "INPUT" "I" # Use new function
        done < "$ALLOWED_PORTS_CONF"
    fi

    ip6tables -P INPUT DROP

    echo -e "${BLUE}💾 保存ipset和ip6tables配置...${NC}"
    mkdir -p /etc/ipset /etc/iptables "$SCRIPT_CONF_DIR"
    ipset save cnipv6 > "$IPSET_V6_CONF"
    ip6tables-save > "$IP6TABLES_RULES_V6"

    echo -e "${GREEN}IPv6防火墙配置完成${NC}"
    verify_firewall_status "ipv6"
}

# 函数：设置systemd服务 (for persistence) - 使用包装脚本
setup_systemd_service() {
    if ! command -v systemctl &>/dev/null; then
        echo -e "${YELLOW}systemctl 命令未找到。无法设置 systemd 服务进行规则持久化。${NC}"
        echo -e "${YELLOW}请确保您的系统使用其他方式持久化 iptables 和 ipset 规则。${NC}"
        return 1
    fi

    echo -e "${BLUE}🛠️ 检查并设置 systemd 自动还原服务 ($SYSTEMD_SERVICE_NAME) 使用包装脚本...${NC}"

    # 检查冲突服务 (例如 Debian/Ubuntu 上的 netfilter-persistent)
    if systemctl list-unit-files | grep -q "netfilter-persistent.service"; then
        if systemctl is-active --quiet netfilter-persistent.service || systemctl is-enabled --quiet netfilter-persistent.service; then
            echo -e "${YELLOW}检测到 'netfilter-persistent.service' 可能处于活动或启用状态。${NC}"
            echo -e "${YELLOW}此服务也用于持久化iptables规则，可能与自定义的 '$SYSTEMD_SERVICE_NAME' 冲突。${NC}"
            read -p "是否要禁用 'netfilter-persistent.service' 以使用 '$SYSTEMD_SERVICE_NAME' (推荐)? (y/N): " disable_native
            if [[ "$disable_native" == "y" || "$disable_native" == "Y" ]]; then
                echo -e "${BLUE}正在禁用 netfilter-persistent.service...${NC}"
                systemctl stop netfilter-persistent.service &>/dev/null
                systemctl disable netfilter-persistent.service &>/dev/null
                echo -e "${GREEN}netfilter-persistent.service 已禁用。${NC}"
            else
                echo -e "${YELLOW}保留 'netfilter-persistent.service'。'$SYSTEMD_SERVICE_NAME' 可能无法按预期工作或产生冲突。${NC}"
            fi
        fi
    fi
    # 检查 RHEL 系列系统的冲突 (例如 iptables.service 或 ipset.service)
    if systemctl list-unit-files | grep -q "iptables.service" || systemctl list-unit-files | grep -q "ipset.service"; then
        if systemctl is-active --quiet iptables.service || systemctl is-enabled --quiet iptables.service || \
           systemctl is-active --quiet ipset.service || systemctl is-enabled --quiet ipset.service; then
            echo -e "${YELLOW}检测到 'iptables.service' 或 'ipset.service' (常见于 RHEL/CentOS) 可能处于活动或启用状态。${NC}"
            echo -e "${YELLOW}这些服务也用于持久化规则，可能与自定义的 '$SYSTEMD_SERVICE_NAME' 冲突。${NC}"
            read -p "是否要禁用这些服务以使用 '$SYSTEMD_SERVICE_NAME' (推荐)? (y/N): " disable_native_rhel
            if [[ "$disable_native_rhel" == "y" || "$disable_native_rhel" == "Y" ]]; then
                echo -e "${BLUE}正在禁用 iptables.service 和 ipset.service...${NC}"
                systemctl stop iptables.service ipset.service &>/dev/null
                systemctl disable iptables.service ipset.service &>/dev/null
                echo -e "${GREEN}iptables.service 和 ipset.service 已禁用。${NC}"
            else
                echo -e "${YELLOW}保留原生服务。'$SYSTEMD_SERVICE_NAME' 可能无法按预期工作或产生冲突。${NC}"
            fi
        fi
    fi

    echo -e "${BLUE}创建包装脚本: $WRAPPER_SCRIPT_PATH ${NC}"
    # 创建包装脚本内容
    cat > "$WRAPPER_SCRIPT_PATH" <<EOF_WRAPPER
#!/bin/sh
# CNBlocker Rule Restore Wrapper Script
# This script is called by $SYSTEMD_SERVICE_NAME

# Exit immediately if a command exits with a non-zero status.
set -e

log_message() {
    echo "CNBlocker Wrapper: \$1" >&2 # Log to stderr, systemd will capture to journal
}

log_message "开始恢复规则..."

# IPv4 规则恢复 (关键)
if [ ! -f "$IPSET_V4_CONF" ]; then
    log_message "错误: IPv4 ipset 配置文件 $IPSET_V4_CONF 未找到!"
    exit 1
fi
log_message "正在从 $IPSET_V4_CONF 恢复 IPv4 ipset..."
/usr/sbin/ipset restore -f "$IPSET_V4_CONF"

if [ ! -f "$IPTABLES_RULES_V4" ]; then
    log_message "错误: IPv4 iptables 规则文件 $IPTABLES_RULES_V4 未找到!"
    exit 1
fi
log_message "正在从 $IPTABLES_RULES_V4 恢复 IPv4 iptables 规则..."
/usr/sbin/iptables-restore -n "$IPTABLES_RULES_V4"

# IPv6 规则恢复 (可选)
if [ -f "$IPSET_V6_CONF" ]; then
    log_message "正在从 $IPSET_V6_CONF 恢复 IPv6 ipset..."
    /usr/sbin/ipset restore -f "$IPSET_V6_CONF" || log_message "警告: IPv6 ipset 恢复失败 (文件: $IPSET_V6_CONF)，继续..."
else
    log_message "信息: IPv6 ipset 配置文件 $IPSET_V6_CONF 未找到，跳过。"
fi

if [ -f "$IP6TABLES_RULES_V6" ]; then
    log_message "正在从 $IP6TABLES_RULES_V6 恢复 IPv6 iptables 规则..."
    /usr/sbin/ip6tables-restore -n "$IP6TABLES_RULES_V6" || log_message "警告: IPv6 iptables 规则恢复失败 (文件: $IP6TABLES_RULES_V6)，继续..."
else
    log_message "信息: IPv6 iptables 规则文件 $IP6TABLES_RULES_V6 未找到，跳过。"
fi

log_message "规则恢复成功完成。"
exit 0
EOF_WRAPPER

    # 设置包装脚本为可执行
    chmod +x "$WRAPPER_SCRIPT_PATH"

    echo -e "${BLUE}创建 systemd 服务文件: $SYSTEMD_SERVICE_FILE ${NC}"
    # 创建 systemd 服务文件内容
    cat > "$SYSTEMD_SERVICE_FILE" <<EOF_SYSTEMD
[Unit]
Description=CNBlocker ipset/iptables restore service (via wrapper)
Documentation=man:ipset(8) man:iptables-restore(8) man:ip6tables-restore(8)
DefaultDependencies=no
After=local-fs.target
Before=network.target sysinit.target shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$WRAPPER_SCRIPT_PATH

[Install]
WantedBy=network.target
EOF_SYSTEMD

    systemctl daemon-reload
    echo -e "${BLUE}尝试启用并启动 $SYSTEMD_SERVICE_NAME 服务...${NC}"
    systemctl disable "$SYSTEMD_SERVICE_NAME" &>/dev/null # 确保旧配置被移除
    if systemctl enable "$SYSTEMD_SERVICE_NAME"; then
        echo -e "${GREEN}$SYSTEMD_SERVICE_NAME 服务已成功链接用于开机启动。${NC}"
    else
        echo -e "${RED}$SYSTEMD_SERVICE_NAME 服务链接失败。请检查 systemd 的错误。${NC}"
        return 1 # 如果启用失败则退出
    fi

    if systemctl restart "$SYSTEMD_SERVICE_NAME"; then
        echo -e "${GREEN}$SYSTEMD_SERVICE_NAME 服务已(重新)启动。${NC}"
    else
        echo -e "${RED}$SYSTEMD_SERVICE_NAME 服务启动失败。请检查日志详情:${NC}"
        echo -e "${RED}  sudo systemctl status $SYSTEMD_SERVICE_NAME ${NC}"
        echo -e "${RED}  sudo journalctl -xeu $SYSTEMD_SERVICE_NAME ${NC}"
    fi

    if command -v check_service_status &>/dev/null; then
      check_service_status
    else
      systemctl status "$SYSTEMD_SERVICE_NAME" --no-pager
    fi
}

# 函数：卸载IPv4规则
uninstall_ipv4() {
    echo -e "${BLUE}🧹 正在卸载IPv4规则并还原防火墙...${NC}"
    iptables -P INPUT ACCEPT # Set default policy to ACCEPT before flushing
    iptables -F INPUT
    iptables -X
    ipset destroy cnipv4 2>/dev/null || true
    rm -f "$IPSET_V4_CONF"
    rm -f "$IPTABLES_RULES_V4"
    iptables-save > "$IPTABLES_RULES_V4" # Save empty ruleset
    echo -e "${GREEN}✅ 已卸载：IPv4规则已清除，默认策略为 ACCEPT。${NC}"
}

# 函数：卸载IPv6规则
uninstall_ipv6() {
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${YELLOW}ip6tables 命令未找到。跳过IPv6规则卸载。${NC}"
        return
    fi
    echo -e "${BLUE}🧹 正在卸载IPv6规则并还原防火墙...${NC}"
    ip6tables -P INPUT ACCEPT
    ip6tables -F INPUT
    ip6tables -X
    ipset destroy cnipv6 2>/dev/null || true
    rm -f "$IPSET_V6_CONF"
    rm -f "$IP6TABLES_RULES_V6"
    ip6tables-save > "$IP6TABLES_RULES_V6" # Save empty ruleset
    echo -e "${GREEN}✅ 已卸载：IPv6规则已清除，默认策略为 ACCEPT。${NC}"
}

# 函数：完全卸载
uninstall_all() {
    uninstall_ipv4
    uninstall_ipv6

    if command -v systemctl &>/dev/null; then
        echo -e "${BLUE}停用并移除 systemd 服务...${NC}"
        systemctl stop "$SYSTEMD_SERVICE_NAME" 2>/dev/null
        systemctl disable "$SYSTEMD_SERVICE_NAME" 2>/dev/null
        rm -f "$SYSTEMD_SERVICE_FILE"
        rm -f "$WRAPPER_SCRIPT_PATH" # 移除包装脚本
        systemctl daemon-reload
        systemctl reset-failed # Clear any failed state for the service
    fi

    # 删除端口配置
    rm -f "$ALLOWED_PORTS_CONF"
    rmdir "$SCRIPT_CONF_DIR" 2>/dev/null || true # Remove dir if empty

    echo -e "${GREEN}✅ 已完全卸载：所有规则与服务已清除。防火墙已重置为默认接受所有入站连接。${NC}"
}


# Helper function to apply or delete a port rule for iptables/ip6tables
# Usage: apply_port_rule <iptables_cmd> <port_entry> <action:ACCEPT|DROP> <chain:INPUT|OUTPUT> <operation:I|D|C>
# Port entry can be a single port (e.g., 80) or a range (e.g., 8000:8100)
apply_port_rule() {
    local ipt_cmd="$1"      # iptables or ip6tables
    local port_entry="$2"   # e.g., 80 or 8000:8100
    local target_action="$3" # e.g., ACCEPT
    local chain="$4"        # e.g., INPUT
    local operation="$5"    # I for insert, D for delete, C for check

    local proto
    for proto in tcp udp; do
        local rule_args=""
        if [[ "$port_entry" == *":"* ]]; then # Port range
            rule_args="-p $proto -m multiport --dports $port_entry -j $target_action"
        else # Single port
            rule_args="-p $proto --dport $port_entry -j $target_action"
        fi

        if [[ "$operation" == "C" ]]; then
            "$ipt_cmd" -C "$chain" $rule_args &>/dev/null
            return $? # Return status of check
        else
            # For -D, check first to avoid error message if rule doesn't exist
            if [[ "$operation" == "D" ]]; then
                if "$ipt_cmd" -C "$chain" $rule_args &>/dev/null; then
                    "$ipt_cmd" -D "$chain" $rule_args
                fi
            else # For -I (Insert)
                # Insert rule at the position just before the final DROP rule for INPUT chain
                # If no explicit DROP rule, insert at the top (default behavior of -I).
                # This example inserts before generic DROP. More specific placement might be needed.
                local final_drop_rule_num=$("$ipt_cmd" -L "$chain" --line-numbers | grep -E "DROP\s+all\s+--\s+\anywhere\s+\anywhere" | awk '{print $1}' | head -n 1)
                if [[ -n "$final_drop_rule_num" && "$chain" == "INPUT" ]]; then
                     "$ipt_cmd" -I "$chain" "$final_drop_rule_num" $rule_args
                else
                     "$ipt_cmd" -I "$chain" 1 $rule_args # Insert at the top or as first rule in user chain
                fi
            fi
        fi
    done
    return 0
}


# 函数：添加放行端口或范围
add_allowed_port() {
    echo -e "${BLUE}请输入要放行的端口号或端口范围 (例如: 80, 或 8000:8100):${NC}"
    read port_input

    # Validate port or port range format (basic validation)
    if ! [[ "$port_input" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
        echo -e "${RED}错误: 无效的端口格式。请输入单个端口 (如 22) 或范围 (如 8000:8100)。${NC}"
        return 1
    fi

    local port_start port_end
    if [[ "$port_input" == *":"* ]]; then
        port_start=$(echo "$port_input" | cut -d: -f1)
        port_end=$(echo "$port_input" | cut -d: -f2)
    else
        port_start="$port_input"
        port_end="$port_input"
    fi

    if ! [[ "$port_start" =~ ^[0-9]+$ && "$port_start" -ge 1 && "$port_start" -le 65535 ]] || \
       ! [[ "$port_end" =~ ^[0-9]+$ && "$port_end" -ge 1 && "$port_end" -le 65535 ]] || \
       (( port_start > port_end )); then
        echo -e "${RED}错误: 端口号必须在1-65535之间，且起始端口不能大于结束端口。${NC}"
        return 1
    fi

    # 检查端口是否已经放行
    mkdir -p "$SCRIPT_CONF_DIR" # Ensure directory exists
    if [ -f "$ALLOWED_PORTS_CONF" ] && grep -q -x "$port_input" "$ALLOWED_PORTS_CONF"; then
        echo -e "${YELLOW}端口/范围 $port_input 已经放行，无需重复操作${NC}"
        return 0
    fi

    # 添加到配置文件
    echo "$port_input" >> "$ALLOWED_PORTS_CONF"

    # 应用到防火墙规则
    if ipset list cnipv4 &>/dev/null; then
        echo -e "${BLUE}应用到IPv4防火墙...${NC}"
        apply_port_rule "iptables" "$port_input" "ACCEPT" "INPUT" "I"
        iptables-save > "$IPTABLES_RULES_V4"
    fi

    if command -v ip6tables &>/dev/null && ipset list cnipv6 &>/dev/null; then
        echo -e "${BLUE}应用到IPv6防火墙...${NC}"
        apply_port_rule "ip6tables" "$port_input" "ACCEPT" "INPUT" "I"
        ip6tables-save > "$IP6TABLES_RULES_V6"
    fi

    echo -e "${GREEN}✅ 成功放行端口/范围 $port_input${NC}"
    verify_port_open_status "$port_input"
}

# 函数：删除放行端口或范围
delete_allowed_port() {
    if [ ! -f "$ALLOWED_PORTS_CONF" ] || [ ! -s "$ALLOWED_PORTS_CONF" ]; then
        echo -e "${YELLOW}当前没有配置的放行端口/范围。${NC}"
        return 0
    fi

    echo -e "${BLUE}当前已配置放行的端口/范围:${NC}"
    cat -n "$ALLOWED_PORTS_CONF"

    echo -e "${BLUE}请输入要删除放行的端口号/范围 (与列表中的条目完全匹配):${NC}"
    read port_input

    # 检查端口是否存在于配置文件中
    if ! grep -q -x "$port_input" "$ALLOWED_PORTS_CONF"; then
        echo -e "${YELLOW}端口/范围 '$port_input' 未在配置文件中找到，无需删除。${NC}"
        return 0
    fi

    # 从配置文件中删除 (use temp file for safer sed)
    sed "/^${port_input//\//\\/}$/d" "$ALLOWED_PORTS_CONF" > /tmp/allowed_ports.tmp && mv /tmp/allowed_ports.tmp "$ALLOWED_PORTS_CONF"


    # 从防火墙规则中删除
    if ipset list cnipv4 &>/dev/null; then
        echo -e "${BLUE}从IPv4防火墙移除...${NC}"
        apply_port_rule "iptables" "$port_input" "ACCEPT" "INPUT" "D"
        iptables-save > "$IPTABLES_RULES_V4"
    fi

    if command -v ip6tables &>/dev/null && ipset list cnipv6 &>/dev/null; then
        echo -e "${BLUE}从IPv6防火墙移除...${NC}"
        apply_port_rule "ip6tables" "$port_input" "ACCEPT" "INPUT" "D"
        ip6tables-save > "$IP6TABLES_RULES_V6"
    fi

    echo -e "${GREEN}✅ 成功删除端口/范围 $port_input 的放行规则${NC}"
}


# 函数：查看放行端口
view_allowed_ports() {
    if [ ! -f "$ALLOWED_PORTS_CONF" ] || [ ! -s "$ALLOWED_PORTS_CONF" ]; then
        echo -e "${YELLOW}当前没有配置的放行端口/范围。${NC}"
        return 0
    fi

    echo -e "${GREEN}当前已配置放行的端口/范围:${NC}"
    echo -e "${BLUE}--------------------${NC}"
    cat "$ALLOWED_PORTS_CONF"
    echo -e "${BLUE}--------------------${NC}"
}

# 函数：查看服务状态
check_service_status() {
    echo -e "${BLUE}检查 $SYSTEMD_SERVICE_NAME 服务状态...${NC}"
    if ! command -v systemctl &>/dev/null; then
        echo -e "${YELLOW}systemctl 命令未找到。无法检查 systemd 服务状态。${NC}"
        return
    fi
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        echo -e "${YELLOW}Systemd 服务 ($SYSTEMD_SERVICE_NAME) 未安装。${NC}"
        return
    fi

    if systemctl is-active --quiet "$SYSTEMD_SERVICE_NAME"; then
        echo -e "${GREEN}$SYSTEMD_SERVICE_NAME 服务正在运行 (active)。${NC}"
    else
        echo -e "${YELLOW}$SYSTEMD_SERVICE_NAME 服务未运行 (inactive/failed)。${NC}"
        systemctl status "$SYSTEMD_SERVICE_NAME" --no-pager | grep -E "(Loaded|Active|Main PID|Status|CGroup|Process)"
    fi

    if systemctl is-enabled --quiet "$SYSTEMD_SERVICE_NAME"; then
        echo -e "${GREEN}$SYSTEMD_SERVICE_NAME 服务已设置为开机启动。${NC}"
    else
        echo -e "${YELLOW}$SYSTEMD_SERVICE_NAME 服务未设置为开机启动。${NC}"
    fi
}

# 函数：验证防火墙规则是否生效
verify_firewall_status() {
    local type="$1" # ipv4 or ipv6
    local ipt_cmd="iptables"
    local ipset_name="cnipv4"

    if [[ "$type" == "ipv6" ]]; then
        if ! command -v ip6tables &>/dev/null; then return; fi
        ipt_cmd="ip6tables"
        ipset_name="cnipv6"
    fi

    echo -e "${BLUE}--- 验证 $type 防火墙状态 ---${NC}"
    # Check ipset
    if ipset list "$ipset_name" &>/dev/null; then
        local set_entries=$(ipset list "$ipset_name" | grep -cE '^[0-9a-fA-F.:/]+') # Count members, more robust for v6
        echo -e "${GREEN}IPSET ($ipset_name): 存在, 包含 $set_entries 条目。${NC}"
    else
        echo -e "${RED}IPSET ($ipset_name): 未找到或未激活!${NC}"
    fi

    # Check iptables INPUT chain for key rules
    echo -e "${BLUE}检查 $ipt_cmd INPUT 链关键规则:${NC}"
    if "$ipt_cmd" -S INPUT | grep -q -- "--match-set $ipset_name src -j ACCEPT"; then
        echo -e "${GREEN}  规则: 允许来自 $ipset_name 的流量 - 存在${NC}"
    else
        echo -e "${RED}  规则: 允许来自 $ipset_name 的流量 - 未找到!${NC}"
    fi

    # Check default policy or final DROP rule
    # Get the policy of the INPUT chain
    input_policy=$($ipt_cmd -L INPUT -n | head -n 1 | awk '{print $4}' | tr -d '()')
    if [[ "$input_policy" == "DROP" ]]; then
        echo -e "${GREEN}  策略: INPUT 链默认策略为 DROP - 存在${NC}"
    elif "$ipt_cmd" -S INPUT | awk '{print $NF}' | grep -q "DROP"; then # Check if last rule is a general DROP
         # More robust check for a final DROP rule (might not be the *very* last due to logging etc.)
         if "$ipt_cmd" -S INPUT | grep -E -- "-j\s+DROP$" &>/dev/null ; then
            echo -e "${GREEN}  规则: INPUT 链包含 DROP 规则 - 存在${NC}"
         else
            echo -e "${RED}  策略/规则: INPUT 链缺少默认 DROP 策略或明确的末尾 DROP 规则! 所有流量可能被允许或由其他规则处理。${NC}"
         fi
    else
        echo -e "${RED}  策略/规则: INPUT 链缺少默认 DROP 策略或明确的末尾 DROP 规则! 所有流量可能被允许或由其他规则处理。${NC}"
    fi


    # Check allowed ports from config
    if [ -f "$ALLOWED_PORTS_CONF" ]; then
        echo -e "${BLUE}检查已放行端口的 $ipt_cmd 规则:${NC}"
        while IFS= read -r port_entry; do
            local found_tcp=false
            local found_udp=false
            if [[ "$port_entry" == *":"* ]]; then # Port range
                if "$ipt_cmd" -S INPUT | grep -q -- "-p tcp -m multiport --dports $port_entry -j ACCEPT"; then found_tcp=true; fi
                if "$ipt_cmd" -S INPUT | grep -q -- "-p udp -m multiport --dports $port_entry -j ACCEPT"; then found_udp=true; fi
            else # Single port
                if "$ipt_cmd" -S INPUT | grep -q -- "-p tcp --dport $port_entry -j ACCEPT"; then found_tcp=true; fi
                if "$ipt_cmd" -S INPUT | grep -q -- "-p udp --dport $port_entry -j ACCEPT"; then found_udp=true; fi
            fi

            if $found_tcp && $found_udp; then
                echo -e "${GREEN}  端口/范围 $port_entry (TCP/UDP): 规则存在${NC}"
            elif $found_tcp; then
                echo -e "${GREEN}  端口/范围 $port_entry (TCP): 规则存在${NC} ${YELLOW}(UDP规则缺失)${NC}"
            elif $found_udp; then
                echo -e "${GREEN}  端口/范围 $port_entry (UDP): 规则存在${NC} ${YELLOW}(TCP规则缺失)${NC}"
            else
                echo -e "${RED}  端口/范围 $port_entry (TCP/UDP): 规则未找到!${NC}"
            fi
        done < "$ALLOWED_PORTS_CONF"
    fi
    echo -e "${BLUE}--- $type 防火墙状态验证结束 ---${NC}"
}

# 函数：验证端口是否真的在监听 (应用层面)
verify_port_open_status() {
    local port_input="$1" # e.g., 80 or 8000:8100 or just a single port to check
    echo -e "${BLUE}检查端口 $port_input 的监听状态 (应用层面)...${NC}"
    echo -e "${YELLOW}注意: 这只检查是否有服务在监听这些端口，不代表防火墙一定放行外部访问。${NC}"

    local port_to_check
    if [[ "$port_input" == *":"* ]]; then
        echo -e "${YELLOW}对于端口范围 $port_input, 将尝试检查范围内的部分端口。${NC}"
        port_to_check=$(echo "$port_input" | cut -d: -f1) # Check first port of range as an example
    else
        port_to_check="$port_input"
    fi

    local listening_found=false
    if command -v ss &>/dev/null; then
        if ss -tulnp | grep -qE "(:${port_to_check}|:${port_input})\s"; then # Check for single or full range if simple
            listening_found=true
            echo -e "${GREEN}检测到服务正在监听端口 $port_to_check (或范围内的起始端口):${NC}"
            ss -tulnp | grep -E "(:${port_to_check}|:${port_input})\s"
        fi
         if [[ "$port_input" == *":"* && "$listening_found" == "false" ]]; then # If range and specific not found, show all
            echo -e "${BLUE}当前所有TCP/UDP监听端口 (供参考，因为正在检查范围 $port_input):${NC}"
            ss -tulnp
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tulnp | grep -qE "(:${port_to_check}|:${port_input})\s"; then
            listening_found=true
            echo -e "${GREEN}检测到服务正在监听端口 $port_to_check (或范围内的起始端口):${NC}"
            netstat -tulnp | grep -E "(:${port_to_check}|:${port_input})\s"
        fi
        if [[ "$port_input" == *":"* && "$listening_found" == "false" ]]; then
            echo -e "${BLUE}当前所有TCP/UDP监听端口 (供参考，因为正在检查范围 $port_input):${NC}"
            netstat -tulnp
        fi
    else
        echo -e "${YELLOW}未找到 'ss' 或 'netstat' 命令，无法检查端口监听状态。${NC}"
        return
    fi

    if ! $listening_found && [[ "$port_input" != *":"* ]]; then
         echo -e "${YELLOW}未检测到服务在监听端口 $port_to_check。即使防火墙放行，也无法访问。${NC}"
    elif ! $listening_found && [[ "$port_input" == *":"* ]]; then
         echo -e "${YELLOW}未检测到服务在监听端口范围 $port_input 的起始端口 $port_to_check。请检查其他端口或服务配置。${NC}"
    fi
}


# --- Main Menu & Logic ---

show_menu() {
    clear
    echo -e "${BLUE}=================================================${NC}"
    echo -e "${GREEN}      中国IP入站控制工具 - 交互式菜单 (v2.1 - Wrapper)${NC}"
    echo -e "${BLUE}=================================================${NC}"
    echo -e "${YELLOW}  --- 安装与配置 ---${NC}"
    echo -e "  ${YELLOW}1.${NC} 安装IPv4仅国内入站规则"
    echo -e "  ${YELLOW}2.${NC} 安装IPv6仅国内入站规则 (如果系统支持)"
    echo -e "  ${YELLOW}3.${NC} (重新)设置规则持久化服务 (Systemd - 使用包装脚本)"
    echo -e "${YELLOW}  --- 端口管理 ---${NC}"
    echo -e "  ${YELLOW}4.${NC} 查看已放行端口/范围"
    echo -e "  ${YELLOW}5.${NC} 添加放行端口/范围"
    echo -e "  ${YELLOW}6.${NC} 删除放行端口/范围"
    echo -e "${YELLOW}  --- 状态检查 ---${NC}"
    echo -e "  ${YELLOW}7.${NC} 查看规则持久化服务状态"
    echo -e "  ${YELLOW}8.${NC} 验证当前防火墙规则 (IPv4)"
    echo -e "  ${YELLOW}9.${NC} 验证当前防火墙规则 (IPv6)"
    echo -e "${YELLOW}  --- 卸载 ---${NC}"
    echo -e "  ${YELLOW}10.${NC} 卸载IPv4规则"
    echo -e "  ${YELLOW}11.${NC} 卸载IPv6规则"
    echo -e "  ${YELLOW}12.${NC} 完全卸载 (移除所有规则、服务和包装脚本)"
    echo -e "${YELLOW}  --- 其他 ---${NC}"
    echo -e "  ${YELLOW}0.${NC} 退出"
    echo -e "${BLUE}=================================================${NC}"
    echo -e "请输入选项 [0-12]: "
}

# 主程序
check_root # Ensure script is run as root from the start

while true; do
    show_menu
    read -r choice

    case $choice in
        1)
            check_dependencies
            check_firewall_conflicts # Check for ufw, firewalld
            if download_cn_ipv4_list; then
                configure_ipv4_firewall
                echo -e "${GREEN}✅ IPv4配置完成：所有非中国IP的入站连接已封禁 (IPv4)，出站不限制。${NC}"
                echo -e "${YELLOW}建议运行选项 '3' 来设置或确认规则持久化服务。${NC}"
            else
                echo -e "${RED}IPv4列表下载失败，配置未完成。${NC}"
            fi
            read -p "按Enter键继续..."
            ;;
        2)
            check_dependencies
            check_firewall_conflicts
            if ! command -v ip6tables &>/dev/null; then
                 echo -e "${RED}ip6tables 命令未找到。无法安装IPv6规则。请确保已安装相应包 (如 iptables 或 iptables-ipv6)。${NC}"
                 read -p "按Enter键继续..."
                 continue
            fi
            if download_cn_ipv6_list; then
                configure_ipv6_firewall
                echo -e "${GREEN}✅ IPv6配置完成：所有非中国IP的入站连接已封禁 (IPv6)，出站不限制。${NC}"
                echo -e "${YELLOW}建议运行选项 '3' 来设置或确认规则持久化服务。${NC}"
            else
                echo -e "${RED}IPv6列表下载失败，配置未完成。${NC}"
            fi
            read -p "按Enter键继续..."
            ;;
        3)
            check_dependencies # Ensure ipset/iptables installed for service to work
            setup_systemd_service
            read -p "按Enter键继续..."
            ;;
        4)
            view_allowed_ports
            read -p "按Enter键继续..."
            ;;
        5)
            add_allowed_port
            read -p "按Enter键继续..."
            ;;
        6)
            delete_allowed_port
            read -p "按Enter键继续..."
            ;;
        7)
            check_service_status
            read -p "按Enter键继续..."
            ;;
        8)
            verify_firewall_status "ipv4"
            read -p "按Enter键继续..."
            ;;
        9)
            verify_firewall_status "ipv6"
            read -p "按Enter键继续..."
            ;;
        10)
            uninstall_ipv4
            read -p "按Enter键继续..."
            ;;
        11)
            uninstall_ipv6
            read -p "按Enter键继续..."
            ;;
        12)
            uninstall_all
            read -p "按Enter键继续..."
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${NC}"
            # Clean up temp files on exit, if any were created and not handled
            rm -f /tmp/cn_ipv4.zone /tmp/cn_ipv6.zone /tmp/allowed_ports.tmp
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重试${NC}"
            sleep 1
            ;;
    esac
done
