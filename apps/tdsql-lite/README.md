# TDSQL-Lite 信创版

轻量级 MySQL 数据库，内置 Manager 管控平台、Agent 运维组件、VictoriaMetrics 监控告警。

## 目录结构

```
8.0.51.1.0/
├── docker-compose.yml              # 容器编排
├── data.yml                        # 1Panel 部署表单定义
├── scripts/init.sh                 # 部署前初始化脚本
├── tools/
│   ├── tdsql-lite-tool             # 管理工具（备份/恢复/密钥等）
│   └── tdsql-lite-tool-agent.sh    # 在 Agent 容器内执行工具的包装脚本
├── etc/
│   ├── agent/                      # Agent 配置文件
│   ├── manager/                    # Manager 配置（密钥等）
│   └── monitoring/                 # 监控告警配置
├── TDSQL-LICENSE-*.lic             # License 文件
├── backup/                         # 备份文件（运行时生成）
└── data/                           # 数据目录（运行时生成）
```

## 部署准备

### 1. 加载 Docker 镜像

镜像文件由离线包提供，部署前需先导入 Docker：

```bash
# 将镜像 tar 文件导入 Docker
docker load -i pause.tar
docker load -i tdsql-mysql.tar
docker load -i tdsql-agent.tar
docker load -i tdsql-manager.tar
docker load -i victoria-metrics.tar
docker load -i vmalert.tar
docker load -i alertmanager.tar
```

> 镜像标签统一为 `:8.0.51.1.0` 版本号。
> 如果镜像已存在则会自动跳过，无需重复加载。

### 2. 放置 License 文件

将 `.lic` 文件放入版本目录（与 `docker-compose.yml` 同级）

### 3. 部署

在 1Panel 应用中点击"部署"，填写表单参数后即可。

部署流程：
1. `init.sh` 自动执行：创建系统用户、生成密码和密钥、写入环境变量
2. `docker compose up -d` 启动所有容器
3. 验证 License 并初始化管理员

## 端口规划

| 端口 | 用途 |
|------|------|
| 8086（可配） | Manager 控制台 |
| 3306（可配） | MySQL |
| 8428（可配） | VictoriaMetrics |
| 8880（可配） | VMAlert |
| 9093（可配） | AlertManager |

## 管理员

- 用户名：`admin`（默认，可在部署表单中修改）
- 密码：自动生成，保存在 `etc/manager/.keys/admin_password`
- Manager 控制台地址：`http://<主机IP>:8086`

## 日志路径

```
logs/manager/    - Manager 日志
data/mysql/      - MySQL 数据 + 日志
```

## 数据备份与恢复

### 备份操作

```bash
# 进入 TDSQL 部署目录
cd /opt/1panel/apps/local/tdsql-lite/tdsql-lite

# 查看 Agent 容器名称（1Panel 自动生成）
docker ps | grep agent

# 执行全量备份
docker exec <agent容器名> /app/tdsql-lite-tool backup
```

> ⚠️ **注意**: 备份文件保存在 1Panel 应用目录下的 `backup/` 中，**卸载应用时该目录也会被一并清理**。建议定期将备份文件复制到 1Panel 之外的其他目录保存。

备份文件目录结构如下：
```
backup/
└── <instance-id>/
    ├── xtrabackup/
    │   └── YYYY-MM-DD/
    │       ├── *.xbstream.lz4           # 物理备份文件
    │       └── *.xbstream.lz4.meta      # 备份元数据
    └── binlog/
        └── *.lz4.meta                   # binlog 归档（PITR 用）
```

### 查看备份可恢复范围

```bash
docker exec <agent容器名> /app/tdsql-lite-tool recoverytime --backup-root /backup
```

输出示例：
```
Start:   2026-07-01 13:52:54
End:     2026-07-02 11:42:33
PITR:    true
Latest:  xtrabackup+1782928815+20260702+020015+backup-3iehojq0.xbstream.lz4
```

### 数据恢复（备份回退）

#### 恢复前准备

```bash
cd /opt/1panel/apps/local/tdsql-lite/tdsql-lite
```

#### Step 1: 确认备份文件存在

```bash
ls -lh backup/<instance-id>/xtrabackup/YYYY-MM-DD/
```

#### Step 2: 查看备份可恢复范围

```bash
docker exec <agent容器名> /app/tdsql-lite-tool recoverytime --backup-root /backup
```

> ⚠️ **注意**: Agent 容器名是 1Panel 自动生成的（如 `1Panel-localtdsql-lite-fOtK-agent`），不是固定的 `tdsql-agent`。包装脚本 `tdsql-lite-tool-agent.sh` 中写死了容器名，如果容器名不匹配会报 `No such container`，建议直接用 `docker exec` 指定完整容器名。

#### Step 3: 启动所有服务（如果未运行）

```bash
docker compose up -d
```

> ⚠️ **注意**: 如果宿主机已有 MySQL 占用了 3306 端口，需先修改 `.env` 中的 `TDSQL_PORT=3306` 为其他端口（如 3307），否则 pause 容器启动时会报 `bind: address already in use`。

#### Step 4: 等待 MySQL 和 Agent 就绪

```bash
# 检查 MySQL
docker exec <mysql容器名> mysqladmin ping -S /data/data/prod/mysql.sock

# 检查 Agent 状态
docker inspect <agent容器名> --format='{{.State.Status}}'
```

> ⚠️ **注意**: Agent 容器依赖 MySQL 的 unix socket，MySQL 未完全就绪时 Agent 会反复重启（状态显示 `Restarting (1)`）。等待 MySQL 就绪后 Agent 会自动稳定下来，无需手动干预。

#### Step 5: 执行恢复

```bash
# 必须先清理 /tmp/xtrabackup/ 残留，否则 xbstream 解压会报 File exists
docker exec <agent容器名> rm -rf /tmp/xtrabackup/*

# 执行备份集恢复
docker exec <agent容器名> /app/tdsql-lite-tool recover \
  --type BackupSet \
  --backup-set "xtrabackup+<timestamp>+<datetime>+backup-<id>.xbstream.lz4" \
  --backup-root /backup \
  --log-dir /data/tdsql-agent/backuplog
```

> ⚠️ **注意**: `--backup-set` 参数的值是备份文件名，需要从备份目录中确认确切文件名。

#### Step 6: 等待恢复完成

恢复耗时主要取决于 `ibdata1` 的大小（2GB 约需 3 分钟），恢复过程自动执行以下阶段：

| 阶段 | 说明 |
|------|------|
| 解压备份 | lz4 解压 + xbstream 提取到 `/tmp/xtrabackup/` |
| apply-log | `innobackupex --prepare` 应用 redo log |
| 停 MySQL | `mysqladmin shutdown` |
| 清数据目录 | 清空 data / binlog / innodb 目录 |
| move-back | `innobackupex --move-back --rsync` 回拷数据（最慢） |
| 改 server_id | 自动重置为新 server_id |
| 启 MySQL | 删除 pause hook，supervisor 拉起 MySQL |
| RESET MASTER | 重置 binlog 文件 |

#### Step 7: 验证恢复

```bash
# 检查容器状态
docker compose ps

# 查看恢复日志
docker exec <agent容器名> cat /data/tdsql-agent/backuplog/nohup/applylog_YYYY-MM-DD | tail -3
docker exec <agent容器名> cat /data/tdsql-agent/backuplog/nohup/moveback_YYYY-MM-DD | tail -3

# 确认 Agent 运行正常（日志中应有 System collector 输出）
docker logs <agent容器名> --tail 5
```

#### 踩坑汇总

| # | 问题 | 原因 | 解决 |
|---|------|------|------|
| 1 | 端口 3306 被占用 | 宿主机系统 MySQL 在跑 | `.env` 中改 `TDSQL_PORT=3307` |
| 2 | Agent 容器不停重启 | 启动时 MySQL 未就绪 | 等待即可，会自动稳定 |
| 3 | 包装脚本报 `No such container: tdsql-agent` | 脚本写死了容器名，1Panel 版本容器名不同 | 直接用 `docker exec` 指定完整容器名 |
| 4 | `xbstream: File exists` 解压失败 | `/tmp/xtrabackup/` 有上次残留 | 先 `rm -rf /tmp/xtrabackup/*` |
| 5 | 恢复后无法远程连接 MySQL | 备份中的密码与当前 `.env` 密码可能不一致 | Agent 通过 unix socket 连接不受影响 |
