#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose --project-directory "${PROJECT_DIR}" -f "${PROJECT_DIR}/docker-compose.yml")

BACKUP_ROOT="${BACKUP_ROOT:-${PROJECT_DIR}/backups}"
RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-7}"
ENTRYPOINT="${VALKEY_CLUSTER_ENTRYPOINT:-valkey-node-1:6379}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_NAME="valkey-cluster-${TIMESTAMP}"
HOST_DIR="${BACKUP_ROOT}/${BACKUP_NAME}"
CONTAINER_DIR="/tmp/${BACKUP_NAME}"
ARCHIVE="${BACKUP_ROOT}/${BACKUP_NAME}.tar.gz"

dc() { "${COMPOSE[@]}" "$@"; }

log() { printf '[backup] %s\n' "$*"; }

cluster_cmd() {
  dc exec -T cli valkey-cli -h "${ENTRYPOINT%%:*}" -p "${ENTRYPOINT##*:}" "$@"
}

cluster_state() {
  cluster_cmd CLUSTER INFO | awk -F: '/^cluster_state:/ {gsub("\r", "", $2); print $2}'
}

write_metadata() {
  {
    printf 'backup_name=%s\n' "${BACKUP_NAME}"
    printf 'created_at=%s\n' "$(date -Is)"
    printf 'project_dir=%s\n' "${PROJECT_DIR}"
    printf 'entrypoint=%s\n' "${ENTRYPOINT}"
    printf 'git_commit=%s\n' "$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
    printf 'retention_count=%s\n' "${RETENTION_COUNT}"
  } > "${HOST_DIR}/metadata.txt"

  dc ps > "${HOST_DIR}/compose-ps.txt"
  cluster_cmd CLUSTER INFO > "${HOST_DIR}/cluster-info.txt"
  cluster_cmd CLUSTER NODES > "${HOST_DIR}/cluster-nodes.txt"
  cluster_cmd CLUSTER SLOTS > "${HOST_DIR}/cluster-slots.txt"

  for node in valkey-node-1 valkey-node-2 valkey-node-3 valkey-node-4 valkey-node-5 valkey-node-6; do
    {
      printf '== %s DBSIZE ==\n' "${node}"
      dc exec -T cli valkey-cli -h "${node}" -p 6379 DBSIZE || true
      printf '\n== %s INFO server ==\n' "${node}"
      dc exec -T cli valkey-cli -h "${node}" -p 6379 INFO server || true
      printf '\n== %s INFO replication ==\n' "${node}"
      dc exec -T cli valkey-cli -h "${node}" -p 6379 INFO replication || true
    } > "${HOST_DIR}/${node}-info.txt"
  done
}

run_cluster_backup() {
  log "running valkey-cli --cluster backup from cli container"
  dc exec -T cli sh -c "rm -rf '${CONTAINER_DIR}' && mkdir -p '${CONTAINER_DIR}' && valkey-cli --cluster backup '${ENTRYPOINT}' '${CONTAINER_DIR}'"
  mkdir -p "${HOST_DIR}/data"
  dc cp "cli:${CONTAINER_DIR}/." "${HOST_DIR}/data"
  dc exec -T cli rm -rf "${CONTAINER_DIR}" >/dev/null 2>&1 || true
}

create_archive() {
  log "creating archive ${ARCHIVE}"
  tar -C "${BACKUP_ROOT}" -czf "${ARCHIVE}" "${BACKUP_NAME}"
  if [ "${KEEP_BACKUP_DIR:-0}" != "1" ]; then
    rm -rf "${HOST_DIR}"
  fi
}

apply_retention() {
  if ! [[ "${RETENTION_COUNT}" =~ ^[0-9]+$ ]]; then
    log "invalid BACKUP_RETENTION_COUNT=${RETENTION_COUNT}; skipping retention"
    return 0
  fi
  if [ "${RETENTION_COUNT}" -le 0 ]; then
    log "retention disabled"
    return 0
  fi

  mapfile -t archives < <(find "${BACKUP_ROOT}" -maxdepth 1 -type f -name 'valkey-cluster-*.tar.gz' -printf '%T@ %p\n' | sort -rn | awk '{print $2}')
  if [ "${#archives[@]}" -le "${RETENTION_COUNT}" ]; then
    return 0
  fi

  for old in "${archives[@]:${RETENTION_COUNT}}"; do
    log "removing old backup ${old}"
    rm -f "${old}"
  done
}

main() {
  mkdir -p "${BACKUP_ROOT}" "${HOST_DIR}"

  log "checking cluster state"
  state="$(cluster_state)"
  if [ "${state}" != "ok" ]; then
    log "cluster_state is '${state}', expected 'ok'"
    exit 1
  fi

  write_metadata
  run_cluster_backup
  create_archive
  apply_retention

  log "backup complete: ${ARCHIVE}"
}

main "$@"
