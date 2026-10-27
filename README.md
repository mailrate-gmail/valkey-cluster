# Valkey Cluster + 轻量 Proxy + Docker Compose

本项目用于在本地运行一个 **Valkey Cluster**：3 个 master、3 个 replica，并额外提供一个基于 `redis-cluster-proxy` 的轻量代理。

proxy 会把整个 Cluster 暴露成一个兼容 Redis 协议的单一入口：

```text
localhost:7777  ->  redis-cluster-proxy  ->  Valkey Cluster 节点
```

## 你会得到什么

- 6 个 Cluster 模式的 Valkey 节点：**3 master + 3 replica**。
- 使用 `valkey-cli --cluster create` 自动分配 16384 个 slot。
- 一个单一 proxy 入口：`localhost:7777`。
- 一个安装了 `valkey-cli` 的 `cli` 工具容器。
- 用于状态检查和快速演示的辅助脚本。

## 重要生产提示

这是学习和实验环境。proxy 使用 [`RedisLabs/redis-cluster-proxy`](https://github.com/RedisLabs/redis-cluster-proxy)，其上游 README 明确说明该项目当前并不活跃维护，不建议直接用于生产环境。

如果要用于生产，需要重新评估：仍在维护的 proxy 方案、原生支持 Cluster 的客户端、TLS/认证、监控、备份以及 proxy 高可用。

## 架构

```text
Client
  |
  | localhost:7777
  v
redis-cluster-proxy
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

# 构建 proxy 镜像，启动 Valkey 节点，初始化 Cluster，启动 proxy 和 CLI 工具容器。
docker compose up -d --build

# 检查 Cluster 和 proxy 状态。
./scripts/status.sh
```

通过 proxy 写入和读取：

```bash
docker compose exec -T cli valkey-cli -h proxy -p 7777 SET hello world
docker compose exec -T cli valkey-cli -h proxy -p 7777 GET hello
docker compose exec -T cli valkey-cli -h proxy -p 7777 DBSIZE
```

如果宿主机安装了 `valkey-cli`，也可以从宿主机直接访问 proxy：

```bash
valkey-cli -h 127.0.0.1 -p 7777 SET host:hello world
valkey-cli -h 127.0.0.1 -p 7777 GET host:hello
```

## Demo

```bash
./scripts/demo.sh
```

这个 demo 会启动整个 stack，通过 proxy 写入几个 key，再读取这些 key，打印它们的 Cluster slot，并显示集群状态。

## 端口

| 组件 | 宿主机端口 | 容器端口 | 用途 |
|------|------------|----------|------|
| proxy | `7777` | `7777` | 客户端单一入口 |
| valkey-node-1 | `7001` | `6379` | 直接调试节点 |
| valkey-node-2 | `7002` | `6379` | 直接调试节点 |
| valkey-node-3 | `7003` | `6379` | 直接调试节点 |
| valkey-node-4 | `7004` | `6379` | 直接调试节点 |
| valkey-node-5 | `7005` | `6379` | 直接调试节点 |
| valkey-node-6 | `7006` | `6379` | 直接调试节点 |

这些直接节点端口主要用于调试。普通客户端应该使用 proxy：`localhost:7777`。除非客户端原生支持 Cluster，并且能理解节点对外通告的 Docker hostname，否则不建议直接连节点端口。

## 常用命令

```bash
# 启动或重新构建全部服务。
make up

# 显示 Cluster 和 proxy 状态。
make status

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

# proxy 应该仍然可以接受普通命令。
docker compose exec -T cli valkey-cli -h proxy -p 7777 SET after:failover ok
docker compose exec -T cli valkey-cli -h proxy -p 7777 GET after:failover

# 恢复节点。
docker compose start valkey-node-1
sleep 15
./scripts/status.sh
```

故障转移后，具体的 master/replica 布局可能会变化。请以 `scripts/status.sh` 中的 `CLUSTER NODES` 输出为准。

## 跨 Slot 命令

proxy 启动时开启了 `--enable-cross-slot`，因此像 `MGET` 或 `DEL` 这类跨不同 slot 的命令可以由 proxy 拆分、转发并合并结果。

示例：

```bash
docker compose exec -T cli valkey-cli -h proxy -p 7777 MGET lab:user:1 lab:user:2
```

注意：proxy 对跨 slot 命令的处理不等同于单节点原子操作。不要把跨 slot 的多 key 写入当成原子事务。

## 重置

删除所有数据和 Cluster 元数据：

```bash
docker compose down -v
docker compose up -d --build
```

`-v` 会删除所有命名数据卷。只在实验重置时使用。

## 故障排查

### proxy 无法启动

查看 Cluster 初始化日志：

```bash
docker compose logs cluster-init
docker compose logs proxy
```

如果 Cluster 元数据处于半初始化状态，重置数据卷：

```bash
docker compose down -v
docker compose up -d --build
```

### 从宿主机直连节点时收到 MOVED 到 Docker hostname

这是预期行为。节点会通告 Docker hostname，便于 Compose 网络内的服务正确路由。宿主机访问建议使用 proxy 入口 `localhost:7777`，或在 `cli` 容器内运行 `valkey-cli`。

### 构建很慢

第一次构建会从源码编译 `redis-cluster-proxy`。后续构建会使用 Docker 缓存。
