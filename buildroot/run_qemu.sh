#!/usr/bin/env bash
#
# run_qemu.sh -- Boot the PEX Linux image in QEMU
#
# Usage:
#   ./buildroot/run_qemu.sh           # normal boot (auto-runs tests, then shell)
#   ./buildroot/run_qemu.sh --shell   # skip auto-test, go straight to shell
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BR_VERSION="2024.02.12"
BR_DIR="${SCRIPT_DIR}/buildroot-${BR_VERSION}"

KERNEL="${BR_DIR}/output/images/Image"
ROOTFS="${BR_DIR}/output/images/rootfs.ext2"
MEM="${MEM:-256}"

# Append string for kernel command line
APPEND="root=/dev/vda console=ttyAMA0"

if [ "${1:-}" = "--shell" ]; then
    # Skip S99pex auto-run by booting into single-user mode
    APPEND="${APPEND} single"
fi

if [ ! -f "${KERNEL}" ]; then
    echo "ERROR: Kernel image not found at ${KERNEL}"
    echo "Run ./buildroot/build_image.sh first."
    exit 1
fi
if [ ! -f "${ROOTFS}" ]; then
    echo "ERROR: Root filesystem not found at ${ROOTFS}"
    echo "Run ./buildroot/build_image.sh first."
    exit 1
fi

if ! command -v qemu-system-aarch64 &>/dev/null; then
    echo "ERROR: qemu-system-aarch64 not found."
    echo "Install: sudo apt-get install -y qemu-system-arm"
    exit 1
fi

echo "╔══════════════════════════════════════════════════╗"
echo "║  Booting PEX Linux in QEMU                       ║"
echo "║  Architecture: aarch64 (virt machine)             ║"
echo "║  RAM: ${MEM}MB                                        ║"
echo "║  Press Ctrl-A X to exit QEMU                      ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Make a snapshot copy so the original rootfs stays clean
ROOTFS_RUN="/tmp/pex-rootfs-run.ext2"
cp "${ROOTFS}" "${ROOTFS_RUN}"

exec qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a57 \
    -m "${MEM}" \
    -kernel "${KERNEL}" \
    -drive file="${ROOTFS_RUN}",format=raw,if=virtio \
    -append "${APPEND}" \
    -nographic \
    -no-reboot
