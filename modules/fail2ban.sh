#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

install_fail2ban(){
    header "安装 Fail2Ban"

    if ! require_commands systemctl awk sshd; then
        pause
        return
    fi

    if [[ ! -r /etc/ssh/sshd_config ]]; then
        error "未找到 SSHD 配置：/etc/ssh/sshd_config。"
        pause
        return
    fi

    if ! ensure_apt_package "fail2ban"; then
        pause
        return
    fi

    local ssh_port
    if ! ssh_port=$(current_ssh_port); then
        error "无法读取 SSHD 有效端口，Fail2Ban 配置未修改。"
        pause
        return 0
    fi

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 604800
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
maxretry = 3
bantime = 604800
EOF

    if ! systemctl enable fail2ban || ! systemctl restart fail2ban; then
        error "Fail2Ban 服务启动失败，请检查 systemctl status fail2ban。"
        pause
        return
    fi

    success "Fail2Ban 已安装并启动。"
    pause
}

require_fail2ban_client(){
    if command -v fail2ban-client >/dev/null 2>&1; then
        return 0
    fi

    error "Fail2Ban 尚未安装，请先选择安装 Fail2Ban。"
    return 1
}

show_fail2ban_status(){
    header "SSHD 状态"

    if ! require_fail2ban_client; then
        pause
        return
    fi

    if ! fail2ban-client status sshd; then
        error "无法获取 sshd jail 状态，请确认 Fail2Ban 服务已启动且 sshd jail 已启用。"
    fi
    pause
}

uninstall_fail2ban(){
    header "卸载 Fail2Ban"
    warning "正在卸载 Fail2Ban..."

    if ! require_commands apt; then
        pause
        return
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop fail2ban 2>/dev/null || true
        systemctl disable fail2ban 2>/dev/null || true
    fi

    if ! apt purge -y fail2ban; then
        error "Fail2Ban 卸载失败。"
        pause
        return
    fi
    if ! apt autoremove -y; then
        warning "Fail2Ban 已卸载，但自动清理无用依赖失败。"
    fi

    success "Fail2Ban 已卸载。"
    pause
}

fail2ban_unban_ip(){
    header "解封 SSHD IP"
    local ip

    if ! require_fail2ban_client; then
        pause
        return
    fi

    read -e -r -p "$(prompt_text "请输入要解封的 IP（输入 0 取消）: ")" ip
    cancel_input "$ip" && return

    if [[ -z "$ip" ]]; then
        error "IP 不能为空。"
        pause
        return
    fi

    if ! fail2ban-client set sshd unbanip "$ip"; then
        error "解封失败，请确认 Fail2Ban 服务已启动且 sshd jail 已启用。"
        pause
        return
    fi

    success "已从 sshd jail 解封 IP: ${ip}"
    pause
}

fail2ban_menu(){
    while true; do
        header "Fail2Ban 管理"
        menu_item "1" "安装 Fail2Ban"
        menu_item "2" "查看 SSHD 状态"
        menu_item "3" "解封 SSHD IP"
        menu_item "4" "卸载 Fail2Ban"
        echo
        menu_item "0" "返回"
        echo
        read -e -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_fail2ban ;;
            2) show_fail2ban_status ;;
            3) fail2ban_unban_ip ;;
            4) uninstall_fail2ban ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}
