#!/bin/bash
# lib/ui.sh - 交互菜单、实时状态与流量面板、一键安装、分阶段卸载与 CLI 分发

smart_install() {
    local mode="${1:-}"
    echo -e "${GREEN}=== nft-akaagiao (nftables 内核转发管理) ${SCRIPT_VERSION} 安装 ===${NC}"
    echo ""
    detect_system
    echo -e "${BLUE}检测到系统: ${GREEN}${OS} ${VER}${NC} (${PKG_MGR} / ${INIT_SYSTEM})"
    echo ""
    echo -e "${YELLOW}步骤 1/3: 检查并安装依赖...${NC}"
    manage_dependencies "install" || { echo -e "${RED}依赖安装失败${NC}"; return 1; }

    echo ""
    echo -e "${YELLOW}步骤 2/3: 初始化目录与内核转发参数...${NC}"
    init_dirs
    ensure_ip_forwarding_quiet
    echo -e "  ${GREEN}✓${NC} 配置目录已就绪: ${CONFIG_DIR}"
    echo -e "  ${GREEN}✓${NC} 内核 IPv4/IPv6 转发已开启"

    echo ""
    echo -e "${YELLOW}步骤 3/3: 配置开机持久化服务...${NC}"
    install_persistence_service

    # 如果已有规则直接原子加载
    if [ -n "$(get_sorted_rule_files)" ]; then
        apply_nft_rules
    fi

    echo ""
    echo -e "${GREEN}=== 安装完成！输入快捷命令 ${WHITE}zz${GREEN} 即可管理 nftables 转发 ===${NC}"
    if [ "$mode" != "--quiet" ] && [ -f /etc/realm/config.json ]; then
        echo -e "${CYAN}提示: 检测到本机存在 /etc/realm/config.json，可执行 ${WHITE}zz switch-from-realm${CYAN} 一键迁移替代 Realm！${NC}"
    fi
}

show_status_summary() {
    load_settings
    echo -e "${BLUE}=== 运行状态 ===${NC}"
    local nft_ver
    nft_ver=$(nft --version 2>/dev/null | head -1 || echo "未安装")
    local fwd_v4
    fwd_v4=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)

    if nftpf_is_active; then
        echo -e "转发引擎: ${GREEN}● 运行中${NC} (${GRAY}${nft_ver}${NC}) | IP转发: $([ "$fwd_v4" = "1" ] && echo -e "${GREEN}开${NC}" || echo -e "${RED}关${NC}") | DDNS: $(ddns_is_active && echo -e "${GREEN}开${NC}" || echo -e "${GRAY}关${NC}")"
    else
        echo -e "转发引擎: ${YELLOW}● 未加载规则${NC} (${GRAY}${nft_ver}${NC}) | IP转发: $([ "$fwd_v4" = "1" ] && echo -e "${GREEN}开${NC}" || echo -e "${RED}关${NC}")"
    fi
    if pgrep -x realm >/dev/null 2>&1; then
        echo -e "Realm状态: ${YELLOW}● 仍在运行${NC} ${GRAY}(可用 6 或 'zz switch-from-realm' 一键迁移替代)${NC}"
    fi
    echo ""
    list_rules_brief || true
    echo ""
}

show_traffic_dashboard() {
    echo -e "${GREEN}=== 端口转发实时流量统计 (nftables 内核原生计数) ===${NC}"
    echo ""
    printf "%-5s %-15s %-26s %-12s %-12s %-12s %s\n" "ID" "监听端口" "转发目标" "上行(出)" "下行(回)" "合计" "备注"
    echo "────────────────────────────────────────────────────────────────────────────────────────"
    local sum_up=0 sum_dn=0 rule_file
    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue
        local up_b dn_b up_p dn_p
        IFS='|' read -r up_b dn_b up_p dn_p <<< "$(get_rule_traffic_live "$RULE_ID")"
        sum_up=$((sum_up + up_b))
        sum_dn=$((sum_dn + dn_b))
        local tot=$((up_b + dn_b))
        local t_disp
        t_disp=$(_format_rule_target_display "$REMOTE_HOST" "$REMOTE_PORT" "$LISTEN_PORT")
        printf "#%-4s %-15s %-26s %-12s %-12s %-12s %s\n" \
            "$RULE_ID" "${LISTEN_PORT}" "${t_disp:0:25}" \
            "$(format_bytes "$up_b")" "$(format_bytes "$dn_b")" "$(format_bytes "$tot")" "${RULE_NOTE:--}"
    done < <(get_sorted_rule_files)
    echo "────────────────────────────────────────────────────────────────────────────────────────"
    printf "%-48s %-12s %-12s %-12s\n" "总计" "$(format_bytes "$sum_up")" "$(format_bytes "$sum_dn")" "$(format_bytes $((sum_up + sum_dn)))"
}

traffic_menu() {
    while true; do
        clear
        show_traffic_dashboard
        echo ""
        echo -e "${GREEN}1.${NC} 刷新流量统计"
        echo -e "${BLUE}2.${NC} 立即持久化流量快照"
        echo -e "${RED}3.${NC} 清零所有规则流量计数"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -r -p "请输入选择 [0-3]: " ch
        case "$ch" in
            1) continue ;;
            2) save_live_counters; echo -e "${GREEN}✓ 快照已保存${NC}"; sleep 1 ;;
            3)
                read -r -p "确认清零全部流量统计? (y/N): " c
                [[ "$c" =~ ^[Yy]$ ]] && reset_all_counters
                sleep 1
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}

show_live_ruleset() {
    echo -e "${GREEN}=== 当前内核 nftables 转发规则集 ===${NC}"
    echo ""
    if nft_table_exists "ip" "$NFT_TABLE_V4"; then
        echo -e "${CYAN}--- table ip ${NFT_TABLE_V4} ---${NC}"
        nft list table ip "$NFT_TABLE_V4"
        echo ""
    else
        echo -e "${GRAY}(table ip ${NFT_TABLE_V4} 未加载)${NC}"
    fi
    if nft_table_exists "ip6" "$NFT_TABLE_V6"; then
        echo -e "${CYAN}--- table ip6 ${NFT_TABLE_V6} ---${NC}"
        nft list table ip6 "$NFT_TABLE_V6"
        echo ""
    fi
}

rules_management_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 转发规则管理 ===${NC}"
        echo ""
        list_rules_brief || true
        echo ""
        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 添加转发规则（单端口/批量/端口段/多目标）"
        echo -e "${GREEN}2.${NC} 编辑转发规则"
        echo -e "${GREEN}3.${NC} 启用/禁用转发规则"
        echo -e "${RED}4.${NC} 删除转发规则（支持批量）"
        echo -e "${BLUE}5.${NC} 负载均衡与故障转移管理"
        echo -e "${CYAN}6.${NC} 查看详细规则列表"
        echo -e "${YELLOW}7.${NC} 一键导出 / 导入配置备份包"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -r -p "请输入选择 [0-7]: " ch
        echo ""
        case "$ch" in
            1) interactive_add_rule; read -r -p "按回车继续..." ;;
            2) interactive_edit_rule ;;
            3) interactive_toggle_rule ;;
            4) interactive_delete_rule ;;
            5) load_balance_menu ;;
            6) list_rules_detailed; read -r -p "按回车继续..." ;;
            7)
                echo "[1] 导出配置包  [2] 导入配置包"
                read -r -p "请选择 [1-2]: " ec
                case "$ec" in
                    1) export_config_archive ;;
                    2) import_config_archive ;;
                esac
                read -r -p "按回车继续..."
                ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

uninstall_nftpf() {
    echo -e "${RED}=== 分阶段卸载 nft-akaagiao ===${NC}"
    echo ""
    echo -e "${YELLOW}第一阶段: 清空 nftpf 转发规则表、停用持久化服务与定时器、删除 /etc/nftpf 配置${NC}"
    echo -e "${GRAY}(不会触碰你系统自带的其他 nftables/iptables 防火墙规则)${NC}"
    read -r -p "确认执行第一阶段清理? (y/N): " c1
    if [[ "$c1" =~ ^[Yy]$ ]]; then
        stop_nft_rules
        remove_persistence_service
        disable_ddns_timer
        disable_failover_timer
        remove_sysctl_config
        rm -rf "$CONFIG_DIR"
        echo -e "${GREEN}✓ 第一阶段清理完成${NC}"
    else
        echo -e "${BLUE}已取消${NC}"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}第二阶段: 删除脚本程序 (/usr/local/bin/nftPF.sh、模块库与 zz 快捷命令)${NC}"
    read -r -p "确认彻底删除脚本文件? (y/N): " c2
    if [[ "$c2" =~ ^[Yy]$ ]]; then
        rm -f "$INSTALL_DIR/nftPF.sh" "$SHORTCUT_PATH"
        rm -rf "$LIB_DIR"
        echo -e "${GREEN}✓ 已彻底卸载完成${NC}"
        exit 0
    else
        echo -e "${BLUE}脚本保留，随时可用 zz 重新配置${NC}"
    fi
}

show_main_menu() {
    while true; do
        clear
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   nft-akaagiao 内核态 nftables 端口转发管理 ${SCRIPT_VERSION}      ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
        echo -e "${GRAY}项目: https://github.com/${REPO_OWNER}/${REPO_NAME} | 快捷命令: zz${NC}"
        echo ""
        show_status_summary

        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 安装 / 更新环境与脚本"
        echo -e "${BLUE}2.${NC} 转发规则管理（增删改查 / 负载均衡 / 备份）"
        echo -e "${CYAN}3.${NC} 实时端口流量统计（内核原生计数）"
        echo -e "${YELLOW}4.${NC} 域名 / DDNS 自动更新管理"
        echo -e "${BLUE}5.${NC} 内核中转优化（IP转发 / conntrack / BBR / Flowtable）"
        echo -e "${GREEN}6.${NC} Realm 一键迁移切换为 nftables"
        echo -e "${GREEN}7.${NC} 原子重载规则 / 停止转发 / 查看实时 ruleset"
        echo -e "${RED}8.${NC} 分阶段卸载"
        echo -e "${YELLOW}0.${NC} 退出"
        echo ""
        read -r -p "请输入选择 [0-8]: " ch
        echo ""
        case "$ch" in
            1)
                smart_install
                read -r -p "按回车继续..."
                ;;
            2)
                check_dependencies
                rules_management_menu
                ;;
            3)
                check_dependencies
                traffic_menu
                ;;
            4)
                check_dependencies
                ddns_management_menu
                ;;
            5)
                check_dependencies
                sysctl_tuning_menu
                ;;
            6)
                check_dependencies
                migrate_realm_menu
                ;;
            7)
                check_dependencies
                echo "[1] 原子热重载 (不中断连接)  [2] 停止并清空转发规则  [3] 查看实时 nft ruleset"
                read -r -p "请选择 [1-3]: " sc
                echo ""
                case "$sc" in
                    1) apply_nft_rules ;;
                    2) stop_nft_rules ;;
                    3) show_live_ruleset ;;
                esac
                read -r -p "按回车继续..."
                ;;
            8)
                uninstall_nftpf
                read -r -p "按回车继续..."
                ;;
            0)
                echo -e "${BLUE}再见！随时输入 zz 再次管理。${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-8${NC}"
                sleep 1
                ;;
        esac
    done
}

show_help() {
    cat <<EOF
nft-akaagiao (${SCRIPT_VERSION}) - Linux 内核态 nftables 端口转发管理工具

用法: zz [命令] [参数]

交互模式:
  zz                        打开交互式管理主菜单

常用 CLI 命令:
  zz install                安装/修复依赖与开机持久化服务
  zz update                 从 GitHub 更新至最新版脚本
  zz status                 查看运行状态、规则概览与流量
  zz list                   查看全部转发规则详情
  zz apply | reload         校验并原子热重载 nftables 规则（零断流）
  zz stop                   停止转发并清空 nftpf 独立表（保存流量快照）
  zz ruleset                查看当前内核生效的 nftables 规则集
  zz traffic [reset]        查看或清零端口流量统计
  zz ddns [--quiet]         检测所有域名目标并在 IP 变化时热更新
  zz failover [check|status|toggle]  故障转移检测与管理
  zz sysctl                 一键应用内核中转调优参数
  zz migrate [路径]         仅导入 Realm 配置（自动检测 /etc/realm）
  zz switch-from-realm [路径]  一键导入 Realm 配置、停用 Realm 并切流至 nftables
  zz export [输出路径]      导出全部配置与流量数据压缩包
  zz import <tar.gz>        从备份包恢复配置并原子重载
  zz uninstall              分阶段彻底卸载
EOF
}

main() {
    detect_system

    case "${1:-}" in
        ""|menu)
            check_root
            init_dirs
            show_main_menu
            ;;
        -h|--help|help)
            show_help
            ;;
        status)
            check_root
            init_dirs
            show_status_summary
            ;;
        list)
            check_root
            init_dirs
            list_rules_detailed
            ;;
        apply|reload)
            check_root
            check_dependencies
            apply_nft_rules
            ;;
        --apply-boot)
            check_root
            check_dependencies
            apply_nft_rules 1
            ;;
        stop)
            check_root
            stop_nft_rules
            ;;
        --stop-boot)
            check_root
            save_live_counters
            nft_table_exists "ip" "$NFT_TABLE_V4" && nft delete table ip "$NFT_TABLE_V4" 2>/dev/null || true
            nft_table_exists "ip6" "$NFT_TABLE_V6" && nft delete table ip6 "$NFT_TABLE_V6" 2>/dev/null || true
            ;;
        ruleset)
            check_root
            show_live_ruleset
            ;;
        traffic)
            check_root
            if [ "${2:-}" = "reset" ]; then
                reset_all_counters
            else
                show_traffic_dashboard
            fi
            ;;
        ddns)
            check_root
            check_dependencies
            if [ "${2:-}" = "--quiet" ]; then
                run_ddns_check 1
            else
                run_ddns_check 0
            fi
            ;;
        failover)
            check_root
            check_dependencies
            case "${2:-status}" in
                check)
                    [ "${3:-}" = "--quiet" ] && run_failover_check 1 || run_failover_check 0
                    ;;
                status) show_health_status ;;
                toggle) failover_management_menu ;;
                *) echo "用法: zz failover [check|status|toggle]" ;;
            esac
            ;;
        sysctl)
            check_root
            apply_relay_sysctl
            ;;
        migrate)
            check_root
            check_dependencies
            migrate_realm_auto "${2:-}" && apply_nft_rules
            ;;
        switch-from-realm)
            check_root
            check_dependencies
            switch_from_realm_cmd "${2:-}"
            ;;
        export)
            check_root
            export_config_archive "${2:-}"
            ;;
        import)
            check_root
            check_dependencies
            import_config_archive "${2:-}"
            ;;
        uninstall)
            check_root
            uninstall_nftpf
            ;;
        *)
            echo -e "${RED}未知命令: $1${NC}"
            show_help
            exit 1
            ;;
    esac
}
