#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
sleep_s="${1:-1}"

cd "${ROOT_DIR}"

echo "[1/5] Building userspace components..."
make lib examples tests demo

echo "[2/5] Building kernel module..."
make kernel

echo "[3/5] Loading module and preparing /dev/pex..."
sudo bash "${ROOT_DIR}/scripts/dev_setup.sh"

echo "[4/5] Running console showcase and tests..."
./examples/protected_workload || true
./examples/showcase_blocking --sleep "${sleep_s}" || true
./tests/test_multithread_violation
./tests/benchmark_entry_exit
python3 ./demo/pex_viewer.py --self-check

echo "[5/5] Snapshotting /proc/pex_stats..."
cat /proc/pex_stats

echo "Run complete."
