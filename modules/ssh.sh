#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

SSHD_CONFIG_FILE="/etc/ssh/sshd_config"

require_sshd_environment(){
    if ! require_commands awk sed systemctl sshd mktemp; then
        return 1
    fi

    if [[ ! -r "$SSHD_CONFIG_FILE" ]]; then
        error "未找到 SSHD 配置：${SSHD_CONFIG_FILE}。"
        return 1
    fi

    return 0
}

sshd_effective_config(){
    local config_file="${1:-$SSHD_CONFIG_FILE}"

    sshd -T -f "$config_file"
}

sshd_config_field(){
    local field="${1,,}"
    awk -v field="$field" '
        tolower($1) == field && !seen[$2]++ {
            printf "%s%s", separator, $2
            separator=","
            found=1
        }
        END {
            if (!found) exit 1
            print ""
        }
    '
}

current_ssh_port(){
    local effective

    if ! effective=$(sshd_effective_config); then
        return 1
    fi
    sshd_config_field port <<< "$effective"
}

restart_ssh_service(){
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        systemctl restart ssh && return 0
    fi
    if systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        systemctl restart sshd && return 0
    fi

    return 1
}

set_sshd_options(){
    local new_config=""
    local option key expected actual effective temp_config

    for option in "$@"; do
        new_config+="${option%%=*} ${option#*=}"$'\n'
    done

    if ! temp_config=$(mktemp "${SSHD_CONFIG_FILE}.netkit.XXXXXX"); then
        return 1
    fi
    # 在 Include 之前写入全局选项；只清理主文件的同名全局项，保留 Match 块。
    if ! cp -p "$SSHD_CONFIG_FILE" "$temp_config" || \
       ! awk -v CONFIG="$new_config" '
BEGIN {
    count=split(CONFIG, lines, "\n")
    for (i=1; i<=count; i++) {
        split(lines[i], fields, /[[:space:]]+/)
        keys[tolower(fields[1])]=1
    }
    printf "%s", CONFIG
}
{
    key=tolower($1)
    if (key == "match") in_match=1
    if (!in_match && key in keys) next
    print
}
' "$SSHD_CONFIG_FILE" > "$temp_config"; then
        rm -f -- "$temp_config"
        return 1
    fi

    if ! sshd -t -f "$temp_config" || ! effective=$(sshd_effective_config "$temp_config"); then
        error "SSHD 配置校验失败，原配置未修改。"
        rm -f -- "$temp_config"
        return 1
    fi
    for option in "$@"; do
        key="${option%%=*}"
        expected="${option#*=}"
        actual=$(sshd_config_field "$key" <<< "$effective") || actual=""
        # OpenSSH -T 可能使用旧名称输出这个等价选项。
        if [[ "${key,,}" == permitrootlogin ]]; then
            [[ "$actual" != without-password ]] || actual=prohibit-password
            [[ "$expected" != without-password ]] || expected=prohibit-password
        fi
        if [[ "$actual" != "$expected" ]]; then
            error "${key} 校验不一致：期望 ${expected}，实际 ${actual:-未读取到}。请检查 Include 或重复配置；原配置未修改。"
            rm -f -- "$temp_config"
            return 1
        fi
    done

    if ! mv -- "$temp_config" "$SSHD_CONFIG_FILE"; then
        rm -f -- "$temp_config"
        return 1
    fi
}

show_ssh_status(){
    header "SSH 状态"

    if ! require_sshd_environment; then
        pause
        return
    fi

    local ssh_port
    local password_auth
    local pubkey_auth
    local root_login
    local service_status
    local key_status

    local effective
    if ! effective=$(sshd_effective_config); then
        error "无法读取 SSHD 有效配置，请先检查配置错误。"
        pause
        return 0
    fi
    ssh_port=$(sshd_config_field port <<< "$effective") || ssh_port="未知"
    password_auth=$(sshd_config_field passwordauthentication <<< "$effective") || password_auth="未知"
    pubkey_auth=$(sshd_config_field pubkeyauthentication <<< "$effective") || pubkey_auth="未知"
    root_login=$(sshd_config_field permitrootlogin <<< "$effective") || root_login="未知"
    info "以下为 sshd 解析后的全局配置（含 Include）；Match 条件可能覆盖登录策略。"
    service_status=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo "unknown")

    if [[ -s /root/.ssh/authorized_keys ]]; then
        key_status="已设置"
    else
        key_status="未设置"
    fi

    kv "SSH 端口              :" "$ssh_port"
    kv "SSH 服务              :" "$service_status"
    kv "Root 密钥             :" "$key_status"
    kv "密码登录              :" "$password_auth"
    kv "公钥登录              :" "$pubkey_auth"
    kv "Root 登录策略         :" "$root_login"

    pause
}

set_ssh_port(){
    header "设置 SSH 端口"

    if ! require_sshd_environment || ! require_commands ss; then
        pause
        return
    fi

    read -e -r -p "$(prompt_text "请输入新的 SSH 端口（输入 0 取消）: ")" ssh_port
    cancel_input "$ssh_port" && return

    if ! valid_port "$ssh_port"; then
        error "SSH 端口无效。"
        pause
        return
    fi

    local old_ssh_port
    if ! old_ssh_port=$(current_ssh_port); then
        error "无法读取 SSHD 有效端口，原配置未修改。"
        pause
        return 0
    fi
    if [[ "$old_ssh_port" == *,* ]]; then
        error "当前配置了多个 SSH 端口（${old_ssh_port}），请先手动整理端口配置。"
        pause
        return 0
    fi

    if [[ "$ssh_port" != "$old_ssh_port" ]] && \
       ss -ltnH | awk '{print $4}' | grep -q ":${ssh_port}$"; then
        warning "端口可能已被占用，请确认后再试。"
        pause
        return
    fi

    info "正在设置 SSH 端口..."
    if ! set_sshd_options "Port=${ssh_port}"; then
        error "SSHD 配置写入失败。"
        pause
        return
    fi

    if command -v ufw >/dev/null 2>&1; then
        if ! ufw allow "${ssh_port}/tcp" comment "SSH" >/dev/null; then
            error "SSH 新端口的 UFW 规则添加失败，SSH 服务未重启。"
            pause
            return
        fi
        if [[ "$ssh_port" != "$old_ssh_port" ]]; then
            ufw delete allow "${old_ssh_port}/tcp" >/dev/null 2>&1 || true
            if [[ "$old_ssh_port" == "22" ]]; then
                ufw delete allow OpenSSH >/dev/null 2>&1 || true
            fi
        fi
    fi

    if ! restart_ssh_service; then
        error "SSH 服务重启失败，请检查 SSHD 配置和服务状态。"
        pause
        return
    fi

    success "SSH 端口已设置为 ${ssh_port}，防火墙规则已更新。"
    pause
}

set_ssh_key(){
    local public_key
    local key_dir="/root/.ssh"
    local config_file="$SSHD_CONFIG_FILE"
    local temp_key backup_dir
    local had_keys=0
    local restored=1

    header "设置 SSH 密钥"

    if ! require_sshd_environment || ! require_commands ssh-keygen sshd mktemp; then
        pause
        return 0
    fi

    read -e -r -p "$(prompt_text "请输入 SSH 公钥（输入 0 取消）: ")" public_key
    public_key=$(trim_edges "$public_key")
    cancel_input "$public_key" && return

    if [[ -z "$public_key" ]]; then
        error "SSH 公钥不能为空。"
        pause
        return 0
    fi

    # 只接受单行 OpenSSH 公钥，避免将私钥或其他可解析文件当作公钥。
    if [[ ! "$public_key" =~ ^(ssh-|ecdsa-|sk-)[^[:space:]]+[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]]; then
        error "SSH 公钥格式无效，请粘贴完整的单行 OpenSSH 公钥。"
        pause
        return 0
    fi

    if ! temp_key=$(mktemp); then
        error "无法创建公钥校验临时文件。"
        pause
        return 0
    fi
    if ! printf '%s\n' "$public_key" > "$temp_key" || \
       ! ssh-keygen -l -f "$temp_key" >/dev/null 2>&1; then
        rm -f -- "$temp_key"
        error "SSH 公钥无效或不完整，现有密钥和登录设置未修改。"
        pause
        return 0
    fi
    rm -f -- "$temp_key"

    if ! mkdir -p "$key_dir" || ! chmod 700 "$key_dir" || \
       ! backup_dir=$(mktemp -d "${key_dir}/.netkit-key-backup.XXXXXX"); then
        error "无法创建 SSH 密钥备份目录。"
        pause
        return 0
    fi
    [[ -e "${key_dir}/authorized_keys" ]] && had_keys=1
    if ! cp -p "$config_file" "${backup_dir}/sshd_config" || \
       { (( had_keys == 1 )) && ! cp -p "${key_dir}/authorized_keys" "${backup_dir}/authorized_keys"; }; then
        error "SSH 配置备份失败，现有密钥和登录设置未修改。"
        pause
        return 0
    fi

    # 保留已有公钥；即使新密钥尚未在另一终端验证，旧密钥仍可登录。
    if ! { grep -qxF -- "$public_key" "${key_dir}/authorized_keys" 2>/dev/null ||
           printf '\n%s\n' "$public_key" >> "${key_dir}/authorized_keys"; } || \
       ! chmod 600 "${key_dir}/authorized_keys" || \
       ! set_sshd_options \
        "PasswordAuthentication=no" \
        "PubkeyAuthentication=yes" \
        "PermitRootLogin=prohibit-password" || \
       ! sshd -t -f "$config_file" || ! restart_ssh_service; then
        cp -p "${backup_dir}/sshd_config" "$config_file" || restored=0
        if (( had_keys == 1 )); then
            cp -p "${backup_dir}/authorized_keys" "${key_dir}/authorized_keys" || restored=0
        else
            rm -f -- "${key_dir}/authorized_keys" || restored=0
        fi
        if (( restored == 1 )); then
            error "SSH 密钥设置失败，已恢复原密钥和 SSHD 配置。"
            if ! restart_ssh_service; then
                error "原配置已恢复，但 SSH 服务重启失败，请检查服务状态。"
            fi
        else
            error "SSH 密钥设置失败，自动恢复不完整，请使用备份恢复。"
        fi
        path_kv "备份目录:" "$backup_dir"
        pause
        return 0
    fi

    success "SSH 公钥已校验并添加，原有公钥已保留，全局密码登录配置已关闭。"
    path_kv "备份目录:" "$backup_dir"
    pause
}

ssh_menu(){
    while true; do
        header "SSH 端口与密钥管理"
        menu_item "1" "设置 SSH 端口"
        menu_item "2" "设置 SSH 密钥"
        menu_item "3" "查看 SSH 状态"
        echo
        menu_item "0" "返回"
        echo
        read -e -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) set_ssh_port ;;
            2) set_ssh_key ;;
            3) show_ssh_status ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}
