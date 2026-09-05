#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

install_ufw(){
    header "安装 UFW"

    if ! ensure_apt_package "ufw"; then
        pause
        return
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        error "UFW 安装完成，但未找到 ufw 命令。"
        pause
        return
    fi

    if ! ufw --force enable >/dev/null; then
        error "UFW 启用失败。"
        pause
        return
    fi

    success "UFW 已安装并启用。"
    pause
}

require_ufw(){
    if command -v ufw >/dev/null 2>&1; then
        return 0
    fi

    error "UFW 尚未安装，请先选择安装 UFW。"
    return 1
}

ufw_batch_add_port(){
    header "允许端口"
    local input
    local port

    if ! require_ufw; then
        pause
        return
    fi

    read -e -r -p "$(prompt_text "请输入要允许的端口（多个用空格分隔，输入 0 取消）: ")" input
    cancel_input "$input" && return
    [[ -z "$input" ]] && error "端口不能为空。" && pause && return
    reject_comma_separator "$input" || return 0

    for port in $(split_items "$input"); do
        valid_port "$port" || { error "端口无效: ${port}"; pause; return; }
    done

    for port in $(split_items "$input"); do
        if ufw allow "${port}/tcp" && ufw allow "${port}/udp"; then
            success "已允许端口: ${port}/tcp 和 ${port}/udp"
        else
            error "端口 ${port} 的 UFW 规则添加失败。"
        fi
    done

    pause
}

ufw_batch_delete_port(){
    header "删除端口"

    local input
    local status_output
    local index
    local display_index
    local record
    local line
    local rule_number
    local port_spec
    local record_port
    local protocol
    local comment
    local descriptor
    local details
    local -A seen_details=()
    local -a rule_records=()
    local -a ports=()
    local -a requested_indexes=()
    local -a delete_rule_numbers=()
    local -A selected_indexes=()
    local -A selected_ports=()

    if ! require_ufw; then
        pause
        return
    fi

    if ! status_output=$(ufw status numbered); then
        error "无法读取 UFW 端口规则。"
        pause
        return
    fi

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+(:[0-9]+)?)(/(tcp|udp))?([[:space:]]|$) ]]; then
            rule_number="${BASH_REMATCH[1]}"
            port_spec="${BASH_REMATCH[2]}"
            protocol="${BASH_REMATCH[5]:-all}"
            comment=""
            [[ "$line" == *"#"* ]] && comment=$(trim_edges "${line#*#}")
            rule_records+=("${rule_number}|${port_spec}|${protocol}|${comment}")
        fi
    done <<< "$status_output"

    if [[ "${#rule_records[@]}" -eq 0 ]]; then
        warning "当前没有可删除的数字端口规则。"
        pause
        return
    fi

    mapfile -t ports < <(
        printf '%s\n' "${rule_records[@]}" | cut -d '|' -f2 | sort -n -u
    )

    section "当前 UFW 端口" "$YELLOW"
    echo
    label " 端口 / 协议 / 注释"
    echo
    for index in "${!ports[@]}"; do
        port_spec="${ports[$index]}"
        details=""
        seen_details=()

        for record in "${rule_records[@]}"; do
            IFS='|' read -r rule_number record_port protocol comment <<< "$record"
            [[ "$record_port" == "$port_spec" ]] || continue

            descriptor="$protocol"
            [[ -n "$comment" ]] && descriptor+=" · ${comment}"
            if [[ -z "${seen_details[$descriptor]:-}" ]]; then
                seen_details["$descriptor"]=1
                details+="${details:+; }${descriptor}"
            fi
        done

        menu_item "$((index + 1))" "${port_spec}  ${details}"
    done

    echo
    read -e -r -p "$(prompt_text "请输入要删除的序号（多个用空格分隔，0 取消）: ")" input
    input=$(trim_edges "$input")
    cancel_input "$input" && return

    if [[ -z "$input" ]]; then
        error "序号不能为空。"
        pause
        return
    fi

    read -r -a requested_indexes <<< "$input"

    for display_index in "${requested_indexes[@]}"; do
        if [[ ! "$display_index" =~ ^[0-9]+$ ]] || \
           (( display_index < 1 || display_index > ${#ports[@]} )); then
            error "无效序号：${display_index}。多个序号请使用空格分隔。"
            pause
            return
        fi

        selected_indexes["$display_index"]=1
        selected_ports["${ports[$((display_index - 1))]}"]=1
    done

    for record in "${rule_records[@]}"; do
        IFS='|' read -r rule_number record_port protocol comment <<< "$record"
        if [[ -n "${selected_ports[$record_port]:-}" ]]; then
            delete_rule_numbers+=("$rule_number")
        fi
    done

    mapfile -t delete_rule_numbers < <(
        printf '%s\n' "${delete_rule_numbers[@]}" | sort -rn -u
    )

    for rule_number in "${delete_rule_numbers[@]}"; do
        if ! ufw --force delete "$rule_number" >/dev/null; then
            error "UFW 规则 ${rule_number} 删除失败。"
            pause
            return
        fi
    done

    for display_index in $(printf '%s\n' "${!selected_indexes[@]}" | sort -n); do
        port_spec="${ports[$((display_index - 1))]}"
        success "已删除端口 ${port_spec} 的 UFW 规则。"
    done

    pause
}

ufw_batch_add_ip(){
    header "允许 IP"
    local input
    local ip

    if ! require_ufw; then
        pause
        return
    fi

    read -e -r -p "$(prompt_text "请输入要允许的 IP/CIDR（多个用空格分隔，输入 0 取消）: ")" input
    cancel_input "$input" && return
    [[ -z "$input" ]] && error "IP 不能为空。" && pause && return
    reject_comma_separator "$input" || return 0

    for ip in $(split_items "$input"); do
        [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP: ${ip}" && pause && return
    done

    for ip in $(split_items "$input"); do
        if ufw allow from "$ip"; then
            success "已允许 IP/CIDR: ${ip}"
        else
            error "IP/CIDR ${ip} 的 UFW 规则添加失败。"
        fi
    done

    pause
}

ufw_batch_delete_ip(){
    header "删除 IP"
    local input
    local ip

    if ! require_ufw; then
        pause
        return
    fi

    read -e -r -p "$(prompt_text "请输入要删除的 IP/CIDR（多个用空格分隔，输入 0 取消）: ")" input
    cancel_input "$input" && return
    [[ -z "$input" ]] && error "IP 不能为空。" && pause && return
    reject_comma_separator "$input" || return 0

    for ip in $(split_items "$input"); do
        [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP: ${ip}" && pause && return
    done

    for ip in $(split_items "$input"); do
        if ufw --force delete allow from "$ip"; then
            success "已删除 IP/CIDR 规则: ${ip}"
        else
            error "IP/CIDR ${ip} 的 UFW 规则删除失败。"
        fi
    done

    pause
}

show_ufw_status(){
    header "UFW 状态"

    if ! require_ufw; then
        pause
        return
    fi

    if ! ufw status verbose; then
        error "无法读取 UFW 状态。"
    fi
    pause
}

uninstall_ufw(){
    header "卸载 UFW"
    warning "正在卸载 UFW..."

    if ! require_commands apt; then
        pause
        return
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw --force disable >/dev/null 2>&1 || true
    fi

    if ! apt purge -y ufw; then
        error "UFW 卸载失败。"
        pause
        return
    fi
    if ! apt autoremove -y; then
        warning "UFW 已卸载，但自动清理无用依赖失败。"
    fi

    success "UFW 已卸载。"
    pause
}

ufw_menu(){
    while true; do
        header "UFW 防火墙管理"
        menu_item "1" "安装 UFW"
        menu_item "2" "查看 UFW 状态"
        menu_item "3" "允许端口"
        menu_item "4" "删除端口"
        menu_item "5" "允许 IP"
        menu_item "6" "删除 IP"
        menu_item "7" "卸载 UFW"
        echo
        menu_item "0" "返回"
        echo
        read -e -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_ufw ;;
            2) show_ufw_status ;;
            3) ufw_batch_add_port ;;
            4) ufw_batch_delete_port ;;
            5) ufw_batch_add_ip ;;
            6) ufw_batch_delete_ip ;;
            7) uninstall_ufw ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}
