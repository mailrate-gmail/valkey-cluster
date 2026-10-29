#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose --project-directory "${PROJECT_DIR}" -f "${PROJECT_DIR}/docker-compose.yml")

RUN_ID_OR_PATTERN="${1:-}"
BATCH_SIZE="${BATCH_SIZE:-500}"
SCAN_COUNT="${SCAN_COUNT:-1000}"
PURGE="${PURGE:-0}"
ENTRYPOINT="${VALKEY_CLUSTER_ENTRYPOINT:-valkey-node-1:6379}"

if [ -z "${RUN_ID_OR_PATTERN}" ]; then
  cat >&2 <<'EOF'
Usage:
  ./scripts/cleanup-bench.sh <RUN_ID|pattern>

Examples:
  ./scripts/cleanup-bench.sh 20261029-103000
  ./scripts/cleanup-bench.sh 'bench:20261029-103000:*'
  ./scripts/cleanup-bench.sh 'bench:*'

Environment:
  BATCH_SIZE=500     Number of single-key UNLINK commands per pipeline flush
  SCAN_COUNT=1000    SCAN hint count per master
  PURGE=1            Run MEMORY PURGE on all cluster nodes after deletion
EOF
  exit 1
fi

if [[ "${RUN_ID_OR_PATTERN}" == bench:* ]]; then
  PATTERN="${RUN_ID_OR_PATTERN}"
else
  PATTERN="bench:${RUN_ID_OR_PATTERN}:*"
fi

dc() { "${COMPOSE[@]}" "$@"; }

printf '[cleanup] pattern=%s\n' "${PATTERN}"
printf '[cleanup] batch_size=%s scan_count=%s\n' "${BATCH_SIZE}" "${SCAN_COUNT}"

dc exec -T \
  -e BENCH_PATTERN="${PATTERN}" \
  -e BATCH_SIZE="${BATCH_SIZE}" \
  -e SCAN_COUNT="${SCAN_COUNT}" \
  -e ENTRYPOINT="${ENTRYPOINT}" \
  python-client python - <<'PY'
import os
from valkey import Valkey

pattern = os.environ["BENCH_PATTERN"]
batch_size = int(os.environ.get("BATCH_SIZE", "500"))
scan_count = int(os.environ.get("SCAN_COUNT", "1000"))
entrypoint = os.environ.get("ENTRYPOINT", "valkey-node-1:6379")
entry_host, entry_port = entrypoint.rsplit(":", 1)

startup = Valkey(host=entry_host, port=int(entry_port), decode_responses=True)

def master_endpoints() -> list[str]:
    raw = startup.execute_command("CLUSTER", "NODES")
    endpoints = []
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        flags = parts[2].split(",")
        if "master" in flags and "fail" not in flags:
            endpoints.append(parts[1].split("@", 1)[0])
    return sorted(set(endpoints))

def flush(pipe):
    if not pipe.command_stack:
        return 0
    return sum(int(x or 0) for x in pipe.execute())

total = 0
for endpoint in master_endpoints():
    host, port = endpoint.rsplit(":", 1)
    node = Valkey(host=host, port=int(port), decode_responses=True)
    pipe = node.pipeline(transaction=False)
    pending = 0
    deleted = 0
    print(f"[cleanup] scanning master={endpoint} pattern={pattern}")
    for key in node.scan_iter(match=pattern, count=scan_count):
        # One UNLINK per command avoids CROSSSLOT while pipeline keeps it efficient.
        pipe.unlink(key)
        pending += 1
        if pending >= batch_size:
            deleted += flush(pipe)
            pipe = node.pipeline(transaction=False)
            pending = 0
    deleted += flush(pipe)
    total += deleted
    print(f"[cleanup] deleted_from_{endpoint}={deleted}")

print(f"deleted={total}")
PY

if [ "${PURGE}" = "1" ]; then
  printf '[cleanup] running MEMORY PURGE on all cluster nodes\n'
  dc exec -T cli valkey-cli --cluster call "${ENTRYPOINT}" MEMORY PURGE
fi
