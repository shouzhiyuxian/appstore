#!/bin/bash
# =============================================================================
# TDSQL-Lite 信创版 - 安装初始化脚本
# 在 docker compose up 之前执行
# =============================================================================
set -e

VERSION_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="${VERSION_DIR}/tools"
ENV_FILE="${VERSION_DIR}/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[TDSQL Init]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[TDSQL Init]${NC} $1"; }
log_error() { echo -e "${RED}[TDSQL Init]${NC} $1"; }

echo "========================================="
echo "[TDSQL Init] TDSQL-Lite 信创版 初始化开始"
echo "========================================="

# ==================== 0. 自动探测 HOST_IP ====================
if [ "${TDSQL_HOST_IP}" = "auto" ] || [ -z "${TDSQL_HOST_IP}" ]; then
    TDSQL_HOST_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    if [ -z "$TDSQL_HOST_IP" ]; then
        TDSQL_HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$TDSQL_HOST_IP" ]; then
        log_error "无法自动探测 HOST_IP，请在表单中手动指定"
        exit 1
    fi
    log_info "自动探测 HOST_IP: ${TDSQL_HOST_IP}"
fi

# ==================== 0.5 清理上次残留 ====================
log_info "清理上次安装残留..."
# 从 1panel 已创建的 .env 中读取 CONTAINER_NAME
CT_PREFIX="tdsql"
if [ -f "$ENV_FILE" ]; then
    CT_FROM_ENV=$(grep '^CONTAINER_NAME=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d "'\"")
    [ -n "$CT_FROM_ENV" ] && CT_PREFIX="$CT_FROM_ENV"
fi
docker rm -f "${CT_PREFIX}-pause" "${CT_PREFIX}-mysql" "${CT_PREFIX}-agent" \
    "${CT_PREFIX}-manager" "${CT_PREFIX}-victoriametrics" "${CT_PREFIX}-vmalert" \
    "${CT_PREFIX}-alertmanager" "${CT_PREFIX}-post-init" 2>/dev/null || true
docker network rm "${CT_PREFIX}-network" 2>/dev/null || true
log_info "✓ 残留已清理"

# ==================== 1. 创建 tdsql 用户 (uid:gid=6666:6666) ====================
if ! getent group 6666 &>/dev/null; then
    log_info "创建 tdsql 组 (gid=6666)..."
    groupadd -g 6666 tdsql
fi
if ! id -u 6666 &>/dev/null; then
    log_info "创建 tdsql 用户 (uid=6666)..."
    useradd -u 6666 -g 6666 -M -s /sbin/nologin tdsql
fi
# 加入 docker 组（Agent 可能需要操作 docker）
if getent group docker &>/dev/null; then
    usermod -aG docker tdsql 2>/dev/null || true
fi
log_info "✓ 用户 tdsql (6666:6666) 就绪"

# ==================== 2. 加载离线 Docker 镜像 ====================
IMAGES_DIR="${VERSION_DIR}/images"
if [ -d "$IMAGES_DIR" ] && ls "$IMAGES_DIR"/*.tar &>/dev/null; then
    log_info "加载 Docker 镜像..."
    for tar_file in "$IMAGES_DIR"/*.tar; do
        IMG_NAME=$(basename "$tar_file" .tar)
        # 如果镜像已存在则跳过
        if docker image inspect "${IMG_NAME}:8.0.51.1.0" &>/dev/null 2>&1; then
            log_info "  跳过(已存在): ${IMG_NAME}:8.0.51.1.0"
            continue
        fi
        log_info "  加载: $(basename "$tar_file")"
        docker load -i "$tar_file"
    done
    log_info "✓ 镜像加载完成"
else
    log_warn "images/ 目录为空，跳过镜像加载（假设镜像已存在）"
fi

# ==================== 3. 创建目录并设置权限 ====================
log_info "创建数据目录..."

mkdir -p "${VERSION_DIR}/data/mysql/etc"
touch "${VERSION_DIR}/data/mysql/etc/add.ini"

for dir in \
    data/manager/etcd \
    data/monitoring/victoriametrics \
    data/monitoring/alertmanager \
    etc/manager/.keys \
    etc/agent \
    etc/monitoring/rules \
    logs/manager \
    backup; do
    mkdir -p "${VERSION_DIR}/${dir}"
done

# MySQL/Agent/Manager 目录: 6666:6666
chown -R 6666:6666 "${VERSION_DIR}/data/mysql" 2>/dev/null || true
chown -R 6666:6666 "${VERSION_DIR}/data/manager" 2>/dev/null || true
chown -R 6666:6666 "${VERSION_DIR}/etc/manager" 2>/dev/null || true
chown -R 6666:6666 "${VERSION_DIR}/etc/agent" 2>/dev/null || true
chown -R 6666:6666 "${VERSION_DIR}/logs/manager" 2>/dev/null || true
chown -R 6666:6666 "${VERSION_DIR}/backup" 2>/dev/null || true

# Monitoring 目录: 65534:65534 (nobody)
chown -R 65534:65534 "${VERSION_DIR}/data/monitoring" 2>/dev/null || true
chown -R 65534:65534 "${VERSION_DIR}/etc/monitoring" 2>/dev/null || true

log_info "✓ 数据目录创建完成"

# ==================== 4. 生成密码（幂等：已存在则复用） ====================
generate_password() {
    local pw
    while true; do
        pw=$(head -c 200 /dev/urandom | tr -dc 'A-Za-z0-9!@#%^_+=-' | head -c 20)
        if echo "$pw" | grep -q '[A-Z]' && \
           echo "$pw" | grep -q '[a-z]' && \
           echo "$pw" | grep -q '[0-9]' && \
           echo "$pw" | grep -qE '[!@#%^_+=-]'; then
            echo "$pw"
            return
        fi
    done
}

PASS_DIR="${VERSION_DIR}/etc/manager/.keys"
mkdir -p "$PASS_DIR"

# MySQL Agent 密码
PASS_FILE="${PASS_DIR}/mysql_password"
if [ ! -f "$PASS_FILE" ]; then
    MYSQL_PASSWORD=$(generate_password)
    echo -n "${MYSQL_PASSWORD}" > "$PASS_FILE"
    chown 6666:6666 "$PASS_FILE"
    chmod 600 "$PASS_FILE"
    log_info "已生成 MySQL Agent 密码"
else
    MYSQL_PASSWORD=$(cat "$PASS_FILE")
    log_info "复用已有 MySQL Agent 密码"
fi

# 管理员密码
ADMIN_PASS_FILE="${PASS_DIR}/admin_password"
if [ ! -f "$ADMIN_PASS_FILE" ]; then
    ADMIN_PASSWORD=$(generate_password)
    echo -n "${ADMIN_PASSWORD}" > "$ADMIN_PASS_FILE"
    chown 6666:6666 "$ADMIN_PASS_FILE"
    chmod 600 "$ADMIN_PASS_FILE"
    log_info "已生成管理员密码"
else
    ADMIN_PASSWORD=$(cat "$ADMIN_PASS_FILE")
    log_info "复用已有管理员密码"
fi

# Monitoring 密码
VM_PASS_FILE="${PASS_DIR}/vm_password"
VM_AUTH_USER="admin"
if [ ! -f "$VM_PASS_FILE" ]; then
    VM_AUTH_PASSWORD=$(generate_password)
    echo -n "${VM_AUTH_PASSWORD}" > "$VM_PASS_FILE"
    chmod 600 "$VM_PASS_FILE"
    log_info "已生成 VictoriaMetrics 密码"
else
    VM_AUTH_PASSWORD=$(cat "$VM_PASS_FILE")
    log_info "复用已有 VictoriaMetrics 密码"
fi

ALERTMANAGER_PASS_FILE="${PASS_DIR}/alertmanager_password"
ALERTMANAGER_AUTH_USER="admin"
if [ ! -f "$ALERTMANAGER_PASS_FILE" ]; then
    ALERTMANAGER_AUTH_PASSWORD=$(generate_password)
    echo -n "${ALERTMANAGER_AUTH_PASSWORD}" > "$ALERTMANAGER_PASS_FILE"
    chmod 600 "$ALERTMANAGER_PASS_FILE"
    log_info "已生成 Alertmanager 密码"
else
    ALERTMANAGER_AUTH_PASSWORD=$(cat "$ALERTMANAGER_PASS_FILE")
    log_info "复用已有 Alertmanager 密码"
fi

VMALERT_PASS_FILE="${PASS_DIR}/vmalert_password"
VMALERT_AUTH_USER="admin"
if [ ! -f "$VMALERT_PASS_FILE" ]; then
    VMALERT_AUTH_PASSWORD=$(generate_password)
    echo -n "${VMALERT_AUTH_PASSWORD}" > "$VMALERT_PASS_FILE"
    chmod 600 "$VMALERT_PASS_FILE"
    log_info "已生成 VMAlert 密码"
else
    VMALERT_AUTH_PASSWORD=$(cat "$VMALERT_PASS_FILE")
    log_info "复用已有 VMAlert 密码"
fi

# ==================== 5. 生成密钥 ====================
log_info "生成密钥..."

KEYS_DIR="${VERSION_DIR}/etc/manager/.keys"
TOOL="${TOOLS_DIR}/tdsql-lite-tool"

# AES 密钥
if [ ! -f "${KEYS_DIR}/aes_key" ]; then
    "$TOOL" keygen aes-key --output "${KEYS_DIR}/aes_key" >/dev/null 2>&1
    chown 6666:6666 "${KEYS_DIR}/aes_key"
    log_info "✓ AES 密钥已生成"
else
    log_info "跳过(已存在): AES 密钥"
fi

# RSA 密钥对
if [ ! -f "${KEYS_DIR}/rsa_private.pem" ]; then
    "$TOOL" keygen rsa-keypair --output-dir "${KEYS_DIR}" >/dev/null 2>&1
    chown 6666:6666 "${KEYS_DIR}"/rsa_* 2>/dev/null || true
    log_info "✓ RSA 密钥对已生成"
else
    log_info "跳过(已存在): RSA 密钥对"
fi

# AES-256-CBC 密钥
if [ ! -f "${KEYS_DIR}/key" ]; then
    "$TOOL" keygen aes256cbc-key --output "${KEYS_DIR}/key" >/dev/null 2>&1
    chown 6666:6666 "${KEYS_DIR}/key"
    log_info "✓ AES-256-CBC 密钥已生成"
else
    log_info "跳过(已存在): AES-256-CBC 密钥"
fi

# 设备指纹
if [ ! -f "${VERSION_DIR}/etc/manager/.fingerprint" ]; then
    "$TOOL" fingerprint init --save-path="${VERSION_DIR}/etc/manager/.fingerprint" >/dev/null 2>&1 || true
    chown 6666:6666 "${VERSION_DIR}/etc/manager/.fingerprint" 2>/dev/null || true
fi

# ==================== 6. 加密 VM 密码（给 Manager 用） ====================
log_info "加密 VM 管理员密码..."
VM_AUTH_PASSWORD_ENCRYPTED=$("$TOOL" encrypt --plaintext "${VM_AUTH_PASSWORD}" 2>/dev/null) || {
    log_error "VM 密码加密失败"
    exit 1
}
echo -n "${VM_AUTH_PASSWORD_ENCRYPTED}" > "${KEYS_DIR}/vm_password_encrypted"
chmod 600 "${KEYS_DIR}/vm_password_encrypted"
log_info "✓ VM 密码已加密"

# ==================== 6.5 替换 Alertmanager 配置占位符 ====================
MONITORING_ETC="${VERSION_DIR}/etc/monitoring"

# alertmanager.yml 占位符替换
ALERTMANAGER_CONF="${MONITORING_ETC}/alertmanager.yml"
if [ -f "$ALERTMANAGER_CONF" ]; then
    sed -i "s/__MANAGER_CONTAINER__/${CT_PREFIX}-manager/g" "$ALERTMANAGER_CONF"
    sed -i "s/__MANAGER_PORT__/8080/g" "$ALERTMANAGER_CONF"
    log_info "✓ alertmanager.yml 占位符已替换"
fi

# web.config.yml bcrypt 哈希生成
WEB_CONFIG="${MONITORING_ETC}/web.config.yml"
if [ -f "$WEB_CONFIG" ] && [ -n "${ALERTMANAGER_AUTH_PASSWORD:-}" ]; then
    HTPASSWD_OUTPUT=$("$TOOL" htpasswd \
        --username "${ALERTMANAGER_AUTH_USER:-admin}" \
        --password "${ALERTMANAGER_AUTH_PASSWORD}" \
        --cost 12 2>&1) || {
        log_warn "tdsql-lite-tool htpasswd 失败，跳过 Basic Auth 配置"
    }
    if [ -n "${HTPASSWD_OUTPUT:-}" ]; then
        ALERTMANAGER_BCRYPT_HASH=$(echo "${HTPASSWD_OUTPUT}" | grep -oE '\$2[aby]\$.*' || true)
        if [ -n "${ALERTMANAGER_BCRYPT_HASH:-}" ]; then
            ESCAPED_HASH=$(printf '%s\n' "${ALERTMANAGER_BCRYPT_HASH}" | sed 's/[&/\$]/\\&/g')
            sed -i.bak -e "s|__ALERTMANAGER_BCRYPT_HASH__|${ESCAPED_HASH}|g" "$WEB_CONFIG"
            rm -f "${WEB_CONFIG}.bak"
            log_info "✓ Alertmanager Basic Auth 已配置"
        fi
    fi
fi

# ==================== 7. 追加密码到 .env ====================
# 1panel 已创建 .env 含 CONTAINER_NAME + formField 值，只追加自动生成的密码
log_info "追加密码到 .env..."
cat >> "$ENV_FILE" << ENVEOF

# ===== Auto-generated by init.sh at $(date) =====
MYSQL_PASSWORD=${MYSQL_PASSWORD}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
VM_AUTH_USER=${VM_AUTH_USER}
VM_AUTH_PASSWORD=${VM_AUTH_PASSWORD}
VM_AUTH_PASSWORD_ENCRYPTED=${VM_AUTH_PASSWORD_ENCRYPTED}
ALERTMANAGER_AUTH_USER=${ALERTMANAGER_AUTH_USER}
ALERTMANAGER_AUTH_PASSWORD=${ALERTMANAGER_AUTH_PASSWORD}
VMALERT_AUTH_USER=${VMALERT_AUTH_USER}
VMALERT_AUTH_PASSWORD=${VMALERT_AUTH_PASSWORD}

# ===== 资源限制兜底（1panel 可能注入 CPUS/MEMORY_LIMIT）=====
CPUS=${CPUS:-2}
MEMORY_LIMIT=${MEMORY_LIMIT:-4G}
ENVEOF
chmod 600 "$ENV_FILE"
log_info "✓ .env 已生成"

# ==================== 8. 清理 Agent 残留状态 ====================
rm -f "${VERSION_DIR}/data/mysql/tdsql-agent/.agent-state.json" 2>/dev/null || true
rm -f "${VERSION_DIR}/data/mysql/tdsql-agent/.install_complete" 2>/dev/null || true
rm -f "${VERSION_DIR}/etc/manager/.install_complete" 2>/dev/null || true

# ==================== 9. 打印信息 ====================
echo "========================================="
echo "[TDSQL Init] 初始化完成"
echo ""
echo "  主机 IP:     ${TDSQL_HOST_IP}"
echo "  MySQL 端口:  ${TDSQL_PORT:-3306}"
echo "  Manager 端口: ${PANEL_APP_PORT_HTTP:-8086}"
echo "  管理员用户:  ${ADMIN_USERNAME:-admin}"
echo "  管理员密码:  (已保存到 ${PASS_DIR}/admin_password)"
echo "  监控告警:    ${INSTALL_MONITORING:-true}"
echo ""
echo "  License 文件请放入: ${VERSION_DIR}/TDSQL-LICENSE-*.lic"
echo "  部署完成后访问: http://${TDSQL_HOST_IP}:${PANEL_APP_PORT_HTTP:-8086}"
echo "========================================="
