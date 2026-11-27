#!/bin/bash
# lib/nft.sh - nftables 规则编译、预校验、原子热重载、计数器持久化与服务生命周期

# === 计数器读写与持久化 ===

# 从实时内核读取 nftpf_v4 / nftpf_v6 命名计数器并落盘
save_live_counters() {
    command -v nft >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    mkdir -p "$STATE_DIR"

    local json
    json=$(nft -j list counters 2>/dev/null) || return 0
    [ -z "$json" ] && return 0

    local -A prev_pkt prev_byt
    if [ -f "$COUNTERS_FILE" ]; then
        local tbl cname pk by
        while IFS='|' read -r tbl cname pk by; do
            [[ "$tbl" =~ ^# ]] || [ -z "$tbl" ] && continue
            prev_pkt["${tbl}:${cname}"]="${pk:-0}"
            prev_byt["${tbl}:${cname}"]="${by:-0}"
        done < "$COUNTERS_FILE"
    fi

    # 内核中存在的计数器覆盖对应键值（内核内已包含上次加载时回填的初始值）
    local line tbl cname pk by
    while IFS='|' read -r tbl cname pk by; do
        [ -z "$tbl" ] && continue
        prev_pkt["${tbl}:${cname}"]="${pk:-0}"
        prev_byt["${tbl}:${cname}"]="${by:-0}"
    done < <(echo "$json" | jq -r --arg v4 "$NFT_TABLE_V4" --arg v6 "$NFT_TABLE_V6" '
        .nftables[]? | select(.counter?) | .counter |
        select(.table == $v4 or .table == $v6) |
        "\(.table)|\(.name)|\(.packets // 0)|\(.bytes // 0)"
    ' 2>/dev/null)

    local tmp k
    tmp=$(mktemp "${COUNTERS_FILE}.tmp.XXXXXX") || return 1
    echo "# table|counter_name|packets|bytes" > "$tmp"
    for k in "${!prev_pkt[@]}"; do
        tbl="${k%%:*}"
        cname="${k#*:}"
        printf '%s|%s|%s|%s\n' "$tbl" "$cname" "${prev_pkt[$k]}" "${prev_byt[$k]}" >> "$tmp"
    done
    mv -fT -- "$tmp" "$COUNTERS_FILE"
}

_get_saved_counter() {
    local tbl="$1" cname="$2"
    if [ -f "$COUNTERS_FILE" ]; then
        local val
        val=$(awk -F'|' -v t="$tbl" -v c="$cname" '$1==t && $2==c {print $3 " " $4; exit}' "$COUNTERS_FILE")
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    fi
    echo "0 0"
}

reset_all_counters() {
    rm -f "$COUNTERS_FILE"
    if nft_table_exists "ip" "$NFT_TABLE_V4"; then
        nft reset counters table ip "$NFT_TABLE_V4" >/dev/null 2>&1 || true
    fi
    if nft_table_exists "ip6" "$NFT_TABLE_V6"; then
        nft reset counters table ip6 "$NFT_TABLE_V6" >/dev/null 2>&1 || true
    fi
    echo -e "${GREEN}✓ 全部规则流量计数器已清零${NC}"
}

# 获取某条规则的实时流量（上行字节|下行字节|上行包|下行包），自动合并 v4+v6
get_rule_traffic_live() {
    local rule_id="$1"
    local up_b=0 dn_b=0 up_p=0 dn_p=0

    if command -v nft >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local json
        json=$(nft -j list counters 2>/dev/null)
        if [ -n "$json" ]; then
            local line cname pk by
            while IFS='|' read -r cname pk by; do
                case "$cname" in
                    "r${rule_id}_up") up_p=$((up_p + pk)); up_b=$((up_b + by)) ;;
                    "r${rule_id}_dn") dn_p=$((dn_p + pk)); dn_b=$((dn_b + by)) ;;
                esac
            done < <(echo "$json" | jq -r --arg v4 "$NFT_TABLE_V4" --arg v6 "$NFT_TABLE_V6" --arg id "$rule_id" '
                .nftables[]? | select(.counter?) | .counter |
                select((.table == $v4 or .table == $v6) and (.name == ("r" + $id + "_up") or .name == ("r" + $id + "_dn"))) |
                "\(.name)|\(.packets // 0)|\(.bytes // 0)"
            ' 2>/dev/null)
        fi
    fi

    printf '%s|%s|%s|%s' "$up_b" "$dn_b" "$up_p" "$dn_p"
}

nft_table_exists() {
    local family="$1" tbl="$2"
    command -v nft >/dev/null 2>&1 && nft list table "$family" "$tbl" >/dev/null 2>&1
}

nftpf_is_active() {
    nft_table_exists "ip" "$NFT_TABLE_V4" || nft_table_exists "ip6" "$NFT_TABLE_V6"
}

# === 健康状态加载（用于故障转移过滤） ===

_is_target_failed() {
    local rule_id="$1" target="$2"
    [ -f "$HEALTH_STATUS_FILE" ] || return 1
    local status
    status=$(awk -F'|' -v id="$rule_id" -v t="$target" '$1==id && $2==t {print $3; exit}' "$HEALTH_STATUS_FILE")
    [ "$status" = "failed" ]
}

# === 构造单协议 DNAT 表达式 ===

_format_dnat_endpoint() {
    local family="$1" ip="$2" port="$3" listen_port="$4"
    # 端口段 1:1 原样透传（REMOTE_PORT=same 或与 LISTEN_PORT 相同端口段）
    if [ "$port" = "same" ] || { [[ "$listen_port" == *-* ]] && [ "$port" = "$listen_port" ]; }; then
        echo "$ip"
        return 0
    fi
    if [ "$family" = "ip6" ]; then
        echo "[${ip}]:${port}"
    else
        echo "${ip}:${port}"
    fi
}

_build_listen_match() {
    local family="$1" listen_ip="$2"
    if [ -z "$listen_ip" ] || [ "$listen_ip" = "any" ] || [ "$listen_ip" = "0.0.0.0" ] || [ "$listen_ip" = "::" ]; then
        echo ""
        return 0
    fi
    if [ "$family" = "ip" ] && is_ipv4 "$listen_ip"; then
        echo "ip daddr ${listen_ip} "
        return 0
    fi
    if [ "$family" = "ip6" ] && is_ipv6 "$listen_ip"; then
        local clean="${listen_ip#[}"; clean="${clean%]}"
        echo "ip6 daddr ${clean} "
        return 0
    fi
    if ! validate_ip "$listen_ip"; then
        echo "iifname \"${listen_ip}\" "
        return 0
    fi
    # 监听 IP 族与目标族不一致，跳过该族
    echo "SKIP"
}

_resolve_snat_action() {
    local family="$1" snat_ip="$2"
    if [ -z "$snat_ip" ] || [ "$snat_ip" = "auto" ] || [ "$snat_ip" = "masquerade" ] || [ "$snat_ip" = "::" ] || [ "$snat_ip" = "0.0.0.0" ]; then
        echo "masquerade"
        return 0
    fi
    if [ "$family" = "ip" ]; then
        if is_ipv4 "$snat_ip"; then
            echo "snat to ${snat_ip}"
            return 0
        elif ! validate_ip "$snat_ip"; then
            local ifip
            ifip=$(get_iface_ip "$snat_ip" 4)
            if [ -n "$ifip" ]; then
                echo "snat to ${ifip}"
                return 0
            fi
        fi
    else
        if is_ipv6 "$snat_ip"; then
            local clean="${snat_ip#[}"; clean="${clean%]}"
            echo "snat to ${clean}"
            return 0
        elif ! validate_ip "$snat_ip"; then
            local ifip
            ifip=$(get_iface_ip "$snat_ip" 6)
            if [ -n "$ifip" ]; then
                echo "snat to ${ifip}"
                return 0
            fi
        fi
    fi
    echo "masquerade"
}

# === 编译完整 nftables 规则集 ===

generate_nft_ruleset() {
    local out_file="$1"
    load_settings

    # 保存当前运行中的计数器以便无缝继承
    save_live_counters

    local v4_counters="" v4_subchains="" v4_pre="" v4_out="" v4_fwd="" v4_post=""
    local v6_counters="" v6_subchains="" v6_pre="" v6_out="" v6_fwd="" v6_post=""
    local v4_count=0 v6_count=0
    local has_v6=false
    host_has_global_ipv6 && has_v6=true

    local rule_file
    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue
        [ "$ENABLED" = "true" ] || continue

        local mark_hex
        mark_hex=$(printf '0x%08x' $((CT_MARK_BASE + RULE_ID)))

        # 解析目标列表和权重
        local -a raw_hosts=() raw_ports=() raw_weights=()
        local tline th tp
        while IFS='|' read -r th tp; do
            [ -z "$th" ] && continue
            raw_hosts+=("$th")
            raw_ports+=("$tp")
        done < <(parse_rule_targets "$REMOTE_HOST" "$REMOTE_PORT")
        [ ${#raw_hosts[@]} -eq 0 ] && continue

        if [ -n "$WEIGHTS" ]; then
            IFS=',' read -ra raw_weights <<< "$WEIGHTS"
        fi

        # 分别构建 IPv4 与 IPv6 候选目标
        local fam
        for fam in ip ip6; do
            [ "$fam" = "ip" ] && [ "$IP_FAMILY" = "ipv6" ] && continue
            [ "$fam" = "ip6" ] && [ "$IP_FAMILY" = "ipv4" ] && continue
            [ "$fam" = "ip6" ] && [ "$has_v6" = false ] && [ "$IP_FAMILY" != "ipv6" ] && continue

            local listen_match
            listen_match=$(_build_listen_match "$fam" "$LISTEN_IP")
            [ "$listen_match" = "SKIP" ] && continue

            local -a fam_ips=() fam_ports=() fam_weights=() fam_orig_targets=()
            local i ip_res w
            for i in "${!raw_hosts[@]}"; do
                local h="${raw_hosts[$i]}"
                local p="${raw_ports[$i]}"
                w="${raw_weights[$i]:-1}"
                [[ "$w" =~ ^[0-9]+$ ]] && (( w >= 1 )) || w=1

                if [ "$fam" = "ip" ]; then
                    ip_res=$(resolve_host_ip "$h" 4) || continue
                else
                    ip_res=$(resolve_host_ip "$h" 6) || continue
                fi

                fam_ips+=("$ip_res")
                fam_ports+=("$p")
                fam_weights+=("$w")
                fam_orig_targets+=("${h}:${p}")
            done

            [ ${#fam_ips[@]} -eq 0 ] && continue

            # 故障转移过滤（全挂时兜底保留首个目标，防止服务彻底黑洞）
            local -a active_ips=() active_ports=() active_weights=()
            if [ "$FAILOVER_ENABLED" = "true" ] && [ ${#fam_ips[@]} -gt 1 ]; then
                for i in "${!fam_ips[@]}"; do
                    local key_target="${fam_orig_targets[$i]}"
                    local key_host="${raw_hosts[$i]}"
                    if ! _is_target_failed "$RULE_ID" "$key_target" && ! _is_target_failed "$RULE_ID" "$key_host"; then
                        active_ips+=("${fam_ips[$i]}")
                        active_ports+=("${fam_ports[$i]}")
                        active_weights+=("${fam_weights[$i]}")
                    fi
                done
                if [ ${#active_ips[@]} -eq 0 ]; then
                    active_ips=("${fam_ips[0]}")
                    active_ports=("${fam_ports[0]}")
                    active_weights=("${fam_weights[0]}")
                fi
            else
                active_ips=("${fam_ips[@]}")
                active_ports=("${fam_ports[@]}")
                active_weights=("${fam_weights[@]}")
            fi

            # 确定本规则要生成的 L4 协议
            local -a protos=()
            case "$PROTOCOL" in
                tcp) protos=("tcp") ;;
                udp) protos=("udp") ;;
                *)   protos=("tcp" "udp") ;;
            esac

            local tbl_name="$NFT_TABLE_V4"
            [ "$fam" = "ip6" ] && tbl_name="$NFT_TABLE_V6"

            # 读取已保存的计数器值实现无损热重载
            local up_pk up_by dn_pk dn_by
            read -r up_pk up_by <<< "$(_get_saved_counter "$tbl_name" "r${RULE_ID}_up")"
            read -r dn_pk dn_by <<< "$(_get_saved_counter "$tbl_name" "r${RULE_ID}_dn")"

            local c_block
            c_block=$(cat <<EOF
    counter r${RULE_ID}_up {
        packets ${up_pk:-0} bytes ${up_by:-0}
    }
    counter r${RULE_ID}_dn {
        packets ${dn_pk:-0} bytes ${dn_by:-0}
    }
EOF
)

            local snat_act
            snat_act=$(_resolve_snat_action "$fam" "$SNAT_IP")

            local subchain_block="" pre_lines="" out_lines="" fwd_lines="" post_lines="" proto

            if [ ${#active_ips[@]} -gt 1 ] && [ "$BALANCE_MODE" != "off" ]; then
                local total_w=0
                for w in "${active_weights[@]}"; do
                    total_w=$((total_w + w))
                done

                local selector=""
                if [ "$BALANCE_MODE" = "iphash" ]; then
                    if [ "$fam" = "ip" ]; then
                        selector="meta mark set jhash ip saddr mod ${total_w}"
                    else
                        selector="meta mark set jhash ip6 saddr mod ${total_w}"
                    fi
                else
                    selector="meta mark set numgen inc mod ${total_w}"
                fi

                local slot_start=0 slot_end=0 match_range="" ep=""
                local chain_body="        ct mark set ${mark_hex}\n        ${selector}\n"
                for i in "${!active_ips[@]}"; do
                    w="${active_weights[$i]}"
                    slot_end=$((slot_start + w - 1))
                    if [ "$slot_start" -eq "$slot_end" ]; then
                        match_range="${slot_start}"
                    else
                        match_range="${slot_start}-${slot_end}"
                    fi
                    ep=$(_format_dnat_endpoint "$fam" "${active_ips[$i]}" "${active_ports[$i]}" "$LISTEN_PORT")
                    chain_body+="        meta mark ${match_range} dnat to ${ep}\n"
                    slot_start=$((slot_end + 1))
                done

                subchain_block="    chain dnat_r${RULE_ID} {\n${chain_body}    }\n"
                for proto in "${protos[@]}"; do
                    pre_lines+="        ${listen_match}${proto} dport ${LISTEN_PORT} jump dnat_r${RULE_ID} comment \"rule-${RULE_ID}\"\n"
                    if [ "$ENABLE_HAIRPIN" = "true" ]; then
                        out_lines+="        fib daddr type local ${proto} dport ${LISTEN_PORT} jump dnat_r${RULE_ID} comment \"rule-${RULE_ID}\"\n"
                    fi
                done
            else
                local ep
                ep=$(_format_dnat_endpoint "$fam" "${active_ips[0]}" "${active_ports[0]}" "$LISTEN_PORT")
                for proto in "${protos[@]}"; do
                    pre_lines+="        ${listen_match}${proto} dport ${LISTEN_PORT} ct mark set ${mark_hex} dnat to ${ep} comment \"rule-${RULE_ID}\"\n"
                    if [ "$ENABLE_HAIRPIN" = "true" ]; then
                        out_lines+="        fib daddr type local ${proto} dport ${LISTEN_PORT} ct mark set ${mark_hex} dnat to ${ep} comment \"rule-${RULE_ID}\"\n"
                    fi
                done
            fi

            fwd_lines+="        ct mark ${mark_hex} ct direction original counter name \"r${RULE_ID}_up\" accept\n"
            fwd_lines+="        ct mark ${mark_hex} ct direction reply counter name \"r${RULE_ID}_dn\" accept\n"
            post_lines+="        ct mark ${mark_hex} ${snat_act} comment \"rule-${RULE_ID}\"\n"

            if [ "$fam" = "ip" ]; then
                v4_counters+="${c_block}"$'\n'
                v4_subchains+="$subchain_block"
                v4_pre+="$pre_lines"
                v4_out+="$out_lines"
                v4_fwd+="$fwd_lines"
                v4_post+="$post_lines"
                v4_count=$((v4_count + 1))
            else
                v6_counters+="${c_block}"$'\n'
                v6_subchains+="$subchain_block"
                v6_pre+="$pre_lines"
                v6_out+="$out_lines"
                v6_fwd+="$fwd_lines"
                v6_post+="$post_lines"
                v6_count=$((v6_count + 1))
            fi
        done
    done < <(get_sorted_rule_files)

    # 检测 Flowtable 可用网卡
    local ft_devs=""
    if [ "$ENABLE_FLOWTABLE" = "true" ]; then
        ft_devs=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -vE '^(lo|docker|veth|br-|virbr|tun|wg)' | paste -sd', ' -)
    fi

    # 写出原子规则集文件
    {
        echo "#!/usr/sbin/nft -f"
        echo "# Generated by nft-akaagiao ${SCRIPT_VERSION} at $(get_gmt8_time '+%Y-%m-%d %H:%M:%S GMT+8')"
        echo "# 仅管理独立表 ${NFT_TABLE_V4} / ${NFT_TABLE_V6}，绝不触碰系统其他防火墙表"
        echo ""
        echo "table ip ${NFT_TABLE_V4}"
        echo "delete table ip ${NFT_TABLE_V4}"
        echo "table ip6 ${NFT_TABLE_V6}"
        echo "delete table ip6 ${NFT_TABLE_V6}"
        echo ""

        if [ "$v4_count" -gt 0 ]; then
            echo "table ip ${NFT_TABLE_V4} {"
            printf '%s' "$v4_counters"
            if [ "$ENABLE_FLOWTABLE" = "true" ] && [ -n "$ft_devs" ]; then
                echo "    flowtable ft_fast {"
                echo "        hook ingress priority filter"
                echo "        devices = { ${ft_devs} }"
                echo "    }"
            fi
            [ -n "$v4_subchains" ] && printf '%b' "$v4_subchains"
            echo "    chain prerouting {"
            echo "        type nat hook prerouting priority dstnat - 5; policy accept;"
            printf '%b' "$v4_pre"
            echo "    }"
            if [ "$ENABLE_HAIRPIN" = "true" ] && [ -n "$v4_out" ]; then
                echo "    chain output {"
                echo "        type nat hook output priority dstnat - 5; policy accept;"
                printf '%b' "$v4_out"
                echo "    }"
            fi
            echo "    chain forward {"
            echo "        type filter hook forward priority filter - 5; policy accept;"
            if [ "$ENABLE_MSS_CLAMP" = "true" ]; then
                echo "        tcp flags syn tcp option maxseg size set rt mtu"
            fi
            if [ "$ENABLE_FLOWTABLE" = "true" ] && [ -n "$ft_devs" ]; then
                echo "        ip protocol { tcp, udp } ct state established flow add @ft_fast"
            fi
            printf '%b' "$v4_fwd"
            echo "    }"
            echo "    chain postrouting {"
            echo "        type nat hook postrouting priority srcnat - 5; policy accept;"
            printf '%b' "$v4_post"
            echo "    }"
            echo "}"
            echo ""
        fi

        if [ "$v6_count" -gt 0 ]; then
            echo "table ip6 ${NFT_TABLE_V6} {"
            printf '%s' "$v6_counters"
            if [ "$ENABLE_FLOWTABLE" = "true" ] && [ -n "$ft_devs" ]; then
                echo "    flowtable ft_fast {"
                echo "        hook ingress priority filter"
                echo "        devices = { ${ft_devs} }"
                echo "    }"
            fi
            [ -n "$v6_subchains" ] && printf '%b' "$v6_subchains"
            echo "    chain prerouting {"
            echo "        type nat hook prerouting priority dstnat - 5; policy accept;"
            printf '%b' "$v6_pre"
            echo "    }"
            if [ "$ENABLE_HAIRPIN" = "true" ] && [ -n "$v6_out" ]; then
                echo "    chain output {"
                echo "        type nat hook output priority dstnat - 5; policy accept;"
                printf '%b' "$v6_out"
                echo "    }"
            fi
            echo "    chain forward {"
            echo "        type filter hook forward priority filter - 5; policy accept;"
            if [ "$ENABLE_MSS_CLAMP" = "true" ]; then
                echo "        tcp flags syn tcp option maxseg size set rt mtu"
            fi
            if [ "$ENABLE_FLOWTABLE" = "true" ] && [ -n "$ft_devs" ]; then
                echo "        meta l4proto { tcp, udp } ct state established flow add @ft_fast"
            fi
            printf '%b' "$v6_fwd"
            echo "    }"
            echo "    chain postrouting {"
            echo "        type nat hook postrouting priority srcnat - 5; policy accept;"
            printf '%b' "$v6_post"
            echo "    }"
            echo "}"
        fi
    } > "$out_file"
}

# 原子验证并重载 nftables（零断流，校验失败绝不破坏线上规则）
apply_nft_rules() {
    local quiet="${1:-0}"
    init_dirs
    ensure_ip_forwarding_quiet

    local tmp_nft
    tmp_nft=$(mktemp "${RULESET_FILE}.tmp.XXXXXX") || return 1

    generate_nft_ruleset "$tmp_nft"

    # 1) 严格语法预校验
    local check_err
    if ! check_err=$(nft -c -f "$tmp_nft" 2>&1); then
        echo -e "${RED}✗ nftables 规则语法校验失败，线上规则未受影响！${NC}" >&2
        echo -e "${YELLOW}错误详情:${NC}" >&2
        echo "$check_err" >&2
        rm -f "$tmp_nft"
        return 1
    fi

    # 2) 原子提交内核
    local apply_err
    if ! apply_err=$(nft -f "$tmp_nft" 2>&1); then
        echo -e "${RED}✗ nftables 规则加载失败！${NC}" >&2
        echo "$apply_err" >&2
        rm -f "$tmp_nft"
        return 1
    fi

    chmod 600 "$tmp_nft"
    mv -fT -- "$tmp_nft" "$RULESET_FILE"

    # 3) 检测是否存在可能拦包的外部 FORWARD policy drop（只提示不乱改）
    if [ "$quiet" != "1" ]; then
        echo -e "${GREEN}✓ nftables 规则已原子热重载（现有连接不受影响）${NC}"
        _check_forward_policy_warning
    fi
    return 0
}

_check_forward_policy_warning() {
    local drop_chains
    drop_chains=$(nft list ruleset 2>/dev/null | grep -E 'hook forward.*policy drop' || true)
    if [ -n "$drop_chains" ]; then
        echo -e "${YELLOW}⚠ 检测到系统其他防火墙表中存在 'hook forward ... policy drop'（如 Docker/UFW/firewalld）${NC}"
        echo -e "${YELLOW}  若转发不通，请确认该防火墙已放行转发流量或关闭对应默认丢弃策略${NC}"
    fi
}

stop_nft_rules() {
    save_live_counters
    nft_table_exists "ip" "$NFT_TABLE_V4" && nft delete table ip "$NFT_TABLE_V4" 2>/dev/null || true
    nft_table_exists "ip6" "$NFT_TABLE_V6" && nft delete table ip6 "$NFT_TABLE_V6" 2>/dev/null || true
    echo -e "${GREEN}✓ nftpf 转发规则表已停止并清空（流量数据已保存，未触碰系统其他防火墙表）${NC}"
}

# === 开机自启持久化服务（systemd / OpenRC） ===

install_persistence_service() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=nft-akaagiao Kernel Port Forwarding (nftables)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/nftPF.sh --apply-boot
ExecReload=/usr/local/bin/nftPF.sh reload
ExecStop=/usr/local/bin/nftPF.sh --stop-boot

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable nftpf.service >/dev/null 2>&1
        echo -e "  ${GREEN}✓${NC} systemd 持久化服务已启用 (nftpf.service)"
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        cat > "$OPENRC_INIT" <<'EOF'
#!/sbin/openrc-run
name="nftpf"
description="nft-akaagiao Kernel Port Forwarding (nftables)"
depend() {
    need net
    after nftables
}
start() {
    ebegin "Applying nft-akaagiao nftables rules"
    /usr/local/bin/nftPF.sh --apply-boot
    eend $?
}
stop() {
    ebegin "Stopping nft-akaagiao nftables rules"
    /usr/local/bin/nftPF.sh --stop-boot
    eend $?
}
EOF
        chmod +x "$OPENRC_INIT"
        rc-update add nftpf default >/dev/null 2>&1
        echo -e "  ${GREEN}✓${NC} OpenRC 持久化服务已启用 (nftpf)"
    fi
}

remove_persistence_service() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl disable --now nftpf.service >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_UNIT"
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-service nftpf stop >/dev/null 2>&1 || true
        rc-update del nftpf default >/dev/null 2>&1 || true
        rm -f "$OPENRC_INIT"
    fi
}
