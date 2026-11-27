#!/bin/bash
# lib/ddns.sh - 域名目标 DDNS 自动解析与零断流热更新

DDNS_SERVICE="/etc/systemd/system/nftpf-ddns.service"
DDNS_TIMER="/etc/systemd/system/nftpf-ddns.timer"
DDNS_CRON="/etc/cron.d/nftpf-ddns"

has_domain_rules() {
    local rule_file th tp
    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue
        [ "$ENABLED" = "true" ] || continue
        while IFS='|' read -r th tp; do
            is_domain "$th" && return 0
        done < <(parse_rule_targets "$REMOTE_HOST" "$REMOTE_PORT")
    done < <(get_sorted_rule_files)
    return 1
}

# 检测所有启用规则中的域名，仅在任意解析 IP 变化时触发原子重载
run_ddns_check() {
    local quiet="${1:-0}"
    init_dirs
    local changed=0 checked=0 rule_file th tp fam old_ip new_ip
    local has_v6=false
    host_has_global_ipv6 && has_v6=true

    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue
        [ "$ENABLED" = "true" ] || continue

        while IFS='|' read -r th tp; do
            is_domain "$th" || continue
            checked=$((checked + 1))

            for fam in 4 6; do
                [ "$fam" = "4" ] && [ "$IP_FAMILY" = "ipv6" ] && continue
                [ "$fam" = "6" ] && [ "$IP_FAMILY" = "ipv4" ] && continue
                [ "$fam" = "6" ] && [ "$has_v6" = false ] && [ "$IP_FAMILY" != "ipv6" ] && continue

                old_ip=$(_dns_cache_get "$th" "$fam" 2>/dev/null || true)
                new_ip=$(resolve_host_ip "$th" "$fam" 2>/dev/null || true)

                if [ -n "$new_ip" ] && [ "$new_ip" != "$old_ip" ]; then
                    changed=1
                    [ "$quiet" != "1" ] && echo -e "${YELLOW}[DDNS] ${th} (IPv${fam}): ${old_ip:-无} → ${GREEN}${new_ip}${NC}"
                fi
            done
        done < <(parse_rule_targets "$REMOTE_HOST" "$REMOTE_PORT")
    done < <(get_sorted_rule_files)

    if [ "$checked" -eq 0 ]; then
        [ "$quiet" != "1" ] && echo -e "${BLUE}当前没有启用中的域名转发规则${NC}"
        return 0
    fi

    if [ "$changed" -eq 1 ]; then
        [ "$quiet" != "1" ] && echo -e "${YELLOW}检测到域名解析变更，正在原子重载 nftables 规则...${NC}"
        apply_nft_rules "$quiet"
    else
        [ "$quiet" != "1" ] && echo -e "${GREEN}✓ 已检查 ${checked} 个域名目标，解析 IP 无变化${NC}"
    fi
}

enable_ddns_timer() {
    load_settings
    local interval="${DDNS_INTERVAL_MIN:-2}"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > "$DDNS_SERVICE" <<'EOF'
[Unit]
Description=nft-akaagiao DDNS Target Resolver
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nftPF.sh ddns --quiet
EOF
        cat > "$DDNS_TIMER" <<EOF
[Unit]
Description=nft-akaagiao DDNS Periodic Refresh

[Timer]
OnBootSec=45s
OnUnitActiveSec=${interval}min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now nftpf-ddns.timer >/dev/null 2>&1
    else
        mkdir -p /etc/cron.d
        echo "*/${interval} * * * * root /usr/local/bin/nftPF.sh ddns --quiet >/dev/null 2>&1" > "$DDNS_CRON"
        chmod 644 "$DDNS_CRON"
    fi
}

disable_ddns_timer() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl disable --now nftpf-ddns.timer >/dev/null 2>&1 || true
        rm -f "$DDNS_TIMER" "$DDNS_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$DDNS_CRON"
}

# 根据当前是否存在域名规则自动启停 DDNS 定时器
sync_ddns_timer() {
    local quiet="${1:-0}"
    if has_domain_rules; then
        enable_ddns_timer
        [ "$quiet" != "1" ] && echo -e "${GREEN}✓ DDNS 定时刷新已自动开启（每 ${DDNS_INTERVAL_MIN} 分钟）${NC}"
    else
        disable_ddns_timer
    fi
}

ddns_is_active() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl is-active nftpf-ddns.timer >/dev/null 2>&1
    else
        [ -f "$DDNS_CRON" ]
    fi
}

ddns_management_menu() {
    while true; do
        clear
        load_settings
        echo -e "${GREEN}=== 域名 / DDNS 自动更新管理 ===${NC}"
        echo ""
        echo -e "定时刷新状态: $(ddns_is_active && echo -e "${GREEN}运行中${NC} (每 ${DDNS_INTERVAL_MIN} 分钟)" || echo -e "${GRAY}未运行${NC}")"
        if [ -f "$DNS_CACHE_FILE" ]; then
            echo ""
            echo -e "${BLUE}当前域名解析缓存:${NC}"
            local h f ip ts dt
            while IFS='|' read -r h f ip ts; do
                [ -z "$h" ] && continue
                dt=$(date -d "@${ts:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts")
                echo -e "  • ${WHITE}${h}${NC} (IPv${f}) → ${GREEN}${ip}${NC}  ${GRAY}[${dt}]${NC}"
            done < "$DNS_CACHE_FILE"
        fi
        echo ""
        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 立即检测所有域名并热更新"
        echo -e "${BLUE}2.${NC} 修改检测间隔 (当前: ${DDNS_INTERVAL_MIN} 分钟)"
        echo -e "${YELLOW}3.${NC} 开启/重启 DDNS 定时器"
        echo -e "${RED}4.${NC} 关闭 DDNS 定时器"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -r -p "请输入选择 [0-4]: " ch
        echo ""
        case "$ch" in
            1) run_ddns_check 0; read -r -p "按回车继续..." ;;
            2)
                read -r -p "请输入新的刷新间隔（分钟，1-60）: " iv
                if [[ "$iv" =~ ^[0-9]+$ ]] && (( iv >= 1 && iv <= 60 )); then
                    DDNS_INTERVAL_MIN="$iv"
                    save_settings
                    ddns_is_active && enable_ddns_timer
                    echo -e "${GREEN}✓ 刷新间隔已设为 ${iv} 分钟${NC}"
                else
                    echo -e "${RED}无效数值${NC}"
                fi
                read -r -p "按回车继续..."
                ;;
            3) enable_ddns_timer; echo -e "${GREEN}✓ DDNS 定时器已开启${NC}"; read -r -p "按回车继续..." ;;
            4) disable_ddns_timer; echo -e "${YELLOW}✓ DDNS 定时器已关闭${NC}"; read -r -p "按回车继续..." ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}
