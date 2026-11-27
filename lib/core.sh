#!/bin/bash
# lib/core.sh - 核心常量、系统检测、依赖管理、校验与原子文件工具

SCRIPT_VERSION="v1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
CYAN='\033[0;36m'
NC='\033[0m'

# 路径布局
CONFIG_DIR="/etc/nftpf"
RULES_DIR="${CONFIG_DIR}/rules"
STATE_DIR="${CONFIG_DIR}/state"
SETTINGS_FILE="${CONFIG_DIR}/settings.conf"
RULESET_FILE="${CONFIG_DIR}/ruleset.nft"
DNS_CACHE_FILE="${STATE_DIR}/dns_cache.conf"
COUNTERS_FILE="${STATE_DIR}/counters.conf"
HEALTH_STATUS_FILE="${STATE_DIR}/health_status.conf"
NOTIFY_CONF="${CONFIG_DIR}/notify.conf"
SYSCTL_CONF="/etc/sysctl.d/90-nftpf-forward.conf"
SYSTEMD_UNIT="/etc/systemd/system/nftpf.service"
OPENRC_INIT="/etc/init.d/nftpf"

# nftables 独立表名（绝不操作其他表或执行 flush ruleset）
NFT_TABLE_V4="nftpf_v4"
NFT_TABLE_V6="nftpf_v6"
CT_MARK_BASE=65536   # 0x00010000 + rule_id

# 默认全局设置
ENABLE_MSS_CLAMP="true"
ENABLE_FLOWTABLE="false"
ENABLE_HAIRPIN="false"
DDNS_INTERVAL_MIN="2"
FAILOVER_INTERVAL_SEC="5"
FAILOVER_FAIL_THRESHOLD="2"
FAILOVER_SUCC_THRESHOLD="2"
FAILOVER_COOLDOWN_SEC="120"
FAILOVER_TIMEOUT_SEC="3"

# 运行时系统标识
OS=""
VER=""
DISTRO=""       # debian | alpine | centos
PKG_MGR=""      # apt-get | apk | dnf | yum
INIT_SYSTEM=""  # systemd | openrc

SHORT_CONNECT_TIMEOUT=5
SHORT_MAX_TIMEOUT=8

# 必备核心工具（尽量保持极致轻量）
REQUIRED_TOOLS=("nft" "ip" "ss" "jq" "curl" "awk" "tar")

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行，请使用 sudo zz${NC}"
        exit 1
    fi
}

get_gmt8_time() {
    TZ='GMT-8' date "$@"
}

# 安全单引号编码，防止规则备注/内容注入命令
rule_quote() {
    local s="$1"
    s=${s//\'/\'\\\'\'}
    s=${s//$'\n'/ }
    printf "'%s'" "$s"
}

init_dirs() {
    mkdir -p "$CONFIG_DIR" "$RULES_DIR" "$STATE_DIR"
    if [ ! -f "$SETTINGS_FILE" ]; then
        save_settings
    fi
}

load_settings() {
    if [ -f "$SETTINGS_FILE" ]; then
        # shellcheck source=/dev/null
        source "$SETTINGS_FILE"
    fi
    ENABLE_MSS_CLAMP="${ENABLE_MSS_CLAMP:-true}"
    ENABLE_FLOWTABLE="${ENABLE_FLOWTABLE:-false}"
    ENABLE_HAIRPIN="${ENABLE_HAIRPIN:-false}"
    DDNS_INTERVAL_MIN="${DDNS_INTERVAL_MIN:-2}"
    FAILOVER_INTERVAL_SEC="${FAILOVER_INTERVAL_SEC:-5}"
    FAILOVER_FAIL_THRESHOLD="${FAILOVER_FAIL_THRESHOLD:-2}"
    FAILOVER_SUCC_THRESHOLD="${FAILOVER_SUCC_THRESHOLD:-2}"
    FAILOVER_COOLDOWN_SEC="${FAILOVER_COOLDOWN_SEC:-120}"
    FAILOVER_TIMEOUT_SEC="${FAILOVER_TIMEOUT_SEC:-3}"
}

save_settings() {
    mkdir -p "$CONFIG_DIR"
    local tmp
    tmp=$(mktemp "${SETTINGS_FILE}.tmp.XXXXXX") || return 1
    cat > "$tmp" <<EOF
# nft-akaagiao 全局配置
ENABLE_MSS_CLAMP=$(rule_quote "$ENABLE_MSS_CLAMP")
ENABLE_FLOWTABLE=$(rule_quote "$ENABLE_FLOWTABLE")
ENABLE_HAIRPIN=$(rule_quote "$ENABLE_HAIRPIN")
DDNS_INTERVAL_MIN=$(rule_quote "$DDNS_INTERVAL_MIN")
FAILOVER_INTERVAL_SEC=$(rule_quote "$FAILOVER_INTERVAL_SEC")
FAILOVER_FAIL_THRESHOLD=$(rule_quote "$FAILOVER_FAIL_THRESHOLD")
FAILOVER_SUCC_THRESHOLD=$(rule_quote "$FAILOVER_SUCC_THRESHOLD")
FAILOVER_COOLDOWN_SEC=$(rule_quote "$FAILOVER_COOLDOWN_SEC")
FAILOVER_TIMEOUT_SEC=$(rule_quote "$FAILOVER_TIMEOUT_SEC")
EOF
    mv -fT -- "$tmp" "$SETTINGS_FILE"
}

# 原子覆盖规则文件中的单个键值，不依赖 sed/awk 避免反斜杠破坏
save_rule_field() {
    local rule_file="$1" field="$2" value="$3"
    local assignment line tmp_file found=0
    local -a lines=()

    [ -f "$rule_file" ] || return 1
    mapfile -t lines < "$rule_file" || return 1
    assignment="${field}=$(rule_quote "$value")"
    for line in "${!lines[@]}"; do
        if [ "${lines[$line]%%=*}" = "$field" ]; then
            lines[$line]="$assignment"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        lines+=("$assignment")
    fi

    tmp_file=$(mktemp "${rule_file}.tmp.XXXXXX") || return 1
    if printf '%s\n' "${lines[@]}" > "$tmp_file" && mv -fT -- "$tmp_file" "$rule_file"; then
        return 0
    fi
    rm -f -- "$tmp_file"
    return 1
}

detect_system() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}错误: 无法识别系统（缺少 /etc/os-release）${NC}"
        exit 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    OS="${NAME:-Linux}"
    VER="${VERSION_ID:-unknown}"

    case "${ID:-}" in
        debian|ubuntu|kali|raspbian|linuxmint)
            DISTRO="debian" ;;
        alpine)
            DISTRO="alpine" ;;
        centos|rhel|rocky|almalinux|fedora|ol)
            DISTRO="centos" ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*) DISTRO="debian" ;;
                *rhel*|*fedora*|*centos*) DISTRO="centos" ;;
                *alpine*) DISTRO="alpine" ;;
                *)
                    echo -e "${RED}错误: 不支持的系统: ${ID:-unknown}${NC}"
                    echo -e "${YELLOW}支持: Debian/Ubuntu, Alpine, CentOS/RHEL/Rocky/AlmaLinux/Fedora${NC}"
                    exit 1 ;;
            esac
            ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"
    elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
    else
        echo -e "${RED}错误: 未找到支持的包管理器${NC}"
        exit 1
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="none"
    fi
}

_tool_to_pkg() {
    local tool="$1"
    case "$tool" in
        nft) echo "nftables" ;;
        ip|ss) echo "iproute2" ;;
        jq) echo "jq" ;;
        curl) echo "curl" ;;
        tar) echo "tar" ;;
        awk)
            if [ "$PKG_MGR" = "apk" ]; then echo "gawk"; else echo "gawk"; fi
            ;;
        conntrack) echo "conntrack" ;;
        *) echo "$tool" ;;
    esac
}

_pkg_install() {
    local pkgs=()
    local p
    for p in "$@"; do
        pkgs+=("$(_tool_to_pkg "$p")")
    done
    # 去重
    local unique_pkgs=()
    for p in "${pkgs[@]}"; do
        local dup=0 u
        for u in "${unique_pkgs[@]}"; do
            [ "$u" = "$p" ] && dup=1 && break
        done
        [ "$dup" -eq 0 ] && unique_pkgs+=("$p")
    done

    case "$PKG_MGR" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${unique_pkgs[@]}" >/dev/null 2>&1
            ;;
        apk)
            apk add --no-cache "${unique_pkgs[@]}" >/dev/null 2>&1
            ;;
        dnf|yum)
            $PKG_MGR install -y -q "${unique_pkgs[@]}" >/dev/null 2>&1
            ;;
    esac

    local failed=0 t
    for t in "$@"; do
        if command -v "$t" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $t 安装成功"
        else
            echo -e "  ${RED}✗${NC} $t 安装失败"
            failed=1
        fi
    done
    return "$failed"
}

manage_dependencies() {
    local mode="${1:-check}"
    local missing=() t
    for t in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$t" >/dev/null 2>&1; then
            missing+=("$t")
        elif [ "$mode" = "install" ]; then
            echo -e "  ${GREEN}✓${NC} $t 已安装"
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        if [ "$mode" = "check" ]; then
            echo -e "${RED}错误: 缺少必备工具: ${missing[*]}${NC}"
            echo -e "${YELLOW}请运行 'zz install' 或选择菜单 1 自动安装依赖${NC}"
            return 1
        elif [ "$mode" = "install" ]; then
            echo -e "${YELLOW}正在使用 ${PKG_MGR} 安装依赖: ${missing[*]} ...${NC}"
            _pkg_install "${missing[@]}" || return 1
        fi
    fi

    # 安装模式顺带尝试安装 conntrack（非强制，用于切流清理旧会话）
    if [ "$mode" = "install" ] && ! command -v conntrack >/dev/null 2>&1; then
        _pkg_install conntrack >/dev/null 2>&1 || true
    fi
    return 0
}

check_dependencies() {
    manage_dependencies "check" || exit 1
}

# === 校验函数 ===

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

validate_port_or_range() {
    local spec="$1"
    if [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local p1="${BASH_REMATCH[1]}" p2="${BASH_REMATCH[2]}"
        validate_port "$p1" && validate_port "$p2" && (( 10#$p1 < 10#$p2 ))
        return $?
    fi
    validate_port "$spec"
}

validate_ports_input() {
    local input="${1// /}"
    [ -z "$input" ] && return 1
    local IFS=',' p
    read -ra arr <<< "$input"
    for p in "${arr[@]}"; do
        validate_port_or_range "$p" || return 1
    done
    return 0
}

is_ipv4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local o
        for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            (( 10#$o <= 255 )) || return 1
        done
        return 0
    fi
    return 1
}

is_ipv6() {
    local ip="$1"
    ip="${ip#[}"
    ip="${ip%]}"
    [[ "$ip" == *":"* ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]
}

validate_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}

is_domain() {
    local h="$1"
    ! is_ipv4 "$h" && ! is_ipv6 "$h" && [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

validate_host() {
    local h="$1"
    h="${h#[}"
    h="${h%]}"
    is_ipv4 "$h" || is_ipv6 "$h" || is_domain "$h"
}

validate_listen_spec() {
    local s="$1"
    [ -z "$s" ] || [ "$s" = "any" ] || [ "$s" = "0.0.0.0" ] || [ "$s" = "::" ] && return 0
    validate_ip "$s" && return 0
    [[ "$s" =~ ^[a-zA-Z0-9_.:-]+$ ]] && ip link show "$s" >/dev/null 2>&1 && return 0
    return 1
}

# === 网络辅助 ===

host_has_global_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '
}

get_iface_ip() {
    local iface="$1" family="${2:-4}"
    if [ "$family" = "6" ]; then
        ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6 / {sub(/\/.*/, "", $2); print $2; exit}'
    else
        ip -4 addr show dev "$iface" scope global 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}'
    fi
}

get_default_iface() {
    ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_local_interfaces_summary() {
    local iface v4 v6
    for iface in $(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -v '^lo$'); do
        v4=$(get_iface_ip "$iface" 4)
        v6=$(get_iface_ip "$iface" 6)
        echo -e "  ${CYAN}${iface}${NC}: IPv4=${GREEN}${v4:-无}${NC} | IPv6=${BLUE}${v6:-无}${NC}"
    done
}

# TCP 连通性检测（优先内置 /dev/tcp，无额外依赖；回退 nc）
check_connectivity() {
    local target="$1" port="$2" timeout_sec="${3:-3}"
    [ -z "$target" ] || [ -z "$port" ] && return 1
    target="${target#[}"
    target="${target%]}"
    if command -v timeout >/dev/null 2>&1; then
        if is_ipv6 "$target"; then
            if command -v nc >/dev/null 2>&1; then
                nc -6 -z -w "$timeout_sec" "$target" "$port" >/dev/null 2>&1
                return $?
            fi
        fi
        timeout "$timeout_sec" bash -c "exec 3<>/dev/tcp/${target}/${port}" >/dev/null 2>&1
        return $?
    elif command -v nc >/dev/null 2>&1; then
        nc -z -w "$timeout_sec" "$target" "$port" >/dev/null 2>&1
        return $?
    fi
    return 1
}

format_bytes() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN {
        if (b >= 1099511627776) printf "%.2f TB", b/1099511627776;
        else if (b >= 1073741824) printf "%.2f GB", b/1073741824;
        else if (b >= 1048576) printf "%.2f MB", b/1048576;
        else if (b >= 1024) printf "%.2f KB", b/1024;
        else printf "%d B", b;
    }'
}

get_sorted_rule_files() {
    [ -d "$RULES_DIR" ] || return 0
    local f
    for f in "${RULES_DIR}"/rule-*.conf; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done | awk -F'rule-|\\.conf' '{print $(NF-1) "\t" $0}' | sort -n -k1,1 | cut -f2-
}

read_rule_file() {
    local rule_file="$1"
    [ -f "$rule_file" ] || return 1
    unset RULE_ID RULE_NOTE ENABLED CREATED_TIME PROTOCOL IP_FAMILY
    unset LISTEN_IP LISTEN_PORT REMOTE_HOST REMOTE_PORT SNAT_IP
    unset BALANCE_MODE WEIGHTS FAILOVER_ENABLED
    # shellcheck source=/dev/null
    source "$rule_file" || return 1
    RULE_NOTE="${RULE_NOTE:-}"
    ENABLED="${ENABLED:-true}"
    PROTOCOL="${PROTOCOL:-both}"
    IP_FAMILY="${IP_FAMILY:-auto}"
    LISTEN_IP="${LISTEN_IP:-any}"
    SNAT_IP="${SNAT_IP:-auto}"
    BALANCE_MODE="${BALANCE_MODE:-off}"
    WEIGHTS="${WEIGHTS:-}"
    FAILOVER_ENABLED="${FAILOVER_ENABLED:-false}"
    return 0
}

generate_rule_id() {
    local max_id=0 f id
    if [ -d "$RULES_DIR" ]; then
        for f in "${RULES_DIR}"/rule-*.conf; do
            [ -f "$f" ] || continue
            id="${f##*/rule-}"
            id="${id%.conf}"
            if [[ "$id" =~ ^[0-9]+$ ]] && (( id > max_id )); then
                max_id="$id"
            fi
        done
    fi
    echo $((max_id + 1))
}

# 规则目标列表解析：支持单目标 "1.2.3.4" + REMOTE_PORT，也支持多目标 "1.2.3.4:443,5.6.7.8:8443" 或 "1.2.3.4,5.6.7.8"
parse_rule_targets() {
    local remote_host="$1" default_port="$2"
    local IFS=',' item h p
    read -ra items <<< "$remote_host"
    for item in "${items[@]}"; do
        item=$(echo "$item" | xargs)
        [ -z "$item" ] && continue
        if [[ "$item" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+|same)$ ]]; then
            h="${BASH_REMATCH[1]}"
            p="${BASH_REMATCH[2]}"
        elif is_ipv6 "$item"; then
            h="${item#[}"; h="${h%]}"
            p="$default_port"
        elif [[ "$item" == *:* ]]; then
            h="${item%:*}"
            p="${item##*:}"
        else
            h="$item"
            p="$default_port"
        fi
        printf '%s|%s\n' "$h" "$p"
    done
}

# === DNS 解析与缓存 ===

resolve_host_ip() {
    local host="$1" family="${2:-4}"
    host="${host#[}"; host="${host%]}"

    if [ "$family" = "4" ] && is_ipv4 "$host"; then
        echo "$host"; return 0
    fi
    if [ "$family" = "6" ] && is_ipv6 "$host"; then
        echo "$host"; return 0
    fi
    if is_ipv4 "$host" || is_ipv6 "$host"; then
        return 1
    fi

    local ip=""
    if [ "$family" = "4" ]; then
        if command -v getent >/dev/null 2>&1; then
            ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
        fi
        if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
            ip=$(dig +short +time=3 +tries=1 A "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        fi
        if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
            ip=$(host -t A -W 3 "$host" 2>/dev/null | awk '/has address/ {print $NF; exit}')
        fi
    else
        if command -v getent >/dev/null 2>&1; then
            ip=$(getent ahostsv6 "$host" 2>/dev/null | awk '!/^fe80:/ {print $1; exit}')
        fi
        if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
            ip=$(dig +short +time=3 +tries=1 AAAA "$host" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | grep -v '^fe80:' | head -1)
        fi
        if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
            ip=$(host -t AAAA -W 3 "$host" 2>/dev/null | awk '/IPv6 address/ {print $NF; exit}')
        fi
    fi

    if [ -n "$ip" ]; then
        _dns_cache_set "$host" "$family" "$ip"
        echo "$ip"
        return 0
    fi

    # DNS 临时不可用时回退缓存（避免开机或短暂断网导致整表加载失败）
    ip=$(_dns_cache_get "$host" "$family")
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi
    return 1
}

_dns_cache_key() {
    printf '%s|%s' "$1" "$2"
}

_dns_cache_get() {
    local key
    key=$(_dns_cache_key "$1" "$2")
    [ -f "$DNS_CACHE_FILE" ] || return 1
    awk -F'|' -v h="$1" -v f="$2" '$1==h && $2==f {print $3; exit}' "$DNS_CACHE_FILE"
}

_dns_cache_set() {
    local host="$1" family="$2" ip="$3"
    mkdir -p "$STATE_DIR"
    local tmp
    tmp=$(mktemp "${DNS_CACHE_FILE}.tmp.XXXXXX") || return 1
    if [ -f "$DNS_CACHE_FILE" ]; then
        awk -F'|' -v h="$host" -v f="$family" '!($1==h && $2==f)' "$DNS_CACHE_FILE" > "$tmp" 2>/dev/null || true
    fi
    printf '%s|%s|%s|%s\n' "$host" "$family" "$ip" "$(date +%s)" >> "$tmp"
    mv -fT -- "$tmp" "$DNS_CACHE_FILE"
}
