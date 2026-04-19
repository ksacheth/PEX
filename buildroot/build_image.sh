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
HOST_OS="$(uname -s)"
HOST_SHIM_DIR=""
DARWIN_FORCE_CLEAN_HOST_E2FSPROGS=0
DARWIN_HOST_E2FSPROGS_MARKER=""

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

ensure_host_shim_dir() {
    if [ -z "${HOST_SHIM_DIR}" ]; then
        HOST_SHIM_DIR="${SCRIPT_DIR}/.host-shims"
    fi

    mkdir -p "${HOST_SHIM_DIR}"
}

rewrite_bin_true_in_file() {
    local file="$1"
    local replacement="$2"
    local escaped_replacement=""

    if [ ! -f "${file}" ] || ! grep -Fq "/bin/true" "${file}"; then
        return 1
    fi

    escaped_replacement="$(printf '%s\n' "${replacement}" | sed 's/[&|]/\\&/g')"
    sed -i.bak "s|/bin/true|${escaped_replacement}|g" "${file}"
    rm -f "${file}.bak"
    return 0
}

configure_darwin_true_shim() {
    local true_bin=""

    if [ -x /usr/bin/true ]; then
        true_bin="/usr/bin/true"
    else
        true_bin="$(type -P true || true)"
    fi

    if [ -z "${true_bin}" ] || [ ! -x "${true_bin}" ]; then
        err "Buildroot on macOS needs a real true executable, but none was found."
        err "Expected /usr/bin/true or another POSIX true in PATH."
        exit 1
    fi

    ensure_host_shim_dir
    ln -sf "${true_bin}" "${HOST_SHIM_DIR}/true"
    ok "Using true shim: ${HOST_SHIM_DIR}/true -> ${true_bin}"
}

patch_darwin_true_refs() {
    local file
    local patched=0
    local true_shim=""
    local -a candidates=(
        "${BR_DIR}/package/Makefile.in"
        "${BR_DIR}/package/autoconf/autoconf.mk"
        "${BR_DIR}/package/bcm2835/bcm2835.mk"
        "${BR_DIR}/package/caps/caps.mk"
        "${BR_DIR}/package/cryptopp/cryptopp.mk"
        "${BR_DIR}/package/dracut/dracut_wrapper"
        "${BR_DIR}/package/faifa/faifa.mk"
        "${BR_DIR}/package/hdparm/hdparm.mk"
        "${BR_DIR}/package/heirloom-mailx/heirloom-mailx.mk"
        "${BR_DIR}/package/olsr/olsr.mk"
        "${BR_DIR}/package/opentyrian/opentyrian.mk"
        "${BR_DIR}/package/pkg-autotools.mk"
        "${BR_DIR}/package/quickjs/quickjs.mk"
        "${BR_DIR}/package/unrar/unrar.mk"
        "${BR_DIR}/package/wireless_tools/wireless_tools.mk"
    )

    ensure_host_shim_dir
    true_shim="${HOST_SHIM_DIR}/true"

    for file in "${candidates[@]}"; do
        if rewrite_bin_true_in_file "${file}" "${true_shim}"; then
            patched=$((patched + 1))
        fi
    done

    if [ "${patched}" -gt 0 ]; then
        ok "Patched ${patched} Buildroot file$( [ "${patched}" -eq 1 ] && echo "" || echo "s" ) to use ${true_shim}."
    fi
}

patch_darwin_host_util_linux() {
    local util_linux_mk="${BR_DIR}/package/util-linux/util-linux.mk"

    if [ ! -f "${util_linux_mk}" ]; then
        return 0
    fi

    if grep -Fq $'\t--disable-libmount \\' "${util_linux_mk}"; then
        return 0
    fi

    if grep -Fq $'\t--enable-libmount \\' "${util_linux_mk}"; then
        sed -i.bak '/^# In the host version of util-linux/,/^# Disable raw command/ s/--enable-libmount/--disable-libmount/' "${util_linux_mk}"
        rm -f "${util_linux_mk}.bak"
        ok "Patched host-util-linux to disable libmount on Darwin."
    fi
}

patch_darwin_host_util_linux_gcc15() {
    local util_linux_mk="${BR_DIR}/package/util-linux/util-linux.mk"

    if [ ! -f "${util_linux_mk}" ]; then
        return 0
    fi

    if grep -Fq "HOST_UTIL_LINUX_POST_CONFIGURE_HOOKS += HOST_UTIL_LINUX_FIX_DARWIN_GCC15_WARNING_FLAG" "${util_linux_mk}"; then
        sed -i.bak 's/HOST_UTIL_LINUX_POST_CONFIGURE_HOOKS += HOST_UTIL_LINUX_FIX_DARWIN_GCC15_WARNING_FLAG/HOST_UTIL_LINUX_PRE_BUILD_HOOKS += HOST_UTIL_LINUX_FIX_DARWIN_GCC15_WARNING_FLAG/' "${util_linux_mk}"
        rm -f "${util_linux_mk}.bak"
        ok "Updated host-util-linux warning hook to run before build on Darwin."
        return 0
    fi

    if grep -Fq "HOST_UTIL_LINUX_FIX_DARWIN_GCC15_WARNING_FLAG" "${util_linux_mk}"; then
        return 0
    fi

    : > "${util_linux_mk}.tmp"
    while IFS= read -r line; do
        if [ "${line}" = '$(eval $(autotools-package))' ]; then
            printf '%s\n' 'define HOST_UTIL_LINUX_FIX_DARWIN_GCC15_WARNING_FLAG' >> "${util_linux_mk}.tmp"
            printf '%s\n' "	find \$(@D) -name Makefile -exec \$(SED) 's,-Wembedded-directive,,g' {} +" >> "${util_linux_mk}.tmp"
            printf '%s\n' 'endef' >> "${util_linux_mk}.tmp"
            printf '%s\n\n' 'HOST_UTIL_LINUX_PRE_BUILD_HOOKS += HOST_UTIL_LINUX_FIX_DARWIN_GCC15_WARNING_FLAG' >> "${util_linux_mk}.tmp"
        fi
        printf '%s\n' "${line}" >> "${util_linux_mk}.tmp"
    done < "${util_linux_mk}"

    mv "${util_linux_mk}.tmp" "${util_linux_mk}"
    ok "Patched host-util-linux to strip -Wembedded-directive on Darwin."
}

patch_darwin_host_util_linux_procfs() {
    local util_linux_mk="${BR_DIR}/package/util-linux/util-linux.mk"

    if [ ! -f "${util_linux_mk}" ]; then
        return 0
    fi

    if grep -Fq "s,ul_strtou64(tok, re, 10),ul_strtou64(tok, (uint64_t *) re, 10)," "${util_linux_mk}"; then
        : > "${util_linux_mk}.tmp"
        while IFS= read -r line; do
            case "${line}" in
                *"s,ul_strtou64(tok, re, 10),ul_strtou64(tok, (uint64_t *) re, 10),"*)
                    printf '%s\n' "	\$(SED) 's|ul_strtou64(tok, re, 10)|ul_strtou64(tok, (uint64_t *) re, 10)|' \$(@D)/lib/procfs.c" >> "${util_linux_mk}.tmp"
                    ;;
                *)
                    printf '%s\n' "${line}" >> "${util_linux_mk}.tmp"
                    ;;
            esac
        done < "${util_linux_mk}"
        mv "${util_linux_mk}.tmp" "${util_linux_mk}"
        ok "Updated host-util-linux procfs hook for Darwin."
        return 0
    fi

    if grep -Fq "HOST_UTIL_LINUX_FIX_DARWIN_PROCFS_TYPES" "${util_linux_mk}"; then
        return 0
    fi

    : > "${util_linux_mk}.tmp"
    while IFS= read -r line; do
        if [ "${line}" = '$(eval $(autotools-package))' ]; then
            printf '%s\n' 'define HOST_UTIL_LINUX_FIX_DARWIN_PROCFS_TYPES' >> "${util_linux_mk}.tmp"
            printf '%s\n' "	\$(SED) 's|ul_strtou64(tok, re, 10)|ul_strtou64(tok, (uint64_t *) re, 10)|' \$(@D)/lib/procfs.c" >> "${util_linux_mk}.tmp"
            printf '%s\n' 'endef' >> "${util_linux_mk}.tmp"
            printf '%s\n\n' 'HOST_UTIL_LINUX_PRE_BUILD_HOOKS += HOST_UTIL_LINUX_FIX_DARWIN_PROCFS_TYPES' >> "${util_linux_mk}.tmp"
        fi
        printf '%s\n' "${line}" >> "${util_linux_mk}.tmp"
    done < "${util_linux_mk}"

    mv "${util_linux_mk}.tmp" "${util_linux_mk}"
    ok "Patched host-util-linux procfs type mismatch on Darwin."
}

patch_darwin_host_e2fsprogs() {
    local e2fsprogs_mk="${BR_DIR}/package/e2fsprogs/e2fsprogs.mk"
    local build_dir="${BR_DIR}/output/build/host-e2fsprogs-1.47.0"

    if [ ! -f "${e2fsprogs_mk}" ]; then
        return 0
    fi

    ensure_host_shim_dir
    DARWIN_HOST_E2FSPROGS_MARKER="${HOST_SHIM_DIR}/host-e2fsprogs-darwin-fix-${BR_VERSION}.stamp"

    if grep -Fq $'\t--disable-elf-shlibs \\' "${e2fsprogs_mk}"; then
        if [ -d "${build_dir}" ] && [ ! -f "${DARWIN_HOST_E2FSPROGS_MARKER}" ]; then
            DARWIN_FORCE_CLEAN_HOST_E2FSPROGS=1
        fi
        return 0
    fi

    if grep -Fq $'\t--enable-elf-shlibs \\' "${e2fsprogs_mk}"; then
        sed -i.bak 's/--enable-elf-shlibs/--disable-elf-shlibs/' "${e2fsprogs_mk}"
        rm -f "${e2fsprogs_mk}.bak"
        DARWIN_FORCE_CLEAN_HOST_E2FSPROGS=1
        ok "Patched host-e2fsprogs to disable ELF shared libs on Darwin."
    fi
}

patch_darwin_host_attr() {
    local attr_mk="${BR_DIR}/package/attr/attr.mk"
    local line=""
    local skip_old_block=0

    if [ ! -f "${attr_mk}" ]; then
        return 0
    fi

    if grep -Fq "darwin_xattr_compat.h" "${attr_mk}"; then
        return 0
    fi

    : > "${attr_mk}.tmp"
    while IFS= read -r line; do
        if [ "${line}" = 'define HOST_ATTR_FIX_DARWIN_XATTR_APIS' ]; then
            skip_old_block=1
            continue
        fi

        if [ "${skip_old_block}" -eq 1 ]; then
            if [ "${line}" = 'HOST_ATTR_PRE_BUILD_HOOKS += HOST_ATTR_FIX_DARWIN_XATTR_APIS' ]; then
                skip_old_block=0
            fi
            continue
        fi

        if [ "${line}" = '$(eval $(host-autotools-package))' ]; then
            cat <<'EOF' >> "${attr_mk}.tmp"
define HOST_ATTR_FIX_DARWIN_XATTR_APIS
	/usr/bin/perl -0pi -e 's@return \(\(walk_flags & WALK_TREE_DEREFERENCE\) \?\n\t\tgetxattr : lgetxattr\)\(path, name, value, size\);@return ((walk_flags & WALK_TREE_DEREFERENCE) ?\n\t\tgetxattr(path, name, value, size, 0, 0) :\n\t\tgetxattr(path, name, value, size, 0, XATTR_NOFOLLOW));@' $(@D)/tools/getfattr.c
	/usr/bin/perl -0pi -e 's@return \(\(walk_flags & WALK_TREE_DEREFERENCE\) \?\n\t\tlistxattr : llistxattr\)\(path, list, size\);@return ((walk_flags & WALK_TREE_DEREFERENCE) ?\n\t\tlistxattr(path, list, size, 0) :\n\t\tlistxattr(path, list, size, XATTR_NOFOLLOW));@' $(@D)/tools/getfattr.c
	/usr/bin/perl -0pi -e 's@return \(opt_deref \? setxattr : lsetxattr\)\(path, name, value, size, 0\);@return opt_deref ?\n\t\tsetxattr(path, name, value, size, 0, 0) :\n\t\tsetxattr(path, name, value, size, 0, XATTR_NOFOLLOW);@' $(@D)/tools/setfattr.c
	/usr/bin/perl -0pi -e 's@return \(opt_deref \? removexattr : lremovexattr\)\(path, name\);@return opt_deref ?\n\t\tremovexattr(path, name, 0) :\n\t\tremovexattr(path, name, XATTR_NOFOLLOW);@' $(@D)/tools/setfattr.c
	{ \
		printf '%s\n' '#ifdef __APPLE__'; \
		printf '%s\n' 'static ssize_t darwin_getxattr_compat(const char *path, const char *name, void *value, size_t size) { return getxattr(path, name, value, size, 0, 0); }'; \
		printf '%s\n' 'static ssize_t darwin_lgetxattr_compat(const char *path, const char *name, void *value, size_t size) { return getxattr(path, name, value, size, 0, XATTR_NOFOLLOW); }'; \
		printf '%s\n' 'static ssize_t darwin_listxattr_compat(const char *path, char *list, size_t size) { return listxattr(path, list, size, 0); }'; \
		printf '%s\n' 'static ssize_t darwin_llistxattr_compat(const char *path, char *list, size_t size) { return listxattr(path, list, size, XATTR_NOFOLLOW); }'; \
		printf '%s\n' 'static int darwin_setxattr_compat(const char *path, const char *name, const void *value, size_t size, int flags) { return setxattr(path, name, value, size, 0, flags); }'; \
		printf '%s\n' 'static int darwin_lsetxattr_compat(const char *path, const char *name, const void *value, size_t size, int flags) { return setxattr(path, name, value, size, 0, flags | XATTR_NOFOLLOW); }'; \
		printf '%s\n' 'static int darwin_removexattr_compat(const char *path, const char *name) { return removexattr(path, name, 0); }'; \
		printf '%s\n' 'static int darwin_lremovexattr_compat(const char *path, const char *name) { return removexattr(path, name, XATTR_NOFOLLOW); }'; \
		printf '%s\n' 'static ssize_t darwin_fgetxattr_compat(int fd, const char *name, void *value, size_t size) { return fgetxattr(fd, name, value, size, 0, 0); }'; \
		printf '%s\n' 'static ssize_t darwin_flistxattr_compat(int fd, char *list, size_t size) { return flistxattr(fd, list, size, 0); }'; \
		printf '%s\n' 'static int darwin_fsetxattr_compat(int fd, const char *name, const void *value, size_t size, int flags) { return fsetxattr(fd, name, value, size, 0, flags); }'; \
		printf '%s\n' 'static int darwin_fremovexattr_compat(int fd, const char *name) { return fremovexattr(fd, name, 0); }'; \
		printf '%s\n' '#define getxattr darwin_getxattr_compat'; \
		printf '%s\n' '#define lgetxattr darwin_lgetxattr_compat'; \
		printf '%s\n' '#define listxattr darwin_listxattr_compat'; \
		printf '%s\n' '#define llistxattr darwin_llistxattr_compat'; \
		printf '%s\n' '#define setxattr darwin_setxattr_compat'; \
		printf '%s\n' '#define lsetxattr darwin_lsetxattr_compat'; \
		printf '%s\n' '#define removexattr darwin_removexattr_compat'; \
		printf '%s\n' '#define lremovexattr darwin_lremovexattr_compat'; \
		printf '%s\n' '#define fgetxattr darwin_fgetxattr_compat'; \
		printf '%s\n' '#define flistxattr darwin_flistxattr_compat'; \
		printf '%s\n' '#define fsetxattr darwin_fsetxattr_compat'; \
		printf '%s\n' '#define fremovexattr darwin_fremovexattr_compat'; \
		printf '%s\n' '#endif'; \
	} > $(@D)/darwin_xattr_compat.h
	/usr/bin/perl -0pi -e 's@#include "../darwin_xattr_compat.h"\n@#include <sys/xattr.h>\n#include "../darwin_xattr_compat.h"\n@ unless /sys\/xattr\.h/;' $(@D)/libattr/libattr.c
	/usr/bin/perl -0pi -e 's@(^#\s*include <sys/xattr\.h>\n)@$$1#include "../darwin_xattr_compat.h"\n@m unless /darwin_xattr_compat\.h/;' $(@D)/libattr/libattr.c
	/usr/bin/perl -0pi -e 's@#include "../darwin_xattr_compat.h"\n@#include <sys/xattr.h>\n#include "../darwin_xattr_compat.h"\n@ unless /sys\/xattr\.h/;' $(@D)/libattr/attr_copy_fd.c
	/usr/bin/perl -0pi -e 's@(^#\s*include <sys/xattr\.h>\n)@$$1#include "../darwin_xattr_compat.h"\n@m unless /darwin_xattr_compat\.h/;' $(@D)/libattr/attr_copy_fd.c
	/usr/bin/perl -0pi -e 's@#include "../darwin_xattr_compat.h"\n@#include <sys/xattr.h>\n#include "../darwin_xattr_compat.h"\n@ unless /sys\/xattr\.h/;' $(@D)/libattr/attr_copy_file.c
	/usr/bin/perl -0pi -e 's@(^#\s*include <sys/xattr\.h>\n)@$$1#include "../darwin_xattr_compat.h"\n@m unless /darwin_xattr_compat\.h/;' $(@D)/libattr/attr_copy_file.c
	/usr/bin/perl -0pi -e 's@\n\t-Wl,--version-script,[^\n]+\\\n@@g' $(@D)/Makefile
endef
HOST_ATTR_PRE_BUILD_HOOKS += HOST_ATTR_FIX_DARWIN_XATTR_APIS

EOF
        fi
        printf '%s\n' "${line}" >> "${attr_mk}.tmp"
    done < "${attr_mk}"

    mv "${attr_mk}.tmp" "${attr_mk}"
    ok "Patched host-attr to use Darwin xattr compatibility shims."
}

sanitize_path() {
    local entry
    local -a sanitized_entries=()
    local removed=0

    IFS=':' read -r -a path_entries <<< "${PATH:-}"
    for entry in "${path_entries[@]}"; do
        case "${entry}" in
            *[$' \t\n']*)
                removed=$((removed + 1))
                ;;
            '')
                ;;
            *)
                sanitized_entries+=("${entry}")
                ;;
        esac
    done

    if [ "${#sanitized_entries[@]}" -eq 0 ]; then
        err "PATH became empty after removing entries with whitespace."
        exit 1
    fi

    PATH="$(IFS=:; echo "${sanitized_entries[*]}")"
    export PATH

    if [ "${removed}" -gt 0 ]; then
        warn "Removed ${removed} PATH entr$( [ "${removed}" -eq 1 ] && echo y || echo ies ) containing whitespace for Buildroot."
    fi
}

configure_darwin_toolchain() {
    local candidate
    local version
    local best_version=-1
    local best_gcc=""
    local best_gxx=""
    local gxx_candidate=""

    if [ -n "${HOSTCC:-}" ] && [ -n "${HOSTCXX:-}" ]; then
        info "Using caller-provided Buildroot host compiler: ${HOSTCC} / ${HOSTCXX}"
        return 0
    fi

    shopt -s nullglob
    for candidate in /opt/homebrew/bin/gcc-[0-9]* /usr/local/bin/gcc-[0-9]*; do
        version="${candidate##*-}"
        case "${version}" in
            ''|*[!0-9]*)
                continue
                ;;
        esac
        gxx_candidate="${candidate%gcc-*}g++-${version}"
        if [ ! -x "${gxx_candidate}" ]; then
            continue
        fi
        if [ "${version}" -gt "${best_version}" ]; then
            best_version="${version}"
            best_gcc="${candidate}"
            best_gxx="${gxx_candidate}"
        fi
    done
    shopt -u nullglob

    if [ -z "${best_gcc}" ] || [ -z "${best_gxx}" ]; then
        err "Buildroot on macOS needs a real GNU GCC toolchain. Apple clang at /usr/bin/gcc is not sufficient."
        err "Install it with: brew install gcc"
        err "Then rerun this script."
        exit 1
    fi

    export HOSTCC="${best_gcc}"
    export HOSTCXX="${best_gxx}"
    ok "Using Homebrew GNU host compiler: ${HOSTCC} / ${HOSTCXX}"
}

is_gnu_patch() {
    local patch_bin="$1"
    "${patch_bin}" -v 2>&1 | grep -q "GNU patch"
}

is_gnu_find() {
    local find_bin="$1"
    "${find_bin}" --version 2>&1 | grep -q "GNU findutils"
}

configure_darwin_bash() {
    local bash_bin=""

    if command -v bash &>/dev/null; then
        bash_bin="$(command -v bash)"
        if "${bash_bin}" -lc 'mapfile -t _tmp < <(printf "ok\n"); [ "${_tmp[0]}" = "ok" ]' >/dev/null 2>&1; then
            export BASH="${bash_bin}"
            ok "Using bash: ${BASH}"
            return 0
        fi
    fi

    for bash_bin in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [ -x "${bash_bin}" ] && "${bash_bin}" -lc 'mapfile -t _tmp < <(printf "ok\n"); [ "${_tmp[0]}" = "ok" ]' >/dev/null 2>&1; then
            export BASH="${bash_bin}"
            ok "Using Homebrew bash: ${BASH}"
            return 0
        fi
    done

    err "Buildroot on macOS needs a newer bash. The system /bin/bash 3.2 is too old."
    err "Install it with: brew install bash"
    err "Then rerun this script."
    exit 1
}

configure_darwin_coreutils() {
    local gnubin_dir=""

    for gnubin_dir in /opt/homebrew/opt/coreutils/libexec/gnubin /usr/local/opt/coreutils/libexec/gnubin; do
        if [ -x "${gnubin_dir}/realpath" ] && [ -x "${gnubin_dir}/ln" ]; then
            PATH="${gnubin_dir}:${PATH}"
            export PATH
            ok "Using Homebrew coreutils via ${gnubin_dir}"
            return 0
        fi
    done

    err "Buildroot on macOS needs GNU coreutils for consistent host tools."
    err "Install it with: brew install coreutils"
    err "Then rerun this script."
    exit 1
}

configure_darwin_patch() {
    local patch_bin
    local gnubin_dir=""

    patch_bin="$(command -v patch || true)"
    if [ -n "${patch_bin}" ] && is_gnu_patch "${patch_bin}"; then
        ok "Using GNU patch: ${patch_bin}"
        return 0
    fi

    if command -v gpatch &>/dev/null; then
        ensure_host_shim_dir
        ln -sf "$(command -v gpatch)" "${HOST_SHIM_DIR}/patch"
        PATH="${HOST_SHIM_DIR}:${PATH}"
        export PATH
        ok "Using Homebrew GNU patch via $(command -v gpatch)"
        return 0
    fi

    for gnubin_dir in /opt/homebrew/opt/gpatch/libexec/gnubin /usr/local/opt/gpatch/libexec/gnubin; do
        if [ -x "${gnubin_dir}/patch" ]; then
            PATH="${gnubin_dir}:${PATH}"
            export PATH
            ok "Using Homebrew GNU patch via ${gnubin_dir}/patch"
            return 0
        fi
    done

    err "Buildroot on macOS needs GNU patch. The system /usr/bin/patch is BSD patch."
    err "Install it with: brew install gpatch"
    err "Then rerun this script."
    exit 1
}

configure_darwin_findutils() {
    local find_bin
    local gnubin_dir=""

    find_bin="$(command -v find || true)"
    if [ -n "${find_bin}" ] && is_gnu_find "${find_bin}"; then
        ok "Using GNU find: ${find_bin}"
        return 0
    fi

    if command -v gfind &>/dev/null; then
        ensure_host_shim_dir
        ln -sf "$(command -v gfind)" "${HOST_SHIM_DIR}/find"
        PATH="${HOST_SHIM_DIR}:${PATH}"
        export PATH
        ok "Using Homebrew GNU find via $(command -v gfind)"
        return 0
    fi

    for gnubin_dir in /opt/homebrew/opt/findutils/libexec/gnubin /usr/local/opt/findutils/libexec/gnubin; do
        if [ -x "${gnubin_dir}/find" ]; then
            PATH="${gnubin_dir}:${PATH}"
            export PATH
            ok "Using Homebrew GNU find via ${gnubin_dir}/find"
            return 0
        fi
    done

    err "Buildroot on macOS needs GNU findutils. The system /usr/bin/find does not support -printf."
    err "Install it with: brew install findutils"
    err "Then rerun this script."
    exit 1
}

configure_darwin_flock() {
    if command -v flock &>/dev/null; then
        ok "Using flock: $(command -v flock)"
        return 0
    fi

    err "Buildroot on macOS needs flock for serialized downloads."
    err "Install it with: brew install flock"
    err "Then rerun this script."
    exit 1
}

# ── Step 0: Check prerequisites ──
info "Checking prerequisites..."

sanitize_path

if [ "${HOST_OS}" = "Darwin" ]; then
    configure_darwin_bash
    configure_darwin_coreutils
    configure_darwin_toolchain
    configure_darwin_patch
    configure_darwin_findutils
    configure_darwin_flock
    configure_darwin_true_shim
fi

missing=""
for cmd in make gcc g++ wget tar cpio unzip rsync bc file; do
    if ! command -v "$cmd" &>/dev/null; then
        missing="${missing} ${cmd}"
    fi
done

if ! command -v qemu-system-aarch64 &>/dev/null; then
    warn "qemu-system-aarch64 not found."
    if [ "${HOST_OS}" = "Darwin" ]; then
        warn "Install it:  brew install qemu"
    else
        warn "Install it:  sudo apt-get install -y qemu-system-arm"
    fi
    warn "The build will proceed but you'll need QEMU to boot the image."
fi

if [ -n "${missing}" ]; then
    err "Missing required tools:${missing}"
    if [ "${HOST_OS}" = "Darwin" ]; then
        err "Install with Homebrew, for example: brew install wget rsync bc file-formula xz qemu"
    else
        err "Install:  sudo apt-get install -y build-essential wget cpio unzip rsync bc file"
    fi
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

if [ "${HOST_OS}" = "Darwin" ]; then
    patch_darwin_true_refs
    patch_darwin_host_util_linux
    patch_darwin_host_util_linux_gcc15
    patch_darwin_host_util_linux_procfs
    patch_darwin_host_e2fsprogs
    patch_darwin_host_attr
fi

# ── GCC 15+ workaround ──
# GCC 15 defaults to C23 where "maybe_unused" is a keyword, breaking old
# gnulib code bundled with host packages (m4, tar, etc.).  Patch Buildroot's
# HOST_CFLAGS to force gnu17 (the pre-GCC-15 default).  Idempotent.
MAKEFILE_IN="${BR_DIR}/package/Makefile.in"
if ! grep -q 'std=gnu17' "${MAKEFILE_IN}" 2>/dev/null; then
    sed -i.bak 's/^HOST_CFLAGS   ?= -O2$/HOST_CFLAGS   ?= -O2 -std=gnu17/' "${MAKEFILE_IN}"
    rm -f "${MAKEFILE_IN}.bak"
    ok "Patched HOST_CFLAGS with -std=gnu17 for GCC 15+ compatibility."
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

if [ "${HOST_OS}" = "Darwin" ] && [ "${DARWIN_FORCE_CLEAN_HOST_E2FSPROGS}" -eq 1 ]; then
    info "Cleaning host-e2fsprogs so Darwin host recipe changes take effect..."
    make -C "${BR_DIR}" BR2_EXTERNAL="${BR_EXTERNAL}" host-e2fsprogs-dirclean
    : > "${DARWIN_HOST_E2FSPROGS_MARKER}"
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
