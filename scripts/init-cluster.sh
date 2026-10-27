#!/bin/sh
set -eu

CLUSTER_NODES="${CLUSTER_NODES:-valkey-node-1:6379 valkey-node-2:6379 valkey-node-3:6379 valkey-node-4:6379 valkey-node-5:6379 valkey-node-6:6379}"
CLUSTER_REPLICAS="${CLUSTER_REPLICAS:-1}"
CLUSTER_WAIT_TIMEOUT="${CLUSTER_WAIT_TIMEOUT:-120}"

log() {
  printf '[cluster-init] %s\n' "$*"
}

node_host() { printf '%s' "$1" | awk -F: '{print $1}'; }
node_port() { printf '%s' "$1" | awk -F: '{print $2}'; }

first_node=$(printf '%s\n' $CLUSTER_NODES | sed -n '1p')
first_host=$(node_host "$first_node")
first_port=$(node_port "$first_node")

wait_for_nodes() {
  log "waiting for Valkey nodes"
  for node in $CLUSTER_NODES; do
    host=$(node_host "$node")
    port=$(node_port "$node")
    i=0
    until valkey-cli -h "$host" -p "$port" PING >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge "$CLUSTER_WAIT_TIMEOUT" ]; then
        log "timeout waiting for $node"
        return 1
      fi
      sleep 1
    done
    log "$node is reachable"
  done
}

cluster_info() {
  valkey-cli -h "$first_host" -p "$first_port" CLUSTER INFO 2>/dev/null || true
}

cluster_state() {
  cluster_info | awk -F: '/^cluster_state:/ {gsub("\r", "", $2); print $2}'
}

known_nodes() {
  cluster_info | awk -F: '/^cluster_known_nodes:/ {gsub("\r", "", $2); print $2}'
}

wait_for_cluster_ok() {
  log "waiting for cluster_state:ok"
  i=0
  while [ "$i" -lt "$CLUSTER_WAIT_TIMEOUT" ]; do
    if [ "$(cluster_state)" = "ok" ]; then
      log "cluster is ok"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  log "cluster did not become ok"
  return 1
}

wait_for_nodes

state=$(cluster_state)
known=$(known_nodes)
known=${known:-0}

if [ "$state" = "ok" ]; then
  log "cluster already initialized"
  exit 0
fi

if [ "$known" -gt 1 ]; then
  log "cluster already has $known known nodes but state is '$state'; waiting instead of recreating"
  wait_for_cluster_ok
  exit 0
fi

log "creating cluster with replicas=$CLUSTER_REPLICAS"
# shellcheck disable=SC2086
valkey-cli --cluster create $CLUSTER_NODES --cluster-replicas "$CLUSTER_REPLICAS" --cluster-yes

wait_for_cluster_ok
