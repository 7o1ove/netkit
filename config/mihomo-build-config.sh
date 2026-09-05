#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
CONFIG_FILE="${MIHOMO_DIR}/config.yaml"
PROTOCOL_DIR="${MIHOMO_DIR}/protocols"
CONFIG_TMP="${CONFIG_FILE}.tmp.$$"
CHECK_ONLY=false
MIHOMO_BIN=""

while (( $# > 0 )); do
    case "$1" in
        --check) CHECK_ONLY=true; shift ;;
        --binary)
            if (( $# < 2 )) || [[ ! -x "$2" ]]; then
                error "请指定可执行的 Mihomo 内核。"
                exit 2
            fi
            MIHOMO_BIN="$2"
            shift 2
            ;;
        *) error "未知参数：$1"; exit 2 ;;
    esac
done

info "正在构建 Mihomo 配置..."
mkdir -p "$MIHOMO_DIR" "$PROTOCOL_DIR"

if [[ -n "$MIHOMO_BIN" ]]; then
    : # 使用更新脚本指定的内核进行校验。
elif command -v mihomo >/dev/null 2>&1; then
    MIHOMO_BIN="$(command -v mihomo)"
elif [[ -x /usr/local/bin/mihomo ]]; then
    MIHOMO_BIN="/usr/local/bin/mihomo"
elif [[ -x /usr/bin/mihomo ]]; then
    MIHOMO_BIN="/usr/bin/mihomo"
else
    error "未检测到 Mihomo。"
    exit 1
fi

FOUND=false
for file in "$PROTOCOL_DIR"/*.yaml; do
    if [[ -f "$file" ]]; then
        FOUND=true
        break
    fi
done

if ! $FOUND; then
    error "未找到 Mihomo 协议配置。"
    exit 1
fi

trap 'rm -f "$CONFIG_TMP"' EXIT

cat > "$CONFIG_TMP" <<EOF
mode: direct
log-level: error

listeners:
EOF

for file in "$PROTOCOL_DIR"/*.yaml; do
    [[ -f "$file" ]] || continue
    cat "$file" >> "$CONFIG_TMP"
    echo >> "$CONFIG_TMP"
done

info "正在测试 Mihomo 配置..."
if ! "$MIHOMO_BIN" -t -d "$MIHOMO_DIR" -f "$CONFIG_TMP"; then
    banner "Mihomo 配置测试失败" "$RED"
    exit 1
fi

if $CHECK_ONLY; then
    success "Mihomo 配置检查通过。"
    exit 0
fi

mv "$CONFIG_TMP" "$CONFIG_FILE"
trap - EXIT

banner "Mihomo 配置构建成功" "$GREEN"
label " Mihomo 主配置文件"
path_value "$CONFIG_FILE"
echo
divider "$GREEN"
