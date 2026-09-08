#!/usr/bin/env bash
# Mihomo AnyTLS 入站配置脚本
# 说明：使用独立的 EC P-256 自签证书，并生成带证书指纹固定的 Mihomo 客户端配置。

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
CONFIG_FILE="${MIHOMO_DIR}/config.yaml"
PROTOCOL_CONFIG="${MIHOMO_DIR}/protocols/anytls.yaml"
CLIENT_FILE="${MIHOMO_DIR}/client/anytls.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
SELF_SIGNED_DIR="${MIHOMO_DIR}/certs/anytls-selfsigned"
CERT_FILE="${SELF_SIGNED_DIR}/server.crt"
KEY_FILE="${SELF_SIGNED_DIR}/private.key"
DOMAIN_FILE="${SELF_SIGNED_DIR}/domain"
SELF_SIGNED_DAYS="3650"
USERNAME="netkit"
CLIENT_FINGERPRINT="chrome"

PORT=""
PASSWORD=""
DOMAIN=""
SERVER_IP=""
CERT_FINGERPRINT=""
OLD_PORT=""
PROTOCOL_BACKUP=""
CONFIG_BACKUP=""

check_root(){
    if [[ "${EUID}" -ne 0 ]]; then
        error "请使用 root 用户运行此脚本。"
        exit 1
    fi
}

install_dependencies(){
    local missing=()
    local package

    for package in curl openssl coreutils iproute2; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            missing+=("$package")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        info "正在安装 Mihomo AnyTLS 环境依赖..."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
}

check_mihomo(){
    if ! command -v mihomo >/dev/null 2>&1 && [[ ! -x /usr/local/bin/mihomo ]]; then
        error "请先安装 Mihomo。"
        exit 1
    fi

    if [[ ! -x "${BUILD_CONFIG_SCRIPT}" ]]; then
        error "未找到配置构建脚本：${BUILD_CONFIG_SCRIPT}"
        exit 1
    fi
}

prompt_yes_no(){
    local message="$1"
    local answer=""

    while true; do
        read -e -r -p "${message} [y/N]: " answer
        case "${answer}" in
            ""|[Nn]) return 1 ;;
            [Yy]) return 0 ;;
            *) warning "请输入 y 或 n，直接回车默认为 n。" ;;
        esac
    done
}

normalize_anytls_domain(){
    local host="$1"

    host="${host#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    host="${host%.}"

    if [[ -z "${host}" || "${host}" == *:* ]]; then
        return 1
    fi
    if [[ ! "${host}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])$ ]]; then
        return 1
    fi

    printf '%s' "${host,,}"
}

certificate_material_valid(){
    local cert_file="$1"
    local key_file="$2"
    local domain="$3"
    local cert_public_key=""
    local key_public_key=""

    [[ -r "${cert_file}" && -r "${key_file}" && -n "${domain}" ]] || return 1
    openssl x509 -in "${cert_file}" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "${key_file}" -noout >/dev/null 2>&1 || return 1
    openssl x509 -in "${cert_file}" -noout -checkend 0 >/dev/null 2>&1 || return 1
    openssl x509 -in "${cert_file}" -noout -checkhost "${domain}" >/dev/null 2>&1 || return 1

    cert_public_key="$(openssl x509 -in "${cert_file}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_public_key="$(openssl pkey -in "${key_file}" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    [[ -n "${cert_public_key}" && "${cert_public_key}" == "${key_public_key}" ]]
}

generate_self_signed_certificate(){
    local temp_dir=""
    local temp_cert=""
    local temp_key=""
    local temp_domain=""

    install -d -m 700 "${SELF_SIGNED_DIR}"
    temp_dir="$(mktemp -d "${SELF_SIGNED_DIR}/.generate.XXXXXX")"
    temp_cert="${temp_dir}/server.crt"
    temp_key="${temp_dir}/private.key"
    temp_domain="${temp_dir}/domain"

    info "正在生成 EC P-256 自签证书（有效期 ${SELF_SIGNED_DAYS} 天）..."
    if ! openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -nodes -sha256 -days "${SELF_SIGNED_DAYS}" \
        -keyout "${temp_key}" \
        -out "${temp_cert}" \
        -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1; then
        rm -f "${temp_cert}" "${temp_key}" "${temp_domain}"
        rmdir "${temp_dir}" >/dev/null 2>&1 || true
        error "自签证书生成失败。"
        exit 1
    fi
    printf '%s\n' "${DOMAIN}" > "${temp_domain}"

    if ! certificate_material_valid "${temp_cert}" "${temp_key}" "${DOMAIN}"; then
        rm -f "${temp_cert}" "${temp_key}" "${temp_domain}"
        rmdir "${temp_dir}" >/dev/null 2>&1 || true
        error "生成的自签证书验证失败。"
        exit 1
    fi

    install -m 644 "${temp_cert}" "${CERT_FILE}.new"
    install -m 600 "${temp_key}" "${KEY_FILE}.new"
    install -m 600 "${temp_domain}" "${DOMAIN_FILE}.new"
    mv -f "${CERT_FILE}.new" "${CERT_FILE}"
    mv -f "${KEY_FILE}.new" "${KEY_FILE}"
    mv -f "${DOMAIN_FILE}.new" "${DOMAIN_FILE}"
    rm -f "${temp_cert}" "${temp_key}" "${temp_domain}"
    rmdir "${temp_dir}" >/dev/null 2>&1 || true
}

check_certificate(){
    local saved_domain=""

    if [[ ! -r "${CERT_FILE}" || ! -r "${KEY_FILE}" || ! -r "${DOMAIN_FILE}" ]]; then
        error "未找到可用的 AnyTLS 自签证书。"
        exit 1
    fi

    saved_domain="$(tr -d '\r\n' < "${DOMAIN_FILE}")"
    if [[ "${saved_domain}" != "${DOMAIN}" ]] || ! certificate_material_valid "${CERT_FILE}" "${KEY_FILE}" "${DOMAIN}"; then
        error "AnyTLS 自签证书、私钥或域名校验失败。"
        exit 1
    fi

    CERT_FINGERPRINT="$(openssl x509 -in "${CERT_FILE}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//')"
    if [[ ! "${CERT_FINGERPRINT}" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]]; then
        error "无法计算自签证书 SHA-256 指纹。"
        exit 1
    fi

    success "AnyTLS TLS 证书有效：${DOMAIN}"
}

prepare_self_signed_certificate(){
    local input=""
    local normalized=""
    local saved_domain=""
    local has_existing=0

    while true; do
        read -e -r -p "请输入 AnyTLS 自签证书域名 / SNI（无需 DNS 解析，输入 0 取消）：" input
        if [[ "${input}" == "0" ]]; then
            warning "已取消。"
            exit "${INPUT_CANCEL_STATUS}"
        fi
        if normalized="$(normalize_anytls_domain "${input}")"; then
            DOMAIN="${normalized}"
            break
        fi
        warning "域名格式无效，请只填写域名，不要填写端口或路径。"
    done

    if [[ -e "${CERT_FILE}" || -e "${KEY_FILE}" || -e "${DOMAIN_FILE}" ]]; then
        has_existing=1
    fi
    if [[ -r "${DOMAIN_FILE}" ]]; then
        saved_domain="$(tr -d '\r\n' < "${DOMAIN_FILE}")"
    fi

    if [[ "${saved_domain}" == "${DOMAIN}" ]] && certificate_material_valid "${CERT_FILE}" "${KEY_FILE}" "${DOMAIN}"; then
        success "复用现有 AnyTLS 自签证书：${DOMAIN}"
    else
        if (( has_existing == 1 )); then
            warning "现有 AnyTLS 自签证书不可复用；重新生成后指纹会变化，客户端必须同步更新。"
            if ! prompt_yes_no "是否重新生成自签证书？"; then
                warning "已取消。"
                exit "${INPUT_CANCEL_STATUS}"
            fi
        fi
        generate_self_signed_certificate
        success "AnyTLS 自签证书生成成功：${DOMAIN}"
    fi

    check_certificate
}

get_server_ip(){
    SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "${SERVER_IP}" ]]; then
        SERVER_IP="$(curl -6fsS --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
    fi
    if [[ -z "${SERVER_IP}" ]]; then
        SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
    fi
    [[ -n "${SERVER_IP}" ]] || SERVER_IP="未知"
}

prompt_port(){
    local input=""
    local candidate=""
    local prompt="端口（50001-65535，留空随机，输入 0 取消）: "

    if [[ -n "${OLD_PORT}" ]]; then
        prompt="端口（50001-65535，留空复用 ${OLD_PORT}，输入 0 取消）: "
    fi

    while true; do
        read -e -r -p "$(prompt_text "${prompt}")" input
        if [[ "${input}" == "0" ]]; then
            warning "已取消。"
            exit "${INPUT_CANCEL_STATUS}"
        fi

        if [[ -z "${input}" && -n "${OLD_PORT}" ]]; then
            PORT="${OLD_PORT}"
            return 0
        fi
        if [[ -z "${input}" ]]; then
            PORT="$(random_available_port 50001 65535)" || exit 1
            return 0
        fi
        if ! valid_port "${input}" || (( 10#${input} < 50001 || 10#${input} > 65535 )); then
            warning "端口必须位于 50001-65535。"
            continue
        fi

        candidate="$((10#${input}))"
        if [[ "${candidate}" != "${OLD_PORT}" ]] && port_in_use "${candidate}"; then
            warning "端口已被占用：${candidate}"
            continue
        fi
        PORT="${candidate}"
        return 0
    done
}

backup_configs(){
    if [[ -f "${PROTOCOL_CONFIG}" ]]; then
        PROTOCOL_BACKUP="${PROTOCOL_CONFIG}.bak.$$"
        cp -a "${PROTOCOL_CONFIG}" "${PROTOCOL_BACKUP}"
    fi
    if [[ -f "${CONFIG_FILE}" ]]; then
        CONFIG_BACKUP="${CONFIG_FILE}.bak.$$"
        cp -a "${CONFIG_FILE}" "${CONFIG_BACKUP}"
    fi
}

rollback_config(){
    if [[ -n "${PROTOCOL_BACKUP}" && -f "${PROTOCOL_BACKUP}" ]]; then
        mv -f "${PROTOCOL_BACKUP}" "${PROTOCOL_CONFIG}"
    else
        rm -f "${PROTOCOL_CONFIG}"
    fi

    if [[ -n "${CONFIG_BACKUP}" && -f "${CONFIG_BACKUP}" ]]; then
        mv -f "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    else
        rm -f "${CONFIG_FILE}"
    fi
}

write_protocol_config(){
    local yaml_password=""
    local yaml_cert=""
    local yaml_key=""

    yaml_password="$(yaml_quote "${PASSWORD}")"
    yaml_cert="$(yaml_quote "${CERT_FILE}")"
    yaml_key="$(yaml_quote "${KEY_FILE}")"

    info "正在写入 Mihomo AnyTLS Listener..."
    umask 077
    mkdir -p "${MIHOMO_DIR}/protocols" "${MIHOMO_DIR}/client"
    {
        echo "  - name: anytls-in"
        echo "    type: anytls"
        echo "    port: ${PORT}"
        echo "    listen: 0.0.0.0"
        echo "    users:"
        echo "      ${USERNAME}: ${yaml_password}"
        echo "    certificate: ${yaml_cert}"
        echo "    private-key: ${yaml_key}"
    } > "${PROTOCOL_CONFIG}"
    chmod 600 "${PROTOCOL_CONFIG}"
}

apply_config(){
    local new_firewall_rule=0

    if ! bash "${BUILD_CONFIG_SCRIPT}"; then
        rollback_config
        error "Mihomo AnyTLS 配置验证失败，已恢复原配置。"
        exit 1
    fi

    if command -v ufw >/dev/null 2>&1; then
        if [[ "${PORT}" != "${OLD_PORT}" ]]; then
            new_firewall_rule=1
        fi
        ufw allow "${PORT}/tcp" comment "Mihomo AnyTLS TCP" >/dev/null
    fi

    info "正在启动 Mihomo..."
    if ! systemctl restart mihomo || ! systemctl is-active --quiet mihomo; then
        rollback_config
        systemctl restart mihomo 2>/dev/null || true
        if (( new_firewall_rule == 1 )); then
            remove_ufw_port_rule "${PORT}" tcp
        fi
        error "Mihomo 启动失败，已恢复原配置。"
        journalctl -u mihomo -n 20 --no-pager 2>/dev/null || true
        exit 1
    fi

    if [[ -n "${OLD_PORT}" && "${OLD_PORT}" != "${PORT}" ]]; then
        remove_ufw_port_rule "${OLD_PORT}" tcp
    fi
}

write_client_info(){
    local link_host=""
    local yaml_server=""
    local yaml_password=""
    local yaml_domain=""
    local yaml_fingerprint=""
    local anytls_link=""

    link_host="$(uri_host "${SERVER_IP}")"
    yaml_server="$(yaml_quote "${SERVER_IP}")"
    yaml_password="$(yaml_quote "${PASSWORD}")"
    yaml_domain="$(yaml_quote "${DOMAIN}")"
    yaml_fingerprint="$(yaml_quote "${CERT_FINGERPRINT}")"
    anytls_link="anytls://${PASSWORD}@${link_host}:${PORT}/?sni=${DOMAIN}&insecure=1#Mihomo%20AnyTLS"

    umask 077
    {
        echo "AnyTLS Link:"
        echo "${anytls_link}"
        echo
        echo "Mihomo / Clash:"
        echo "- name: Mihomo AnyTLS"
        echo "  type: anytls"
        echo "  server: ${yaml_server}"
        echo "  port: ${PORT}"
        echo "  password: ${yaml_password}"
        echo "  client-fingerprint: ${CLIENT_FINGERPRINT}"
        echo "  udp: true"
        echo "  sni: ${yaml_domain}"
        echo "  alpn:"
        echo "    - h2"
        echo "    - http/1.1"
        echo "  skip-cert-verify: true"
        echo "  fingerprint: ${yaml_fingerprint}"
    } > "${CLIENT_FILE}"
    chmod 600 "${CLIENT_FILE}"
}

cleanup_backups(){
    [[ -z "${PROTOCOL_BACKUP}" ]] || rm -f "${PROTOCOL_BACKUP}"
    [[ -z "${CONFIG_BACKUP}" ]] || rm -f "${CONFIG_BACKUP}"
}

show_result(){
    local anytls_link=""
    anytls_link="$(sed -n '/^AnyTLS Link:$/ {n;p;q;}' "${CLIENT_FILE}")"

    banner "Mihomo AnyTLS 安装成功" "${GREEN}"
    kv "Server IP   :" "${SERVER_IP}"
    kv "Domain      :" "${DOMAIN}"
    kv "Port        :" "${PORT}/TCP"
    kv "Password    :" "${PASSWORD}"
    kv "UDP         :" "已开启（UDP over TCP）"
    kv "Certificate :" "自签证书 + SHA-256 指纹固定"
    kv "Fingerprint :" "${CERT_FINGERPRINT}"
    echo
    label " AnyTLS Link"
    value "${anytls_link}"
    echo
    path_kv "主配置文件      :" "${CONFIG_FILE}"
    path_kv "协议配置文件    :" "${PROTOCOL_CONFIG}"
    path_kv "连接信息文件    :" "${CLIENT_FILE}"
    path_kv "TLS 证书        :" "${CERT_FILE}"
    echo
    label " Mihomo / Clash YAML"
    echo
    sed -n '/^Mihomo \/ Clash:/,$p' "${CLIENT_FILE}" | tail -n +2 | while IFS= read -r line; do
        value "${line}"
    done
    echo
    divider "${GREEN}"
}

main(){
    check_root
    banner "安装 Mihomo AnyTLS"
    install_dependencies
    check_mihomo
    mkdir -p "${MIHOMO_DIR}/protocols" "${MIHOMO_DIR}/client"
    OLD_PORT="$(yaml_number_field "${PROTOCOL_CONFIG}" "port")"
    prompt_port
    prepare_self_signed_certificate
    get_server_ip
    info "自签模式使用 VPS IP 连接；SNI ${DOMAIN} 无需配置 A/AAAA 记录。"
    PASSWORD="$(openssl rand -hex 32)"
    if [[ -z "${PASSWORD}" ]]; then
        error "AnyTLS 密码生成失败。"
        exit 1
    fi
    backup_configs
    write_protocol_config
    apply_config
    write_client_info
    cleanup_backups
    show_result
}

main "$@"
