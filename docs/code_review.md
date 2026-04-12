# PEX (SoftTEE) — Full Code Review

## Overall Verdict

The project compiles, the architecture makes sense, and the demo flow is well-structured. But there are several **correctness bugs** — including two that will silently corrupt behaviour at runtime — plus a handful of design and style issues. The most critical bugs live in the kernel module and the mmap offset logic.

---

## 1. Kernel Module — [pex_main.c](file:///home/parallels/SoftTEE/kernel/pex_main.c)

### 🔴 Critical Bugs

#### 1.1 `pex_ctx_create` leaks the context on `copy_to_user` failure (line 131-133)

```c
if (copy_to_user(argp, &req, sizeof(req)))
    return -EFAULT;          // ← ctx is already in the hash table and live_contexts incremented
```

If `copy_to_user` fails, the newly-created context is already inserted into the hash table and the live-context counter has been incremented, but the user never learns the `ctx_id`. The context is **permanently leaked** — nothing will ever destroy it.

**Fix:** Either remove the context from the hash table and free it on failure, or copy back before inserting.

#### 1.2 `pex_ctx_create` first ID is 2, not 1 (line 115)

```c
static atomic_t g_next_ctx_id = ATOMIC_INIT(1);
// ...
id = atomic_inc_return(&g_next_ctx_id);   // returns 2 on first call
```

`atomic_inc_return` pre-increments, so the first context ID is **2**. This isn't a crash, but it's inconsistent with the mental model (starts at 1) and means `ctx_id == 1` is never used. If `ctx_id <= 0` is used as "invalid" in userspace (which it is — see `pex.c` line 69, 92, 106, etc.), this is safe but wasteful and confusing.

**Fix:** Initialize to `ATOMIC_INIT(0)` so the first ID is 1.

#### 1.3 `pex_vma_fault` takes a mutex in the page-fault path (line 381)

```c
mutex_lock(&ctx->lock);
```

This is logically correct but **dangerous**. The page-fault handler runs with `mmap_read_lock` held. Taking a mutex from within `pex_vma_fault` is legal but creates a lock-ordering dependency: if any other code path holds `ctx->lock` and then calls `mmap_write_lock`, you get a deadlock (**ABBA**).

This is exactly what happens in `pex_ctx_exit` (line 265-273):

```c
mutex_lock(&ctx->lock);    // A
// ...
mmap_write_lock(ctx->mapped_mm);   // B — deadlock if fault path holds B and waits on A
```

If another thread faults on the VMA while the owner thread is inside `pex_ctx_exit` holding `ctx->lock` and waiting for `mmap_write_lock`, the fault handler will try `mutex_lock(&ctx->lock)` and deadlock.

**Fix:** Use a spinlock or rwlock for the `active` flag check in the fault path, or restructure `pex_ctx_exit` to drop `ctx->lock` before taking `mmap_write_lock`.

#### 1.4 `pex_exit` calls `zap_vma_ptes` — API availability / safety (line 271)

`zap_vma_ptes` is a helper that not all kernel versions export. On 6.x kernels it was reworked. There's no version guard here (unlike the `vm_flags_set` guard on line 466). If the kernel doesn't export it, the module won't load.

Also, calling `zap_vma_ptes` while holding `ctx->lock` and `mmap_write_lock` is fine in isolation, but contributes to the deadlock risk above.

#### 1.5 Reading `ctx` fields under spinlock without refcount (lines 351-358)

In `pex_proc_read`, context fields are read while holding `g_ctx_table_lock` (spinlock). No `kref_get` is taken, so the context could theoretically be freed by another CPU between the `hash_del` in `pex_ctx_destroy` and here. In practice this race is narrow because `pex_ctx_destroy` also takes the spinlock, so the iteration is protected. However, accessing `ctx->name` (a string) under a spinlock is fine for `scnprintf`, but accessing `total_ns` etc. without the mutex means you could read torn 64-bit values on 32-bit architectures.

### 🟡 Design Concerns

#### 1.6 No `pex_vma_open` handler

The `vm_operations_struct` defines `.close` but not `.open`. If the VMA is split (e.g. by `mprotect` on a sub-range), the kernel calls `.open` on the new VMA. Without `.open`, the `vm_private_data` pointer in the new VMA will be valid but the refcount won't be incremented, leading to a use-after-free when `.close` is called on both halves.

**Fix:** Either add `.open` that calls `kref_get`, or set `VM_DONTEXPAND` on the VMA to prevent splitting.

#### 1.7 `pex_exit` wipes only if `ctx->mapped_mm` matches (line 265)

If a different mm maps the context (shouldn't normally happen due to the tgid check in mmap, but after `fork` it could via COW), the zap won't happen. This is probably fine given `VM_DONTCOPY`, but worth documenting.

#### 1.8 Module cleanup calls `kref_put` under spinlock (line 554)

```c
spin_lock_irqsave(&g_ctx_table_lock, flags);
hash_for_each_safe(g_ctx_table, bkt, tmp, ctx, hnode) {
    hash_del(&ctx->hnode);
    kref_put(&ctx->refcount, pex_ctx_release);   // may call vfree, kfree
}
spin_unlock_irqrestore(&g_ctx_table_lock, flags);
```

`pex_ctx_release` calls `vfree` and `kfree`, which may sleep. Calling these under a spinlock with IRQs disabled is **illegal** and will trigger a `BUG: sleeping function called from invalid context` on debug kernels.

**Fix:** Collect contexts into a list outside the spinlock, then free them.

---

## 2. UAPI Header — [pex_uapi.h](file:///home/parallels/SoftTEE/libpex/include/pex_uapi.h)

### 🟡 Issues

#### 2.1 Kernel types in userspace-visible header

The header uses `#include <linux/ioctl.h>` and `#include <linux/types.h>`, which is correct for kernel-side but means userspace code that includes this via `pex.h` must have Linux UAPI headers installed. This works on Linux but is unusual — normally UAPI headers are self-contained or wrapped.

#### 2.2 `pex_ctx_info.active` type mismatch

In the kernel, `ctx->active` is `bool` (line 34 of pex_main.c), but `pex_ctx_info.active` is `__u32`. The assignment `info.active = ctx->active` on line 299 widens bool → u32, which is fine, but the reverse (if anyone writes to it) is not guarded. Minor.

#### 2.3 `pex_fault_event` is declared but never used

The struct is defined but no ioctl or read path exposes it. Dead code — either implement the fault event ring or remove the struct.

---

## 3. Userspace Library — [pex.c](file:///home/parallels/SoftTEE/libpex/src/pex.c) / [pex.h](file:///home/parallels/SoftTEE/libpex/include/pex.h)

### 🔴 Critical Bug

#### 3.1 `pex_map` mmap offset vs. kernel `vm_pgoff` mismatch (line 143)

```c
off = ((off_t)h->ctx_id) << 12;
addr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, h->fd, off);
```

The kernel's `pex_mmap` reads the context ID as:

```c
int ctx_id = (int)vma->vm_pgoff;   // kernel/pex_main.c:433
```

`vma->vm_pgoff` is `offset / PAGE_SIZE`. So if the user passes `off = ctx_id << 12`, then `vm_pgoff = (ctx_id << 12) / 4096 = ctx_id` — this works **only if PAGE_SIZE is 4096**. On ARM64 with 16K or 64K pages, this breaks:

- 16K pages: `vm_pgoff = (ctx_id << 12) / 16384 = ctx_id / 4` (truncated)
- 64K pages: `vm_pgoff = (ctx_id << 12) / 65536 = ctx_id / 16` (truncated)

**Fix:** Use `off = (off_t)h->ctx_id * sysconf(_SC_PAGESIZE)` or `off = (off_t)h->ctx_id * page_size` (you already have `page_size` from the line above).

### 🟡 Minor Issues

#### 3.2 `pex_close` doesn't call `pex_destroy`

If the user calls `pex_close` without `pex_destroy`, the kernel context remains alive (leaked). This is a valid design choice (the user is responsible for the lifecycle), but it would be safer to auto-destroy in `pex_close` or at least document the requirement prominently.

---

## 4. Examples

### [showcase_blocking.c](file:///home/parallels/SoftTEE/examples/showcase_blocking.c)

#### 🟡 4.1 `siglongjmp` from a signal handler into a `pthread` program (line 20)

Using `siglongjmp` from `SIGSEGV` is technically undefined behaviour in POSIX. In practice it works on Linux/glibc for single-threaded signal handling, but it's fragile. If the signal fires on a thread other than the main thread, the `g_jmp` buffer (thread-local would be needed) will corrupt the stack. Since this demo only calls `guarded_write_ul`/`guarded_read_ul` from the main thread before/after the pthread section, it's OK in practice, but the cross-thread `pex_enter` in `cross_thread_enter` could itself trigger a fault if the memory access is made from that thread. Currently it doesn't touch the mapped region from the rogue thread, so this is safe.

### [protected_workload.c](file:///home/parallels/SoftTEE/examples/protected_workload.c)

Looks correct. Clean lifecycle management with `goto cleanup`. No issues found.

---

## 5. Tests

### [test_multithread_violation.c](file:///home/parallels/SoftTEE/tests/test_multithread_violation.c)

#### 🟡 5.1 Race on `g_thread_rc`

`g_thread_rc` is a plain `int` written by the spawned thread and read by the main thread after `pthread_join`. Since `pthread_join` provides a happens-before guarantee, this is actually safe. No issue.

✅ Test logic is correct.

### [benchmark_entry_exit.c](file:///home/parallels/SoftTEE/tests/benchmark_entry_exit.c)

✅ Clean and correct. The benchmark properly measures wall-clock time for enter/exit cycles.

---

## 6. Python Demo — [pex_viewer.py](file:///home/parallels/SoftTEE/demo/pex_viewer.py)

### 🟡 Issues

#### 6.1 `PexCtxInfo` ctypes struct may have wrong layout due to padding

```python
class PexCtxInfo(ctypes.Structure):
    _fields_ = [
        ("ctx_id", ctypes.c_int32),       # offset 0
        ("owner_tgid", ctypes.c_int32),   # offset 4
        ("owner_tid", ctypes.c_int32),     # offset 8
        ("active", ctypes.c_uint32),      # offset 12
        ("policy_flags", ctypes.c_uint32),# offset 16
        ("size", ctypes.c_uint64),        # offset 24 (after 4 bytes padding)
        ...
    ]
```

The C struct has `__u32 policy_flags` followed by `__u64 size`. On most architectures (x86_64, ARM64), the compiler inserts 4 bytes of padding between `policy_flags` and `size` to align `size` to 8 bytes. ctypes does this too by default, so this should match. However, if the kernel struct ever gets `__packed`, this will break silently. Worth adding `_pack_ = 1` or verifying with a `static_assert(sizeof(...))` in the C code.

#### 6.2 `ctypes.memset(self.mapped_addr, 0, MAP_SIZE)` after `pex_exit` (line 461)

In `exit_protected_mode`, `_wipe_protected_buffer()` is called **before** `pex_exit()`. This is correct — the wipe happens while the context is still active (memory is accessible). Good.

#### 6.3 `_wipe_protected_buffer` could crash if context is inactive

`_wipe_protected_buffer` at line 429 calls `ctypes.memset(self.mapped_addr, 0, MAP_SIZE)`. If called when the context is inactive, this will trigger a SIGSEGV (caught by the kernel fault handler). It's only called from `exit_protected_mode` (where active is true) and `on_close` (where active is checked first), so this is safe in practice.

#### 6.4 Thread safety of `self.runtime.enter()` from rogue thread (line 480)

The rogue thread calls `self.runtime.enter()` which calls `self._lib.pex_enter(...)`. The `PexHandle` struct is shared across threads. The `ioctl` call itself is thread-safe (it goes to the kernel), but the ctypes `byref(self.handle)` creates a pointer to the same `PexHandle` struct. Since `pex_enter` only reads from the handle (doesn't modify it), this is safe.

---

## 7. Build System

### [Root Makefile](file:///home/parallels/SoftTEE/Makefile)

#### 🟡 7.1 `make all` does NOT build the kernel module

```makefile
all: lib examples tests demo
```

The README says "build everything except the kernel module with `make all`", which matches. But `demo_script.md` says:

```
make all
make kernel
```

This is fine — just worth noting that `make all` alone is not sufficient for a working demo.

#### 7.2 `run-showcase` builds and loads but doesn't unload

`run-showcase` calls `dev_setup.sh` (which loads the module) and then runs the showcase. The module is left loaded. This is expected behaviour for a dev workflow, just documenting.

### [libpex Makefile](file:///home/parallels/SoftTEE/libpex/Makefile)

✅ Clean. Builds both static and shared libraries.

### [kernel Makefile](file:///home/parallels/SoftTEE/kernel/Makefile)

✅ Standard out-of-tree module build.

---

## 8. Scripts

### [dev_setup.sh](file:///home/parallels/SoftTEE/scripts/dev_setup.sh)

#### 🟡 8.1 `modprobe -r` vs `rmmod`

Line 26 uses `modprobe -r pex`, but the module is loaded with `insmod` (not `modprobe`). `modprobe -r` should still work — it looks up the loaded module by name, not by how it was loaded. However, if the module isn't in the standard module path, `modprobe -r` may not find it. Using `rmmod pex` would be more reliable.

#### 🟡 8.2 Manual `mknod` despite `udev`

The script creates `/dev/pex` manually and `chmod 666`. Since the module uses `class_create` + `device_create`, udev should create the device node automatically. The manual `mknod` will work but may conflict with udev (creating a duplicate node). The `rm -f /dev/pex` before `mknod` handles this, but it would be cleaner to let udev manage it.

### [run_all.sh](file:///home/parallels/SoftTEE/scripts/run_all.sh)

✅ Clean. Uses `|| true` for expected-failure examples.

---

## 9. Documentation

### [README.md](file:///home/parallels/SoftTEE/README.md)

#### 🟡 9.1 Broken doc links (lines 123-124)

```markdown
- Project/report writeup: [docs/report.md](/home/ubuntu/OS/PEX/docs/report.md)
- Live narration and demo checklist: [docs/demo_script.md](/home/ubuntu/OS/PEX/docs/demo_script.md)
```

These point to `/home/ubuntu/OS/PEX/...` — a completely different path. Should be relative: `docs/report.md` and `docs/demo_script.md`.

#### 9.2 `docs/report.md` doesn't exist

The README references a report file, but there's no `docs/report.md` in the repo. Either add it or remove the reference.

---

## Priority-Ordered Fix List

| # | Severity | File | Issue |
|---|----------|------|-------|
| 1 | 🔴 Critical | `pex_main.c` | `kref_put` / `vfree` / `kfree` called under spinlock in module exit (§1.8) |
| 2 | 🔴 Critical | `pex_main.c` | ABBA deadlock between `ctx->lock` and `mmap_write_lock` in exit vs fault path (§1.3) |
| 3 | 🔴 Critical | `pex_main.c` | Context leak on `copy_to_user` failure in `pex_ctx_create` (§1.1) |
| 4 | 🔴 Critical | `pex.c` | `pex_map` offset calculation assumes 4K pages (§3.1) |
| 5 | 🟡 Medium | `pex_main.c` | Missing `.open` VMA handler → use-after-free on VMA split (§1.6) |
| 6 | 🟡 Medium | `pex_main.c` | `zap_vma_ptes` availability not version-guarded (§1.4) |
| 7 | 🟡 Low | `pex_main.c` | First context ID is 2 instead of 1 (§1.2) |
| 8 | 🟡 Low | `pex_uapi.h` | `pex_fault_event` struct is dead code (§2.3) |
| 9 | 🟡 Low | `README.md` | Broken absolute-path doc links (§9.1) |
| 10 | 🟡 Low | `README.md` | Missing `docs/report.md` file (§9.2) |

---

## Summary

The overall architecture is solid — a real kernel module with device file, ioctl interface, procfs observability, user-space library, and a demo GUI is a well-rounded system project. The userspace code (library, examples, tests, Python demo) is clean and well-structured.

The kernel module has the most issues, which is expected — kernel code is simply harder to get right. The **three critical kernel bugs** (spinlock + sleeping allocation, ABBA deadlock, and context leak) should be fixed before any demo. The **mmap offset assumption** in `pex_map` is a portability bug that will bite on non-4K-page architectures (common on ARM64).
