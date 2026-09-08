#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

MIHOMO_INSTALL_SCRIPT="${SCRIPT_DIR}/core/mihomo-core.sh"
MIHOMO_ANYTLS_SCRIPT="${SCRIPT_DIR}/core/mihomo-anytls.sh"
MIHOMO_SS_SCRIPT="${SCRIPT_DIR}/core/mihomo-shadowsocks.sh"
MIHOMO_HY2_SCRIPT="${SCRIPT_DIR}/core/mihomo-hysteria2.sh"
MIHOMO_HY2_HOP_SCRIPT="${SCRIPT_DIR}/core/mihomo-hysteria2-port-hopping.sh"
MIHOMO_BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"

MIHOMO_SERVICE="mihomo"
MIHOMO_DIR="/etc/mihomo"
MIHOMO_PROTOCOL_DIR="${MIHOMO_DIR}/protocols"
MIHOMO_CLIENT_DIR="${MIHOMO_DIR}/client"
MIHOMO_HY2_HOP_SERVICE="mihomo-hysteria2-port-hopping.service"
MIHOMO_HY2_HOP_START="20000"
MIHOMO_HY2_HOP_END="50000"
MIHOMO_HY2_HOP_STATE="${MIHOMO_DIR}/hysteria2-port-hopping.range"
MIHOMO_HY2_SELF_SIGNED_DIR="${MIHOMO_DIR}/certs/hysteria2-selfsigned"
MIHOMO_ANYTLS_SELF_SIGNED_DIR="${MIHOMO_DIR}/certs/anytls-selfsigned"
MIHOMO_HY2_MASQUERADE_DIR="${MIHOMO_DIR}/masquerade"

SELECTED_VERSION=""

select_mihomo_version(){
    local input
    local release_json

    SELECTED_VERSION=""

    echo
    read -e -r -p "$(prompt_text "请输入 Mihomo 正式稳定版版本号（回车使用最新稳定版，输入 0 取消）: ")" input
    input=$(trim_edges "$input")

    cancel_input "$input" && return "$INPUT_CANCEL_STATUS"

    if [[ -z "$input" ]]; then
        return 0
    fi

    input="v${input#v}"

    if [[ ! "$input" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "版本号格式无效：${input}"
        error "仅支持正式稳定版版本号。"
        return 1
    fi

    info "正在验证 Mihomo ${input}..."

    if ! require_commands curl; then
        return 1
    fi

    if ! release_json=$(curl -fsSL -L \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/${input}"); then
        error "未找到 Mihomo ${input}，请检查版本号。"
        return 1
    fi

    if ! grep -q '"prerelease":[[:space:]]*false' <<< "$release_json" || \
       ! grep -q '"draft":[[:space:]]*false' <<< "$release_json"; then
        error "Mihomo ${input} 不是正式稳定版，已拒绝安装。"
        return 1
    fi

    SELECTED_VERSION="$input"
}

rebuild_or_stop_mihomo(){
    local found=false
    local file

    for file in "$MIHOMO_PROTOCOL_DIR"/*.yaml; do
        if [[ -f "$file" ]]; then
            found=true
            break
        fi
    done

    if $found; then
        if ! require_commands systemctl; then
            return 1
        fi

        if ! bash "$MIHOMO_BUILD_CONFIG_SCRIPT"; then
            error "Mihomo 配置重建失败。"
            return 1
        fi
        if ! systemctl restart "$MIHOMO_SERVICE"; then
            error "Mihomo 配置已重建，但服务重启失败。"
            return 1
        fi
        success "Mihomo 配置已重建并重启。"
    else
        rm -f "${MIHOMO_DIR}/config.yaml"
        systemctl stop "$MIHOMO_SERVICE" 2>/dev/null || true
        warning "已无协议配置，Mihomo 已停止。"
    fi
}

show_client_info(){
    header "连接信息"

    section "Mihomo" "$GREEN"
    echo
    section "AnyTLS" "$YELLOW"
    echo
    if [[ -f "${MIHOMO_CLIENT_DIR}/anytls.txt" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == "AnyTLS Link:" ]]; then
                label " AnyTLS Link"
                echo
                continue
            fi
            if [[ "$line" == "Mihomo / Clash:" ]]; then
                echo
                divider "$CYAN" "-"
                echo
                label " Mihomo / Clash YAML"
                echo
                continue
            fi
            value "$line"
        done < "${MIHOMO_CLIENT_DIR}/anytls.txt"
    else
        warning "未配置"
    fi

    echo
    section "Hysteria2" "$YELLOW"
    echo
    if [[ -f "${MIHOMO_CLIENT_DIR}/hysteria2.txt" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == "Hysteria2 Link:" ]]; then
                label " Hysteria2 Link"
                echo
                continue
            fi
            if [[ "$line" == "Mihomo / Clash:" ]]; then
                echo
                divider "$CYAN" "-"
                echo
                label " Mihomo / Clash YAML"
                echo
                continue
            fi
            value "$line"
        done < "${MIHOMO_CLIENT_DIR}/hysteria2.txt"
    else
        warning "未配置"
    fi

    echo
    section "Shadowsocks" "$YELLOW"
    echo
    if [[ -f "${MIHOMO_CLIENT_DIR}/shadowsocks.txt" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == "SS Link:" ]]; then
                label " Shadowsocks Link"
                echo
                continue
            fi
            if [[ "$line" == "Mihomo / Clash:" ]]; then
                echo
                divider "$CYAN" "-"
                echo
                label " Mihomo / Clash YAML"
                echo
                continue
            fi
            value "$line"
        done < "${MIHOMO_CLIENT_DIR}/shadowsocks.txt"
    else
        warning "未配置"
    fi

    pause
}

install_mihomo(){
    local selection_status=0

    header "安装 / 更新 Mihomo"
    select_mihomo_version || selection_status=$?
    [[ "$selection_status" -eq "$INPUT_CANCEL_STATUS" ]] && return
    if [[ "$selection_status" -ne 0 ]]; then
        pause
        return
    fi

    if [[ -n "$SELECTED_VERSION" ]]; then
        warning "正在安装 Mihomo ${SELECTED_VERSION}..."
    else
        warning "正在安装 Mihomo 最新正式稳定版..."
    fi

    run_script_and_pause "$MIHOMO_INSTALL_SCRIPT" "$SELECTED_VERSION"
}

configure_mihomo_hysteria2(){
    run_script_and_pause "$MIHOMO_HY2_SCRIPT"
}

configure_mihomo_anytls(){
    run_script_and_pause "$MIHOMO_ANYTLS_SCRIPT"
}

configure_mihomo_shadowsocks(){
    run_script_and_pause "$MIHOMO_SS_SCRIPT"
}

remove_mihomo_hysteria2_port_hopping(){
    local listener_port="${1:-${MIHOMO_HY2_HOP_START}}"
    local hop_start="${MIHOMO_HY2_HOP_START}"
    local hop_end="${MIHOMO_HY2_HOP_END}"
    local range=""
    local service_values=""
    local service_port=""

    if [[ -r "${MIHOMO_HY2_HOP_STATE}" ]]; then
        range=$(tr -d '\r\n' < "${MIHOMO_HY2_HOP_STATE}")
        if [[ "${range}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            hop_start="${BASH_REMATCH[1]}"
            hop_end="${BASH_REMATCH[2]}"
        fi
    elif [[ -r "/etc/systemd/system/${MIHOMO_HY2_HOP_SERVICE}" ]]; then
        service_values=$(sed -nE 's#^ExecStart=.*/mihomo-hysteria2-port-hopping\.sh start ([0-9]+) ([0-9]+) ([0-9]+)$#\1 \2 \3#p' \
            "/etc/systemd/system/${MIHOMO_HY2_HOP_SERVICE}" | head -n1)
        if [[ -n "${service_values}" ]]; then
            read -r hop_start hop_end service_port <<< "${service_values}"
        fi
    fi

    systemctl disable --now "${MIHOMO_HY2_HOP_SERVICE}" >/dev/null 2>&1 || true
    if [[ -r "${MIHOMO_HY2_HOP_SCRIPT}" ]]; then
        bash "${MIHOMO_HY2_HOP_SCRIPT}" stop \
            "${hop_start}" "${hop_end}" "${listener_port}" \
            >/dev/null 2>&1 || true
    fi
    rm -f "/etc/systemd/system/${MIHOMO_HY2_HOP_SERVICE}" \
        "/etc/systemd/system/mihomo.service.d/hysteria2-port-hopping.conf" \
        "${MIHOMO_HY2_HOP_STATE}"
    rmdir /etc/systemd/system/mihomo.service.d >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    remove_ufw_port_rule "${hop_start}:${hop_end}" udp
    remove_ufw_port_rule "20000:50000" udp
    remove_ufw_port_rule "${listener_port}" udp
}

remove_mihomo_hysteria2_assets(){
    if [[ -d "${MIHOMO_HY2_SELF_SIGNED_DIR}" ]]; then
        case "${MIHOMO_HY2_SELF_SIGNED_DIR}" in
            "${MIHOMO_DIR}/certs/hysteria2-selfsigned") ;;
            *)
                error "拒绝删除异常的 HY2 自签证书目录：${MIHOMO_HY2_SELF_SIGNED_DIR}"
                return 1
                ;;
        esac
        rm -rf -- "${MIHOMO_HY2_SELF_SIGNED_DIR}"
        rmdir "${MIHOMO_DIR}/certs" >/dev/null 2>&1 || true
        success "HY2 自签证书、私钥和域名记录已删除；下次安装会生成新的指纹。"
    fi

    if [[ -d "${MIHOMO_HY2_MASQUERADE_DIR}" ]]; then
        case "${MIHOMO_HY2_MASQUERADE_DIR}" in
            "${MIHOMO_DIR}/masquerade") ;;
            *)
                error "拒绝删除异常的 HY2 静态网页目录：${MIHOMO_HY2_MASQUERADE_DIR}"
                return 1
                ;;
        esac
        rm -rf -- "${MIHOMO_HY2_MASQUERADE_DIR}"
        success "HY2 本地静态网页已删除。"
    fi
}

uninstall_mihomo_hysteria2(){
    local port

    header "卸载 Mihomo Hysteria2"
    warning "正在卸载 Mihomo Hysteria2..."
    port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/hysteria2.yaml" "port")
    remove_mihomo_hysteria2_port_hopping "${port:-${MIHOMO_HY2_HOP_START}}"
    rm -f "${MIHOMO_PROTOCOL_DIR}/hysteria2.yaml" "${MIHOMO_CLIENT_DIR}/hysteria2.txt"
    if ! rebuild_or_stop_mihomo; then
        pause
        return
    fi
    remove_mihomo_hysteria2_assets
    success "Mihomo Hysteria2 已卸载。"
    pause
}

remove_mihomo_anytls_assets(){
    if [[ ! -d "${MIHOMO_ANYTLS_SELF_SIGNED_DIR}" ]]; then
        return 0
    fi

    case "${MIHOMO_ANYTLS_SELF_SIGNED_DIR}" in
        "${MIHOMO_DIR}/certs/anytls-selfsigned") ;;
        *)
            error "拒绝删除异常的 AnyTLS 自签证书目录：${MIHOMO_ANYTLS_SELF_SIGNED_DIR}"
            return 1
            ;;
    esac

    rm -rf -- "${MIHOMO_ANYTLS_SELF_SIGNED_DIR}"
    rmdir "${MIHOMO_DIR}/certs" >/dev/null 2>&1 || true
    success "AnyTLS 自签证书、私钥和域名记录已删除；下次安装会生成新的指纹。"
}

uninstall_mihomo_anytls(){
    local port

    header "卸载 Mihomo AnyTLS"
    warning "正在卸载 Mihomo AnyTLS..."
    port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/anytls.yaml" "port")
    rm -f "${MIHOMO_PROTOCOL_DIR}/anytls.yaml" "${MIHOMO_CLIENT_DIR}/anytls.txt"
    if ! rebuild_or_stop_mihomo; then
        pause
        return
    fi
    remove_ufw_port_rule "$port" tcp
    remove_mihomo_anytls_assets
    success "Mihomo AnyTLS 已卸载。"
    pause
}

uninstall_mihomo_shadowsocks(){
    local port

    header "卸载 Mihomo Shadowsocks"
    warning "正在卸载 Mihomo Shadowsocks..."
    port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/shadowsocks.yaml" "port")
    rm -f "${MIHOMO_PROTOCOL_DIR}/shadowsocks.yaml" "${MIHOMO_CLIENT_DIR}/shadowsocks.txt"
    if ! rebuild_or_stop_mihomo; then
        pause
        return
    fi
    remove_ufw_port_rule "$port" tcp
    remove_ufw_port_rule "$port" udp
    pause
}

show_mihomo_logs(){
    header "Mihomo 日志"

    if ! command -v journalctl >/dev/null 2>&1; then
        error "当前系统不支持 journalctl，无法查看 Mihomo 日志。"
        pause
        return
    fi

    if ! command -v mihomo >/dev/null 2>&1; then
        warning "未检测到 Mihomo，以下可能没有可用日志。"
        echo
    fi

    section "最近 100 条日志" "$YELLOW"
    echo
    if ! journalctl -u "$MIHOMO_SERVICE" -n 100 --no-pager; then
        error "Mihomo 日志读取失败。"
    fi

    pause
}

show_mihomo_core(){
    header "Mihomo 核心"

    local status
    status=$(systemctl is-active "$MIHOMO_SERVICE" 2>/dev/null || true)
    status=${status:-unknown}

    if [[ "$status" == "active" ]]; then
        success "Mihomo 状态: 运行中"
    else
        warning "Mihomo 状态: ${status}"
    fi

    echo
    if command -v mihomo >/dev/null 2>&1; then
        label "版本"
        value "$(mihomo -v | head -n1)"
    else
        warning "未检测到 Mihomo。"
    fi

    echo
    section "协议配置" "$YELLOW"
    echo
    if [[ -f "${MIHOMO_CLIENT_DIR}/anytls.txt" ]]; then
        kv "AnyTLS           :" "已配置（UDP over TCP 已开启）"
    else
        kv "AnyTLS           :" "未配置"
    fi

    if [[ -f "${MIHOMO_CLIENT_DIR}/hysteria2.txt" ]]; then
        kv "Hysteria2       :" "已配置（BBR，UDP 跳跃端口位于 20000-50000）"
    else
        kv "Hysteria2       :" "未配置"
    fi

    if [[ -f "${MIHOMO_CLIENT_DIR}/shadowsocks.txt" ]]; then
        kv "Shadowsocks      :" "已配置（UDP 已开启）"
    else
        kv "Shadowsocks      :" "未配置"
    fi

    pause
}

restart_mihomo(){
    header "重启 Mihomo"

    if ! command -v mihomo >/dev/null 2>&1; then
        error "未检测到 Mihomo，请先安装。"
        pause
        return
    fi

    if ! require_commands systemctl; then
        pause
        return
    fi

    info "正在重启 Mihomo..."
    if ! systemctl restart "$MIHOMO_SERVICE"; then
        error "Mihomo 重启失败。"
        pause
        return
    fi

    sleep 1
    if systemctl is-active --quiet "$MIHOMO_SERVICE"; then
        success "Mihomo 重启成功。"
    else
        error "Mihomo 重启失败。"
    fi

    pause
}

uninstall_mihomo(){
    local hysteria2_port anytls_port shadowsocks_port

    header "卸载 Mihomo"
    warning "即将卸载 Mihomo，并删除其配置和连接信息。"

    if ! confirm_action "确认卸载 Mihomo 吗？"; then
        warning "已取消。"
        pause
        return
    fi

    hysteria2_port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/hysteria2.yaml" "port")
    anytls_port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/anytls.yaml" "port")
    shadowsocks_port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/shadowsocks.yaml" "port")
    remove_mihomo_hysteria2_port_hopping "${hysteria2_port:-${MIHOMO_HY2_HOP_START}}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$MIHOMO_SERVICE" 2>/dev/null || true
    fi
    remove_ufw_port_rule "$anytls_port" tcp
    remove_ufw_port_rule "$shadowsocks_port" tcp
    remove_ufw_port_rule "$shadowsocks_port" udp
    rm -f /usr/local/bin/mihomo /etc/systemd/system/mihomo.service
    rm -rf "$MIHOMO_DIR"
    if command -v systemctl >/dev/null 2>&1 && ! systemctl daemon-reload; then
        warning "Mihomo 已删除，但 systemd 配置重载失败。"
    fi

    if command -v mihomo >/dev/null 2>&1; then
        warning "Mihomo 程序仍然存在，请检查是否由其他方式安装。"
    else
        success "Mihomo 与其配置已卸载。"
    fi

    pause
}

mihomo_menu(){
    while true; do
        header "Mihomo"
        menu_item "1" "安装 / 更新 Mihomo"
        menu_item "2" "查看 Mihomo 核心"
        menu_item "3" "查看 Mihomo 日志"
        menu_item "4" "安装 AnyTLS"
        menu_item "5" "卸载 AnyTLS"
        menu_item "6" "安装 Hysteria2"
        menu_item "7" "卸载 Hysteria2"
        menu_item "8" "安装 Shadowsocks"
        menu_item "9" "卸载 Shadowsocks"
        menu_item "10" "重启 Mihomo"
        menu_item "11" "卸载 Mihomo"
        echo
        menu_item "0" "返回主菜单"
        echo

        read -e -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_mihomo ;;
            2) show_mihomo_core ;;
            3) show_mihomo_logs ;;
            4) configure_mihomo_anytls ;;
            5) uninstall_mihomo_anytls ;;
            6) configure_mihomo_hysteria2 ;;
            7) uninstall_mihomo_hysteria2 ;;
            8) configure_mihomo_shadowsocks ;;
            9) uninstall_mihomo_shadowsocks ;;
            10) restart_mihomo ;;
            11) uninstall_mihomo ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}
