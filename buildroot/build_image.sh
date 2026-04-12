#!/usr/bin/env bash
#
# build_image.sh -- Build a custom Linux image with PEX subsystem using Buildroot
#
# Usage:
#   ./buildroot/build_image.sh          # full build
#   ./buildroot/build_image.sh rebuild   # rebuild PEX package + rootfs only
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BR_EXTERNAL="${SCRIPT_DIR}"
BR_VERSION="2024.02.12"
BR_DIR="${SCRIPT_DIR}/buildroot-${BR_VERSION}"
BR_TARBALL="buildroot-${BR_VERSION}.tar.xz"
BR_URL="https://buildroot.org/downloads/${BR_TARBALL}"

JOBS="${JOBS:-2}"  # low default due to RAM constraints

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*"; }

# ── Step 0: Check prerequisites ──
info "Checking prerequisites..."

missing=""
for cmd in make gcc g++ wget tar cpio unzip rsync bc file; do
    if ! command -v "$cmd" &>/dev/null; then
        missing="${missing} ${cmd}"
    fi
done

if ! command -v qemu-system-aarch64 &>/dev/null; then
    warn "qemu-system-aarch64 not found."
    warn "Install it:  sudo apt-get install -y qemu-system-arm"
    warn "The build will proceed but you'll need QEMU to boot the image."
fi

if [ -n "${missing}" ]; then
    err "Missing required tools:${missing}"
    err "Install:  sudo apt-get install -y build-essential wget cpio unzip rsync bc file"
    exit 1
fi

ok "Prerequisites satisfied."

# ── Step 1: Download Buildroot ──
if [ ! -d "${BR_DIR}" ]; then
    info "Downloading Buildroot ${BR_VERSION}..."
    if [ ! -f "${SCRIPT_DIR}/${BR_TARBALL}" ]; then
        wget -q --show-progress -O "${SCRIPT_DIR}/${BR_TARBALL}" "${BR_URL}"
    fi
    info "Extracting..."
    tar -xf "${SCRIPT_DIR}/${BR_TARBALL}" -C "${SCRIPT_DIR}"
    ok "Buildroot extracted to ${BR_DIR}"
else
    ok "Buildroot ${BR_VERSION} already present."
fi

# ── Step 2: Configure ──
if [ "${1:-}" = "rebuild" ]; then
    info "Rebuild mode: cleaning PEX package and regenerating rootfs..."
    make -C "${BR_DIR}" BR2_EXTERNAL="${BR_EXTERNAL}" pex-dirclean
else
    info "Configuring Buildroot with PEX defconfig..."
    make -C "${BR_DIR}" BR2_EXTERNAL="${BR_EXTERNAL}" pex_aarch64_virt_defconfig
    ok "Configuration applied."
fi

# ── Step 3: Build ──
info "Building (jobs=${JOBS}). This may take 15-30 minutes on first run..."
info "  Kernel:  Linux 6.6 LTS (aarch64)"
info "  Target:  QEMU virt machine"
info "  Includes: pex.ko, libpex, demo apps, Python 3"
echo ""

make -C "${BR_DIR}" BR2_EXTERNAL="${BR_EXTERNAL}" -j"${JOBS}" 2>&1 | \
    tee "${SCRIPT_DIR}/build.log"

# ── Step 4: Verify output ──
KERNEL="${BR_DIR}/output/images/Image"
ROOTFS="${BR_DIR}/output/images/rootfs.ext2"

if [ ! -f "${KERNEL}" ] || [ ! -f "${ROOTFS}" ]; then
    err "Build failed — kernel or rootfs image not found."
    err "Check ${SCRIPT_DIR}/build.log for details."
    exit 1
fi

echo ""
ok "Build successful!"
echo ""
info "Output files:"
echo "  Kernel:  ${KERNEL}  ($(du -h "${KERNEL}" | cut -f1))"
echo "  RootFS:  ${ROOTFS}  ($(du -h "${ROOTFS}" | cut -f1))"
echo ""
info "To boot the image:"
echo "  ${SCRIPT_DIR}/run_qemu.sh"
echo ""
info "Or manually:"
echo "  qemu-system-aarch64 -M virt -cpu cortex-a57 -m 256 \\"
echo "    -kernel ${KERNEL} \\"
echo "    -drive file=${ROOTFS},format=raw,if=virtio \\"
echo "    -append 'root=/dev/vda console=ttyAMA0' \\"
echo "    -nographic -no-reboot"
