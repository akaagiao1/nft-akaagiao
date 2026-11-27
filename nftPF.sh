#!/bin/bash
# nft-akaagiao (nftPF) - 高性能内核态 nftables 端口转发管理工具
# 灵感源自 zywe03/realm-xwPF，针对 Linux nftables 内核态 NAT 转发深度重构优化
# 快捷命令: zz

INSTALL_DIR="/usr/local/bin"
LIB_DIR="/usr/local/bin/nftpf-lib"
SHORTCUT_PATH="/usr/local/bin/zz"

REPO_OWNER="${NFTPF_REPO_OWNER:-akaagiao1}"
REPO_NAME="${NFTPF_REPO_NAME:-nft-akaagiao}"
REPO_BRANCH="${NFTPF_REPO_BRANCH:-main}"
REPO_RAW_URL="${NFTPF_REPO_RAW_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}}"
GH_PROXY_PREFIX="${NFTPF_GH_PROXY:-}"

LIB_FILES=(
    "core.sh"
    "sysctl.sh"
    "nft.sh"
    "rules.sh"
    "ddns.sh"
    "failover.sh"
    "migrate.sh"
    "ui.sh"
)

_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_BLUE='\033[0;34m'
_NC='\033[0m'

_effective_url() {
    local raw_url="$1"
    if [ -n "$GH_PROXY_PREFIX" ]; then
        printf '%s/%s' "${GH_PROXY_PREFIX%/}" "$raw_url"
    else
        printf '%s' "$raw_url"
    fi
}

_download_once() {
    local url="$1" target="$2"
    local tmp_dir tmp
    tmp_dir=$(mktemp -d "${target}.download.XXXXXX") || return 1
    tmp="$tmp_dir/file"

    if { command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 8 --max-time 25 "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; } ||
       { command -v wget >/dev/null 2>&1 && wget -q -T 10 -t 1 -O "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; }; then
        if mv -fT -- "$tmp" "$target"; then
            rmdir "$tmp_dir" 2>/dev/null || true
            return 0
        fi
    fi
    rm -rf -- "$tmp_dir" 2>/dev/null || true
    return 1
}

# 原子下载（文本脚本自动清除 CR，支持直连与自动代理回退）
_download() {
    local raw_url="$1" target="$2" is_binary="${3:-0}"
    local -a candidates=()
    if [ -n "$GH_PROXY_PREFIX" ]; then
        candidates+=("${GH_PROXY_PREFIX%/}/${raw_url}")
    fi
    candidates+=("$raw_url" "https://v6.gh-proxy.org/${raw_url}" "https://ghfast.top/${raw_url}")

    local u
    for u in "${candidates[@]}"; do
        if _download_once "$u" "$target"; then
            if [ "$is_binary" != "1" ]; then
                tr -d '\r' < "$target" > "${target}.lf" && mv -fT -- "${target}.lf" "$target"
            fi
            return 0
        fi
    done
    return 1
}

_bootstrap_from_tarball() {
    command -v tar >/dev/null 2>&1 || return 1
    local tar_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/nftpf-tar.XXXXXX) || return 1
    local tar_file="${tmp_dir}/repo.tar.gz"

    if _download "$tar_url" "$tar_file" 1 && tar -xzf "$tar_file" -C "$tmp_dir" 2>/dev/null; then
        local extracted=""
        extracted=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
        if [ -n "$extracted" ] && [ -f "$extracted/nftPF.sh" ] && [ -f "$extracted/lib/core.sh" ]; then
            _bootstrap_from_local "$extracted"
            local rc=$?
            rm -rf -- "$tmp_dir"
            return "$rc"
        fi
    fi
    rm -rf -- "$tmp_dir"
    return 1
}

_bootstrap_from_local() {
    local src_dir="$1"
    echo -e "${_YELLOW}正在安装/更新脚本文件...${_NC}"
    mkdir -p "$LIB_DIR"
    tr -d '\r' < "$src_dir/nftPF.sh" > "$INSTALL_DIR/nftPF.sh.new" && mv -fT -- "$INSTALL_DIR/nftPF.sh.new" "$INSTALL_DIR/nftPF.sh" || return 1
    chmod +x "$INSTALL_DIR/nftPF.sh"
    echo -e "  ${_GREEN}✓${_NC} nftPF.sh"
    local f
    for f in "${LIB_FILES[@]}"; do
        tr -d '\r' < "$src_dir/lib/$f" > "$LIB_DIR/$f.new" && mv -fT -- "$LIB_DIR/$f.new" "$LIB_DIR/$f" || return 1
        chmod +x "$LIB_DIR/$f"
        echo -e "  ${_GREEN}✓${_NC} lib/$f"
    done
    ln -sf "$INSTALL_DIR/nftPF.sh" "$SHORTCUT_PATH"
    echo -e "${_GREEN}✓ 快捷命令已创建: zz${_NC}"
    echo ""
}

_bootstrap() {
    # 如果是从本地克隆仓库目录执行且包含完整的 lib/，优先本地安装
    local script_dir=""
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
    fi
    if [ "${NFTPF_FORCE_REMOTE:-0}" != "1" ] && [ -n "$script_dir" ] && \
       [ "$script_dir" != "$INSTALL_DIR" ] && [ -f "$script_dir/lib/core.sh" ] && [ -f "$script_dir/lib/nft.sh" ]; then
        _bootstrap_from_local "$script_dir"
        return $?
    fi

    echo -e "${_YELLOW}正在从远端安装/更新脚本文件...${_NC}"
    echo -e "${_BLUE}仓库: https://github.com/${REPO_OWNER}/${REPO_NAME} (${REPO_BRANCH})${_NC}"

    # 优先单次拉取源码归档包（1 次 HTTPS 请求完成全部模块安装，国内网络更稳更快）
    if _bootstrap_from_tarball; then
        echo -e "${_GREEN}=== 脚本文件安装完成 ===${_NC}"
        echo ""
        return 0
    fi

    echo -e "${_YELLOW}归档包下载失败，回退逐文件拉取...${_NC}"
    mkdir -p "$LIB_DIR"

    if _download "$REPO_RAW_URL/nftPF.sh" "$INSTALL_DIR/nftPF.sh"; then
        chmod +x "$INSTALL_DIR/nftPF.sh"
        echo -e "  ${_GREEN}✓${_NC} nftPF.sh"
    else
        echo -e "  ${_RED}✗${_NC} nftPF.sh 下载失败"
        return 1
    fi

    local failed=0 f
    for f in "${LIB_FILES[@]}"; do
        if _download "$REPO_RAW_URL/lib/$f" "$LIB_DIR/$f"; then
            chmod +x "$LIB_DIR/$f"
            echo -e "  ${_GREEN}✓${_NC} lib/$f"
        else
            echo -e "  ${_RED}✗${_NC} lib/$f 下载失败"
            failed=1
        fi
    done

    [ "$failed" -eq 1 ] && return 1

    ln -sf "$INSTALL_DIR/nftPF.sh" "$SHORTCUT_PATH"
    echo -e "${_GREEN}✓ 快捷命令已创建: zz${_NC}"
    echo -e "${_GREEN}=== 脚本文件安装完成 ===${_NC}"
    echo ""
}

_load_libs() {
    local load_dir="$LIB_DIR"
    local script_dir=""
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
    fi
    if [ ! -f "$load_dir/core.sh" ] && [ -n "$script_dir" ] && [ -f "$script_dir/lib/core.sh" ]; then
        load_dir="$script_dir/lib"
    fi

    if [ ! -d "$load_dir" ] || [ ! -f "$load_dir/core.sh" ]; then
        echo -e "${_RED}错误: 未找到模块目录，请先安装:${_NC}"
        echo -e "${_BLUE}curl -fsSL ${REPO_RAW_URL}/nftPF.sh | sudo bash -s install${_NC}"
        return 1
    fi

    local f
    for f in "${LIB_FILES[@]}"; do
        if [ -f "$load_dir/$f" ]; then
            # shellcheck source=/dev/null
            source "$load_dir/$f"
        else
            echo -e "${_RED}错误: 缺少模块 $f${_NC}"
            return 1
        fi
    done
}

case "${1:-}" in
    install)
        [ "$(id -u)" -ne 0 ] && { echo -e "${_RED}错误: 需要 root 权限${_NC}"; exit 1; }
        _bootstrap || exit 1
        _load_libs || exit 1
        _SKIP_SCRIPT_UPDATE=1 smart_install "${2:-}"
        ;;
    update)
        [ "$(id -u)" -ne 0 ] && { echo -e "${_RED}错误: 需要 root 权限${_NC}"; exit 1; }
        NFTPF_FORCE_REMOTE=1 _bootstrap || exit 1
        _load_libs || exit 1
        echo -e "${_GREEN}✓ 脚本已更新至 ${SCRIPT_VERSION}${_NC}"
        ;;
    *)
        _load_libs || exit 1
        main "$@"
        ;;
esac
