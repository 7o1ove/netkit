#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
MIHOMO_BIN="/usr/local/bin/mihomo"
MIHOMO_SERVICE_FILE="/etc/systemd/system/mihomo.service"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
REQUESTED_VERSION="${1:-}"
ARCHIVE=""
EXTRACTED=""
UPDATE_DIR=""
UPDATE_STARTED=0
RESTART_ATTEMPTED=0
ENABLE_ATTEMPTED=0
OLD_ACTIVE=0
OLD_ENABLED=""
HAS_PROTOCOL=false

restore_update_file(){
    local backup="$1"
    local target="$2"

    if [[ -e "$backup" || -L "$backup" ]]; then
        cp -a -- "$backup" "$target"
    else
        rm -f -- "$target"
    fi
}

rollback_update(){
    local failed=0

    warning "Mihomo 更新失败，正在恢复原内核和配置..."
    if (( RESTART_ATTEMPTED == 1 )); then
        systemctl stop mihomo || failed=1
    fi
    if [[ -e "${UPDATE_DIR}/mihomo.old" || -L "${UPDATE_DIR}/mihomo.old" ]]; then
        mv -f -- "${UPDATE_DIR}/mihomo.old" "$MIHOMO_BIN" || failed=1
    else
        rm -f -- "$MIHOMO_BIN" || failed=1
    fi
    restore_update_file "${UPDATE_DIR}/config.yaml" "${MIHOMO_DIR}/config.yaml" || failed=1
    restore_update_file "${UPDATE_DIR}/mihomo.service" "$MIHOMO_SERVICE_FILE" || failed=1
    systemctl daemon-reload || failed=1

    if (( ENABLE_ATTEMPTED == 1 )); then
        case "$OLD_ENABLED" in
            enabled) systemctl enable mihomo >/dev/null || failed=1 ;;
            enabled-runtime)
                systemctl disable mihomo >/dev/null || failed=1
                systemctl enable --runtime mihomo >/dev/null || failed=1
                ;;
            *) systemctl disable mihomo >/dev/null || failed=1 ;;
        esac
    fi
    if (( RESTART_ATTEMPTED == 1 && OLD_ACTIVE == 1 )); then
        if ! systemctl restart mihomo; then
            failed=1
        else
            sleep 1
            systemctl is-active --quiet mihomo || failed=1
        fi
    fi

    if (( failed != 0 )); then
        error "自动恢复未完全成功，请检查 Mihomo 服务并使用保留的备份。"
        return 1
    fi
    success "已恢复更新前的内核、配置和服务状态。"
}

cleanup(){
    local status=$?
    local keep_backup=0
    trap - EXIT INT TERM

    if (( status != 0 && UPDATE_STARTED == 1 )); then
        if ! rollback_update; then
            keep_backup=1
            path_kv "备份目录:" "$UPDATE_DIR"
        fi
    fi
    [[ -z "$ARCHIVE" ]] || rm -f -- "$ARCHIVE"
    [[ -z "$EXTRACTED" ]] || rm -f -- "$EXTRACTED"
    if [[ -n "$UPDATE_DIR" ]] && (( keep_backup == 0 )); then
        rm -f -- "${UPDATE_DIR}/mihomo.old" "${UPDATE_DIR}/mihomo.new" \
            "${UPDATE_DIR}/config.yaml" "${UPDATE_DIR}/mihomo.service"
        rmdir -- "$UPDATE_DIR" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "$REQUESTED_VERSION" && ! "$REQUESTED_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "版本号格式无效：${REQUESTED_VERSION}"
    error "仅支持正式稳定版版本号。"
    exit 1
fi

info "正在安装 Mihomo 环境依赖..."
apt update
apt install -y curl ca-certificates gzip coreutils

if [[ -n "$REQUESTED_VERSION" ]]; then
    VERSION="$REQUESTED_VERSION"
else
    info "正在获取 Mihomo 最新正式稳定版..."
    RELEASE_JSON=$(curl -fsSL -L \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/repos/MetaCubeX/mihomo/releases/latest)
    VERSION=$(sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' <<< "$RELEASE_JSON" | head -n1)

    if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "无法获取 Mihomo 最新正式稳定版版本号。"
        exit 1
    fi
fi

case "$(uname -m)" in
    x86_64|amd64) ASSET="mihomo-linux-amd64-compatible-${VERSION}.gz" ;;
    aarch64|arm64) ASSET="mihomo-linux-arm64-${VERSION}.gz" ;;
    armv7l|armv7) ASSET="mihomo-linux-armv7-${VERSION}.gz" ;;
    i386|i486|i586|i686) ASSET="mihomo-linux-386-${VERSION}.gz" ;;
    *) error "暂不支持当前 CPU 架构：$(uname -m)"; exit 1 ;;
esac

DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}/${ASSET}"
ARCHIVE=$(mktemp /tmp/mihomo.XXXXXX.gz)
EXTRACTED=$(mktemp /tmp/mihomo.XXXXXX)

info "正在下载 Mihomo ${VERSION}..."
curl -fL --retry 3 --retry-delay 2 -o "$ARCHIVE" "$DOWNLOAD_URL"

if ! gzip -t "$ARCHIVE"; then
    error "Mihomo 下载文件校验失败。"
    exit 1
fi

gzip -dc "$ARCHIVE" > "$EXTRACTED"
chmod 0755 "$EXTRACTED"

if ! "$EXTRACTED" -v >/dev/null 2>&1; then
    error "下载的 Mihomo 程序无法运行，请检查系统架构兼容性。"
    exit 1
fi
NEW_VERSION=$("$EXTRACTED" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
if [[ "$NEW_VERSION" != "$VERSION" ]]; then
    error "Mihomo 版本校验失败：期望 ${VERSION}，实际 ${NEW_VERSION:-未知}。"
    exit 1
fi

# 新内核通过两种配置检查后，才允许修改现有安装。
if [[ -f "${MIHOMO_DIR}/config.yaml" ]]; then
    info "正在用新内核检查现有 Mihomo 配置..."
    "$EXTRACTED" -t -d "$MIHOMO_DIR" -f "${MIHOMO_DIR}/config.yaml"
fi
for file in "${MIHOMO_DIR}/protocols"/*.yaml; do
    if [[ -f "$file" ]]; then
        HAS_PROTOCOL=true
        break
    fi
done
if $HAS_PROTOCOL; then
    bash "$BUILD_CONFIG_SCRIPT" --check --binary "$EXTRACTED"
fi

systemctl is-active --quiet mihomo && OLD_ACTIVE=1
OLD_ENABLED=$(systemctl is-enabled mihomo 2>/dev/null || true)

# 新旧程序都暂存在目标文件系统，使用重命名替换，避免覆盖运行中的程序。
mkdir -p "$(dirname "$MIHOMO_BIN")"
UPDATE_DIR=$(mktemp -d "${MIHOMO_BIN}.update.XXXXXX")
if [[ -e "$MIHOMO_BIN" || -L "$MIHOMO_BIN" ]]; then
    cp -a -- "$MIHOMO_BIN" "${UPDATE_DIR}/mihomo.old"
fi
if [[ -e "${MIHOMO_DIR}/config.yaml" ]]; then
    cp -a -- "${MIHOMO_DIR}/config.yaml" "${UPDATE_DIR}/config.yaml"
fi
if [[ -e "$MIHOMO_SERVICE_FILE" ]]; then
    cp -a -- "$MIHOMO_SERVICE_FILE" "${UPDATE_DIR}/mihomo.service"
fi
install -m 0755 "$EXTRACTED" "${UPDATE_DIR}/mihomo.new"

UPDATE_STARTED=1
mv -f -- "${UPDATE_DIR}/mihomo.new" "$MIHOMO_BIN"

info "正在准备 Mihomo 目录和服务..."
mkdir -p "$MIHOMO_DIR" "${MIHOMO_DIR}/protocols" "${MIHOMO_DIR}/client"
cat > "$MIHOMO_SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=${MIHOMO_BIN} -d ${MIHOMO_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
if $HAS_PROTOCOL; then
    bash "$BUILD_CONFIG_SCRIPT" --binary "$MIHOMO_BIN"
    RESTART_ATTEMPTED=1
    systemctl restart mihomo
    for attempt in 1 2 3; do
        sleep 1
        if ! systemctl is-active --quiet mihomo; then
            error "Mihomo 新内核启动后未保持运行。"
            exit 1
        fi
    done
else
    RESTART_ATTEMPTED=1
    systemctl stop mihomo
fi
ENABLE_ATTEMPTED=1
systemctl enable mihomo
UPDATE_STARTED=0

banner "Mihomo 安装完成" "$GREEN"
value "$("$MIHOMO_BIN" -v | head -n1)"
echo
path_kv "程序文件        :" "$MIHOMO_BIN"
path_kv "配置目录        :" "$MIHOMO_DIR"
path_kv "协议配置        :" "${MIHOMO_DIR}/protocols"
path_kv "连接信息        :" "${MIHOMO_DIR}/client"
echo
divider "$GREEN"
success "Mihomo ${VERSION} 安装完成。"
success "Mihomo 服务已设置为开机启动。"
if $HAS_PROTOCOL; then
    success "现有协议配置已重建，Mihomo 服务已重启。"
else
    success "服务会在协议配置完成后启动。"
fi
divider "$GREEN"
