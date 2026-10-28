# Valkey Cluster + valkey-py + Docker Compose

本项目在本地运行一个 **Valkey Cluster**：3 个 master、3 个 replica，并提供一个基于 **valkey-py** 的 Cluster-aware 客户端示例。

当前方案不再使用 `redis-cluster-proxy`。Valkey 官方文档推荐使用 Cluster-aware client 连接 Valkey Cluster，客户端负责发现 slot map、处理 `MOVED` / `ASK`、failover 和 reshard 后的拓扑刷新。

```text
Python app / valkey-py
  |
  | CLUSTER SLOTS / MOVED / ASK
  v
Valkey Cluster nodes
```

## 你会得到什么

- 6 个 Cluster 模式的 Valkey 节点：**3 master + 3 replica**。
- 使用 `valkey-cli --cluster create` 自动分配 16384 个 slot。
- 一个 `cli` 工具容器，内置 `valkey-cli`。
- 一个 `python-client` 容器，内置 `valkey-py`。
- 一个 `valkey-admin` Web UI，用于查看拓扑、slot、replication 和 key。
- Python 示例：普通读写、同 slot 多 key、跨 slot 应用层拆分/合并。
- 自动备份脚本：`scripts/backup.sh`。

## 新手实验手册

面向 Valkey 新手的完整 hands-on lab 见：[`Handson_lab.md`](Handson_lab.md)

手册覆盖系统架构、功能边界、启动方式、配置参数、压测方案、日常运维和在线/停机迁移方案。

## 架构

```text
python-client container
  |
  | valkey-py ValkeyCluster(host="valkey-node-1", port=6379)
  |
  +--> valkey-node-1  master/replica，Docker 内部端口 6379，宿主机端口 7001
  +--> valkey-node-2  master/replica，Docker 内部端口 6379，宿主机端口 7002
  +--> valkey-node-3  master/replica，Docker 内部端口 6379，宿主机端口 7003
  +--> valkey-node-4  master/replica，Docker 内部端口 6379，宿主机端口 7004
  +--> valkey-node-5  master/replica，Docker 内部端口 6379，宿主机端口 7005
  +--> valkey-node-6  master/replica，Docker 内部端口 6379，宿主机端口 7006
```

集群使用 `--cluster-replicas 1` 创建，因此每个 master 会有 1 个 replica。

## 快速开始

```bash
cd ~/valkey-cluster

# 构建 python-client 镜像，启动 Valkey 节点，初始化 Cluster。
docker compose up -d --build

# 检查 Cluster 和 valkey-py 客户端连通性。
./scripts/status.sh
```

运行 Python demo：

```bash
./scripts/demo.sh
```

也可以手动执行：

```bash
docker compose exec -T python-client python /scripts/valkey_py_demo.py
```

## 使用 valkey-cli 直接验证 Cluster

在 Compose 网络内使用 `cli` 工具容器：

```bash
docker compose exec -T cli valkey-cli -c -h valkey-node-1 -p 6379 SET hello world
docker compose exec -T cli valkey-cli -c -h valkey-node-1 -p 6379 GET hello
docker compose exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER INFO
```

注意：节点通告的是 Docker hostname，宿主机直接用 `valkey-cli -c -p 7001` 可能会被重定向到 `valkey-node-N`，而宿主机默认不能解析这些名字。宿主机应用建议放进同一个 Docker 网络，或改用能解析这些 hostname 的环境。

## 使用 Valkey Admin 图形界面

本项目已接入 Valkey 官方的 **Valkey Admin** Web UI：

```text
http://127.0.0.1:8080
```

Compose 中已预配置连接：

```text
VALKEY_HOST=valkey-node-1
VALKEY_PORT=6379
```

Valkey Admin 会自动识别 Cluster 拓扑，可用于查看：

- Cluster Topology
- slots 分布
- master / replica 关系
- key browser
- metrics
- command console

安全提示：Valkey Admin Web 模式默认没有认证。本项目只绑定到 `127.0.0.1:8080`，不要直接暴露到公网。

## valkey-py 示例说明

示例脚本：`scripts/valkey_py_demo.py`

核心连接方式：

```python
from valkey.cluster import ValkeyCluster

client = ValkeyCluster(host="valkey-node-1", port=6379, decode_responses=True)
```

valkey-py 会：

- 连接启动节点；
- 拉取 Cluster slot map；
- 根据 key 计算 slot；
- 直接把命令路由到正确节点；
- 遇到 `MOVED` / `ASK` 时刷新拓扑。

## 跨 slot 多 key 操作

Cluster 要求事务、Lua、原子多 key 操作必须同 slot。如果需要多 key 原子性，请使用 hash tag：

```text
cart:{1001}:items
cart:{1001}:total
```

这两个 key 都按 `{1001}` 计算 slot，可以直接：

```python
client.mget(["cart:{1001}:items", "cart:{1001}:total"])
```

如果 key 不同 slot，只能在应用层拆分再合并，且不具备原子性。示例脚本里提供了：

```python
cross_slot_mget(client, keys)
cross_slot_delete(client, keys)
```

它们的逻辑是：

```text
计算每个 key 的 slot
按 slot 分组
每组分别执行 MGET / DEL
最后按原 key 顺序合并结果
```

## 端口

| 组件 | 宿主机端口 | 容器端口 | 用途 |
|------|------------|----------|------|
| valkey-node-1 | `7001` | `6379` | 直接调试节点 |
| valkey-node-2 | `7002` | `6379` | 直接调试节点 |
| valkey-node-3 | `7003` | `6379` | 直接调试节点 |
| valkey-node-4 | `7004` | `6379` | 直接调试节点 |
| valkey-node-5 | `7005` | `6379` | 直接调试节点 |
| valkey-node-6 | `7006` | `6379` | 直接调试节点 |

## 常用命令

```bash
# 启动或重新构建全部服务。
make up

# 显示 Cluster 和 valkey-py 状态。
make status

# 运行 Python demo。
make demo

# 创建一次 Cluster 备份。
make backup

# 跟踪日志。
make logs

# 停止容器，但保留数据卷。
make down

# 删除所有 Cluster 数据并从零重建。
make reset
```

不使用 `make` 也可以：

```bash
docker compose up -d --build
./scripts/status.sh
docker compose logs -f --tail=100
docker compose down
docker compose down -v
```

## 故障测试

停止一个节点，观察 Cluster 自动故障转移：

```bash
docker compose stop valkey-node-1
sleep 15
./scripts/status.sh

# valkey-py 应该仍然可以通过 Cluster 拓扑继续访问。
docker compose exec -T python-client python /scripts/valkey_py_demo.py --status-only

# 恢复节点。
docker compose start valkey-node-1
sleep 15
./scripts/status.sh
```

故障转移后，具体的 master/replica 布局可能会变化。请以 `scripts/status.sh` 中的 `CLUSTER NODES` 输出为准。

## 重置

删除所有数据和 Cluster 元数据：

```bash
docker compose down -v
docker compose up -d --build
```

`-v` 会删除所有命名数据卷。只在实验重置时使用。

## 备份

创建一次备份：

```bash
./scripts/backup.sh
```

默认生成：

```text
backups/valkey-cluster-YYYYMMDD-HHMMSS.tar.gz
```

保留最近 7 份备份。可通过环境变量调整：

```bash
BACKUP_RETENTION_COUNT=14 ./scripts/backup.sh
```

恢复说明见：[`restore-notes.md`](restore-notes.md)

## 故障排查

### Python 客户端无法连接

查看初始化和客户端日志：

```bash
docker compose logs cluster-init
docker compose logs python-client
./scripts/status.sh
```

如果 Cluster 元数据处于半初始化状态，重置数据卷：

```bash
docker compose down -v
docker compose up -d --build
```

### 宿主机直连节点时收到 MOVED 到 Docker hostname

这是预期行为。节点会通告 Docker hostname，便于 Compose 网络内的服务正确路由。宿主机应用如果不能解析 `valkey-node-N`，请运行在 Compose 网络内，或调整节点通告地址。

### 是否还需要 proxy

默认不需要。Valkey Cluster 的推荐方式是使用 Cluster-aware client，例如 `valkey-py`、Valkey GLIDE、valkey-go、iovalkey、valkey-java 等。proxy 只适合兼容旧客户端或隐藏拓扑，但会引入额外故障点和维护风险。
