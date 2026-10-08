#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

readonly SCRIPT_NAME="${0##*/}"
readonly V2BX_VERSION="v1.1.202609251427"
readonly RELEASE_BASE="https://github.com/Shannon-x/V2bX/releases/download"
readonly INSTALL_DIR="/usr/local/V2bX"
readonly CONFIG_DIR="/etc/V2bX"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly DNS_FILE="${CONFIG_DIR}/dns.json"
readonly OUTBOUND_FILE="${CONFIG_DIR}/custom_outbound.json"
readonly ROUTE_FILE="${CONFIG_DIR}/route.json"
readonly SERVICE_FILE="/etc/systemd/system/v2bx.service"
readonly NOTIFY_CONFIG_FILE="${V2BX_NOTIFY_FILE:-/root/v2bx-notify.conf}"

ARCHIVE_FILE=""
PROBE_FILE=""
CONFIG_TMP=""
OUTBOUND_TMP=""
ROUTE_TMP=""
CURRENT_STEP="初始化"
LAST_ERROR=""
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-465}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-${SMTP_PASS:-}}"
SMTP_FROM="${SMTP_FROM:-${SMTP_USER}}"
SMTP_TO="${SMTP_TO:-}"
SMTP_SECURITY="${SMTP_SECURITY:-smtps}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-${TELEGRAM_ID:-}}"

log() {
    printf '[V2bX] %s\n' "$*"
}

warn() {
    printf '[V2bX] 警告: %s\n' "$*" >&2
}

die() {
    LAST_ERROR="$*"
    printf '[V2bX] 错误: %s\n' "$*" >&2
    exit 1
}

load_notification_config() {
    local file_mode

    if [[ -r "${NOTIFY_CONFIG_FILE}" ]]; then
        file_mode="$(stat -c '%a' "${NOTIFY_CONFIG_FILE}")"
        if (( (8#${file_mode} & 077) != 0 )); then
            warn "通知配置权限为 ${file_mode}，建议执行: chmod 600 '${NOTIFY_CONFIG_FILE}'"
        fi
        # shellcheck disable=SC1090
        source "${NOTIFY_CONFIG_FILE}"
        log "已载入失败通知配置 ${NOTIFY_CONFIG_FILE}"
    fi

    SMTP_HOST="${SMTP_HOST:-}"
    SMTP_PORT="${SMTP_PORT:-465}"
    SMTP_USER="${SMTP_USER:-}"
    SMTP_PASSWORD="${SMTP_PASSWORD:-${SMTP_PASS:-}}"
    SMTP_FROM="${SMTP_FROM:-${SMTP_USER}}"
    SMTP_TO="${SMTP_TO:-}"
    SMTP_SECURITY="${SMTP_SECURITY:-smtps}"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-${TELEGRAM_ID:-}}"
}

build_failure_message() {
    local status="$1"
    local host_name
    local failure_time

    host_name="$(hostname 2>/dev/null || printf 'unknown')"
    failure_time="$(date '+%Y-%m-%d %H:%M:%S %z')"
    cat <<EOF
V2bX 自动对接失败

时间: ${failure_time}
主机: ${host_name}
面板: ${PANEL_URL:-尚未读取}
节点 ID: ${NODE_ID:-尚未读取}
当前步骤: ${CURRENT_STEP}
退出码: ${status}
错误: ${LAST_ERROR:-未知错误，请查看 systemd/开机日志}
EOF
}

curl_config_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    printf '"%s"' "${value}"
}

send_smtp_notification() {
    local message="$1"
    local smtp_url
    local message_file
    local config_file
    local curl_status

    case "${SMTP_SECURITY,,}" in
        smtps|ssl)
            smtp_url="smtps://${SMTP_HOST}:${SMTP_PORT}"
            ;;
        starttls|tls)
            smtp_url="smtp://${SMTP_HOST}:${SMTP_PORT}"
            ;;
        none|plain)
            smtp_url="smtp://${SMTP_HOST}:${SMTP_PORT}"
            ;;
        *)
            warn "不支持 SMTP_SECURITY=${SMTP_SECURITY}，请使用 smtps、starttls 或 none。"
            return 1
            ;;
    esac

    message_file="$(mktemp)"
    config_file="$(mktemp)"
    chmod 0600 "${message_file}" "${config_file}"
    {
        printf 'From: %s\r\n' "${SMTP_FROM}"
        printf 'To: %s\r\n' "${SMTP_TO}"
        printf 'Subject: [V2bX] deployment failed on %s\r\n' "$(hostname 2>/dev/null || printf 'unknown')"
        printf 'Date: %s\r\n' "$(date -R)"
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n\r\n'
        printf '%s\r\n' "${message}"
    } >"${message_file}"
    {
        printf 'url = '; curl_config_quote "${smtp_url}"; printf '\n'
        printf 'user = '; curl_config_quote "${SMTP_USER}:${SMTP_PASSWORD}"; printf '\n'
        printf 'mail-from = '; curl_config_quote "${SMTP_FROM}"; printf '\n'
        printf 'mail-rcpt = '; curl_config_quote "${SMTP_TO}"; printf '\n'
        printf 'upload-file = '; curl_config_quote "${message_file}"; printf '\n'
        printf 'fail\nsilent\nshow-error\nconnect-timeout = 15\nmax-time = 45\n'
        if [[ "${SMTP_SECURITY,,}" != "none" && "${SMTP_SECURITY,,}" != "plain" ]]; then
            printf 'ssl-reqd\n'
        fi
    } >"${config_file}"

    curl --config "${config_file}"
    curl_status=$?
    rm -f -- "${config_file}"
    rm -f -- "${message_file}"
    return "${curl_status}"
}

send_telegram_notification() {
    local message="$1"
    local config_file
    local curl_status

    config_file="$(mktemp)"
    chmod 0600 "${config_file}"
    {
        printf 'url = '
        curl_config_quote "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        printf '\nrequest = "POST"\nfail\nsilent\nshow-error\nconnect-timeout = 15\nmax-time = 30\n'
    } >"${config_file}"

    curl --config "${config_file}" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" >/dev/null
    curl_status=$?
    rm -f -- "${config_file}"
    return "${curl_status}"
}

send_failure_notifications() {
    local status="$1"
    local message

    if [[ -z "${SMTP_HOST}${SMTP_USER}${SMTP_PASSWORD}${SMTP_TO}${TELEGRAM_BOT_TOKEN}${TELEGRAM_CHAT_ID}" ]]; then
        return
    fi

    if ! command -v curl >/dev/null 2>&1; then
        warn "系统没有 curl，无法发送失败通知。"
        return
    fi

    message="$(build_failure_message "${status}")"

    if [[ -n "${SMTP_HOST}" && -n "${SMTP_USER}" && -n "${SMTP_PASSWORD}" &&
          -n "${SMTP_FROM}" && -n "${SMTP_TO}" ]]; then
        if send_smtp_notification "${message}"; then
            log "失败通知邮件已发送到 ${SMTP_TO}"
        else
            warn "SMTP 失败通知发送失败。"
        fi
    elif [[ -n "${SMTP_HOST}${SMTP_USER}${SMTP_PASSWORD}${SMTP_TO}" ]]; then
        warn "SMTP 配置不完整，未发送邮件。"
    fi

    if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
        if send_telegram_notification "${message}"; then
            log "Telegram 失败通知已发送。"
        else
            warn "Telegram 失败通知发送失败。"
        fi
    elif [[ -n "${TELEGRAM_BOT_TOKEN}${TELEGRAM_CHAT_ID}" ]]; then
        warn "Telegram 配置不完整，未发送消息。"
    fi
}

cleanup() {
    if [[ -n "${ARCHIVE_FILE}" && -f "${ARCHIVE_FILE}" ]]; then
        rm -f -- "${ARCHIVE_FILE}"
    fi
    if [[ -n "${PROBE_FILE}" && -f "${PROBE_FILE}" ]]; then
        rm -f -- "${PROBE_FILE}"
    fi
    if [[ -n "${CONFIG_TMP}" && -f "${CONFIG_TMP}" ]]; then
        rm -f -- "${CONFIG_TMP}"
    fi
    if [[ -n "${OUTBOUND_TMP}" && -f "${OUTBOUND_TMP}" ]]; then
        rm -f -- "${OUTBOUND_TMP}"
    fi
    if [[ -n "${ROUTE_TMP}" && -f "${ROUTE_TMP}" ]]; then
        rm -f -- "${ROUTE_TMP}"
    fi
}

on_exit() {
    local status="$1"

    trap - ERR EXIT
    set +e
    cleanup
    if (( status != 0 )); then
        send_failure_notifications "${status}"
    fi
    exit "${status}"
}

on_error() {
    local line="$1"
    local code="$2"
    LAST_ERROR="第 ${line} 行执行失败（退出码 ${code}）"
    printf '[V2bX] 错误: 第 %s 行执行失败（退出码 %s）。\n' "${line}" "${code}" >&2
    exit "${code}"
}

trap 'on_exit "$?"' EXIT
trap 'on_error "${LINENO}" "$?"' ERR

usage() {
    cat <<EOF
用法:
  sudo ./${SCRIPT_NAME} <面板地址> <通信密钥> <节点ID> [API版本]

示例:
  sudo ./${SCRIPT_NAME} "https://dashboard.example.com" "uuid" 12

固定内核版本: ${V2BX_VERSION}（不查询最新版，不自动切换版本）

可选参数和环境变量:
  API版本             1（默认，VLESS/VMess 等独立节点）或 2（v2node）
  NODE_TYPE           节点类型，默认 vless
  GITHUB_PROXY_PREFIX GitHub 下载代理前缀，例如 https://ghfast.top/
  CUSTOM_OUTBOUND_FILE
                      仓库外的自定义出站 JSON 文件（推荐 root 所有、权限 600）
  V2BX_NOTIFY_FILE    失败通知配置文件，默认 /root/v2bx-notify.conf

失败通知:
  SMTP 和 Telegram 均为可选；配置完整的渠道会在部署失败时自动发送。
  通知内容不包含面板通信密钥、SMTP 密码或出站节点密码。

无交互开机脚本示例:
  sudo env CUSTOM_OUTBOUND_FILE=/root/v2bx-outbound.json \\
    ./${SCRIPT_NAME} "https://dashboard.example.com" "uuid" 12
EOF
}

load_notification_config

[[ "${EUID}" -eq 0 ]] || die "必须使用 root 用户运行（请在命令前加 sudo）。"
if (( $# < 3 || $# > 4 )); then
    usage
    exit 1
fi

PANEL_URL="${1%/}"
PANEL_KEY="$2"
NODE_ID="$3"
API_VERSION="${4:-${API_VERSION:-1}}"
NODE_TYPE="${NODE_TYPE:-vless}"
GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-}"
CUSTOM_OUTBOUND_FILE="${CUSTOM_OUTBOUND_FILE:-}"

[[ "${PANEL_URL}" =~ ^https?://[^[:space:]]+$ ]] ||
    die "面板地址必须是完整的 http:// 或 https:// URL。"
[[ -n "${PANEL_KEY}" ]] || die "通信密钥不能为空。"
[[ "${NODE_ID}" =~ ^[1-9][0-9]*$ ]] || die "节点 ID 必须是大于 0 的整数。"
[[ "${API_VERSION}" == "1" || "${API_VERSION}" == "2" ]] ||
    die "API 版本只能是 1 或 2。"
[[ "${NODE_TYPE}" =~ ^(vmess|vless|trojan|shadowsocks|hysteria|hysteria2|tuic|anytls)$ ]] ||
    die "不支持的 NODE_TYPE: ${NODE_TYPE}"

if [[ "${API_VERSION}" == "2" && "${NODE_TYPE}" != "vless" ]]; then
    warn "API v2 的协议由 v2node 配置返回，NODE_TYPE 仅用于后续 V1 用户/流量接口。"
fi

warn_if_file_is_shared() {
    local label="$1"
    local file_path="$2"
    local file_mode

    file_mode="$(stat -c '%a' "${file_path}")"
    if (( (8#${file_mode} & 077) != 0 )); then
        warn "${label} 当前权限为 ${file_mode}，建议执行: chmod 600 '${file_path}'"
    fi
}

install_packages() {
    local packages=(curl unzip jq ca-certificates)

    if command -v apt-get >/dev/null 2>&1; then
        log "检测到 Debian/Ubuntu，安装基础依赖"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y "${packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        log "检测到 Amazon Linux/RHEL（dnf），安装基础依赖"
        dnf install -y "${packages[@]}"
    elif command -v yum >/dev/null 2>&1; then
        log "检测到 Amazon Linux/CentOS（yum），安装基础依赖"
        yum install -y "${packages[@]}"
    else
        die "不支持当前系统：未找到 apt-get、dnf 或 yum。"
    fi

    if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates >/dev/null
    elif command -v update-ca-trust >/dev/null 2>&1; then
        update-ca-trust extract >/dev/null 2>&1 || update-ca-trust >/dev/null
    fi

    command -v systemctl >/dev/null 2>&1 ||
        die "当前系统没有 systemd，无法创建 V2bX 服务。"
}

detect_asset_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf '64'
            ;;
        aarch64|arm64)
            printf 'arm64-v8a'
            ;;
        armv7l|armv7)
            printf 'arm32-v7a'
            ;;
        armv6l|armv6)
            printf 'arm32-v6'
            ;;
        armv5tel|armv5l)
            printf 'arm32-v5'
            ;;
        s390x|riscv64|mips|mipsle|mips64|mips64le|ppc64|ppc64le)
            printf '%s' "$(uname -m)"
            ;;
        *)
            die "V2bX 没有适配当前 CPU 架构的自动映射: $(uname -m)"
            ;;
    esac
}

probe_panel() {
    local endpoint
    local http_code
    local message

    if [[ "${API_VERSION}" == "2" ]]; then
        endpoint="${PANEL_URL}/api/v2/server/config"
    else
        endpoint="${PANEL_URL}/api/v1/server/UniProxy/config"
    fi

    PROBE_FILE="$(mktemp)"
    log "检查面板 API 连通性（不会输出通信密钥）"
    if ! http_code="$(curl -sS -L \
        --connect-timeout 10 \
        --max-time 30 \
        --output "${PROBE_FILE}" \
        --write-out '%{http_code}' \
        --get "${endpoint}" \
        --data-urlencode "node_type=${NODE_TYPE}" \
        --data-urlencode "node_id=${NODE_ID}" \
        --data-urlencode "token=${PANEL_KEY}")"; then
        die "无法连接面板 API。请检查 EC2 出站规则、DNS、面板域名和 TLS 证书。"
    fi

    if [[ ! "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
        die "面板 API 返回 HTTP ${http_code}。请检查通信密钥、节点 ID、节点类型和 WAF/CDN 规则。"
    fi
    jq -e . "${PROBE_FILE}" >/dev/null 2>&1 ||
        die "面板 API 返回的不是 JSON；域名可能跳转到了登录页或被 CDN/WAF 拦截。"

    message="$(jq -r 'select(.status == "fail") | .message // "unknown error"' "${PROBE_FILE}")"
    [[ -z "${message}" ]] || die "面板 API 拒绝请求: ${message}"

    PANEL_PORT="$(jq -r '.server_port // empty' "${PROBE_FILE}")"
    log "面板 API 检查通过（API v${API_VERSION}, ${NODE_TYPE} 节点 ${NODE_ID}）"
}

install_v2bx() {
    local asset_arch="$1"
    local version="$2"
    local asset_name="V2bX-linux-${asset_arch}.zip"
    local upstream_url="${RELEASE_BASE}/${version}/${asset_name}"
    local download_url="${GITHUB_PROXY_PREFIX}${upstream_url}"
    local archive_size

    install -d -m 0755 "${INSTALL_DIR}" "${CONFIG_DIR}"
    ARCHIVE_FILE="$(mktemp)"
    log "下载 V2bX ${version}（$(uname -m) -> ${asset_name}）"
    if ! curl -fL \
        --retry 5 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 900 \
        --output "${ARCHIVE_FILE}" \
        "${download_url}"; then
        die "下载失败：${upstream_url}。若 EC2 无法直连 GitHub，可设置 GITHUB_PROXY_PREFIX。"
    fi

    archive_size="$(stat -c '%s' "${ARCHIVE_FILE}")"
    (( archive_size >= 1000000 )) ||
        die "下载文件异常，仅 ${archive_size} 字节。"
    unzip -tqq "${ARCHIVE_FILE}" ||
        die "下载文件不是有效的 ZIP 压缩包。"
    unzip -oq "${ARCHIVE_FILE}" -d "${INSTALL_DIR}"

    [[ -f "${INSTALL_DIR}/V2bX" ]] ||
        die "发行包内未找到 V2bX 可执行文件。"
    chmod 0755 "${INSTALL_DIR}/V2bX"
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "${INSTALL_DIR}/V2bX" >/dev/null 2>&1 || true
    fi
    "${INSTALL_DIR}/V2bX" version >/dev/null ||
        die "V2bX 无法在当前 CPU 上运行，请检查实例架构。"

    [[ -f "${INSTALL_DIR}/geoip.dat" ]] ||
        die "发行包缺少 geoip.dat。"
    [[ -f "${INSTALL_DIR}/geosite.dat" ]] ||
        die "发行包缺少 geosite.dat。"
    install -m 0644 "${INSTALL_DIR}/geoip.dat" "${CONFIG_DIR}/geoip.dat"
    install -m 0644 "${INSTALL_DIR}/geosite.dat" "${CONFIG_DIR}/geosite.dat"
}

write_route_config() {
    local netflix_outbound="$1"
    local has_dmm="$2"
    local has_javdb="$3"

    ROUTE_TMP="$(mktemp "${CONFIG_DIR}/route.json.tmp.XXXXXX")"
    jq -n \
        --arg netflix_outbound "${netflix_outbound}" \
        --argjson has_dmm "${has_dmm}" \
        --argjson has_javdb "${has_javdb}" \
        '{
          domainStrategy: "IPIfNonMatch",
          rules: (
            (if $has_dmm then [{
              type: "field",
              outboundTag: "dmm",
              domain: ["domain:dmm.com", "domain:dmm.co.jp"]
            }] else [] end) +
            (if $has_javdb then [{
              type: "field",
              outboundTag: "javdb",
              domain: ["domain:javdb.com", "domain:jdbstatic.com"]
            }] else [] end) +
            [
              {
                type: "field",
                outboundTag: "block",
                ip: ["geoip:private"]
              },
              {
                type: "field",
                outboundTag: "block",
                protocol: ["bittorrent"]
              },
              {
                type: "field",
                outboundTag: $netflix_outbound,
                domain: ["geosite:netflix"]
              },
              {
                type: "field",
                outboundTag: "IPv4_out",
                network: "tcp,udp"
              }
            ]
          )
        }' >"${ROUTE_TMP}"

    # 交叉校验路由引用的每个 outboundTag，防止服务启动后静默不分流。
    jq -e --slurpfile outbounds "${OUTBOUND_FILE}" '
        [.rules[].outboundTag] as $route_tags |
        [$outbounds[0][].tag] as $outbound_tags |
        all($route_tags[]; . as $tag | $outbound_tags | index($tag) != null)
    ' "${ROUTE_TMP}" >/dev/null ||
        die "route.json 引用了 custom_outbound.json 中不存在的出站标签。"

    if [[ "${has_dmm}" == "true" ]]; then
        jq -e 'any(.rules[]; .outboundTag == "dmm")' "${ROUTE_TMP}" >/dev/null ||
            die "未能写入 DMM 分流规则。"
    fi
    if [[ "${has_javdb}" == "true" ]]; then
        jq -e 'any(.rules[]; .outboundTag == "javdb")' "${ROUTE_TMP}" >/dev/null ||
            die "未能写入 JAVDB 分流规则。"
    fi

    chmod 0644 "${ROUTE_TMP}"
    mv -f "${ROUTE_TMP}" "${ROUTE_FILE}"
    ROUTE_TMP=""
    log "已重写 ${ROUTE_FILE}（DMM=${has_dmm}, JAVDB=${has_javdb}）"
}

write_config() {
    local netflix_outbound="IPv4_out"

    if command -v ip >/dev/null 2>&1 && ip -6 route show default | grep -q '^default'; then
        netflix_outbound="IPv6_out"
        log "检测到 IPv6 默认路由，Netflix 保持 IPv6 出站"
    else
        log "未检测到 IPv6 默认路由，Netflix 自动改用 IPv4 出站"
    fi

    if [[ -f "${CONFIG_FILE}" ]]; then
        local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "${CONFIG_FILE}" "${backup_file}"
        log "旧配置已备份到 ${backup_file}"
    fi

    CONFIG_TMP="$(mktemp "${CONFIG_DIR}/config.json.tmp.XXXXXX")"
    jq -n \
        --arg panel_url "${PANEL_URL}" \
        --arg panel_key "${PANEL_KEY}" \
        --arg node_type "${NODE_TYPE}" \
        --argjson node_id "${NODE_ID}" \
        --argjson api_version "${API_VERSION}" \
        '{
          Log: {Level: "info", Output: ""},
          Cores: [{
            Type: "xray",
            Log: {Level: "error", ErrorPath: "/etc/V2bX/error.log"},
            AssetPath: "/etc/V2bX/",
            DnsConfigPath: "/etc/V2bX/dns.json",
            OutboundConfigPath: "/etc/V2bX/custom_outbound.json",
            RouteConfigPath: "/etc/V2bX/route.json",
            XrayConnectionConfig: {
              handshake: 10,
              connIdle: 300,
              uplinkOnly: 2,
              downlinkOnly: 4,
              bufferSize: 256
            }
          }],
          Nodes: [{
            Core: "xray",
            ApiHost: $panel_url,
            ApiKey: $panel_key,
            NodeID: $node_id,
            NodeType: $node_type,
            Timeout: 30,
            ApiVersion: $api_version,
            ListenIP: "0.0.0.0",
            SendIP: "0.0.0.0",
            DeviceOnlineMinTraffic: 200,
            ReportMinTraffic: 0,
            EnableProxyProtocol: false,
            EnableUot: true,
            EnableTFO: false,
            DNSType: "UseIPv4",
            DisableSniffing: false,
            CertConfig: {CertMode: "none"}
          }]
        }' >"${CONFIG_TMP}"
    chmod 0600 "${CONFIG_TMP}"
    mv -f "${CONFIG_TMP}" "${CONFIG_FILE}"
    CONFIG_TMP=""

    cat >"${DNS_FILE}" <<'EOF'
{
  "servers": [
    "1.1.1.1",
    "8.8.8.8",
    "localhost"
  ],
  "tag": "dns_inbound"
}
EOF

    # 先生成不含敏感信息的基础出站；私密文件无效时保留此配置继续部署。
    OUTBOUND_TMP="$(mktemp "${CONFIG_DIR}/custom_outbound.json.tmp.XXXXXX")"
    jq -n '[
          {
            tag: "IPv4_out",
            protocol: "freedom",
            settings: {domainStrategy: "UseIPv4v6"}
          },
          {
            tag: "IPv6_out",
            protocol: "freedom",
            settings: {domainStrategy: "UseIPv6"}
          },
          {
            tag: "block",
            protocol: "blackhole"
          }
        ]' >"${OUTBOUND_TMP}"

    if [[ -n "${CUSTOM_OUTBOUND_FILE}" ]]; then
        if [[ ! -r "${CUSTOM_OUTBOUND_FILE}" ]]; then
            warn "无法读取 CUSTOM_OUTBOUND_FILE: ${CUSTOM_OUTBOUND_FILE}"
            warn "已退化为基础直连出站，DMM/JAVDB 专用路由不会启用。"
        elif ! jq -e '
            type == "array" and
            any(.[]; .tag == "IPv4_out") and
            any(.[]; .tag == "IPv6_out") and
            any(.[]; .tag == "block")
        ' "${CUSTOM_OUTBOUND_FILE}" >/dev/null 2>&1; then
            warn "CUSTOM_OUTBOUND_FILE 不是有效 JSON，或缺少 IPv4_out、IPv6_out、block。"
            warn "已退化为基础直连出站，DMM/JAVDB 专用路由不会启用。"
        else
            warn_if_file_is_shared "自定义出站文件" "${CUSTOM_OUTBOUND_FILE}"
            install -m 0600 "${CUSTOM_OUTBOUND_FILE}" "${OUTBOUND_TMP}"
            log "已载入本地自定义出站配置"
        fi
    fi

    chmod 0600 "${OUTBOUND_TMP}"
    mv -f "${OUTBOUND_TMP}" "${OUTBOUND_FILE}"
    OUTBOUND_TMP=""

    local has_dmm=false
    local has_javdb=false
    if jq -e 'any(.[]; .tag == "dmm")' "${OUTBOUND_FILE}" >/dev/null; then
        has_dmm=true
    fi
    if jq -e 'any(.[]; .tag == "javdb")' "${OUTBOUND_FILE}" >/dev/null; then
        has_javdb=true
    fi

    write_route_config "${netflix_outbound}" "${has_dmm}" "${has_javdb}"
    if [[ "${has_dmm}" == "true" ]]; then
        log "DMM 分流：dmm.com、dmm.co.jp -> dmm"
    else
        warn "出站配置没有 dmm 标签，未启用 DMM 分流。"
    fi
    if [[ "${has_javdb}" == "true" ]]; then
        log "JAVDB 分流：javdb.com、jdbstatic.com -> javdb"
    else
        warn "出站配置没有 javdb 标签，未启用 JAVDB 分流。"
    fi

    chmod 0600 "${CONFIG_FILE}"
    chmod 0600 "${OUTBOUND_FILE}"
    chmod 0644 "${DNS_FILE}" "${ROUTE_FILE}"

    jq -e . "${CONFIG_FILE}" >/dev/null
    jq -e . "${DNS_FILE}" >/dev/null
    jq -e . "${OUTBOUND_FILE}" >/dev/null
    jq -e . "${ROUTE_FILE}" >/dev/null
}

write_service() {
    systemctl stop v2bx.service >/dev/null 2>&1 || true
    # 兼容上游安装脚本曾创建的大小写不同服务，避免同一节点启动两个进程。
    systemctl disable --now V2bX.service >/dev/null 2>&1 || true

    cat >"${SERVICE_FILE}" <<'EOF'
[Unit]
Description=V2bX Service
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/usr/local/V2bX
ExecStart=/usr/local/V2bX/V2bX server --config /etc/V2bX/config.json
Restart=always
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable v2bx.service >/dev/null
    systemctl restart v2bx.service
    sleep 3

    if ! systemctl is-active --quiet v2bx.service; then
        printf '\n'
        systemctl status v2bx.service --no-pager -l || true
        journalctl -u v2bx.service -n 80 --no-pager || true
        die "V2bX 启动失败，诊断日志见上方。"
    fi
}

main() {
    local asset_arch

    CURRENT_STEP="安装系统依赖"
    install_packages
    CURRENT_STEP="检查面板 API"
    probe_panel
    CURRENT_STEP="检测 CPU 架构"
    asset_arch="$(detect_asset_arch)"
    CURRENT_STEP="下载并安装 V2bX ${V2BX_VERSION}"
    install_v2bx "${asset_arch}" "${V2BX_VERSION}"
    CURRENT_STEP="生成出站和路由配置"
    write_config
    CURRENT_STEP="启动 V2bX 服务"
    write_service
    CURRENT_STEP="部署完成"

    printf '\n'
    log "部署完成：V2bX ${V2BX_VERSION} 已运行"
    log "系统架构：$(uname -m)（发行包 ${asset_arch}）"
    log "面板接口：API v${API_VERSION} / ${NODE_TYPE} / 节点 ${NODE_ID}"
    if [[ -n "${PANEL_PORT:-}" ]]; then
        log "请确认 AWS Security Group 已按节点协议放行端口 ${PANEL_PORT}"
    fi
    log "查看日志：journalctl -u v2bx -f"
    systemctl status v2bx.service --no-pager -n 20
}

main "$@"
