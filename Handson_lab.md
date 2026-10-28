# Valkey Cluster + valkey-py 新手 Hands-on Lab

> 适用目录：`/home/opc/valkey-cluster`  
> 适用对象：第一次接触 Valkey Cluster 的同学  
> 实验目标：理解 Valkey Cluster 架构、启动方式、客户端访问、压测、日常运维和迁移方案

---

## 1. 实验场景

假设你负责一个课程报名系统。系统需要用 Valkey 存储：

- 学生会话：`session:<student_id>`
- 课程库存：`course:<course_id>:quota`
- 报名状态：`enroll:<course_id>:<student_id>`
- 购物车或草稿：`cart:{student_id}:items`

单机 Valkey 的问题是容量有限、写入压力集中、单点故障风险高。这个实验使用 **Valkey Cluster** 把数据自动分散到多个 master 节点，并通过 replica 提供故障转移能力。

本项目采用官方推荐思路：

```text
应用 / valkey-py Cluster 客户端
  |
  | 获取 slot map，处理 MOVED / ASK
  v
Valkey Cluster 节点
```

本项目**不使用 proxy**。Cluster-aware client 负责路由。

---

## 2. 系统架构说明

### 2.1 组件

| 组件 | 数量 | 说明 |
|------|------|------|
| `valkey-node-1` ~ `valkey-node-6` | 6 | Valkey Cluster 节点 |
| master | 3 | 每个 master 负责一段 hash slots |
| replica | 3 | 每个 master 一个 replica |
| `cluster-init` | 1 | 一次性容器，执行 `valkey-cli --cluster create` |
| `cli` | 1 | 工具容器，内置 `valkey-cli` 和 `valkey-benchmark` |
| `python-client` | 1 | Python 工具容器，内置 `valkey-py` |

### 2.2 架构图

```text
python-client / application
  |
  | ValkeyCluster(host="valkey-node-1", port=6379)
  |
  +--> valkey-node-1  master/replica, host port 7001
  +--> valkey-node-2  master/replica, host port 7002
  +--> valkey-node-3  master/replica, host port 7003
  +--> valkey-node-4  master/replica, host port 7004
  +--> valkey-node-5  master/replica, host port 7005
  +--> valkey-node-6  master/replica, host port 7006
```

### 2.3 数据如何分片

Valkey Cluster 使用 16384 个 hash slot：

```text
slot = CRC16(key) % 16384
```

每个 master 负责一段 slot。客户端根据 key 计算 slot，然后把命令发到对应节点。

查看某个 key 的 slot：

```bash
docker compose exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER KEYSLOT session:1001
```

### 2.4 为什么不需要 proxy

Valkey Cluster 的正常访问方式是 **Cluster-aware client**。

`valkey-py` 会：

- 连接一个启动节点；
- 执行 `CLUSTER SLOTS` / `CLUSTER SHARDS` 获取拓扑；
- 根据 key 计算 slot；
- 把命令发到正确节点；
- 遇到 `MOVED` / `ASK` 时刷新拓扑。

proxy 只适合兼容旧客户端或隐藏拓扑，不是本实验默认方案。

---

## 3. 功能说明：已具备和欠缺

### 3.1 已具备功能

| 功能 | 状态 | 说明 |
|------|------|------|
| 服务端分片 | 支持 | Valkey Cluster 自动按 slot 分片 |
| 自动故障转移 | 支持 | master 故障后 replica 会被提升 |
| 3 master + 3 replica | 支持 | 当前 Compose 固定 6 节点 |
| slot 自动分配 | 支持 | `cluster-init` 自动创建集群 |
| Cluster-aware 客户端 | 支持 | `python-client` 使用 `valkey-py` |
| 同 slot 多 key | 支持 | 使用 hash tag，例如 `cart:{1001}:items` |
| 跨 slot 批量读 | 示例支持 | `valkey_py_demo.py` 演示应用层拆分/合并 |
| 压测 | 支持 | 使用 `valkey-benchmark --cluster` |
| 日常状态检查 | 支持 | `scripts/status.sh` |

### 3.2 当前欠缺或限制

| 限制 | 说明 |
|------|------|
| 没有认证 | 当前实验环境未配置 `requirepass` / ACL |
| 没有 TLS | Cluster bus 和客户端连接都未启用 TLS |
| 没有持久化备份流程自动化 | 只开启 AOF，备份需要自行做 |
| 没有监控系统 | 未集成 Prometheus / Grafana |
| 没有自动扩缩容脚本 | 扩容需要修改 Compose 并执行 `add-node` / `reshard` |
| 跨 slot 事务不支持 | 事务和 Lua 要求所有 key 在同一 slot |
| 跨 slot 多 key 不原子 | 应用层拆分/合并只适合非原子场景 |
| 宿主机直接 cluster 访问有 hostname 问题 | 节点通告 Docker hostname，宿主机默认解析不了 |

---

## 4. 如何启动

### 4.1 启动前检查

```bash
cd ~/valkey-cluster
docker --version
docker compose version
```

### 4.2 启动集群

```bash
docker compose up -d --build
```

启动过程会做几件事：

1. 启动 6 个 Valkey 节点；
2. 等待所有节点健康；
3. `cluster-init` 执行 `valkey-cli --cluster create ... --cluster-replicas 1`；
4. 启动 `cli` 工具容器；
5. 启动 `python-client` 容器。

### 4.3 查看状态

```bash
./scripts/status.sh
```

关键输出应该包括：

```text
cluster_state:ok
cluster_slots_assigned:16384
cluster_known_nodes:6
cluster_size:3
```

### 4.4 运行 Python demo

```bash
./scripts/demo.sh
```

demo 会展示：

- `valkey-py` 连接 Cluster；
- 打印 key 对应的 slot；
- 写入普通 key；
- 使用 hash tag 做同 slot `MGET`；
- 应用层拆分/合并实现跨 slot `MGET`；
- 清理测试 key。

### 4.5 `~/.profile` 快捷函数

当前实验环境已经在 `~/.profile` 中增加了两个 Valkey helper 函数。新开终端后执行：

```bash
source ~/.profile
```

然后可以使用：

```bash
# Cluster-aware valkey-cli，会自动使用 -c 并连接启动节点 valkey-node-1。
vc SET profile:test ok
vc GET profile:test
vc DEL profile:test

# Node-local valkey-cli，第一个参数是节点 hostname，适合查看节点本地状态。
vn valkey-node-1 CLUSTER INFO
vn valkey-node-1 INFO replication
vn valkey-node-2 DBSIZE
```

函数含义：

| 函数 | 用途 | 示例 |
|------|------|------|
| `vc` | 走 Cluster-aware 模式执行普通读写命令 | `vc SET k v` |
| `vn` | 直连指定节点执行管理/排查命令 | `vn valkey-node-1 CLUSTER NODES` |

如果提示 `vc: command not found` 或 `vn: command not found`，说明当前 shell 尚未加载 `.profile`，重新执行 `source ~/.profile` 即可。

---

## 5. 配置参数

核心配置位于 `docker-compose.yml`。

### 5.1 Valkey 节点参数

| 参数 | 当前值 | 说明 |
|------|--------|------|
| `--port` | `6379` | 容器内部服务端口 |
| `--bind` | `0.0.0.0` | 监听所有地址 |
| `--protected-mode` | `no` | 实验环境关闭保护模式 |
| `--appendonly` | `yes` | 开启 AOF 持久化 |
| `--appendfsync` | `everysec` | 每秒刷盘一次 |
| `--cluster-enabled` | `yes` | 开启 Cluster 模式 |
| `--cluster-config-file` | `nodes.conf` | Cluster 自动维护的节点配置文件 |
| `--cluster-node-timeout` | `5000` | 5 秒无响应后判定节点故障 |
| `--cluster-announce-hostname` | `$HOSTNAME` | 通告 Docker hostname |
| `--cluster-announce-port` | `6379` | 通告客户端端口 |
| `--cluster-announce-bus-port` | `16379` | 通告 Cluster bus 端口 |
| `--cluster-preferred-endpoint-type` | `hostname` | 优先使用 hostname 通告拓扑 |

### 5.2 cluster-init 参数

| 环境变量 | 当前值 | 说明 |
|----------|--------|------|
| `CLUSTER_NODES` | 6 个节点地址 | 创建 Cluster 时使用的节点列表 |
| `CLUSTER_REPLICAS` | `1` | 每个 master 分配 1 个 replica |
| `CLUSTER_WAIT_TIMEOUT` | `120` | 等待节点/集群就绪的超时时间 |

### 5.3 端口映射

| 节点 | 宿主机端口 | 容器端口 |
|------|------------|----------|
| `valkey-node-1` | `7001` | `6379` |
| `valkey-node-2` | `7002` | `6379` |
| `valkey-node-3` | `7003` | `6379` |
| `valkey-node-4` | `7004` | `6379` |
| `valkey-node-5` | `7005` | `6379` |
| `valkey-node-6` | `7006` | `6379` |

注意：这些端口主要用于调试。应用建议运行在 Compose 网络内，或确保能解析 `valkey-node-N` hostname。

---

## 6. 基础操作实验

### 6.1 通过 valkey-cli 写入

```bash
docker compose exec -T cli valkey-cli -c -h valkey-node-1 -p 6379 SET hello world
docker compose exec -T cli valkey-cli -c -h valkey-node-1 -p 6379 GET hello
```

### 6.2 查看 Cluster 节点

```bash
docker compose exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER NODES
```

### 6.3 查看 key 的 slot

```bash
docker compose exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER KEYSLOT hello
```

### 6.4 使用 valkey-py

```bash
docker compose exec -T python-client python /scripts/valkey_py_demo.py
```

---

## 7. 压测方案

压测目标：了解当前 3 master + 3 replica 集群在不同并发和数据大小下的吞吐与延迟表现。

### 7.1 压测前准备

确认集群健康：

```bash
./scripts/status.sh
```

建议压测前清空实验数据：

```bash
docker compose down -v
docker compose up -d --build
```

### 7.2 使用 valkey-benchmark 进行 Cluster 压测

`valkey-benchmark` 已在 `cli` 容器中。

基础压测：

```bash
docker compose exec -T cli valkey-benchmark \
  --cluster \
  -h valkey-node-1 -p 6379 \
  -t set,get \
  -n 100000 \
  -c 60 \
  -d 128 \
  --threads 2
```

参数说明：

| 参数 | 说明 |
|------|------|
| `--cluster` | 启用 Cluster 模式，benchmark 会感知 slot |
| `-h valkey-node-1 -p 6379` | 启动连接节点 |
| `-t set,get` | 测试 `SET` 和 `GET` |
| `-n 100000` | 总请求数 |
| `-c 60` | 并发连接数，Cluster 模式下应不小于节点数 |
| `-d 128` | value 大小，单位字节 |
| `--threads 2` | benchmark 客户端线程数 |

CSV 输出，方便保存结果：

```bash
docker compose exec -T cli valkey-benchmark \
  --cluster -h valkey-node-1 -p 6379 \
  -t set,get -n 100000 -c 60 -d 128 --threads 2 --csv
```

### 7.3 多组压测建议

| 场景 | 命令参数建议 | 观察点 |
|------|--------------|--------|
| 小 value | `-d 16` | QPS 上限 |
| 中 value | `-d 1024` | 网络和 CPU |
| 大 value | `-d 4096` | 延迟和带宽 |
| 低并发 | `-c 10` | 单连接/低并发表现 |
| 高并发 | `-c 200` | 饱和点和尾延迟 |

### 7.4 压测时观察指标

Cluster 状态：

```bash
./scripts/status.sh
```

节点统计：

```bash
docker compose exec -T cli valkey-cli -h valkey-node-1 -p 6379 INFO stats
docker compose exec -T cli valkey-cli -h valkey-node-1 -p 6379 INFO commandstats
```

慢日志：

```bash
docker compose exec -T cli valkey-cli -h valkey-node-1 -p 6379 SLOWLOG GET 10
```

容器资源：

```bash
docker stats
```

### 7.5 压测注意事项

- 压测前确认没有其他实验数据；
- 记录命令参数、QPS、p50/p95/p99 延迟；
- 压测会写入大量 key，压测后可以用 `docker compose down -v` 重置；
- 不要把本地 Docker 压测结果当成生产容量结果，只能用于学习和相对比较。

---

## 8. 日常运维操作

### 8.1 查看整体状态

```bash
./scripts/status.sh
```

### 8.2 查看日志

```bash
docker compose logs --tail=100 valkey-node-1
docker compose logs --tail=100 cluster-init
docker compose logs --tail=100 python-client
```

持续跟踪：

```bash
docker compose logs -f --tail=100
```

### 8.3 查看节点角色和 slot

```bash
docker compose exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER NODES
docker compose exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER SLOTS
```

### 8.4 查看每个节点 key 数

```bash
for n in 1 2 3 4 5 6; do
  echo "valkey-node-$n"
  docker compose exec -T cli valkey-cli -h valkey-node-$n -p 6379 DBSIZE
done
```

### 8.5 故障转移演练

停止一个 master 或节点：

```bash
docker compose stop valkey-node-1
sleep 15
./scripts/status.sh
```

恢复节点：

```bash
docker compose start valkey-node-1
sleep 15
./scripts/status.sh
```

注意：恢复后的节点可能变成 replica，具体角色以 `CLUSTER NODES` 为准。

### 8.6 手动 failover

如果要维护某个 master，可以先找它的 replica，然后在 replica 上执行：

```bash
docker compose exec -T cli valkey-cli -h <replica-host> -p 6379 CLUSTER FAILOVER
```

执行前先确认 replica 同步正常：

```bash
docker compose exec -T cli valkey-cli -h <replica-host> -p 6379 INFO replication
```

### 8.7 重启

重启单节点：

```bash
docker compose restart valkey-node-1
```

停止整个环境但保留数据：

```bash
docker compose down
```

重新启动：

```bash
docker compose up -d --build
```

### 8.8 备份

当前实验开启 AOF，数据存放在 Docker named volumes 中。

简单备份思路：

1. 停止写入或进入维护窗口；
2. 对每个节点数据卷做文件级备份；
3. 或使用 `valkey-cli --cluster backup` 导出：

```bash
docker compose exec -T cli sh -c '
  rm -rf /tmp/backup && mkdir -p /tmp/backup &&
  valkey-cli --cluster backup valkey-node-1:6379 /tmp/backup &&
  ls -lh /tmp/backup
'
```

这里的 `/tmp/backup` 位于 `cli` 容器内。生产环境应挂载宿主机目录或对象存储，并使用更正式的备份、校验和恢复演练流程。

### 8.9 重置实验环境

```bash
docker compose down -v
docker compose up -d --build
```

`-v` 会删除所有数据卷，只能用于实验重置。

---

## 9. 迁移方案

迁移目标通常是从 standalone / Sentinel / 旧 Redis 迁移到当前 Valkey Cluster。

迁移前必须先解决两件事：

1. **key 命名规划**：需要事务或 Lua 的相关 key 必须用 hash tag 放到同 slot；
2. **客户端改造**：应用必须使用 Cluster-aware client，例如 `valkey-py`。

### 9.1 停机迁移

停机迁移适合：数据量较小、可以接受维护窗口、业务切换简单的场景。

流程：

1. 通知维护窗口；
2. 停止旧系统写入；
3. 从旧实例导出或扫描数据；
4. 导入 Valkey Cluster；
5. 校验 key 数量和抽样数据；
6. 切换应用连接配置到 Valkey Cluster；
7. 启动业务并观察。

#### 方式 A：使用 `valkey-cli --cluster import`

如果旧实例能被 `cli` 容器访问，可以使用：

```bash
docker compose exec -T cli valkey-cli --cluster import valkey-node-1:6379 \
  --cluster-from <old-host>:<old-port> \
  --cluster-copy \
  --cluster-replace
```

说明：

- `valkey-node-1:6379` 是目标 Cluster 中任意一个可用节点；
- `<old-host>:<old-port>` 是旧 standalone 或旧主库；
- `--cluster-copy` 表示复制数据，不从旧库删除；
- `--cluster-replace` 表示目标有同名 key 时覆盖。

#### 方式 B：应用脚本迁移

逻辑如下：

```text
从旧库 SCAN key
读取 key 类型和值
写入 Valkey Cluster
保留 TTL
记录失败 key
重复校验
```

优点是可控，缺点是需要自己处理各种数据类型和 TTL。

### 9.2 在线迁移

在线迁移适合：不能长时间停机、数据量较大、需要灰度切换的场景。

推荐流程：

1. 新建 Valkey Cluster；
2. 应用增加 dual-write：新写入同时写旧库和新 Cluster；
3. 后台全量迁移历史数据；
4. 做增量补偿或再次扫描；
5. 校验数据一致性；
6. 灰度读新 Cluster；
7. 逐步放量；
8. 停止旧库写入；
9. 最终切换并保留旧库一段时间用于回滚。

#### 在线迁移关键点

| 项目 | 说明 |
|------|------|
| 双写幂等 | 写入要能重复执行，不产生脏数据 |
| TTL 保留 | 迁移时必须保留剩余过期时间 |
| 数据类型 | string/hash/list/set/zset/stream 要分别处理 |
| 校验 | 至少做 key 数量、抽样值、业务关键 key 校验 |
| 回滚 | 保留旧库，切换初期可快速回退 |
| hash tag | 需要事务/Lua 的 key 要提前改名或映射 |

### 9.3 从 Sentinel 多分片迁移到 Valkey Cluster

如果来源是之前的“Sentinel 多分片 + 客户端分片”架构，需要注意：

- 旧架构按 `cksum(key) % SHARDS` 路由；
- Valkey Cluster 按 `CRC16(key) % 16384` 路由；
- 两者分片规则完全不同；
- 不能简单修改客户端地址后直接读取旧数据。

建议做法：

1. 枚举每个旧分片的所有 key；
2. 逐 key 读取并写入新 Valkey Cluster；
3. 应用改为 `valkey-py` Cluster 客户端；
4. 需要原子多 key 的业务，提前改成 hash tag key 设计；
5. 完成校验后切流。

### 9.4 迁移校验命令

目标 Cluster 状态：

```bash
./scripts/status.sh
```

抽样读取：

```bash
docker compose exec -T python-client python - <<'PY'
from valkey.cluster import ValkeyCluster
c = ValkeyCluster(host="valkey-node-1", port=6379, decode_responses=True)
for key in ["session:1001", "course:1001:quota", "cart:{1001}:items"]:
    print(key, c.get(key))
PY
```

统计 key 数：

```bash
for n in 1 2 3 4 5 6; do
  docker compose exec -T cli valkey-cli -h valkey-node-$n -p 6379 DBSIZE
done
```

---

## 10. 实验清理

删除 demo 可能留下的 key：

```bash
docker compose exec -T python-client python /scripts/valkey_py_demo.py
```

该 demo 会自动清理自己写入的 key。

完全重置：

```bash
docker compose down -v
docker compose up -d --build
```

---

## 11. 学习检查点

完成实验后，请确认你能回答：

1. Valkey Cluster 为什么不需要 proxy？
2. 16384 个 slot 是如何决定 key 位置的？
3. 为什么事务和 Lua 要求所有 key 在同 slot？
4. `valkey-py` 如何处理 `MOVED` / `ASK`？
5. 跨 slot `MGET` 如何在应用层实现？为什么不原子？
6. `docker compose down` 和 `docker compose down -v` 有什么区别？
7. 压测时应该记录哪些指标？
8. 停机迁移和在线迁移分别适合什么场景？
