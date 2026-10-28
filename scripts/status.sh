#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose --project-directory "${PROJECT_DIR}" -f "${PROJECT_DIR}/docker-compose.yml")

dc() { "${COMPOSE[@]}" "$@"; }
vcli() { dc exec -T cli valkey-cli "$@"; }

nodes=(valkey-node-1 valkey-node-2 valkey-node-3 valkey-node-4 valkey-node-5 valkey-node-6)

echo "== Compose services =="
dc ps

echo
echo "== Cluster info =="
vcli -h valkey-node-1 -p 6379 CLUSTER INFO | grep -E '^(cluster_state|cluster_slots_assigned|cluster_known_nodes|cluster_size):'

echo
echo "== Cluster nodes =="
vcli -h valkey-node-1 -p 6379 CLUSTER NODES | sort

echo
echo "== Per-node key counts =="
for node in "${nodes[@]}"; do
  printf '%-14s ' "$node"
  vcli -h "$node" -p 6379 DBSIZE
done

echo
echo "== valkey-py smoke test =="
dc exec -T python-client python /scripts/valkey_py_demo.py --status-only
