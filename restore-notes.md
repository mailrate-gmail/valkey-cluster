# Valkey Cluster Restore Notes

本文档说明当前项目的备份内容和恢复思路。当前已实现自动备份脚本：

```bash
./scripts/backup.sh
```

备份文件默认生成在：

```text
backups/valkey-cluster-YYYYMMDD-HHMMSS.tar.gz
```

## 备份内容

归档中包含：

- `metadata.txt`：备份时间、项目目录、入口节点、git commit 等；
- `compose-ps.txt`：备份时 Compose 服务状态；
- `cluster-info.txt`：`CLUSTER INFO` 输出；
- `cluster-nodes.txt`：`CLUSTER NODES` 输出；
- `cluster-slots.txt`：`CLUSTER SLOTS` 输出；
- `valkey-node-*-info.txt`：每个节点的 `DBSIZE`、`INFO server`、`INFO replication`；
- `data/`：`valkey-cli --cluster backup` 生成的数据文件。

## 实验环境恢复思路

当前项目自动化的是“备份”，不是“一键恢复”。恢复需要谨慎操作，建议先在新的实验目录或新机器上演练。

高层流程：

1. 停止业务写入；
2. 解压备份归档；
3. 重建空 Valkey Cluster；
4. 根据 `data/` 中的备份文件恢复数据；
5. 校验 `cluster_state=ok`；
6. 校验 key 数量和抽样业务 key；
7. 恢复应用流量。

## 停机恢复建议

适合实验或小数据量场景：

```bash
docker compose down -v
docker compose up -d --build
./scripts/status.sh
```

然后根据备份文件做导入。不同 Valkey/Redis 版本、备份格式和目标拓扑可能需要不同恢复命令，恢复前请先在测试环境验证。

## 生产恢复要求

生产环境必须补充：

- 明确 RPO / RTO；
- 定期恢复演练；
- 备份加密；
- 远端上传，例如 S3 / OSS / NFS；
- 备份完整性校验；
- 失败告警；
- 迁移和恢复期间的写入冻结或双写策略。

## 校验命令

恢复后检查：

```bash
./scripts/status.sh
```

抽样读取：

```bash
docker compose exec -T python-client python - <<'PY'
from valkey.cluster import ValkeyCluster
c = ValkeyCluster(host="valkey-node-1", port=6379, decode_responses=True)
for key in ["demo:string:001", "demo:hash:001", "demo:stream:001"]:
    print(key, c.type(key), c.exists(key))
PY
```
