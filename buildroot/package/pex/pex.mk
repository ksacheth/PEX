################################################################################
#
# pex -- Kernel-Assisted Protected Execution Subsystem
#
################################################################################

PEX_VERSION = 1.0
PEX_SITE = $(realpath $(BR2_EXTERNAL_PEX_PATH)/..)
PEX_SITE_METHOD = local
PEX_LICENSE = GPL-2.0
PEX_INSTALL_STAGING = NO
PEX_INSTALL_TARGET = YES
PEX_DEPENDENCIES = linux

# ── Kernel module ────────────────────────────────────────────────────────────
define PEX_BUILD_KERNEL_MODULE
	$(MAKE) $(LINUX_MAKE_FLAGS) \
		-C $(LINUX_DIR) \
		M=$(@D)/kernel \
		modules
endef

# ── Userspace library ────────────────────────────────────────────────────────
define PEX_BUILD_LIBPEX
	$(TARGET_CC) $(TARGET_CFLAGS) -fPIC -Iinclude -c \
		-o $(@D)/libpex/src/pex.o \
		$(@D)/libpex/src/pex.c
	$(TARGET_AR) rcs $(@D)/libpex/libpex.a $(@D)/libpex/src/pex.o
	$(TARGET_CC) -shared -o $(@D)/libpex/libpex.so $(@D)/libpex/src/pex.o
endef

# ── Example and test binaries ────────────────────────────────────────────────
define PEX_BUILD_APPS
	$(TARGET_CC) $(TARGET_CFLAGS) -I$(@D)/libpex/include \
		-o $(@D)/examples/protected_workload \
		$(@D)/examples/protected_workload.c \
		$(@D)/libpex/libpex.a

	$(TARGET_CC) $(TARGET_CFLAGS) -I$(@D)/libpex/include -pthread \
		-o $(@D)/examples/showcase_blocking \
		$(@D)/examples/showcase_blocking.c \
		$(@D)/libpex/libpex.a

	$(TARGET_CC) $(TARGET_CFLAGS) -I$(@D)/libpex/include -pthread \
		-o $(@D)/tests/test_multithread_violation \
		$(@D)/tests/test_multithread_violation.c \
		$(@D)/libpex/libpex.a

	$(TARGET_CC) $(TARGET_CFLAGS) -I$(@D)/libpex/include \
		-o $(@D)/tests/benchmark_entry_exit \
		$(@D)/tests/benchmark_entry_exit.c \
		$(@D)/libpex/libpex.a
endef

# ── Combined build ───────────────────────────────────────────────────────────
define PEX_BUILD_CMDS
	$(call PEX_BUILD_KERNEL_MODULE)
	$(call PEX_BUILD_LIBPEX)
	$(call PEX_BUILD_APPS)
endef

# ── Install into target rootfs ───────────────────────────────────────────────
define PEX_INSTALL_TARGET_CMDS
	# Kernel module
	$(INSTALL) -D -m 0644 $(@D)/kernel/pex.ko \
		$(TARGET_DIR)/lib/modules/pex.ko

	# Shared library
	$(INSTALL) -D -m 0755 $(@D)/libpex/libpex.so \
		$(TARGET_DIR)/usr/lib/libpex.so

	# Example binaries
	$(INSTALL) -D -m 0755 $(@D)/examples/protected_workload \
		$(TARGET_DIR)/opt/pex/protected_workload
	$(INSTALL) -D -m 0755 $(@D)/examples/showcase_blocking \
		$(TARGET_DIR)/opt/pex/showcase_blocking

	# Test binaries
	$(INSTALL) -D -m 0755 $(@D)/tests/test_multithread_violation \
		$(TARGET_DIR)/opt/pex/test_multithread_violation
	$(INSTALL) -D -m 0755 $(@D)/tests/benchmark_entry_exit \
		$(TARGET_DIR)/opt/pex/benchmark_entry_exit

	# Python demo (for --self-check)
	$(INSTALL) -D -m 0755 $(@D)/demo/pex_viewer.py \
		$(TARGET_DIR)/opt/pex/pex_viewer.py

	# Encrypted PPM assets (if any)
	if [ -d $(@D)/demo/assets ]; then \
		mkdir -p $(TARGET_DIR)/opt/pex/assets; \
		cp -a $(@D)/demo/assets/* $(TARGET_DIR)/opt/pex/assets/ 2>/dev/null || true; \
	fi
endef

$(eval $(generic-package))
