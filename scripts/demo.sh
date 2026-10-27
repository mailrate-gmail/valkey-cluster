#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose --project-directory "${PROJECT_DIR}" -f "${PROJECT_DIR}/docker-compose.yml")

dc() { "${COMPOSE[@]}" "$@"; }
vcli() { dc exec -T cli valkey-cli -h proxy -p 7777 "$@"; }

log() { printf '[demo] %s\n' "$*"; }

wait_for_proxy() {
  for _ in $(seq 1 60); do
    if vcli PING >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  log "proxy did not become ready"
  return 1
}

log "starting stack"
dc up -d --build
wait_for_proxy

log "writing through proxy"
vcli SET lab:user:1 alice
vcli SET lab:user:2 bob
vcli SET lab:order:1 paid

log "reading through proxy"
vcli GET lab:user:1
vcli MGET lab:user:1 lab:user:2 lab:order:1

log "cluster key slots"
dc exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER KEYSLOT lab:user:1
dc exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER KEYSLOT lab:user:2
dc exec -T cli valkey-cli -h valkey-node-1 -p 6379 CLUSTER KEYSLOT lab:order:1

log "status"
"${PROJECT_DIR}/scripts/status.sh"
