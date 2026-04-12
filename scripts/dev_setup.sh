#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
MODULE_PATH="${ROOT_DIR}/kernel/pex.ko"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if [[ ! -f "${MODULE_PATH}" ]]; then
  echo "kernel/pex.ko not found, building kernel module..."
  make -C "${ROOT_DIR}" kernel
fi

if [[ ! -f "${MODULE_PATH}" ]]; then
  echo "Could not find built module at ${MODULE_PATH}" >&2
  echo "Make sure kernel headers are installed and 'make kernel' succeeds." >&2
  exit 1
fi

reuse_loaded_module=0
if grep -q '^pex ' /proc/modules; then
  if modprobe -r pex 2>/dev/null; then
    echo "Unloaded existing pex module."
  else
    echo "pex module is already loaded and busy; reusing the existing module."
    reuse_loaded_module=1
  fi
fi

if [[ "${reuse_loaded_module}" -eq 0 ]]; then
  insmod "${MODULE_PATH}"
fi

major="$(grep " pex$" /proc/devices | awk '{print $1}')"
if [[ -z "${major}" ]]; then
  echo "Could not find pex major number" >&2
  exit 1
fi

if [[ -e /dev/pex ]]; then
  rm -f /dev/pex
fi
mknod /dev/pex c "${major}" 0
chmod 666 /dev/pex

echo "PEX device ready at /dev/pex (major=${major})."
