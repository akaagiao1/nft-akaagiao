#!/bin/bash
# lib/rules.sh - 转发规则 CRUD、端口段/批量创建、负载均衡与权重、导入导出

# 非交互创建单条规则文件（供交互添加与 Realm 迁移共用）
create_rule_record() {
    local listen_port="$1"
    local remote_host="$2"
    local remote_port="$3"
    local protocol="${4:-both}"
    local listen_ip="${5:-any}"
    local snat_ip="${6:-auto}"
    local ip_family="${7:-auto}"
    local rule_note="${8:-}"
    local balance_mode="${9:-off}"
    local weights="${10:-}"
    local enabled="${11:-true}"
    local failover="${12:-false}"

    init_dirs
    local rule_id
    rule_id=$(generate_rule_id)
    local rule_file="${RULES_DIR}/rule-${rule_id}.conf"
    local tmp
    tmp=$(mktemp "${rule_file}.tmp.XXXXXX") || return 1

    cat > "$tmp" <<EOF
RULE_ID=${rule_id}
ENABLED=$(rule_quote "$enabled")
PROTOCOL=$(rule_quote "$protocol")
IP_FAMILY=$(rule_quote "$ip_family")
LISTEN_IP=$(rule_quote "$listen_ip")
LISTEN_PORT=$(rule_quote "$listen_port")
REMOTE_HOST=$(rule_quote "$remote_host")
REMOTE_PORT=$(rule_quote "$remote_port")
SNAT_IP=$(rule_quote "$snat_ip")
RULE_NOTE=$(rule_quote "$rule_note")
BALANCE_MODE=$(rule_quote "$balance_mode")
WEIGHTS=$(rule_quote "$weights")
FAILOVER_ENABLED=$(rule_quote "$failover")
CREATED_TIME=$(rule_quote "$(get_gmt8_time '+%Y-%m-%d %H:%M:%S')")
EOF
    mv -fT -- "$tmp" "$rule_file"
    echo "$rule_id"
}

_proto_badge() {
    case "$1" in
        tcp) echo -e "${BLUE}[TCP]${NC}" ;;
        udp) echo -e "${YELLOW}[UDP]${NC}" ;;
        *)   echo -e "${GREEN}[TCP+UDP]${NC}" ;;
    esac
}

_balance_badge() {
    case "$1" in
        roundrobin) echo -e " ${YELLOW}[轮询]${NC}" ;;
        iphash)     echo -e " ${CYAN}[IP哈希]${NC}" ;;
        *)          echo "" ;;
    esac
}

_format_rule_target_display() {
    local remote_host="$1" remote_port="$2" listen_port="$3"
    if [[ "$remote_host" == *","* ]]; then
        echo "${remote_host}"
    elif [ "$remote_port" = "same" ] || { [[ "$listen_port" == *-* ]] && [ "$remote_port" = "$listen_port" ]; }; then
        echo "${remote_host}:(同端口段)"
    elif is_ipv6 "$remote_host"; then
        echo "[${remote_host#[}]:${remote_port}" | sed 's/\]\]/]/g'
    else
        echo "${remote_host}:${remote_port}"
    fi
}

list_rules_brief() {
    local count=0 enabled_cnt=0 disabled_cnt=0
    local rule_file
    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue
        count=$((count + 1))
        if [ "$ENABLED" = "true" ]; then
            enabled_cnt=$((enabled_cnt + 1))
        else
            disabled_cnt=$((disabled_cnt + 1))
        fi
    done < <(get_sorted_rule_files)

    if [ "$count" -eq 0 ]; then
        echo -e "转发规则: ${YELLOW}暂无${NC}（可在菜单 2 添加，或菜单 6 一键从 Realm 导入）"
        return 1
    fi

    echo -e "规则总数: ${GREEN}${enabled_cnt}${NC} 启用 / ${YELLOW}${disabled_cnt}${NC} 禁用 / 共 ${WHITE}${count}${NC} 条"
    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue

        local listen_disp="${LISTEN_IP}"
        [ "$listen_disp" = "any" ] && listen_disp="*"
        local target_disp
        target_disp=$(_format_rule_target_display "$REMOTE_HOST" "$REMOTE_PORT" "$LISTEN_PORT")
        local p_badge b_badge f_badge n_badge t_badge
        p_badge=$(_proto_badge "$PROTOCOL")
        b_badge=$(_balance_badge "$BALANCE_MODE")
        f_badge=""
        [ "$FAILOVER_ENABLED" = "true" ] && f_badge=" ${CYAN}[故障转移]${NC}"
        n_badge=""
        [ -n "$RULE_NOTE" ] && n_badge=" | 备注: ${GREEN}${RULE_NOTE}${NC}"

        local up_b dn_b up_p dn_p
        IFS='|' read -r up_b dn_b up_p dn_p <<< "$(get_rule_traffic_live "$RULE_ID")"
        local total_b=$((up_b + dn_b))
        t_badge=""
        if [ "$total_b" -gt 0 ]; then
            t_badge=" | 流量: ${CYAN}↑$(format_bytes "$up_b") ↓$(format_bytes "$dn_b")${NC}"
        fi

        if [ "$ENABLED" = "true" ]; then
            local snat_disp=""
            [ "$SNAT_IP" != "auto" ] && [ "$SNAT_IP" != "masquerade" ] && snat_disp=" (SNAT:${SNAT_IP})"
            echo -e "  ${GREEN}#${RULE_ID}${NC} ${listen_disp}:${GREEN}${LISTEN_PORT}${NC} → ${WHITE}${target_disp}${NC}${snat_disp} ${p_badge}${b_badge}${f_badge}${t_badge}${n_badge}"
        else
            echo -e "  ${GRAY}#${RULE_ID} ${listen_disp}:${LISTEN_PORT} → ${target_disp} [已禁用]${n_badge}${NC}"
        fi
    done < <(get_sorted_rule_files)
    return 0
}

list_rules_detailed() {
    echo -e "${GREEN}=== 转发规则详细列表 ===${NC}"
    echo ""
    local count=0 rule_file
    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue
        count=$((count + 1))

        local st_str="${GREEN}启用${NC}"
        [ "$ENABLED" != "true" ] && st_str="${RED}禁用${NC}"
        local target_disp
        target_disp=$(_format_rule_target_display "$REMOTE_HOST" "$REMOTE_PORT" "$LISTEN_PORT")
        local up_b dn_b up_p dn_p
        IFS='|' read -r up_b dn_b up_p dn_p <<< "$(get_rule_traffic_live "$RULE_ID")"

        echo -e "ID ${BLUE}#${RULE_ID}${NC} [${st_str}] 备注: ${GREEN}${RULE_NOTE:-无}${NC}"
        echo -e "  入口: ${CYAN}${LISTEN_IP}:${LISTEN_PORT}${NC}  →  出口: ${WHITE}${target_disp}${NC}"
        echo -e "  协议: ${PROTOCOL} | 地址族: ${IP_FAMILY} | SNAT: ${SNAT_IP} | 均衡: ${BALANCE_MODE}${WEIGHTS:+ (权重:$WEIGHTS)} | 故障转移: ${FAILOVER_ENABLED}"
        echo -e "  流量: ↑$(format_bytes "$up_b") (${up_p} pkts) / ↓$(format_bytes "$dn_b") (${dn_p} pkts) | 创建: ${CREATED_TIME:-未知}"
        echo ""
    done < <(get_sorted_rule_files)

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}暂无转发规则${NC}"
        return 1
    fi
    echo -e "${BLUE}共 ${count} 条规则${NC}"
    return 0
}

# 检查本机端口占用（仅警告，不强行阻断）
_warn_port_conflict() {
    local port_spec="$1"
    [[ "$port_spec" == *-* ]] && return 0
    local occ
    occ=$(ss -tulnp 2>/dev/null | grep -E "[:.]${port_spec}[[:space:]]" || true)
    if [ -n "$occ" ]; then
        echo -e "${YELLOW}⚠ 注意: 端口 ${port_spec} 当前被本机进程监听:${NC}"
        echo "$occ" | sed 's/^/  /'
        echo -e "${YELLOW}  nftables prerouting DNAT 优先级高于本机进程，流量将被直接转发出去。${NC}"
    fi
}

interactive_add_rule() {
    echo -e "${GREEN}=== 添加 nftables 转发规则 ===${NC}"
    echo ""
    echo -e "${BLUE}本机网卡概览:${NC}"
    get_local_interfaces_summary
    echo ""

    # 1. 本地监听端口（支持单端口、逗号批量、端口段）
    local listen_ports
    while true; do
        read -r -p "本地监听端口 (支持单端口 8443 / 批量 80,443 / 端口段 10000-10100): " listen_ports
        listen_ports="${listen_ports// /}"
        if validate_ports_input "$listen_ports"; then
            break
        fi
        echo -e "${RED}无效端口格式，请重新输入${NC}"
    done

    # 2. 目标地址（支持 IPv4 / IPv6 / 域名 / 逗号分隔多目标）
    local remote_host
    while true; do
        echo -e "${GRAY}提示: 支持单个 IP/域名，或多目标负载均衡 (如 1.1.1.1:443,2.2.2.2:8443 或 a.com,b.com)${NC}"
        read -r -p "目标落地 IP 或域名: " remote_host
        remote_host="${remote_host// /}"
        [ -z "$remote_host" ] && { echo -e "${RED}目标地址不能为空${NC}"; continue; }

        local all_ok=true item h p
        IFS=',' read -ra items <<< "$remote_host"
        for item in "${items[@]}"; do
            if [[ "$item" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+|same)$ ]]; then
                h="${BASH_REMATCH[1]}"; p="${BASH_REMATCH[2]}"
                is_ipv6 "$h" && { [ "$p" = "same" ] || validate_port "$p"; } || all_ok=false
            elif is_ipv6 "$item"; then
                :
            elif [[ "$item" == *:* ]]; then
                h="${item%:*}"; p="${item##*:}"
                validate_host "$h" && { [ "$p" = "same" ] || validate_port "$p"; } || all_ok=false
            else
                validate_host "$item" || all_ok=false
            fi
        done
        if [ "$all_ok" = true ]; then
            break
        fi
        echo -e "${RED}包含无效的 IP/域名或端口，请重新输入${NC}"
    done

    # 3. 目标端口（如果是端口段，默认 same 1:1 透传；如果是批量端口，支持逗号对应或单端口）
    local remote_ports=""
    local need_remote_port=true
    if [[ "$remote_host" == *","* ]] && [[ "$remote_host" == *":"* ]]; then
        need_remote_port=false
        remote_ports="0"
    fi
    if [ "$need_remote_port" = true ]; then
        while true; do
            if [[ "$listen_ports" == *-* ]]; then
                read -r -p "目标端口 (端口段建议直接回车按 1:1 原端口转发，或填单端口如 443): " remote_ports
                remote_ports="${remote_ports// /}"
                if [ -z "$remote_ports" ] || [ "$remote_ports" = "same" ] || [ "$remote_ports" = "$listen_ports" ]; then
                    remote_ports="same"
                    break
                elif validate_port "$remote_ports"; then
                    break
                else
                    echo -e "${RED}端口段目标仅支持原端口映射(回车/same)或映射到单个端口${NC}"
                fi
            else
                read -r -p "目标端口 (回车默认与监听端口一致 ${listen_ports}): " remote_ports
                remote_ports="${remote_ports// /}"
                [ -z "$remote_ports" ] && remote_ports="$listen_ports"
                if validate_ports_input "$remote_ports"; then
                    break
                fi
                echo -e "${RED}无效目标端口，请重新输入${NC}"
            fi
        done
    fi

    # 4. 协议选择
    echo ""
    echo "转发协议: [1] TCP+UDP (默认)  [2] 仅 TCP  [3] 仅 UDP"
    read -r -p "请选择 [1-3, 默认1]: " p_ch
    local protocol="both"
    case "${p_ch:-1}" in
        2) protocol="tcp" ;;
        3) protocol="udp" ;;
        *) protocol="both" ;;
    esac

    # 5. 入口监听 IP/网卡 & 出口 SNAT（可选高级项）
    read -r -p "指定入口监听 IP 或网卡名 (回车默认全部 any): " listen_ip
    listen_ip="${listen_ip// /}"
    if [ -z "$listen_ip" ]; then
        listen_ip="any"
    elif ! validate_listen_spec "$listen_ip"; then
        echo -e "${YELLOW}入口 IP/网卡无效，回退为 any${NC}"
        listen_ip="any"
    fi

    read -r -p "指定出口 SNAT IP 或网卡名 (回车默认自动 masquerade): " snat_ip
    snat_ip="${snat_ip// /}"
    [ -z "$snat_ip" ] && snat_ip="auto"

    # 6. 地址族提示（检测是否为域名）
    local ip_family="auto"
    if is_domain "${remote_host%%,*}"; then
        echo "域名解析族: [1] 自动双栈 (默认)  [2] 仅 IPv4  [3] 仅 IPv6"
        read -r -p "请选择 [1-3, 默认1]: " f_ch
        case "${f_ch:-1}" in
            2) ip_family="ipv4" ;;
            3) ip_family="ipv6" ;;
            *) ip_family="auto" ;;
        esac
    fi

    # 7. 若多目标，顺便选择负载均衡模式
    local balance_mode="off" weights=""
    if [[ "$remote_host" == *","* ]]; then
        echo ""
        echo "检测到多个目标，选择负载均衡模式: [1] 轮询 roundrobin (默认)  [2] IP哈希 iphash  [3] 关闭(仅首目标)"
        read -r -p "请选择 [1-3, 默认1]: " b_ch
        case "${b_ch:-1}" in
            2) balance_mode="iphash" ;;
            3) balance_mode="off" ;;
            *) balance_mode="roundrobin" ;;
        esac
    fi

    # 8. 备注
    read -r -p "规则备注 (可选，直接回车跳过): " rule_note
    rule_note=$(echo "$rule_note" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-60)

    # 展开逗号批量端口并创建
    IFS=',' read -ra lp_arr <<< "$listen_ports"
    IFS=',' read -ra rp_arr <<< "$remote_ports"
    local i lp rp new_id created=0
    for i in "${!lp_arr[@]}"; do
        lp="${lp_arr[$i]}"
        if [ "${#rp_arr[@]}" -eq 1 ]; then
            rp="${rp_arr[0]}"
        elif [ "$i" -lt "${#rp_arr[@]}" ]; then
            rp="${rp_arr[$i]}"
        else
            rp="${rp_arr[0]}"
        fi
        _warn_port_conflict "$lp"
        new_id=$(create_rule_record "$lp" "$remote_host" "$rp" "$protocol" "$listen_ip" "$snat_ip" "$ip_family" "$rule_note" "$balance_mode" "$weights" "true" "false")
        echo -e "${GREEN}✓ 已创建规则 #${new_id}: ${listen_ip}:${lp} → ${remote_host}:${rp} (${protocol})${NC}"
        created=$((created + 1))
    done

    if [ "$created" -gt 0 ]; then
        apply_nft_rules
        sync_ddns_timer 1
    fi
}

interactive_edit_rule() {
    echo -e "${YELLOW}=== 编辑转发规则 ===${NC}"
    echo ""
    list_rules_brief || { read -r -p "按回车返回..."; return 1; }
    echo ""
    read -r -p "请输入要编辑的规则 ID: " rid
    [[ "$rid" =~ ^[0-9]+$ ]] || { echo -e "${RED}无效 ID${NC}"; read -r -p "按回车返回..."; return 1; }
    local rf="${RULES_DIR}/rule-${rid}.conf"
    read_rule_file "$rf" || { echo -e "${RED}规则 #${rid} 不存在${NC}"; read -r -p "按回车返回..."; return 1; }

    echo -e "${BLUE}编辑规则 #${rid}（直接回车保留原值）${NC}"
    local v

    read -r -p "本地监听端口 [${LISTEN_PORT}]: " v
    if [ -n "$v" ]; then
        validate_port_or_range "$v" && save_rule_field "$rf" LISTEN_PORT "$v" || echo -e "${RED}端口无效，保留原值${NC}"
    fi

    read -r -p "目标地址 [${REMOTE_HOST}]: " v
    [ -n "$v" ] && save_rule_field "$rf" REMOTE_HOST "${v// /}"

    read -r -p "目标端口 [${REMOTE_PORT}]: " v
    if [ -n "$v" ]; then
        if [ "$v" = "same" ] || validate_port_or_range "$v"; then
            save_rule_field "$rf" REMOTE_PORT "$v"
        else
            echo -e "${RED}端口无效，保留原值${NC}"
        fi
    fi

    read -r -p "转发协议 (both/tcp/udp) [${PROTOCOL}]: " v
    case "$v" in
        both|tcp|udp) save_rule_field "$rf" PROTOCOL "$v" ;;
        "") ;;
        *) echo -e "${RED}无效协议，保留原值${NC}" ;;
    esac

    read -r -p "入口监听 IP/网卡 [${LISTEN_IP}]: " v
    if [ -n "$v" ]; then
        validate_listen_spec "$v" && save_rule_field "$rf" LISTEN_IP "$v" || echo -e "${RED}无效监听地址，保留原值${NC}"
    fi

    read -r -p "出口 SNAT IP/网卡/auto [${SNAT_IP}]: " v
    [ -n "$v" ] && save_rule_field "$rf" SNAT_IP "${v// /}"

    read -r -p "规则备注 [${RULE_NOTE}]: " v
    if [ -n "$v" ]; then
        v=$(echo "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-60)
        save_rule_field "$rf" RULE_NOTE "$v"
    fi

    apply_nft_rules
    sync_ddns_timer 1
    read -r -p "按回车继续..."
}

interactive_delete_rule() {
    echo -e "${YELLOW}=== 删除转发规则 ===${NC}"
    echo ""
    list_rules_brief || { read -r -p "按回车返回..."; return 1; }
    echo ""
    read -r -p "请输入要删除的规则 ID (多个用逗号分隔，如 1,2,3): " input
    input="${input// /}"
    [ -z "$input" ] && return 0

    local IFS=',' id deleted=0
    read -ra ids <<< "$input"
    for id in "${ids[@]}"; do
        if [[ "$id" =~ ^[0-9]+$ ]] && [ -f "${RULES_DIR}/rule-${id}.conf" ]; then
            rm -f "${RULES_DIR}/rule-${id}.conf"
            echo -e "${GREEN}✓ 已删除规则 #${id}${NC}"
            deleted=$((deleted + 1))
        else
            echo -e "${RED}✗ 未找到规则 #${id}${NC}"
        fi
    done

    if [ "$deleted" -gt 0 ]; then
        apply_nft_rules
        sync_ddns_timer 1
        sync_failover_timer 1
    fi
    read -r -p "按回车继续..."
}

interactive_toggle_rule() {
    echo -e "${YELLOW}=== 启用/禁用转发规则 ===${NC}"
    echo ""
    list_rules_brief || { read -r -p "按回车返回..."; return 1; }
    echo ""
    read -r -p "请输入要切换状态的规则 ID (多个用逗号分隔): " input
    input="${input// /}"
    [ -z "$input" ] && return 0

    local IFS=',' id changed=0 rf
    read -ra ids <<< "$input"
    for id in "${ids[@]}"; do
        rf="${RULES_DIR}/rule-${id}.conf"
        if [[ "$id" =~ ^[0-9]+$ ]] && read_rule_file "$rf"; then
            if [ "$ENABLED" = "true" ]; then
                save_rule_field "$rf" ENABLED "false"
                echo -e "${YELLOW}✓ 规则 #${id} 已禁用${NC}"
            else
                save_rule_field "$rf" ENABLED "true"
                echo -e "${GREEN}✓ 规则 #${id} 已启用${NC}"
            fi
            changed=$((changed + 1))
        else
            echo -e "${RED}✗ 无效规则 ID: ${id}${NC}"
        fi
    done

    [ "$changed" -gt 0 ] && apply_nft_rules
    read -r -p "按回车继续..."
}

# === 负载均衡与权重管理 ===

load_balance_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 内核态负载均衡与故障转移管理 ===${NC}"
        echo ""
        local has_multi=false rule_file
        while IFS= read -r rule_file; do
            [ -f "$rule_file" ] || continue
            read_rule_file "$rule_file" || continue
            [[ "$REMOTE_HOST" == *","* ]] || continue
            has_multi=true
            local targets_cnt
            targets_cnt=$(parse_rule_targets "$REMOTE_HOST" "$REMOTE_PORT" | wc -l)
            echo -e "  ${BLUE}#${RULE_ID}${NC} 端口:${GREEN}${LISTEN_PORT}${NC} | 目标数:${targets_cnt} | 模式:${YELLOW}${BALANCE_MODE}${NC} | 权重:${CYAN}${WEIGHTS:-均等}${NC} | 故障转移:$([ "$FAILOVER_ENABLED" = "true" ] && echo -e "${GREEN}开${NC}" || echo -e "${GRAY}关${NC}")"
            echo -e "      目标: ${WHITE}${REMOTE_HOST}${NC}"
        done < <(get_sorted_rule_files)

        if [ "$has_multi" = false ]; then
            echo -e "${YELLOW}当前暂无多目标规则。${NC}"
            echo -e "${GRAY}提示: 添加规则时在目标地址填逗号分隔的多个目标（如 1.1.1.1:443,2.2.2.2:443）即可启用内核负载均衡。${NC}"
        fi

        echo ""
        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 修改规则负载均衡模式 (roundrobin / iphash / off)"
        echo -e "${BLUE}2.${NC} 配置规则目标权重 (如 3,1)"
        echo -e "${YELLOW}3.${NC} 开启/关闭规则故障转移与健康检查"
        echo -e "${CYAN}4.${NC} 查看节点健康状态"
        echo -e "${GREEN}0.${NC} 返回上级菜单"
        echo ""
        read -r -p "请输入选择 [0-4]: " ch
        echo ""
        case "$ch" in
            1)
                read -r -p "请输入规则 ID: " rid
                local rf="${RULES_DIR}/rule-${rid}.conf"
                if read_rule_file "$rf"; then
                    echo "选择模式: [1] roundrobin(轮询)  [2] iphash(源IP哈希)  [3] off(关闭)"
                    read -r -p "请选择 [1-3]: " mc
                    case "$mc" in
                        1) save_rule_field "$rf" BALANCE_MODE "roundrobin" ;;
                        2) save_rule_field "$rf" BALANCE_MODE "iphash" ;;
                        3) save_rule_field "$rf" BALANCE_MODE "off" ;;
                        *) echo -e "${RED}无效选择${NC}"; sleep 1; continue ;;
                    esac
                    apply_nft_rules
                else
                    echo -e "${RED}规则不存在${NC}"
                fi
                read -r -p "按回车继续..."
                ;;
            2)
                read -r -p "请输入规则 ID: " rid
                local rf="${RULES_DIR}/rule-${rid}.conf"
                if read_rule_file "$rf"; then
                    local tcnt
                    tcnt=$(parse_rule_targets "$REMOTE_HOST" "$REMOTE_PORT" | wc -l)
                    echo -e "当前目标 (${tcnt} 个): ${WHITE}${REMOTE_HOST}${NC}"
                    read -r -p "请输入对应权重 (逗号分隔 ${tcnt} 个 1-100 整数，如 3,1): " w_in
                    w_in="${w_in// /}"
                    if [[ "$w_in" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                        IFS=',' read -ra w_arr <<< "$w_in"
                        if [ "${#w_arr[@]}" -eq "$tcnt" ]; then
                            save_rule_field "$rf" WEIGHTS "$w_in"
                            apply_nft_rules
                        else
                            echo -e "${RED}权重数量(${#w_arr[@]})与目标数(${tcnt})不一致${NC}"
                        fi
                    else
                        echo -e "${RED}权重格式无效${NC}"
                    fi
                else
                    echo -e "${RED}规则不存在${NC}"
                fi
                read -r -p "按回车继续..."
                ;;
            3)
                failover_management_menu
                ;;
            4)
                show_health_status
                read -r -p "按回车继续..."
                ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# === 一键导出 / 导入配置包 ===

export_config_archive() {
    local out_path="${1:-/root/nftpf-backup-$(get_gmt8_time '+%Y%m%d-%H%M%S').tar.gz}"
    init_dirs
    save_live_counters
    if tar -czf "$out_path" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")" 2>/dev/null; then
        echo -e "${GREEN}✓ 全部配置、规则与流量数据已导出到: ${WHITE}${out_path}${NC}"
        return 0
    else
        echo -e "${RED}✗ 导出失败: ${out_path}${NC}"
        return 1
    fi
}

import_config_archive() {
    local in_path="$1"
    if [ -z "$in_path" ]; then
        read -r -p "请输入备份压缩包 (.tar.gz) 完整路径: " in_path
    fi
    if [ ! -f "$in_path" ]; then
        echo -e "${RED}✗ 文件不存在: ${in_path}${NC}"
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/nftpf-import.XXXXXX) || return 1
    if ! tar -xzf "$in_path" -C "$tmp_dir" 2>/dev/null || [ ! -d "${tmp_dir}/nftpf" ]; then
        echo -e "${RED}✗ 压缩包结构无效（未找到 nftpf 目录）${NC}"
        rm -rf "$tmp_dir"
        return 1
    fi

    init_dirs
    cp -a "${tmp_dir}/nftpf/." "$CONFIG_DIR/"
    rm -rf "$tmp_dir"
    echo -e "${GREEN}✓ 配置包已导入到 ${CONFIG_DIR}${NC}"
    apply_nft_rules
    sync_ddns_timer 1
    sync_failover_timer 1
}
