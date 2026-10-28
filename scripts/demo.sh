#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose --project-directory "${PROJECT_DIR}" -f "${PROJECT_DIR}/docker-compose.yml")

dc() { "${COMPOSE[@]}" "$@"; }

log() { printf '[demo] %s\n' "$*"; }

wait_for_cluster() {
  for _ in $(seq 1 60); do
    if dc exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER INFO 2>/dev/null \
      | grep -q '^cluster_state:ok'; then
      return 0
    fi
    sleep 1
  done
  log "cluster did not become ready"
  return 1
}

log "starting stack"
dc up -d --build
wait_for_cluster

log "running valkey-py cluster demo"
dc exec -T python-client python /scripts/valkey_py_demo.py

log "status"
"${PROJECT_DIR}/scripts/status.sh"
