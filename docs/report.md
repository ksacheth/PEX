# Kernel-Assisted Protected Execution Subsystem (PEX) SofTEE

## Abstract

Modern operating systems provide strong process isolation but offer limited support for defining protected execution regions inside a process. PEX introduces a kernel-assisted abstraction for fault-gated access control based on protected execution contexts. Each context is created through `/dev/pex`, mapped into a process address space, and guarded by kernel-enforced entry, exit, ownership, and page-fault rules.

The implementation includes a Linux kernel module, a C user-space runtime, console validation programs, and a Tkinter viewer that demonstrates protected media reveal. The VMA fault handler denies a page's initial access while the context is inactive or the faulting thread is not the creator; the owner-thread policy also denies cross-thread entry attempts. Because a successful fault installs a process-wide PTE until exit, this is a fault-gated teaching prototype rather than complete thread-local memory isolation. PEX shows how conventional operating-system mechanisms such as `ioctl`, `mmap`, fault handling, process accounting, and `/proc` observability can be combined into an operating-system-level demonstration.

## 1. Introduction

Traditional operating systems isolate one process from another, but many applications also need protection boundaries between components running inside the same address space. Libraries, worker threads, and helper routines often share a process even when they should not have equal access to sensitive state.

PEX addresses this gap by introducing protected execution contexts that are managed by the kernel but controlled by user space through an explicit runtime API. A context owns a protected memory region, an execution policy, and a set of counters. The fault handler admits a page only when the context is active and the faulting thread is the creator; that check does not run again after the page is present in the process page table.

## 2. Motivation

Modern applications increasingly need:

- protection for secrets handled inside a larger process
- controlled entry and exit around sensitive operations
- thread-aware access restrictions
- observable fault and execution statistics

Existing systems usually stop at process-level protection or hardware-specific trusted-execution features. PEX explores how far an operating-system-only design can go using standard Linux mechanisms and a programmable user-space interface.

## 3. Problem Statement

Conventional operating systems do not directly expose a general-purpose abstraction for:

- kernel-mediated, fault-gated access control within a process
- explicit execution boundaries around protected work
- page-fault-based denial of mapped memory when inactive
- per-context accounting for entries, exits, runtime, and violations

Without such an abstraction, applications must either trust all in-process code equally or build ad hoc protections in user space.

## 4. Objectives

The implemented system has six primary objectives:

1. define a protected execution abstraction inside the operating system
2. enforce protected-memory access through kernel page-fault handling
3. require explicit entry and exit for protected work
4. bind contexts to an owning process and thread
5. detect and count policy violations
6. expose runtime state through query APIs and `/proc`

## 5. System Design

### 5.1 Protected Execution Context

A PEX context is a kernel-managed object containing:

- a protected kernel buffer
- an owning process and thread
- policy flags such as `PEX_POLICY_OWNER_THREAD_ONLY`
- active or inactive execution state
- runtime counters for entries, exits, faults, and protected time

### 5.2 Components

The implementation contains four main layers:

1. `kernel/pex_main.c`
   kernel module implementing `/dev/pex`, fd-lifetime cleanup, `ioctl`, `mmap`, fault handling, and `/proc/pex_stats`
2. `libpex`
   C runtime exposing `pex_open`, `pex_create`, `pex_map`, `pex_enter`, `pex_exit`, `pex_get_info`, `pex_unmap`, `pex_destroy`, and `pex_close`
3. `examples/` and `tests/`
   console programs for validation, blocked-memory proof, thread-policy faults,
   lifetime cleanup, access/limit enforcement, and performance measurement
4. `demo/pex_viewer.py`
   Tkinter demonstration that copies a startup-decrypted bundled image into the mapping after entry, then reveals a normal display-buffer copy

## 6. Architecture

The architecture is layered:

- user application code calls the `libpex` runtime
- the runtime communicates with the kernel through `ioctl` and `mmap`
- the kernel module owns enforcement and accounting
- observability data is returned through `PEX_IOCTL_GET_CTX_INFO` and `/proc/pex_stats`

This keeps policy enforcement in kernel space while leaving demo logic and protected workloads in user space.

## 7. Memory Management

### 7.1 Protected Allocation

Each context allocates a kernel-owned buffer with `vmalloc_user`. User space maps the region with `mmap` on `/dev/pex`, using the context identifier as the page offset selector.

### 7.2 Access Control

The mapping exists continuously. When an access triggers a VMA fault, the
handler admits the page only when:

- the context is active
- the current thread matches the owner thread

If the context is inactive or the wrong thread triggers that fault, the VMA fault handler logs the violation and returns `VM_FAULT_SIGSEGV`. A successful fault inserts a PTE into the process page table. Linux does not re-run the VMA fault handler for later accesses through that PTE, so another thread in the same process can access an already-faulted page until `pex_exit()` zaps the mapping's PTEs. PEX therefore demonstrates fault-gated access, not durable thread-local memory isolation.

### 7.3 Exit Behavior

When the owner calls `pex_exit()`, the kernel updates timing data, flips the context to inactive, and zaps the VMA PTEs so later touches fault again.

### 7.4 Context Lifetime

Each open `/dev/pex` file keeps a private list of the contexts it created. On the
final close of that file, the module removes those contexts from the global
lookup table, deactivates any active context, and revokes its mapped PTEs before
dropping the table reference. A mapped VMA holds a separate context reference;
the VMA `open` callback acquires an additional reference when Linux splits the
mapping, and each VMA close releases one. The mapping retains the `mm_struct`
with `mmgrab()`/`mmdrop()`, rather than keeping an `mm_users` reference.

### 7.5 Allocation Authorization And Limits

The setup script creates `/dev/pex` with owner `root`, mode `0660`, and an
authorized group. On a host, that group defaults to the primary group of the
user who invoked `sudo`; an administrator can instead set the existing
`PEX_DEVICE_GROUP` environment variable. Buildroot defaults to the `root`
group. Users outside the device group cannot open the device.

The kernel serializes context creation and enforces a 16 MiB maximum context
size, 8 contexts or 16 MiB per process, and 64 contexts or 64 MiB across the
module. It returns `-E2BIG` for an oversized individual context and `-EDQUOT`
when a process or global quota would be exceeded. `/proc/pex_stats` also reports
`live_bytes` alongside the context and fault counters.

## 8. Execution Control

Execution is controlled through explicit transitions:

- `pex_enter()` validates process ownership, conditionally checks
  `PEX_POLICY_OWNER_THREAD_ONLY`, and marks the context active
- `pex_exit()` validates state and the creator thread, updates counters, and
  invalidates mapped PTEs again

After `pex_exit()` has invalidated its PTEs, direct access to the protected mapping without a successful `pex_enter()` faults, even though the VMA remains in the process address space.

## 9. Access Control Mechanisms

The current implementation enforces:

- process ownership for context operations through `owner_tgid`
- optional creator-thread enforcement for `pex_enter()` through
  `PEX_POLICY_OWNER_THREAD_ONLY`
- creator-thread and activity checks when a page faults
- device-node authorization through `root:<authorized-group>` mode `0660`
- per-process and global allocation quotas
- per-context fault accounting

The flag does not make the whole context shareable when it is absent: the current fault and `pex_exit()` paths require the creator thread unconditionally. In the demo configuration, every context sets the flag so a cross-thread `pex_enter()` attempt is explicitly rejected and counted.

## 10. Fault Handling

PEX currently tracks these fault classes:

- `PEX_FAULT_MEM_ACCESS`
  touching the mapped region while the context is inactive or from the wrong thread
- `PEX_FAULT_CROSS_THREAD`
  calling `pex_enter()` from a non-owner thread when thread-only policy is active, or calling `pex_exit()` from a non-owner thread
- `PEX_FAULT_BAD_STATE`
  entering an already-active context or exiting an inactive one
- `PEX_FAULT_BAD_OWNER`
  process-owner violations

Faults are logged with `pr_warn` and reflected in both per-context and global counters.

## 11. Process And Thread Management

Each context is bound to:

- the creating process
- the creating thread

The thread binding is especially important for the windowed demo, where the main UI thread is the only valid owner. A rogue worker thread that calls `pex_enter()` is denied, and the viewer immediately shows the updated fault count. This proves entry control only; it does not prove that a secondary thread cannot read a page the owner has already faulted in while the context remains active.

## 12. Scheduling And Accounting

PEX records:

- total entries
- total exits
- total faults
- accumulated protected execution time in nanoseconds

The benchmark in `tests/benchmark_entry_exit.c` measures average `pex_enter()` plus `pex_exit()` latency across repeated iterations.

## 13. Observability

Observability is provided through two interfaces:

- `PEX_IOCTL_GET_CTX_INFO`
  per-context structured state for applications and the Tkinter viewer
- `/proc/pex_stats`
  global summary plus human-readable per-context lines

Example fields include:

- `live_contexts`
- `active_contexts`
- `total_faults`
- per-context `entries`, `exits`, `faults`, `ns`, and `name`

## 14. Experimental Evaluation

The repository contains seven concrete evaluation scenarios:

1. inactive-memory fault gating
   `examples/showcase_blocking.c` demonstrates that touching the mapped region while inactive triggers a real fault
2. execution control
   `examples/protected_workload.c` performs protected work only between `pex_enter()` and `pex_exit()`
3. thread-policy enforcement
   `tests/test_multithread_violation.c` verifies that a secondary thread cannot enter the owner-thread-only context and that fault counters rise
4. protected-media reveal
   `demo/pex_viewer.py` copies a startup-decrypted PPM into the mapping after entry and reveals a normal display-buffer copy
5. context lifetime
   `tests/test_lifetime_cleanup.c` checks close-without-destroy, `SIGKILL` while mapped and active, and split-VMA teardown against the initial `/proc/pex_stats` counts
6. access control and resource limits
   `tests/test_access_limits.c` drops a child to an unprivileged UID, then verifies per-process and global context/byte quota denial and recovery after close
7. performance
   `tests/benchmark_entry_exit.c` reports average enter/exit overhead

## 15. Results

The implementation successfully demonstrates:

- kernel-assisted context lifecycle and fault-gated memory access
- owner-thread-only entry control when the corresponding policy flag is set
- page-fault-based protected-memory denial outside active mode
- fd-close cleanup, including active-context deactivation and split-VMA reference accounting. The new regression passed on Ubuntu 24.04 with Linux 6.8.0-139-generic and `rmmod pex` succeeded afterward; the aarch64 Buildroot/QEMU image remains untested.
- root-and-authorized-group device access, plus bounded per-process and global context/byte allocation. The access-limit regression passed on Ubuntu 24.04 with Linux 6.8.0-139-generic; the aarch64 Buildroot/QEMU image remains untested.
- visible fault accounting for policy violations
- runtime observability through `/proc` and user-space queries

The Tkinter viewer also makes the mechanism intuitive during a live demo by tying the protected-mode transition to a visible image reveal.

## 16. Limitations

PEX is intentionally a software prototype and has important limits:

- it is not hardware-backed trusted execution
- it does not prevent screenshots or secure the display pipeline
- it decrypts the bundled image in user space at viewer startup and renders a
  normal display-buffer copy
- it does not provide durable thread-local memory isolation: a page already
  faulted in by the creator may be readable by another thread in the same
  process until `pex_exit()` invalidates its PTE
- `PEX_POLICY_OWNER_THREAD_ONLY` controls `pex_enter()` only; the fault and
  exit paths still require the creator thread when the flag is absent
- the viewer uses a 2 MiB mapping rather than a single protected page
- it does not mediate arbitrary syscalls made by protected code
- it does not currently support coordinated multi-process sharing
- it relies on a loadable kernel module rather than upstream kernel integration

## 17. Future Work

Useful next steps include:

- upstreaming the abstraction into a teaching or research kernel tree
- richer policies for shared or delegated ownership
- syscall filtering or capability reduction during protected execution
- stronger event logging and structured fault records
- experiments with hardware-assisted secure display or secure memory

## 18. Conclusion

PEX shows that operating systems can expose a practical, programmable abstraction for fault-gated protected execution within a process. By combining `ioctl`, `mmap`, ownership checks, fault handling, and `/proc` observability, the system provides a bounded teaching and demonstration prototype.

The result is not a replacement for hardware TEEs or a complete in-process isolation boundary, but it is a clear demonstration that kernel-enforced lifecycle transitions and fault-gated memory access can be built as an operating-system subsystem.

## 19. Demonstration Scenarios

### 19.1 Protected Media Reveal Simulation

The windowed demo uses an encrypted bundled PPM asset. It decrypts that asset in user space during viewer startup. Outside protected mode, the window shows a locked placeholder. After `pex_enter()`, the owner thread copies the already-decrypted bytes into the 2 MiB protected mapping, copies them again into a normal display buffer, and reveals the image. After `pex_exit()`, the mapping and display buffer are zeroized and the image disappears again.

This demonstrates controlled reveal of sensitive content. It does not claim true screenshot prevention or hardware-backed secure display.

### 19.2 Thread-Policy Entry Control

The demo includes a rogue-thread action that spawns a secondary thread and attempts `pex_enter()` on the same context. The kernel rejects the attempt under `PEX_POLICY_OWNER_THREAD_ONLY`, and the fault counter increases.

### 19.3 Controlled Execution Boundaries

Protected work must occur between explicit `pex_enter()` and `pex_exit()` calls. The console showcase reinforces this by proving that inactive mapped-memory access still faults, even though the VMA exists.

### 19.4 Dynamic Page Protection

PEX uses demand-fault handling and PTE zapping on exit to make a page fault again after protected execution ends. During active execution, an already-inserted PTE is process-wide and does not cause the fault handler to re-check the accessing thread.

### 19.5 Fault Detection And Recovery

Violation attempts are counted and logged. The system remains usable after a denied cross-thread entry attempt, making the fault behavior visible without crashing the main demo flow.

### 19.6 Observability And Monitoring

The viewer refreshes per-context counters through `PEX_IOCTL_GET_CTX_INFO` and global counters through `/proc/pex_stats`, giving live visibility into entries, exits, runtime, and faults.

### 19.7 Secure Application Use Cases

This teaching prototype is suitable for demonstrations of:

- context lifecycle control
- fault-gated access after exit
- denied cross-thread entry attempts
- encrypted-asset reveal simulations without secure-display claims
