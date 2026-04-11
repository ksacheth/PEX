#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

cd "${ROOT_DIR}"

echo "[1/4] Building userspace components..."
make lib examples tests demo

echo "[2/4] Building kernel module..."
make kernel

echo "[3/4] Loading module and preparing /dev/pex..."
sudo bash "${ROOT_DIR}/scripts/dev_setup.sh"

echo "[4/4] Launching Tkinter viewer..."
if [[ -z "${DISPLAY:-}" ]]; then
  echo "No DISPLAY detected; running the real-kernel viewer self-check instead of the windowed UI."
  python3 "${ROOT_DIR}/demo/pex_viewer.py" --self-check
else
  python3 "${ROOT_DIR}/demo/pex_viewer.py"
fi
