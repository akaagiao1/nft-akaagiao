#!/bin/bash
# lib/failover.sh - 轻量化健康检查、故障转移与 Telegram/Webhook 通知

FAILOVER_SERVICE="/etc/systemd/system/nftpf-failover.service"
FAILOVER_TIMER="/etc/systemd/system/nftpf-failover.timer"
FAILOVER_CRON="/etc/cron.d/nftpf-failover"
FAILOVER_LOCK="/var/lock/nftpf-failover.lock"

# === 通知模块（支持 Telegram Bot & 通用 Webhook：飞书/钉钉/企微） ===

load_notify_conf() {
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_API_HOST="https://api.telegram.org"
    WEBHOOK_URL=""
    NOTIFY_NODE_NAME="$(hostname)"
    if [ -f "$NOTIFY_CONF" ]; then
        # shellcheck source=/dev/null
        source "$NOTIFY_CONF"
    fi
}

save_notify_conf() {
    mkdir -p "$CONFIG_DIR"
    local tmp
    tmp=$(mktemp "${NOTIFY_CONF}.tmp.XXXXXX") || return 1
    cat > "$tmp" <<EOF
TG_BOT_TOKEN=$(rule_quote "$TG_BOT_TOKEN")
TG_CHAT_ID=$(rule_quote "$TG_CHAT_ID")
TG_API_HOST=$(rule_quote "${TG_API_HOST:-https://api.telegram.org}")
WEBHOOK_URL=$(rule_quote "$WEBHOOK_URL")
NOTIFY_NODE_NAME=$(rule_quote "${NOTIFY_NODE_NAME:-$(hostname)}")
EOF
    chmod 600 "$tmp"
    mv -fT -- "$tmp" "$NOTIFY_CONF"
}

send_notify() {
    local title="$1" body="$2"
    load_notify_conf
    local full_msg="[${NOTIFY_NODE_NAME}] ${title}"$'\n'"${body}"$'\n'"时间: $(get_gmt8_time '+%Y-%m-%d %H:%M:%S GMT+8')"

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        local api="${TG_API_HOST%/}/bot${TG_BOT_TOKEN}/sendMessage"
        curl -fsS --connect-timeout 5 --max-time 10 -X POST "$api" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${full_msg}" >/dev/null 2>&1 || true
    fi

    if [ -n "$WEBHOOK_URL" ]; then
        local payload
        if [[ "$WEBHOOK_URL" == *"open.feishu.cn"* ]] || [[ "$WEBHOOK_URL" == *"open.larksuite.com"* ]]; then
            payload=$(jq -nc --arg t "$full_msg" '{msg_type:"text",content:{text:$t}}')
        else
            payload=$(jq -nc --arg t "$full_msg" '{msgtype:"text",text:{content:$t}}')
        fi
        curl -fsS --connect-timeout 5 --max-time 10 -X POST "$WEBHOOK_URL" \
            -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1 || true
    fi
}

has_failover_rules() {
    local rule_file
    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue
        if [ "$ENABLED" = "true" ] && [ "$FAILOVER_ENABLED" = "true" ] && [[ "$REMOTE_HOST" == *","* ]]; then
            return 0
        fi
    done < <(get_sorted_rule_files)
    return 1
}

# 执行一次健康检查，仅当节点状态在 healthy <-> failed 之间切换时原子重载 nftables
run_failover_check() {
    local quiet="${1:-0}"
    init_dirs
    load_settings

    mkdir -p "$(dirname "$FAILOVER_LOCK")"
    exec 201>"$FAILOVER_LOCK"
    if command -v flock >/dev/null 2>&1; then
        flock -n 201 || return 0
    fi

    if [ ! -f "$HEALTH_STATUS_FILE" ]; then
        echo "# RULE_ID|TARGET|STATUS|FAIL_CNT|SUCC_CNT|LAST_CHECK|FAIL_START" > "$HEALTH_STATUS_FILE"
    fi

    local now changed=0 rule_file th tp check_port target_key
    now=$(date +%s)

    while IFS= read -r rule_file; do
        [ -f "$rule_file" ] || continue
        read_rule_file "$rule_file" || continue
        [ "$ENABLED" = "true" ] || continue
        [ "$FAILOVER_ENABLED" = "true" ] || continue
        [[ "$REMOTE_HOST" == *","* ]] || continue

        while IFS='|' read -r th tp; do
            [ -z "$th" ] && continue
            check_port="$tp"
            if [ "$check_port" = "same" ] || [[ "$check_port" == *-* ]]; then
                check_port="${LISTEN_PORT%%-*}"
            fi
            target_key="${th}:${tp}"

            local line status fail_cnt succ_cnt last_chk fail_start
            line=$(awk -F'|' -v id="$RULE_ID" -v t="$target_key" '$1==id && $2==t {print; exit}' "$HEALTH_STATUS_FILE")
            if [ -n "$line" ]; then
                IFS='|' read -r _ _ status fail_cnt succ_cnt last_chk fail_start <<< "$line"
                fail_start="${fail_start:-0}"
            else
                status="healthy"
                fail_cnt=0
                succ_cnt=0
                last_chk=0
                fail_start=0
            fi

            if check_connectivity "$th" "$check_port" "$FAILOVER_TIMEOUT_SEC"; then
                succ_cnt=$((succ_cnt + 1))
                fail_cnt=0
                if [ "$status" = "failed" ] && [ "$succ_cnt" -ge "$FAILOVER_SUCC_THRESHOLD" ]; then
                    if (( now - fail_start >= FAILOVER_COOLDOWN_SEC )); then
                        status="healthy"
                        fail_start=0
                        changed=1
                        [ "$quiet" != "1" ] && echo -e "${GREEN}[恢复] 规则 #${RULE_ID} 目标 ${target_key} 已恢复健康${NC}"
                        send_notify "节点恢复" "规则 #${RULE_ID} (端口 ${LISTEN_PORT}) 目标 ${target_key} 已恢复并重新加入转发"
                    fi
                fi
            else
                fail_cnt=$((fail_cnt + 1))
                succ_cnt=0
                if [ "$status" = "healthy" ] && [ "$fail_cnt" -ge "$FAILOVER_FAIL_THRESHOLD" ]; then
                    status="failed"
                    fail_start="$now"
                    changed=1
                    [ "$quiet" != "1" ] && echo -e "${RED}[故障] 规则 #${RULE_ID} 目标 ${target_key} 连续失败 ${fail_cnt} 次，已摘除${NC}"
                    send_notify "节点故障摘除" "规则 #${RULE_ID} (端口 ${LISTEN_PORT}) 目标 ${target_key} 探测失败，已自动从 nftables 摘除"
                fi
            fi

            local tmp
            tmp=$(mktemp "${HEALTH_STATUS_FILE}.tmp.XXXXXX")
            awk -F'|' -v id="$RULE_ID" -v t="$target_key" '!($1==id && $2==t)' "$HEALTH_STATUS_FILE" > "$tmp" 2>/dev/null || true
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$RULE_ID" "$target_key" "$status" "$fail_cnt" "$succ_cnt" "$now" "$fail_start" >> "$tmp"
            mv -fT -- "$tmp" "$HEALTH_STATUS_FILE"
        done < <(parse_rule_targets "$REMOTE_HOST" "$REMOTE_PORT")
    done < <(get_sorted_rule_files)

    if [ "$changed" -eq 1 ]; then
        apply_nft_rules "$quiet"
    fi
}

enable_failover_timer() {
    load_settings
    local iv="${FAILOVER_INTERVAL_SEC:-5}"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > "$FAILOVER_SERVICE" <<'EOF'
[Unit]
Description=nft-akaagiao Failover Health Check
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nftPF.sh failover check --quiet
EOF
        cat > "$FAILOVER_TIMER" <<EOF
[Unit]
Description=nft-akaagiao Failover Health Check Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=${iv}s
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now nftpf-failover.timer >/dev/null 2>&1
    else
        mkdir -p /etc/cron.d
        echo "* * * * * root /usr/local/bin/nftPF.sh failover check --quiet >/dev/null 2>&1" > "$FAILOVER_CRON"
        chmod 644 "$FAILOVER_CRON"
    fi
}

disable_failover_timer() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl disable --now nftpf-failover.timer >/dev/null 2>&1 || true
        rm -f "$FAILOVER_TIMER" "$FAILOVER_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$FAILOVER_CRON"
}

sync_failover_timer() {
    local quiet="${1:-0}"
    if has_failover_rules; then
        enable_failover_timer
        [ "$quiet" != "1" ] && echo -e "${GREEN}✓ 故障转移健康检查已启动（每 ${FAILOVER_INTERVAL_SEC} 秒）${NC}"
    else
        disable_failover_timer
    fi
}

show_health_status() {
    echo -e "${BLUE}=== 节点健康检查状态 ===${NC}"
    echo ""
    if [ ! -f "$HEALTH_STATUS_FILE" ] || ! grep -qv '^#' "$HEALTH_STATUS_FILE"; then
        echo -e "${YELLOW}暂无健康检查记录${NC}"
        return 0
    fi
    local rid target st fc sc lc fs dt
    while IFS='|' read -r rid target st fc sc lc fs; do
        [[ "$rid" =~ ^# ]] || [ -z "$rid" ] && continue
        dt=$(date -d "@${lc:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
        if [ "$st" = "failed" ]; then
            echo -e "  规则 #${rid} | ${WHITE}${target}${NC} | 状态: ${RED}故障${NC} | 失败:${fc} | 最后检查:${dt}"
        else
            echo -e "  规则 #${rid} | ${WHITE}${target}${NC} | 状态: ${GREEN}健康${NC} | 成功:${sc} | 最后检查:${dt}"
        fi
    done < "$HEALTH_STATUS_FILE"
}

notify_settings_menu() {
    load_notify_conf
    echo -e "${GREEN}=== 故障转移通知配置 ===${NC}"
    echo ""
    echo -e "当前节点名:   ${CYAN}${NOTIFY_NODE_NAME}${NC}"
    echo -e "Telegram Bot: $([ -n "$TG_BOT_TOKEN" ] && echo -e "${GREEN}已配置${NC} (ChatID: $TG_CHAT_ID)" || echo -e "${GRAY}未配置${NC}")"
    echo -e "Webhook URL:  $([ -n "$WEBHOOK_URL" ] && echo -e "${GREEN}已配置${NC}" || echo -e "${GRAY}未配置${NC}")"
    echo ""
    read -r -p "节点显示名称 [${NOTIFY_NODE_NAME}]: " v
    [ -n "$v" ] && NOTIFY_NODE_NAME="$v"
    read -r -p "Telegram Bot Token (回车保留, 输入 clear 清除): " v
    [ "$v" = "clear" ] && TG_BOT_TOKEN="" || { [ -n "$v" ] && TG_BOT_TOKEN="$v"; }
    if [ -n "$TG_BOT_TOKEN" ]; then
        read -r -p "Telegram Chat ID [${TG_CHAT_ID}]: " v
        [ -n "$v" ] && TG_CHAT_ID="$v"
        read -r -p "Telegram API Host [${TG_API_HOST}]: " v
        [ -n "$v" ] && TG_API_HOST="$v"
    fi
    read -r -p "Webhook URL (企微/飞书/钉钉, 回车保留, 输入 clear 清除): " v
    [ "$v" = "clear" ] && WEBHOOK_URL="" || { [ -n "$v" ] && WEBHOOK_URL="$v"; }
    save_notify_conf
    echo -e "${GREEN}✓ 通知配置已保存${NC}"
    read -r -p "是否发送测试通知? (y/N): " t
    if [[ "$t" =~ ^[Yy]$ ]]; then
        send_notify "测试通知" "nft-akaagiao 告警通道验证成功"
        echo -e "${GREEN}✓ 已发送测试消息${NC}"
    fi
    read -r -p "按回车继续..."
}

failover_management_menu() {
    while true; do
        clear
        echo -e "${YELLOW}=== 故障转移管理 ===${NC}"
        echo ""
        local has_any=false rule_file
        while IFS= read -r rule_file; do
            [ -f "$rule_file" ] || continue
            read_rule_file "$rule_file" || continue
            [[ "$REMOTE_HOST" == *","* ]] || continue
            has_any=true
            echo -e "  规则 #${BLUE}${RULE_ID}${NC} (端口 ${LISTEN_PORT}) | 目标: ${REMOTE_HOST} | 故障转移: $([ "$FAILOVER_ENABLED" = "true" ] && echo -e "${GREEN}开启${NC}" || echo -e "${RED}关闭${NC}")"
        done < <(get_sorted_rule_files)

        [ "$has_any" = false ] && echo -e "${GRAY}暂无多目标规则（需先配置多目标负载均衡规则）${NC}"
        echo ""
        echo "请选择操作:"
        echo -e "${GREEN}1.${NC} 开启/关闭指定规则的故障转移"
        echo -e "${BLUE}2.${NC} 立即执行一次健康检查"
        echo -e "${CYAN}3.${NC} 配置 Telegram / Webhook 告警通知"
        echo -e "${GREEN}0.${NC} 返回"
        echo ""
        read -r -p "请输入选择 [0-3]: " ch
        echo ""
        case "$ch" in
            1)
                read -r -p "请输入规则 ID: " rid
                local rf="${RULES_DIR}/rule-${rid}.conf"
                if read_rule_file "$rf"; then
                    if [ "$FAILOVER_ENABLED" = "true" ]; then
                        save_rule_field "$rf" FAILOVER_ENABLED "false"
                        echo -e "${YELLOW}✓ 规则 #${rid} 已关闭故障转移${NC}"
                    else
                        save_rule_field "$rf" FAILOVER_ENABLED "true"
                        [ "$BALANCE_MODE" = "off" ] && save_rule_field "$rf" BALANCE_MODE "roundrobin"
                        echo -e "${GREEN}✓ 规则 #${rid} 已开启故障转移${NC}"
                    fi
                    apply_nft_rules
                    sync_failover_timer
                else
                    echo -e "${RED}规则不存在${NC}"
                fi
                read -r -p "按回车继续..."
                ;;
            2)
                run_failover_check 0
                show_health_status
                read -r -p "按回车继续..."
                ;;
            3) notify_settings_menu ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}
