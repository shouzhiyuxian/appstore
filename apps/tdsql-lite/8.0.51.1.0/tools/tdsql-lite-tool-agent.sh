#!/bin/bash
# ============================================================
# 在 Agent 容器内执行 tdsql-lite-tool
# 使用: ./tdsql-lite-tool-agent.sh <subcommand> [args...]
#
# 示例:
#   ./tdsql-lite-tool-agent.sh --help
#   ./tdsql-lite-tool-agent.sh keygen aes-key --output /tmp/key
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 读取配置，从 COMPOSE_PROJECT_NAME 派生容器名
if [ -f "${SCRIPT_DIR}/../config.env" ]; then
    source "${SCRIPT_DIR}/../config.env"
fi
AGENT_CONTAINER="${COMPOSE_PROJECT_NAME:-tdsql}-agent"

# 透传所有参数到 agent 容器内的 tdsql-lite-tool
docker exec "${AGENT_CONTAINER}" /app/tdsql-lite-tool "$@"
