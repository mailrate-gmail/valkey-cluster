#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose --project-directory "${PROJECT_DIR}" -f "${PROJECT_DIR}/docker-compose.yml")

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
REQUESTS="${REQUESTS:-100000}"
CLIENTS="${CLIENTS:-16}"
DATA_SIZE="${DATA_SIZE:-128}"
KEYSPACE="${KEYSPACE:-100000}"
PIPELINE_SIZE="${PIPELINE_SIZE:-100}"
VALUE="${BENCH_VALUE:-}"

dc() { "${COMPOSE[@]}" "$@"; }

printf '[benchmark] runner=valkey-py\n'
printf '[benchmark] run_id=%s\n' "${RUN_ID}"
printf '[benchmark] key_pattern=bench:%s:{<random-int>}\n' "${RUN_ID}"
printf '[benchmark] cleanup_command=./scripts/cleanup-bench.sh %s\n' "${RUN_ID}"

dc exec -T \
  -e RUN_ID="${RUN_ID}" \
  -e REQUESTS="${REQUESTS}" \
  -e CLIENTS="${CLIENTS}" \
  -e DATA_SIZE="${DATA_SIZE}" \
  -e KEYSPACE="${KEYSPACE}" \
  -e PIPELINE_SIZE="${PIPELINE_SIZE}" \
  -e BENCH_VALUE="${VALUE}" \
  python-client python - <<'PY'
from __future__ import annotations

import os
import random
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

from valkey.cluster import ValkeyCluster

run_id = os.environ["RUN_ID"]
requests = int(os.environ.get("REQUESTS", "100000"))
clients = int(os.environ.get("CLIENTS", "16"))
data_size = int(os.environ.get("DATA_SIZE", "128"))
keyspace = int(os.environ.get("KEYSPACE", "100000"))
pipeline_size = int(os.environ.get("PIPELINE_SIZE", "100"))
value = os.environ.get("BENCH_VALUE") or ("x" * data_size)

if requests <= 0:
    raise SystemExit("REQUESTS must be > 0")
if clients <= 0:
    raise SystemExit("CLIENTS must be > 0")
if keyspace <= 0:
    raise SystemExit("KEYSPACE must be > 0")

def connect() -> ValkeyCluster:
    return ValkeyCluster(host="valkey-node-1", port=6379, decode_responses=True)

def worker(worker_id: int, count: int) -> int:
    client = connect()
    rng = random.Random(f"{run_id}:{worker_id}")
    written = 0
    pipe = client.pipeline(transaction=False)
    pending = 0

    for _ in range(count):
        n = rng.randrange(keyspace)
        key = f"bench:{run_id}:{{{n:012d}}}"
        pipe.set(key, value)
        pending += 1
        if pending >= pipeline_size:
            pipe.execute()
            written += pending
            pipe = client.pipeline(transaction=False)
            pending = 0

    if pending:
        pipe.execute()
        written += pending
    return written

base = requests // clients
remainder = requests % clients
work = [base + (1 if i < remainder else 0) for i in range(clients)]

start = time.perf_counter()
total = 0
with ThreadPoolExecutor(max_workers=clients) as executor:
    futures = [executor.submit(worker, i, count) for i, count in enumerate(work) if count > 0]
    for future in as_completed(futures):
        total += future.result()
elapsed = time.perf_counter() - start
qps = total / elapsed if elapsed else 0

client = connect()
print(f"requests={total}")
print(f"clients={clients}")
print(f"pipeline_size={pipeline_size}")
print(f"keyspace={keyspace}")
print(f"data_size={len(value)}")
print(f"elapsed_seconds={elapsed:.3f}")
print(f"qps={qps:.2f}")
print("sample_keys:")
for i in range(3):
    key = f"bench:{run_id}:{{{i:012d}}}"
    print(f"  {key} slot={client.keyslot(key)}")
PY
