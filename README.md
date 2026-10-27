# Valkey Cluster + Lightweight Proxy + Docker Compose

This project runs a local **Valkey Cluster** with 3 masters and 3 replicas, plus a lightweight proxy based on `redis-cluster-proxy`.

The proxy exposes the cluster as a single Redis-compatible endpoint:

```text
localhost:7777  ->  redis-cluster-proxy  ->  Valkey Cluster nodes
```

## What This Gives You

- 6 Valkey nodes in cluster mode: **3 masters + 3 replicas**.
- Automatic slot assignment via `valkey-cli --cluster create`.
- A single proxy endpoint on `localhost:7777`.
- A `cli` toolbox container with `valkey-cli` installed.
- Helper scripts for status checks and a quick demo.

## Important Production Note

This is a learning and lab setup. The proxy uses [`RedisLabs/redis-cluster-proxy`](https://github.com/RedisLabs/redis-cluster-proxy), whose upstream README says it is not actively maintained and should not be used as-is for production.

For production, evaluate maintained proxy options, native Cluster-aware clients, TLS/auth, monitoring, backup, and proxy high availability.

## Architecture

```text
Client
  |
  | localhost:7777
  v
redis-cluster-proxy
  |
  +--> valkey-node-1  master/replica, port 6379 inside Docker, 7001 on host
  +--> valkey-node-2  master/replica, port 6379 inside Docker, 7002 on host
  +--> valkey-node-3  master/replica, port 6379 inside Docker, 7003 on host
  +--> valkey-node-4  master/replica, port 6379 inside Docker, 7004 on host
  +--> valkey-node-5  master/replica, port 6379 inside Docker, 7005 on host
  +--> valkey-node-6  master/replica, port 6379 inside Docker, 7006 on host
```

The cluster is created with `--cluster-replicas 1`, so each master gets one replica.

## Quick Start

```bash
cd ~/valkey-cluster

# Build proxy image, start Valkey nodes, initialize cluster, start proxy and CLI toolbox.
docker compose up -d --build

# Check the cluster and proxy.
./scripts/status.sh
```

Write and read through the proxy:

```bash
docker compose exec -T cli valkey-cli -h proxy -p 7777 SET hello world
docker compose exec -T cli valkey-cli -h proxy -p 7777 GET hello
docker compose exec -T cli valkey-cli -h proxy -p 7777 DBSIZE
```

From the host, if you have `valkey-cli` installed:

```bash
valkey-cli -h 127.0.0.1 -p 7777 SET host:hello world
valkey-cli -h 127.0.0.1 -p 7777 GET host:hello
```

## Demo

```bash
./scripts/demo.sh
```

The demo starts the stack, writes several keys through the proxy, reads them back, prints their cluster slots, and shows cluster status.

## Ports

| Component | Host Port | Container Port | Purpose |
|-----------|-----------|----------------|---------|
| proxy | `7777` | `7777` | Single endpoint for clients |
| valkey-node-1 | `7001` | `6379` | Direct node debugging |
| valkey-node-2 | `7002` | `6379` | Direct node debugging |
| valkey-node-3 | `7003` | `6379` | Direct node debugging |
| valkey-node-4 | `7004` | `6379` | Direct node debugging |
| valkey-node-5 | `7005` | `6379` | Direct node debugging |
| valkey-node-6 | `7006` | `6379` | Direct node debugging |

The direct node ports are for debugging. Normal clients should use the proxy at `localhost:7777` unless they are Cluster-aware and understand the advertised Docker hostnames.

## Useful Commands

```bash
# Start or rebuild everything.
make up

# Show cluster and proxy status.
make status

# Follow logs.
make logs

# Stop containers but keep volumes.
make down

# Delete all cluster data and recreate from scratch.
make reset
```

Without `make`:

```bash
docker compose up -d --build
./scripts/status.sh
docker compose logs -f --tail=100
docker compose down
docker compose down -v
```

## Failure Test

Stop one node and observe Cluster failover:

```bash
docker compose stop valkey-node-1
sleep 15
./scripts/status.sh

# The proxy should still accept normal commands.
docker compose exec -T cli valkey-cli -h proxy -p 7777 SET after:failover ok
docker compose exec -T cli valkey-cli -h proxy -p 7777 GET after:failover

# Bring the node back.
docker compose start valkey-node-1
sleep 15
./scripts/status.sh
```

The exact master/replica layout may change after failover. Use `CLUSTER NODES` from `scripts/status.sh` as the source of truth.

## Cross-Slot Commands

The proxy is started with `--enable-cross-slot`, so commands such as `MGET` or `DEL` across different slots can be split and merged by the proxy.

Example:

```bash
docker compose exec -T cli valkey-cli -h proxy -p 7777 MGET lab:user:1 lab:user:2
```

Important: cross-slot proxy handling is not the same as an atomic single-node operation. Do not treat cross-slot multi-key writes as atomic transactions.

## Reset

To remove all data and cluster metadata:

```bash
docker compose down -v
docker compose up -d --build
```

`-v` deletes all named volumes. Use it only for lab resets.

## Troubleshooting

### Proxy does not start

Check cluster initialization logs:

```bash
docker compose logs cluster-init
docker compose logs proxy
```

If cluster metadata is partially initialized, reset volumes:

```bash
docker compose down -v
docker compose up -d --build
```

### Direct node access from host gets MOVED to a Docker hostname

This is expected. Nodes announce Docker hostnames so services inside the Compose network can route correctly. Use the proxy endpoint `localhost:7777` for host access, or run `valkey-cli` inside the `cli` container.

### Build is slow

The first build compiles `redis-cluster-proxy` from source. Later builds use Docker cache.
