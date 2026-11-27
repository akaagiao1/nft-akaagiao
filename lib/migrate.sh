#!/bin/bash
# lib/migrate.sh - 一键迁移 Realm 配置（支持 realm-xwPF rules、config.json、config.toml）

# 清理被 Realm 占用的旧 conntrack UDP/TCP 状态，加速切换后即刻生效
clear_conntrack_for_ports() {
    command -v conntrack >/dev/null 2>&1 || return 0
    local rule_file p
    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue
        [ "$ENABLED" = "true" ] || continue
        [[ "$LISTEN_PORT" == *-* ]] && continue
        p="$LISTEN_PORT"
        conntrack -D -p udp --dport "$p" >/dev/null 2>&1 || true
        conntrack -D -p tcp --dport "$p" >/dev/null 2>&1 || true
    done < <(get_sorted_rule_files)
}

# 检查是否已存在相同 (LISTEN_PORT, REMOTE_HOST, REMOTE_PORT, PROTOCOL) 规则，避免重复导入
_rule_duplicate_exists() {
    local lp="$1" rh="$2" rp="$3" proto="$4"
    local rf
    while IFS= read -r rf; do
        [ -f "$rf" ] || continue
        read_rule_file "$rf" || continue
        if [ "$LISTEN_PORT" = "$lp" ] && [ "$REMOTE_HOST" = "$rh" ] && [ "$REMOTE_PORT" = "$rp" ] && [ "$PROTOCOL" = "$proto" ]; then
            return 0
        fi
    done < <(get_sorted_rule_files)
    return 1
}

_normalize_realm_listen_ip() {
    local ip="$1"
    ip="${ip#[}"; ip="${ip%]}"
    case "$ip" in
        ""|"::"|"0.0.0.0"|"*") echo "any" ;;
        *) echo "$ip" ;;
    esac
}

_normalize_realm_snat() {
    local ip="$1"
    ip="${ip#[}"; ip="${ip%]}"
    case "$ip" in
        ""|"::"|"0.0.0.0") echo "auto" ;;
        *) echo "$ip" ;;
    esac
}

# 1) 从 realm-xwPF 的 /etc/realm/rules/rule-*.conf 导入（完整保留备注、权重、协议、启用状态）
migrate_from_realm_rules_dir() {
    local src_dir="${1:-/etc/realm/rules}"
    if [ ! -d "$src_dir" ] || [ -z "$(ls -A "${src_dir}"/rule-*.conf 2>/dev/null)" ]; then
        return 1
    fi

    echo -e "${BLUE}检测到 realm-xwPF 规则目录: ${src_dir}${NC}"
    local imported=0 skipped=0 warn_l7=0 warn_v6=0 f

    # 收集同端口多规则，自动合并为 nftables 单规则多目标负载均衡
    local -A port_targets port_proto port_listen_ip port_snat port_note port_balance port_weights port_failover port_enabled

    for f in $(ls "${src_dir}"/rule-*.conf 2>/dev/null | sort -t- -k2 -n); do
        [ -f "$f" ] || continue
        (
            unset RULE_ID RULE_NAME RULE_ROLE SECURITY_LEVEL LISTEN_PORT LISTEN_IP THROUGH_IP
            unset REMOTE_HOST REMOTE_PORT FORWARD_TARGET RULE_NOTE ENABLED BALANCE_MODE TARGET_STATES WEIGHTS
            unset FAILOVER_ENABLED MPTCP_MODE PROXY_MODE PROTOCOL
            # shellcheck source=/dev/null
            source "$f" 2>/dev/null || exit 1
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${RULE_ROLE:-1}" "${SECURITY_LEVEL:-standard}" "${LISTEN_PORT:-}" "${LISTEN_IP:-::}" \
                "${THROUGH_IP:-::}" "${REMOTE_HOST:-}" "${REMOTE_PORT:-}" "${FORWARD_TARGET:-}" \
                "${RULE_NOTE:-}" "${ENABLED:-true}" "${BALANCE_MODE:-off}" "${WEIGHTS:-}" \
                "${FAILOVER_ENABLED:-false}" "${PROTOCOL:-both}" "${MPTCP_MODE:-off}" "${PROXY_MODE:-off}"
        ) > /tmp/.nftpf_realm_row.$$ 2>/dev/null || continue

        local r_role r_sec r_lport r_lip r_tip r_rhost r_rport r_ftarget r_note r_en r_bal r_w r_fo r_proto
        IFS=$'\t' read -r r_role r_sec r_lport r_lip r_tip r_rhost r_rport r_ftarget r_note r_en r_bal r_w r_fo r_proto < /tmp/.nftpf_realm_row.$$
        rm -f /tmp/.nftpf_realm_row.$$

        [ -z "$r_lport" ] && continue
        if [ "$r_role" = "2" ]; then
            echo -e "  ${YELLOW}⚠ 跳过端口 ${r_lport}: 双端 Realm 隧道解密端 (RULE_ROLE=2)，nftables 为纯 L3/L4 转发不支持 TLS/WS 解密${NC}"
            warn_l7=$((warn_l7 + 1))
            skipped=$((skipped + 1))
            continue
        fi
        if [ -n "$r_sec" ] && [ "$r_sec" != "standard" ]; then
            echo -e "  ${YELLOW}⚠ 注意 端口 ${r_lport}: 原 Realm 规则启用了 ${r_sec} 传输加密，导入 nftables 后将变为纯 L4 转发${NC}"
            warn_l7=$((warn_l7 + 1))
        fi

        local lip snat targets_str
        lip=$(_normalize_realm_listen_ip "$r_lip")
        snat=$(_normalize_realm_snat "$r_tip")

        if [[ "$r_rhost" == *","* ]]; then
            local IFS=',' h acc=""
            read -ra h_arr <<< "$r_rhost"
            for h in "${h_arr[@]}"; do
                h=$(echo "$h" | xargs)
                [ -z "$h" ] && continue
                acc="${acc:+${acc},}${h}:${r_rport}"
            done
            targets_str="$acc"
        else
            targets_str="${r_rhost}:${r_rport}"
        fi

        if [ -z "${port_targets[$r_lport]:-}" ]; then
            port_targets["$r_lport"]="$targets_str"
            port_proto["$r_lport"]="$r_proto"
            port_listen_ip["$r_lport"]="$lip"
            port_snat["$r_lport"]="$snat"
            port_note["$r_lport"]="$r_note"
            port_balance["$r_lport"]="$r_bal"
            port_weights["$r_lport"]="$r_w"
            port_failover["$r_lport"]="$r_fo"
            port_enabled["$r_lport"]="$r_en"
        else
            port_targets["$r_lport"]="${port_targets[$r_lport]},${targets_str}"
            [ -n "$r_note" ] && [ -z "${port_note[$r_lport]}" ] && port_note["$r_lport"]="$r_note"
            [ "$r_bal" != "off" ] && port_balance["$r_lport"]="$r_bal"
            [ -n "$r_w" ] && port_weights["$r_lport"]="$r_w"
            [ "$r_fo" = "true" ] && port_failover["$r_lport"]="true"
        fi
    done

    local lp
    for lp in $(printf '%s\n' "${!port_targets[@]}" | sort -n); do
        local ts="${port_targets[$lp]}"
        local rh rp bal="${port_balance[$lp]}"
        if [[ "$ts" == *","* ]]; then
            rh="$ts"
            rp="0"
            [ "$bal" = "off" ] && bal="roundrobin"
        else
            if [[ "$ts" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
                rh="${BASH_REMATCH[1]}"; rp="${BASH_REMATCH[2]}"
            else
                rh="${ts%:*}"; rp="${ts##*:}"
            fi
        fi

        if _rule_duplicate_exists "$lp" "$rh" "$rp" "${port_proto[$lp]}"; then
            echo -e "  ${GRAY}跳过已存在规则: ${lp} → ${rh}:${rp}${NC}"
            skipped=$((skipped + 1))
            continue
        fi

        local nid
        nid=$(create_rule_record "$lp" "$rh" "$rp" "${port_proto[$lp]}" "${port_listen_ip[$lp]}" "${port_snat[$lp]}" "auto" "${port_note[$lp]}" "$bal" "${port_weights[$lp]}" "${port_enabled[$lp]}" "${port_failover[$lp]}")
        echo -e "  ${GREEN}✓ 导入规则 #${nid}: :${lp} → ${rh}$([ "$rp" != "0" ] && echo ":${rp}") (${port_proto[$lp]})${port_note[$lp]:+ [${port_note[$lp]}]}${NC}"
        imported=$((imported + 1))
    done

    echo -e "${GREEN}导入完成: 新增 ${imported} 条，跳过 ${skipped} 条${NC}"
    if host_has_global_ipv6; then
        echo -e "${YELLOW}ℹ 提示: 本机同时具有 IPv6，nftables 仅支持 IPv4→IPv4 与 IPv6→IPv6，不会将 IPv6 入站转发到纯 IPv4 落地。${NC}"
    fi
    return 0
}

# 2) 从标准 Realm config.json 导入
migrate_from_realm_json() {
    local json_file="$1"
    [ -f "$json_file" ] || return 1
    if ! jq -e '.endpoints | type == "array"' "$json_file" >/dev/null 2>&1; then
        echo -e "${RED}错误: ${json_file} 不是有效的 Realm JSON 配置${NC}"
        return 1
    fi

    echo -e "${BLUE}正在解析 Realm JSON 配置: ${json_file}${NC}"
    local count imported=0 skipped=0 i
    count=$(jq '.endpoints | length' "$json_file")

    for ((i = 0; i < count; i++)); do
        local listen remote extra balance through l_trans r_trans proto
        listen=$(jq -r ".endpoints[$i].listen // empty" "$json_file")
        remote=$(jq -r ".endpoints[$i].remote // empty" "$json_file")
        extra=$(jq -r ".endpoints[$i].extra_remotes[]? // empty" "$json_file" | paste -sd',' -)
        balance=$(jq -r ".endpoints[$i].balance // empty" "$json_file")
        through=$(jq -r ".endpoints[$i].through // .endpoints[$i].interface // empty" "$json_file")
        l_trans=$(jq -r ".endpoints[$i].listen_transport // empty" "$json_file")
        r_trans=$(jq -r ".endpoints[$i].remote_transport // empty" "$json_file")
        proto=$(jq -r --argjson idx "$i" '
            def eff($f):
                if .endpoints[$idx].network[$f] != null then .endpoints[$idx].network[$f]
                elif .network[$f] != null then .network[$f]
                else false end;
            if (.network.no_tcp == null and .network.use_udp == null
                and .endpoints[$idx].network.no_tcp == null
                and .endpoints[$idx].network.use_udp == null) then "both"
            else
                (eff("no_tcp")) as $nt | (eff("use_udp")) as $uu |
                if $nt == false and $uu == true then "both"
                elif $nt == false and $uu == false then "tcp"
                elif $nt == true and $uu == true then "udp"
                else "invalid" end
            end' "$json_file" 2>/dev/null)

        [ -z "$listen" ] || [ -z "$remote" ] || [ "$proto" = "invalid" ] && { skipped=$((skipped + 1)); continue; }
        if [ -n "$l_trans" ]; then
            echo -e "  ${YELLOW}⚠ 跳过 endpoint[$i] (${listen}): 包含 listen_transport (${l_trans})，nftables 不支持隧道解密${NC}"
            skipped=$((skipped + 1))
            continue
        fi
        [ -n "$r_trans" ] && echo -e "  ${YELLOW}⚠ 注意 endpoint[$i] (${listen}): 原配置有 remote_transport (${r_trans})，将降级为纯 L4 转发${NC}"

        local l_ip l_port
        l_port="${listen##*:}"
        l_ip=$(_normalize_realm_listen_ip "${listen%:*}")
        local snat
        snat=$(_normalize_realm_snat "$through")

        local r_host r_port bal_mode="off" weights=""
        if [ -n "$extra" ]; then
            r_host="${remote},${extra}"
            r_port="0"
            if [[ "$balance" == *"iphash"* ]]; then
                bal_mode="iphash"
                weights=$(echo "$balance" | sed -n 's/.*iphash:[[:space:]]*//p' | tr -d ' ')
            else
                bal_mode="roundrobin"
                weights=$(echo "$balance" | sed -n 's/.*roundrobin:[[:space:]]*//p' | tr -d ' ')
            fi
        else
            if [[ "$remote" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
                r_host="${BASH_REMATCH[1]}"; r_port="${BASH_REMATCH[2]}"
            else
                r_host="${remote%:*}"; r_port="${remote##*:}"
            fi
        fi

        if _rule_duplicate_exists "$l_port" "$r_host" "$r_port" "$proto"; then
            echo -e "  ${GRAY}跳过已存在规则: ${l_port} → ${r_host}:${r_port}${NC}"
            skipped=$((skipped + 1))
            continue
        fi

        local nid
        nid=$(create_rule_record "$l_port" "$r_host" "$r_port" "$proto" "$l_ip" "$snat" "auto" "from-realm" "$bal_mode" "$weights" "true" "false")
        echo -e "  ${GREEN}✓ 导入规则 #${nid}: ${l_ip}:${l_port} → ${r_host}$([ "$r_port" != "0" ] && echo ":${r_port}") (${proto})${NC}"
        imported=$((imported + 1))
    done

    echo -e "${GREEN}JSON 导入完成: 新增 ${imported} 条，跳过 ${skipped} 条${NC}"
    return 0
}

# 3) 从标准 Realm config.toml 导入
migrate_from_realm_toml() {
    local toml_file="$1"
    [ -f "$toml_file" ] || return 1
    echo -e "${BLUE}正在解析 Realm TOML 配置: ${toml_file}${NC}"

    local imported=0 skipped=0
    local in_ep=0 listen="" remote="" through="" l_trans=""
    local _flush_ep
    _flush_ep() {
        [ "$in_ep" -eq 1 ] || return 0
        if [ -n "$listen" ] && [ -n "$remote" ]; then
            if [ -n "$l_trans" ]; then
                echo -e "  ${YELLOW}⚠ 跳过 ${listen}: 包含 listen_transport${NC}"
                skipped=$((skipped + 1))
            else
                local l_port="${listen##*:}"
                local l_ip
                l_ip=$(_normalize_realm_listen_ip "${listen%:*}")
                local snat
                snat=$(_normalize_realm_snat "$through")
                local r_host="${remote%:*}" r_port="${remote##*:}"
                r_host="${r_host#[}"; r_host="${r_host%]}"
                if _rule_duplicate_exists "$l_port" "$r_host" "$r_port" "both"; then
                    skipped=$((skipped + 1))
                else
                    local nid
                    nid=$(create_rule_record "$l_port" "$r_host" "$r_port" "both" "$l_ip" "$snat" "auto" "from-realm-toml" "off" "" "true" "false")
                    echo -e "  ${GREEN}✓ 导入规则 #${nid}: ${l_ip}:${l_port} → ${r_host}:${r_port}${NC}"
                    imported=$((imported + 1))
                fi
            fi
        fi
        listen=""; remote=""; through=""; l_trans=""
    }

    local line key val
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*$//' | xargs)
        [ -z "$line" ] && continue
        if [[ "$line" == "[[endpoints]]" ]]; then
            _flush_ep
            in_ep=1
            continue
        elif [[ "$line" =~ ^\[.*\]$ ]]; then
            _flush_ep
            in_ep=0
            continue
        fi
        if [ "$in_ep" -eq 1 ] && [[ "$line" == *"="* ]]; then
            key=$(echo "${line%%=*}" | xargs)
            val=$(echo "${line#*=}" | xargs | sed 's/^["'\'']//;s/["'\'']$//')
            case "$key" in
                listen) listen="$val" ;;
                remote) remote="$val" ;;
                through|interface) through="$val" ;;
                listen_transport) l_trans="$val" ;;
            esac
        fi
    done < "$toml_file"
    _flush_ep

    echo -e "${GREEN}TOML 导入完成: 新增 ${imported} 条，跳过 ${skipped} 条${NC}"
    return 0
}

# 自动扫描本机 Realm 配置并导入
migrate_realm_auto() {
    local custom_path="${1:-}"
    if [ -n "$custom_path" ]; then
        if [ -d "$custom_path" ]; then
            migrate_from_realm_rules_dir "$custom_path"
        elif [[ "$custom_path" == *.json ]]; then
            migrate_from_realm_json "$custom_path"
        elif [[ "$custom_path" == *.toml ]]; then
            migrate_from_realm_toml "$custom_path"
        else
            echo -e "${RED}不支持的路径或格式: ${custom_path}${NC}"
            return 1
        fi
        return $?
    fi

    if [ -d /etc/realm/rules ] && [ -n "$(ls -A /etc/realm/rules/rule-*.conf 2>/dev/null)" ]; then
        migrate_from_realm_rules_dir /etc/realm/rules
        return $?
    elif [ -f /etc/realm/config.json ]; then
        migrate_from_realm_json /etc/realm/config.json
        return $?
    elif [ -f /etc/realm/config.toml ]; then
        migrate_from_realm_toml /etc/realm/config.toml
        return $?
    else
        echo -e "${YELLOW}未在默认路径 (/etc/realm) 检测到 Realm 配置文件${NC}"
        return 1
    fi
}

stop_and_disable_realm() {
    echo -e "${YELLOW}正在停止并禁用 Realm 服务...${NC}"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop realm.service >/dev/null 2>&1 || true
        systemctl disable realm.service >/dev/null 2>&1 || true
        systemctl stop realm-health-check.timer realm-health-check.service >/dev/null 2>&1 || true
        systemctl disable realm-health-check.timer realm-health-check.service >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-service realm stop >/dev/null 2>&1 || true
        rc-update del realm default >/dev/null 2>&1 || true
    fi
    if pgrep -x realm >/dev/null 2>&1; then
        pkill -x realm >/dev/null 2>&1 || true
        sleep 1
    fi
    if ! pgrep -x realm >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Realm 进程已停止并取消开机自启（原 /etc/realm 配置保留做备份）${NC}"
    else
        echo -e "${RED}⚠ 仍有 realm 进程残留，请手动检查${NC}"
    fi
}

# 一键无缝替代 Realm：导入配置 -> 内核转发准备 -> 停用 Realm -> 原子加载 nftables -> 清理旧 conntrack
switch_from_realm_cmd() {
    local src_path="${1:-}"
    echo -e "${GREEN}=== 一键将 Realm 迁移并切换为 nftables ===${NC}"
    echo ""
    migrate_realm_auto "$src_path" || return 1
    echo ""
    apply_relay_sysctl
    echo ""
    stop_and_disable_realm
    echo ""
    if apply_nft_rules; then
        clear_conntrack_for_ports
        install_persistence_service
        sync_ddns_timer 1
        sync_failover_timer 1
        echo ""
        echo -e "${GREEN}✓ 已成功用 nftables 接管全部原 Realm 转发规则！${NC}"
        return 0
    else
        echo -e "${RED}✗ nftables 加载失败，正在尝试回滚恢复 Realm 服务...${NC}"
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            systemctl enable --now realm.service >/dev/null 2>&1 || true
        elif [ "$INIT_SYSTEM" = "openrc" ]; then
            rc-service realm start >/dev/null 2>&1 || true
        fi
        return 1
    fi
}

migrate_realm_menu() {
    clear
    echo -e "${GREEN}=== Realm 一键迁移至 nftables ===${NC}"
    echo ""
    echo "请选择操作:"
    echo -e "${GREEN}1.${NC} 一键迁移并切换（导入 Realm 规则 + 停用 Realm + 立即由 nftables 接管）"
    echo -e "${BLUE}2.${NC} 仅导入 Realm 规则（不停止 Realm，适合先预览检查）"
    echo -e "${YELLOW}3.${NC} 指定自定义 Realm 配置文件路径 (.json / .toml / rules目录)"
    echo -e "${GREEN}0.${NC} 返回主菜单"
    echo ""
    read -r -p "请输入选择 [0-3]: " ch
    echo ""
    case "$ch" in
        1) switch_from_realm_cmd ;;
        2) migrate_realm_auto && apply_nft_rules ;;
        3)
            read -r -p "请输入路径: " p
            [ -n "$p" ] && migrate_realm_auto "$p" && apply_nft_rules
            ;;
        0) return 0 ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
    read -r -p "按回车继续..."
}
