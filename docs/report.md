# Kernel-Assisted Protected Execution Subsystem (PEX) SofTEE

## Abstract

Modern operating systems provide strong process isolation but offer limited support for defining protected execution regions inside a process. PEX introduces a kernel-assisted abstraction for intra-process isolation based on protected execution contexts. Each context is created through `/dev/pex`, mapped into a process address space, and guarded by kernel-enforced entry, exit, ownership, and page-fault rules.

The implementation includes a Linux kernel module, a C user-space runtime, console validation programs, and a Tkinter viewer that demonstrates protected media reveal. Sensitive data is only readable while the owner thread is inside protected mode, while unauthorized memory touches and cross-thread entry attempts are denied and counted. PEX shows how conventional operating-system mechanisms such as `ioctl`, `mmap`, fault handling, process accounting, and `/proc` observability can be combined to form a software trusted execution environment.

## 1. Introduction

Traditional operating systems isolate one process from another, but many applications also need protection boundaries between components running inside the same address space. Libraries, worker threads, and helper routines often share a process even when they should not have equal access to sensitive state.

PEX addresses this gap by introducing protected execution contexts that are managed by the kernel but controlled by user space through an explicit runtime API. A context owns a protected memory region, an execution policy, and a set of counters. Access to the mapped region is enabled only while the authorized thread is inside protected mode.

## 2. Motivation

Modern applications increasingly need:

- protection for secrets handled inside a larger process
- controlled entry and exit around sensitive operations
- thread-aware access restrictions
- observable fault and execution statistics

Existing systems usually stop at process-level protection or hardware-specific trusted-execution features. PEX explores how far an operating-system-only design can go using standard Linux mechanisms and a programmable user-space interface.

## 3. Problem Statement

Conventional operating systems do not directly expose a general-purpose abstraction for:

- kernel-enforced intra-process isolation
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
   kernel module implementing `/dev/pex`, `ioctl`, `mmap`, fault handling, and `/proc/pex_stats`
2. `libpex`
   C runtime exposing `pex_open`, `pex_create`, `pex_map`, `pex_enter`, `pex_exit`, `pex_get_info`, `pex_unmap`, `pex_destroy`, and `pex_close`
3. `examples/` and `tests/`
   console programs for validation, blocked-memory proof, thread-policy faults, and performance measurement
4. `demo/pex_viewer.py`
   Tkinter demonstration that reveals an encrypted bundled image only inside protected mode

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

The mapping exists continuously, but page access is granted only when:

- the context is active
- the current thread matches the owner thread

If the context is inactive or the wrong thread touches the mapping, the VMA fault handler logs the violation and returns `VM_FAULT_SIGSEGV`.

### 7.3 Exit Behavior

When the owner calls `pex_exit()`, the kernel updates timing data, flips the context to inactive, and zaps the VMA PTEs so later touches fault again.

## 8. Execution Control

Execution is controlled through explicit transitions:

- `pex_enter()` validates ownership, checks thread policy, and marks the context active
- `pex_exit()` validates state and owner thread, updates counters, and disables mapped-page access again

Direct access to the protected mapping without a successful `pex_enter()` does not succeed, even though the mapping is present in the process address space.

## 9. Access Control Mechanisms

The current implementation enforces:

- process ownership through `owner_tgid`
- optional thread ownership through `PEX_POLICY_OWNER_THREAD_ONLY`
- context activity checks on page faults
- per-context fault accounting

In the demo configuration, every context uses owner-thread-only mode to make cross-thread violations explicit and easy to observe.

## 10. Fault Handling

PEX currently tracks these fault classes:

- `PEX_FAULT_MEM_ACCESS`
  touching the mapped region while the context is inactive or from the wrong thread
- `PEX_FAULT_CROSS_THREAD`
  calling `pex_enter()` or `pex_exit()` from a non-owner thread when thread-only policy is active
- `PEX_FAULT_BAD_STATE`
  entering an already-active context or exiting an inactive one
- `PEX_FAULT_BAD_OWNER`
  process-owner violations

Faults are logged with `pr_warn` and reflected in both per-context and global counters.

## 11. Process And Thread Management

Each context is bound to:

- the creating process
- the creating thread

The thread binding is especially important for the windowed demo, where the main UI thread is the only valid owner. A rogue worker thread that calls `pex_enter()` is denied, and the viewer immediately shows the updated fault count.

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

The repository evaluates the subsystem with five concrete scenarios:

1. memory isolation
   `examples/showcase_blocking.c` demonstrates that touching the mapped region while inactive triggers a real fault
2. execution control
   `examples/protected_workload.c` performs protected work only between `pex_enter()` and `pex_exit()`
3. thread-policy enforcement
   `tests/test_multithread_violation.c` verifies that a secondary thread cannot enter the owner-thread-only context and that fault counters rise
4. protected-media reveal
   `demo/pex_viewer.py` reveals a bundled encrypted PPM image only during protected mode
5. performance
   `tests/benchmark_entry_exit.c` reports average enter/exit overhead

## 15. Results

The implementation successfully demonstrates:

- kernel-assisted intra-process isolation
- owner-thread-only execution control
- page-fault-based protected-memory denial outside active mode
- visible fault accounting for policy violations
- runtime observability through `/proc` and user-space queries

The Tkinter viewer also makes the mechanism intuitive during a live demo by tying the protected-mode transition to a visible image reveal.

## 16. Limitations

PEX is intentionally a software prototype and has important limits:

- it is not hardware-backed trusted execution
- it does not prevent screenshots or secure the display pipeline
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

PEX shows that operating systems can expose a practical, programmable abstraction for fine-grained protected execution within a process. By combining `ioctl`, `mmap`, ownership checks, fault handling, and `/proc` observability, the system creates a software trusted execution environment suitable for research, teaching, and demonstration.

The result is not a replacement for hardware TEEs, but it is a clear demonstration that kernel-enforced execution boundaries and protected-memory access can be built as an operating-system subsystem.

## 19. Demonstration Scenarios

### 19.1 Protected Media Reveal Simulation

The windowed demo uses an encrypted bundled PPM asset. Outside protected mode, the window shows a locked placeholder. After `pex_enter()`, the owner thread decrypts the image into the protected page, copies it into a display buffer, and reveals it. After `pex_exit()`, the protected page is zeroized and the image disappears again.

This demonstrates controlled reveal of sensitive content. It does not claim true screenshot prevention or hardware-backed secure display.

### 19.2 Thread-Isolated Execution

The demo includes a rogue-thread action that spawns a secondary thread and attempts `pex_enter()` on the same context. The kernel rejects the attempt under `PEX_POLICY_OWNER_THREAD_ONLY`, and the fault counter increases.

### 19.3 Controlled Execution Boundaries

Protected work must occur between explicit `pex_enter()` and `pex_exit()` calls. The console showcase reinforces this by proving that inactive mapped-memory access still faults, even though the VMA exists.

### 19.4 Dynamic Page Protection

PEX uses demand-fault handling and PTE zapping on exit to make the mapped region readable and writable only during active protected execution.

### 19.5 Fault Detection And Recovery

Violation attempts are counted and logged. The system remains usable after a denied cross-thread entry attempt, making the fault behavior visible without crashing the main demo flow.

### 19.6 Observability And Monitoring

The viewer refreshes per-context counters through `PEX_IOCTL_GET_CTX_INFO` and global counters through `/proc/pex_stats`, giving live visibility into entries, exits, runtime, and faults.

### 19.7 Secure Application Use Cases

This style of software TEE is suitable for demonstrations and prototypes involving:

- protected key handling
- confidential in-process routines
- per-thread sensitive operations
- DRM-like reveal simulations
- sandboxed computation inside larger applications
