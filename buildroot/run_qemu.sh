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

file_size_bytes() {
    local path="$1"

    if stat -f '%z' "${path}" >/dev/null 2>&1; then
        stat -f '%z' "${path}"
    else
        stat -c '%s' "${path}"
    fi
}

parse_size_to_bytes() {
    local value="${1//\"/}"
    local number=""
    local suffix=""
    local multiplier=1

    if [[ ! "${value}" =~ ^([0-9]+)([KMGTP]?)B?$ ]]; then
        return 1
    fi

    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"

    case "${suffix}" in
        K) multiplier=1024 ;;
        M) multiplier=$((1024 * 1024)) ;;
        G) multiplier=$((1024 * 1024 * 1024)) ;;
        T) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
        P) multiplier=$((1024 * 1024 * 1024 * 1024 * 1024)) ;;
    esac

    echo $((number * multiplier))
}

rootfs_size_from_superblock() {
    local image="$1"
    local blocks=""
    local log_block_size=""
    local block_size=0

    blocks="$(od -An -N 4 -j 1028 -tu4 "${image}" 2>/dev/null | tr -d '[:space:]')"
    log_block_size="$(od -An -N 4 -j 1048 -tu4 "${image}" 2>/dev/null | tr -d '[:space:]')"

    if [[ ! "${blocks}" =~ ^[0-9]+$ ]] || [[ ! "${log_block_size}" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    block_size=$((1024 << log_block_size))
    echo $((blocks * block_size))
}

rootfs_size_from_build_config() {
    local config_file=""
    local size_line=""
    local size_value=""

    for config_file in \
        "${BR_DIR}/.config" \
        "${SCRIPT_DIR}/configs/pex_aarch64_virt_defconfig"
    do
        if [ ! -f "${config_file}" ]; then
            continue
        fi

        size_line="$(grep -E '^BR2_TARGET_ROOTFS_EXT2_SIZE=' "${config_file}" | tail -n 1 || true)"
        if [ -z "${size_line}" ]; then
            continue
        fi

        size_value="${size_line#*=}"
        parse_size_to_bytes "${size_value}" && return 0
    done

    return 1
}

format_mib() {
    local bytes="$1"
    echo $((bytes / 1024 / 1024))
}

find_e2fsck() {
    if [ -x "${BR_DIR}/output/host/sbin/e2fsck" ]; then
        echo "${BR_DIR}/output/host/sbin/e2fsck"
        return 0
    fi

    if command -v e2fsck &>/dev/null; then
        command -v e2fsck
        return 0
    fi

    return 1
}

cleanup() {
    if [ -n "${ROOTFS_RUN:-}" ] && [ -f "${ROOTFS_RUN}" ]; then
        rm -f "${ROOTFS_RUN}"
    fi
}

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
ROOTFS_RUN="$(mktemp /tmp/pex-rootfs-run.XXXXXX)"
trap cleanup EXIT
cp "${ROOTFS}" "${ROOTFS_RUN}"

ROOTFS_ACTUAL_BYTES="$(file_size_bytes "${ROOTFS_RUN}")"
ROOTFS_EXPECTED_BYTES="$(rootfs_size_from_superblock "${ROOTFS_RUN}" || rootfs_size_from_build_config || true)"

if [ -n "${ROOTFS_EXPECTED_BYTES}" ] && [ "${ROOTFS_ACTUAL_BYTES}" -lt "${ROOTFS_EXPECTED_BYTES}" ]; then
    if ! command -v truncate &>/dev/null; then
        echo "ERROR: Root filesystem image appears truncated."
        echo "Actual size:   ${ROOTFS_ACTUAL_BYTES} bytes ($(format_mib "${ROOTFS_ACTUAL_BYTES}") MiB)"
        echo "Expected size: ${ROOTFS_EXPECTED_BYTES} bytes ($(format_mib "${ROOTFS_EXPECTED_BYTES}") MiB)"
        echo "Re-copy the image preserving sparse files, or install a 'truncate' command."
        exit 1
    fi

    echo "WARN: Root filesystem image is smaller than the filesystem it contains."
    echo "      This usually means a sparse Buildroot image was copied without preserving its logical size."
    echo "      Padding the temporary QEMU disk from $(format_mib "${ROOTFS_ACTUAL_BYTES}") MiB to $(format_mib "${ROOTFS_EXPECTED_BYTES}") MiB."
    truncate -s "${ROOTFS_EXPECTED_BYTES}" "${ROOTFS_RUN}"
fi

E2FSCK_BIN="$(find_e2fsck || true)"
if [ -n "${E2FSCK_BIN}" ]; then
    set +e
    FSCK_OUTPUT="$("${E2FSCK_BIN}" -fn "${ROOTFS_RUN}" 2>&1)"
    FSCK_STATUS=$?
    set -e

    if [ $((FSCK_STATUS & 4)) -ne 0 ] || [ $((FSCK_STATUS & 8)) -ne 0 ] || \
       [ $((FSCK_STATUS & 16)) -ne 0 ] || [ $((FSCK_STATUS & 32)) -ne 0 ] || \
       [ $((FSCK_STATUS & 128)) -ne 0 ]; then
        echo "ERROR: Root filesystem image failed a read-only fsck check."
        echo "       The copied image is corrupted and should be recopied or rebuilt before boot."
        echo ""
        echo "${FSCK_OUTPUT}" | sed -n '1,80p'
        exit 1
    fi
fi

qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a57 \
    -m "${MEM}" \
    -kernel "${KERNEL}" \
    -drive file="${ROOTFS_RUN}",format=raw,if=virtio \
    -append "${APPEND}" \
    -nographic \
    -no-reboot
