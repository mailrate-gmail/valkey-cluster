#!/usr/bin/env python3
"""Valkey Cluster client demo using valkey-py.

The script runs inside the docker compose network and connects to one startup
node. valkey-py discovers the cluster topology, caches the slot map, routes
commands to the right node, and refreshes topology when MOVED/ASK is returned.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from typing import Iterable

from valkey.cluster import ValkeyCluster


STARTUP_HOST = "valkey-node-1"
STARTUP_PORT = 6379


def connect() -> ValkeyCluster:
    return ValkeyCluster(host=STARTUP_HOST, port=STARTUP_PORT, decode_responses=True)


def group_by_slot(client: ValkeyCluster, keys: Iterable[str]) -> dict[int, list[str]]:
    groups: dict[int, list[str]] = defaultdict(list)
    for key in keys:
        groups[client.keyslot(key)].append(key)
    return dict(groups)


def cross_slot_mget(client: ValkeyCluster, keys: list[str]) -> list[str | None]:
    """MGET replacement for keys that may be in different slots.

    This is not atomic. It groups keys by slot, issues one MGET per slot, and
    merges replies back to the original key order.
    """
    values_by_key: dict[str, str | None] = {}
    for slot_keys in group_by_slot(client, keys).values():
        values = client.mget(slot_keys)
        values_by_key.update(zip(slot_keys, values))
    return [values_by_key.get(key) for key in keys]


def cross_slot_delete(client: ValkeyCluster, keys: list[str]) -> int:
    """DEL replacement for keys that may be in different slots."""
    deleted = 0
    for slot_keys in group_by_slot(client, keys).values():
        deleted += int(client.delete(*slot_keys))
    return deleted


def print_status(client: ValkeyCluster) -> None:
    info = client.cluster_info()
    print(f"cluster_state={info.get('cluster_state')}")
    print(f"cluster_slots_assigned={info.get('cluster_slots_assigned')}")
    print(f"cluster_known_nodes={info.get('cluster_known_nodes')}")


def run_demo(status_only: bool) -> None:
    client = connect()
    print_status(client)

    if status_only:
        return

    keys = ["lab:user:1", "lab:user:2", "lab:order:1"]
    print("\nkey slots:")
    for key in keys:
        print(f"  {key} -> slot {client.keyslot(key)}")

    print("\nwrite keys through valkey-py cluster client:")
    client.set("lab:user:1", "alice")
    client.set("lab:user:2", "bob")
    client.set("lab:order:1", "paid")
    print("  SET done")

    print("\nsame-slot MGET via hash tag:")
    client.set("cart:{1001}:items", "book,pen")
    client.set("cart:{1001}:total", "42")
    print(client.mget(["cart:{1001}:items", "cart:{1001}:total"]))

    print("\ncross-slot MGET implemented in application code:")
    print(cross_slot_mget(client, keys))

    print("\ncleanup:")
    deleted = cross_slot_delete(client, keys + ["cart:{1001}:items", "cart:{1001}:total"])
    print(f"  deleted={deleted}")


def main() -> int:
    parser = argparse.ArgumentParser(description="valkey-py cluster-aware client demo")
    parser.add_argument("--status-only", action="store_true", help="only test connectivity and cluster status")
    args = parser.parse_args()
    run_demo(args.status_only)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
