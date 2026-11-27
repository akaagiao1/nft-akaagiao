#!/bin/bash
# lib/sysctl.sh - Linux 内核转发参数调优（IP转发、conntrack扩容、BBR+FQ、MSS钳制、Flowtable）

# 静默确保内核开启 IPv4 / IPv6 转发（nftables NAT 转发必需前提）
ensure_ip_forwarding_quiet() {
    local v4_fwd
    v4_fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
    if [ "$v4_fwd" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    fi
    if [ -f /proc/sys/net/ipv6/conf/all/forwarding ]; then
        local v6_fwd
        v6_fwd=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)
        if [ "$v6_fwd" != "1" ]; then
            sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>&1 || true
        fi
    fi
    # 若尚未持久化转发配置，则写入最小转发持久化文件
    if [ ! -f "$SYSCTL_CONF" ]; then
        mkdir -p "$(dirname "$SYSCTL_CONF")"
        cat > "$SYSCTL_CONF" <<'EOF'
# nft-akaagiao 基础内核转发配置
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
        sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    fi
}

# 一键应用中转机高并发内核调优配置
apply_relay_sysctl() {
    echo -e "${YELLOW}正在应用 nftables 中转内核优化参数...${NC}"

    # 尝试加载 nf_conntrack 与 tcp_bbr 模块
    modprobe nf_conntrack >/dev/null 2>&1 || true
    modprobe tcp_bbr >/dev/null 2>&1 || true

    # 根据内存大小动态决定 conntrack 上限，避免小内存 VPS OOM
    local mem_mb ct_max
    mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 512)
    if [ "$mem_mb" -ge 4096 ]; then
        ct_max=524288
    elif [ "$mem_mb" -ge 2048 ]; then
        ct_max=262144
    elif [ "$mem_mb" -ge 1024 ]; then
        ct_max=131072
    else
        ct_max=65536
    fi

    local has_bbr=false
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        has_bbr=true
    fi

    mkdir -p "$(dirname "$SYSCTL_CONF")"
    {
        echo "# nft-akaagiao 内核中转调优配置 ($(get_gmt8_time '+%Y-%m-%d %H:%M:%S'))"
        echo "# IPv4 / IPv6 路由转发"
        echo "net.ipv4.ip_forward = 1"
        echo "net.ipv6.conf.all.forwarding = 1"
        echo "net.ipv6.conf.default.forwarding = 1"
        echo ""
        echo "# 宽松反向路径过滤，兼容多网卡/非对称路由"
        echo "net.ipv4.conf.all.rp_filter = 2"
        echo "net.ipv4.conf.default.rp_filter = 2"
        echo ""
        echo "# 连接跟踪表扩容与超时优化（防高并发 NAT 丢包）"
        echo "net.netfilter.nf_conntrack_max = ${ct_max}"
        echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
        echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
        echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30"
        echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30"
        echo "net.netfilter.nf_conntrack_udp_timeout = 30"
        echo "net.netfilter.nf_conntrack_udp_timeout_stream = 120"
        echo ""
        echo "# 网卡队列与 TCP 缓冲区优化"
        echo "net.core.netdev_max_backlog = 16384"
        echo "net.core.somaxconn = 8192"
        echo "net.core.rmem_max = 16777216"
        echo "net.core.wmem_max = 16777216"
        echo "net.ipv4.tcp_rmem = 4096 87380 16777216"
        echo "net.ipv4.tcp_wmem = 4096 65536 16777216"
        echo "net.ipv4.tcp_mtu_probing = 1"
        echo "net.ipv4.tcp_fastopen = 3"
        echo "net.core.default_qdisc = fq"
        if [ "$has_bbr" = true ]; then
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
    } > "$SYSCTL_CONF"

    # 逐行生效，忽略容器/特定内核不支持的单个 sysctl 键
    local line key val ok_cnt=0 skip_cnt=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] || [ -z "${line// }" ] && continue
        key=$(echo "${line%%=*}" | xargs)
        val=$(echo "${line#*=}" | xargs)
        if sysctl -w "${key}=${val}" >/dev/null 2>&1; then
            ok_cnt=$((ok_cnt + 1))
        else
            skip_cnt=$((skip_cnt + 1))
        fi
    done < "$SYSCTL_CONF"

    echo -e "${GREEN}✓ 内核参数已应用并持久化到 ${SYSCTL_CONF}${NC}"
    echo -e "  生效项: ${GREEN}${ok_cnt}${NC} | 内核跳过: ${GRAY}${skip_cnt}${NC} | conntrack 上限: ${CYAN}${ct_max}${NC} | BBR: $([ "$has_bbr" = true ] && echo -e "${GREEN}已启用${NC}" || echo -e "${YELLOW}内核不支持${NC}")"
}

show_sysctl_status() {
    load_settings
    local v4_fwd v6_fwd ct_cur ct_max cc qdisc
    v4_fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "N/A")
    v6_fwd=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo "N/A")
    ct_cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")
    cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "N/A")
    qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "N/A")

    echo -e "${BLUE}=== 内核与转发高级参数状态 ===${NC}"
    echo -e "  IPv4 转发 (ip_forward):      $([ "$v4_fwd" = "1" ] && echo -e "${GREEN}开启 (1)${NC}" || echo -e "${RED}关闭 ($v4_fwd)${NC}")"
    echo -e "  IPv6 转发 (v6 forwarding):   $([ "$v6_fwd" = "1" ] && echo -e "${GREEN}开启 (1)${NC}" || echo -e "${YELLOW}关闭 ($v6_fwd)${NC}")"
    echo -e "  连接跟踪 (conntrack):        ${CYAN}${ct_cur}${NC} / ${GREEN}${ct_max}${NC}"
    echo -e "  拥塞控制 / 队列:             ${GREEN}${cc}${NC} + ${CYAN}${qdisc}${NC}"
    echo -e "  TCP MSS 钳制 (防 MTU 黑洞):  $([ "$ENABLE_MSS_CLAMP" = "true" ] && echo -e "${GREEN}开启${NC}" || echo -e "${YELLOW}关闭${NC}")"
    echo -e "  Flowtable 极速卸载:          $([ "$ENABLE_FLOWTABLE" = "true" ] && echo -e "${GREEN}开启${NC} ${GRAY}(已建立连接绕过计数链)${NC}" || echo -e "${GRAY}关闭 (精确流量统计)${NC}")"
    echo -e "  本机回环 Hairpin NAT:        $([ "$ENABLE_HAIRPIN" = "true" ] && echo -e "${GREEN}开启${NC}" || echo -e "${GRAY}关闭${NC}")"
}

sysctl_tuning_menu() {
    while true; do
        clear
        show_sysctl_status
        echo ""
        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 一键应用中转内核优化 (ip_forward + conntrack + BBR + FQ)"
        echo -e "${GREEN}2.${NC} 切换 TCP MSS 钳制 (当前: ${ENABLE_MSS_CLAMP})"
        echo -e "${YELLOW}3.${NC} 切换 Flowtable 极速转发卸载 (当前: ${ENABLE_FLOWTABLE})"
        echo -e "${BLUE}4.${NC} 切换本机回环 Hairpin NAT (当前: ${ENABLE_HAIRPIN})"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -r -p "请输入选择 [0-4]: " ch
        echo ""
        case "$ch" in
            1)
                apply_relay_sysctl
                read -r -p "按回车键继续..."
                ;;
            2)
                if [ "$ENABLE_MSS_CLAMP" = "true" ]; then ENABLE_MSS_CLAMP="false"; else ENABLE_MSS_CLAMP="true"; fi
                save_settings
                apply_nft_rules
                read -r -p "按回车键继续..."
                ;;
            3)
                echo -e "${YELLOW}提示: 开启 Flowtable 可显著降低万兆/高吞吐转发的 CPU 占用，${NC}"
                echo -e "${YELLOW}      但已建立连接会走内核快路径，单规则 forward 流量计数将不再完整累计。${NC}"
                if [ "$ENABLE_FLOWTABLE" = "true" ]; then
                    ENABLE_FLOWTABLE="false"
                else
                    ENABLE_FLOWTABLE="true"
                fi
                save_settings
                if ! apply_nft_rules; then
                    echo -e "${RED}当前内核或网卡不支持 Flowtable，已自动回退关闭${NC}"
                    ENABLE_FLOWTABLE="false"
                    save_settings
                    apply_nft_rules 1 || true
                fi
                read -r -p "按回车键继续..."
                ;;
            4)
                if [ "$ENABLE_HAIRPIN" = "true" ]; then ENABLE_HAIRPIN="false"; else ENABLE_HAIRPIN="true"; fi
                save_settings
                apply_nft_rules
                read -r -p "按回车键继续..."
                ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

remove_sysctl_config() {
    rm -f "$SYSCTL_CONF"
}
