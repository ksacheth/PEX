# PROJECT DOSSIER: PEX SofTEE (Kernel-Assisted Protected Execution Subsystem)
Evidence refreshed on 2026-09-16 at commit `6513a83`.
Last verified by me: [AUTHOR TO FILL]

> **Evidence convention.** `path:N` = file and line at commit `6513a83`. `git:<sha>` = commit evidence.
> **Tags.** `[VERIFY]` = inferred by reading, not observed running. `[AUTHOR TO FILL]` = only the project owner can answer.
> **Before trusting this file:** resolve every tag, then set "Last verified by me".

---

## 1. Identity
- **One-line pitch:** A Linux kernel module plus a C runtime that creates a fault-gated protected-execution context inside a single process. An inactive or wrong-thread first touch faults; an already-installed PTE remains process-wide until exit. (`README.md:3`, `kernel/pex_main.c:460-489`)
- **Repo URL:** https://github.com/ksacheth/PEX (`git remote -v`; also `buildroot/package/pex/Config.in:10`)
- **Status:** Local only. No hosted deployment; nothing to deploy. It runs in two places:
  - (a) on a host Linux machine with matching kernel headers (`README.md:163-170`);
  - (b) in a Buildroot aarch64 image booted under QEMU (`buildroot/run_qemu.sh:194-202`).
  - Host-Linux path verified on 2026-09-16 on the Parallels VM; the module built and loaded, and the named baseline programs passed. I have no recorded QEMU validation run. (`experiments/logs/phase1-make-kernel.log`, `experiments/logs/phase1-device-listing.log`, `experiments/logs/phase1-protected-workload.log`, `experiments/logs/phase1-showcase-blocking.log`, `experiments/logs/phase1-test-multithread-violation.log`, `experiments/logs/phase1-viewer-self-check.log`)
- **Timeline (from `git log`):** 2026-03-03 17:06 +0530 (`git:b317854`) to 2026-04-21 16:16 +0530 (`git:6513a83`). That is about 7 weeks, with 13 commits.
  - Commit days: 2026-03-03 (3), 2026-04-03 (2), 2026-04-11 (2), 2026-04-12 (2), 2026-04-19 (1), 2026-04-21 (3).
  - Approx hours spent: Unknown. Do not claim.
- **Course / context (class, deadline, grading):** I built PEX as a course project.

### Commit history
| Commit | Date | What changed (from `git show --stat`) |
|---|---|---|
| `b317854` | 2026-03-03 | Initial commit; README only |
| `55ab537` | 2026-03-03 | Project structure, Makefile, `tee_sim.h` API stubs (pre-pivot design) |
| `40446fe` | 2026-03-03 | `src/loader.c`: `dlopen` enclave loader + OpenSSL SHA-256 of the enclave file (pre-pivot) |
| `62f49d5` | 2026-04-03 | `tee_destroy()` added (pre-pivot) |
| `da05db6` | 2026-04-03 | Merge PR #1 (parent `62f49d5`) |
| `6fcf5bf` | 2026-04-11 | **Architecture pivot.** Deleted `src/`, `include/`, `samples/*.c`. Added `kernel/pex_main.c` (566 lines), `libpex/`, examples, tests, `demo/pex_viewer.py` (651 lines), `docs/`, `scripts/`. 30 files, +2924/−219 |
| `8ceb3b8` | 2026-04-11 | Added image assets (`assets/test.jpg`, `assets/test.ppm`, encrypted hex); viewer changes (+159/−47) |
| `b8c481e` | 2026-04-12 | Buildroot integration: 15 files, +647. Vendored `buildroot-2024.02.12.tar.xz` (5.5 MB) |
| `6b3e66a` | 2026-04-12 | Merge PR #2 (parent `b8c481e`) |
| `ec888cb` | 2026-04-19 | "fix for darwin": `build_image.sh` +545 lines of macOS host patches |
| `8e47eb0` | 2026-04-21 | README rewrite; `build_image.sh` / `run_qemu.sh` rootfs-size and fsck checks |
| `1685fb4` | 2026-04-21 | Kernel mapping fix: `vmf_insert_pfn` + `VM_PFNMAP`; PTE zap moved outside `ctx->lock`. Showcase now returns failure; viewer path resolution |
| `6513a83` | 2026-04-21 | Non-Linux fallback types in `pex_uapi.h`; `pex.mk` include/rsync fix; committed binary `samples/host` |

- **Project scope vs external components:**
    - Linux kernel APIs (kbuild, `vmalloc_user`, `vmf_insert_pfn`, `zap_vma_ptes`);
    - Buildroot 2024.02.12 (vendored tarball, `buildroot/build_image.sh:14-17`);
    - Linux 6.6.87 (`buildroot/configs/pex_aarch64_virt_defconfig:16`);
    - QEMU, glibc/pthreads, and the Python stdlib (ctypes, tkinter).
  - Source and license of `assets/test.jpg` (6000×3376 JPEG): Unknown. Do not claim.

## 2. Problem & Users
- **Problem it solves (as documented):** Operating systems isolate processes from each other. They do not offer a general way to isolate a sensitive region *inside* one process. PEX adds kernel-enforced entry/exit, owner-thread binding, fault-gated memory, and per-context accounting. (`docs/report.md:9-35`)
- **Explicit non-goal (documented):** "kernel-assisted intra-process isolation, not hardware-backed trusted execution." (`README.md:21`; `docs/report.md:203-209`)
- **Who uses it:** No evidence of real users anywhere in the repo: no telemetry, no issues referenced, no deployment. The docs frame it for "research, teaching, and demonstration" (`docs/report.md:223`). Actual users/audience: Unknown. Do not claim.
- **Why I built it:** I built it as a course project; the specific personal motivation is unknown. Do not claim beyond the documented aim to explore "how far an operating-system-only design can go" (`docs/report.md:24`).

## 3. Architecture
- **Components and how they connect:**
```
  demo/pex_viewer.py (Tkinter UI) ──ctypes──┐          examples/*.c, tests/*.c
  loads libpex.so (pex_viewer.py:32-47)     │          static-link libpex.a (Makefile:16-22)
                                            ▼                     │
                         libpex  (libpex/src/pex.c) ◄─────────────┘
                           open / ioctl / mmap on /dev/pex
                                            │
  ───────────────────── user / kernel boundary ─────────────────────
                                            ▼
                    pex.ko  (kernel/pex_main.c, char device "pex")
     ┌──────────────────────┬─────────────────────────┬─────────────────────────┐
  pex_open/release     pex_mmap() + pex_vm_ops      /proc/pex_stats
  CREATE/DESTROY/      .fault = pex_vma_fault       pex_proc_read()
  ENTER/EXIT/INFO       .open/.close hold VMA refs    (pex_main.c:418-451)
  (pex_main.c:399-415) (pex_main.c:460-630)
     └──────────────┬───────┴─────────────────────────┘
      global hashtable g_ctx_table (64 buckets, spinlock)  (pex_main.c:24,48-49)
        └─ struct pex_context: vmalloc_user buffer, owner tgid/tid, policy,
           active flag, counters, mapping/VMA info, kref, mutex (pex_main.c:27-49)
```
- **Shared ABI:** `libpex/include/pex_uapi.h` is included by both the kernel (`kernel/pex_main.c:22`) and userspace (`libpex/include/pex.h:7`).
  - It defines the ioctls `_IOWR/_IOW('P', 1..5)` (`pex_uapi.h:76-81`).
  - **Drafting check (x86-64 sandbox):** the ctypes mirror in Python matches the C layout on x86-64: both are 64 bytes, with `size` at offset 24. The aarch64 layout was not size-checked, but the viewer `--self-check` passed there. (`experiments/logs/phase1-viewer-self-check.log`)

- **Request/data flow for the main feature (fault-gated protected memory), step by step:**
  1. **Open.** `pex_open()` calls `open("/dev/pex", O_RDWR)` (`libpex/src/pex.c:22`). The kernel allocates a per-file context list (`pex_main.c:578-588`).
  2. **Create.** `pex_create()` sends `ioctl(PEX_IOCTL_CREATE_CTX)` (`pex.c:58`). The kernel:
     - rejects size 0, a context over 16 MiB, and per-process or global quota excess (`pex_main.c:168-203`);
     - serializes allocation admission, then `kzalloc`s the context and `vmalloc_user(size)`s the buffer (`:225-239`);
     - assigns an id with `atomic_inc_return` (`:115`);
     - records the owner tgid/tid (`:117-118`);
     - inserts the context into both the global table and the creating file's list under the spinlock (`pex_main.c:225-228`);
     - copies the id back (`:128-131`).
  3. **Map.** `pex_map()` requires size to be a multiple of the page size (`pex.c:139-141`). It calls `mmap(..., MAP_SHARED, fd, ctx_id << 12)` (`pex.c:143-144`). The kernel's `pex_mmap()`:
     - reads `ctx_id = vm_pgoff` (`pex_main.c:443`);
     - requires the same tgid (`:455`), `len <= size` and page-aligned (`:460`), and at most one mapping per context (`:465`, `-EBUSY`);
     - takes an `mm_count` reference with `mmgrab()` and records one VMA reference (`pex_main.c:561-565`);
     - sets `VM_DONTCOPY | VM_DONTDUMP | VM_DONTEXPAND | VM_PFNMAP` (`:567-571`);
     - installs `pex_vm_ops` (`:572-573`).
     - **No pages are inserted at mmap time.**
  4. **Touch while inactive.** The access goes to `pex_vma_fault()`. If `!ctx->active` or `current tid != owner_tid`, the kernel logs a `PEX_FAULT_MEM_ACCESS` fault and returns `VM_FAULT_SIGSEGV` (`pex_main.c:393-396`). The showcase catches the signal with `sigsetjmp`/`siglongjmp` (`examples/showcase_blocking.c:15-41`).
  5. **Enter.** `pex_enter()` sends `ioctl(ENTER)`. The kernel checks:
     - owner tgid (`pex_main.c:201`);
     - owner tid if `PEX_POLICY_OWNER_THREAD_ONLY` is set (`:206-207`);
     - that the context is not already active (`:212`, `-EBUSY`).
     - Then it sets `active = true`, `entries++`, and `enter_ns` (`:218-221`).
  6. **Touch while active (owner thread).** The fault handler maps the offset to its vmalloc page (`:399-405`) and calls `vmf_insert_pfn()` (`:413`). Later touches of that page do not fault.
  7. **Exit.** `pex_exit()` sends `ioctl(EXIT)`. The kernel:
     - requires an active context (`:250`) and the owner tid (`:255`);
     - updates `active`, `exits` and `total_ns` (`:261-266`);
     - snapshots the mapping and drops `ctx->lock`;
     - takes `mmap_write_lock`, iterates every VMA in the original mapping range, then zaps each matching VMA's PTEs (`pex_main.c:82-125,328-363`).
     - The next touch faults again, so the process gets SIGSEGV.
  8. **Observe.** `pex_get_info()` uses `ioctl(GET_CTX_INFO)` (`pex_main.c:291-322`). `/proc/pex_stats` shows global and per-context lines (`:342-375`).
  9. **Teardown.**
     - `pex_unmap()` calls `munmap`, which triggers `pex_vma_close()`. Each VMA drops one context reference; the last one clears the mapping and calls `mmdrop()` (`pex_main.c:491-529`).
     - `pex_destroy()` sends `ioctl(DESTROY)`. The kernel checks the owner tgid, removes the context from the table and creating-file list, deactivates it if active, then drops its table reference (`pex_main.c:239-281`).
     - Closing the creating device file removes every remaining listed context, deactivates active mappings, and drops table references outside the spinlock (`pex_main.c:591-619`).

- **Where it runs:**
  - **Host:** Linux with matching headers, root to `insmod`, and `/dev/pex` created by `mknod` as `root:<authorized-group>` mode `0660`. The host setup defaults to the invoking sudo user's primary group, or an administrator can provide `PEX_DEVICE_GROUP` (`scripts/dev_setup.sh:7-14,52-58`).
  - **Emulated:** Buildroot image with these settings:
    - Linux 6.6.87 (`pex_aarch64_virt_defconfig:16`), 4 KB pages (`buildroot/configs/linux.config:41`), glibc (`defconfig:10`);
    - 128 MB ext2 rootfs (`defconfig:24-25`), Python 3 (`defconfig:45-46`);
    - booted with `qemu-system-aarch64 -M virt -cpu cortex-a57 -m ${MEM:-256}` (`buildroot/run_qemu.sh:17,194-202`).
    - Init script `S99pex` loads the module and runs the validation suite at boot (`buildroot/overlay/etc/init.d/S99pex:7-16`).
  - **Kernel-version compatibility guards:** `vm_flags_set` for kernels ≥6.3 (`pex_main.c:476-480`) and the `class_create` signature for ≥6.4 (`pex_main.c:513-517`).

## 4. Tech Stack + WHY
| Layer | Choice (evidence) | Why I chose it | Alternatives I considered / rejected |
|-------|-------------------|----------------|--------------------------------------|
| Frontend | Python 3 + Tkinter desktop viewer, stdlib only (`demo/pex_viewer.py:4-14`); binds to C via `ctypes` (`:94-173`) | I chose it to iterate quickly on a visual demonstration while keeping the C runtime as the interface to PEX. (`demo/pex_viewer.py:94-173`) | No specific rejected GUI framework is recorded. Do not claim. |
| Backend (kernel) | Out-of-tree loadable module in C, built with kbuild (`kernel/Makefile:1-11`). Char device, `ioctl`, `mmap` + custom `vm_operations_struct`, procfs (`kernel/pex_main.c`) | I needed kernel control of mapping faults and PTE revocation; a userspace function call cannot enforce that boundary. (`kernel/pex_main.c:275-286`, `kernel/pex_main.c:381-414`) | Pre-pivot design was a userspace `dlopen` enclave loader with SHA-256 (`src/libtee.c:9-13` in `git:62f49d5`, removed in `git:6fcf5bf`). I abandoned it because it directly called a function pointer in the same address space and `tee_exit()` did not revoke access. (`src/libtee.c:9-26` in `git:62f49d5`) |
| Userspace runtime | C library `libpex`, built as both `.a` and `.so` (`libpex/Makefile:6-19`); 9 functions (`libpex/include/pex.h:20-29`) | I used one small C API so the C programs and Python bindings could call the same ioctl-based runtime. (`libpex/src/pex.c:17-165`, `demo/pex_viewer.py:94-173`) | No specific rejected runtime API is recorded. Do not claim. |
| Database | None. All state lives in kernel memory and is lost on module unload (`pex_main.c:548-570`) | N/A | N/A |
| Infra/Deploy | Buildroot 2024.02.12 external tree (`buildroot/external.desc`, `external.mk`, `package/pex/pex.mk`); aarch64 QEMU `virt` target (`defconfig:7`); `JOBS` defaults to 2 "due to RAM constraints" (`build_image.sh:19`) | I used Buildroot and QEMU's aarch64 `virt` target for a controlled, bootable Linux demonstration environment. (`buildroot/configs/pex_aarch64_virt_defconfig:7-16`, `buildroot/run_qemu.sh:194-202`) Darwin/Homebrew handling proves support code, not my host hardware. (`buildroot/build_image.sh:644-652`) | No recorded evaluation of Yocto, Docker, or x86 QEMU. Do not claim. |
| Build | GNU Make (root `Makefile`, `libpex/Makefile`) + kbuild. Flags `-O2 -Wall -Wextra` (`Makefile:2`) | Unknown. Do not claim a personal rationale. | CMake/Meson are not used; no recorded comparison. (`Makefile:1-24`, `libpex/Makefile:1-22`) |
| Other libs | pthreads (`Makefile:18,21`); POSIX signals + `sigsetjmp` (`examples/showcase_blocking.c:1-3`); GCC toolchain from Buildroot | Unknown. Do not claim a personal rationale. | No recorded alternatives. Do not claim. |

## 5. Key Features (how each actually works)
- **Feature A: Context lifecycle over `ioctl`.**
  - What: create, destroy, enter, exit, and get info on a named protected context.
  - How: one `unlocked_ioctl` switch (`kernel/pex_main.c:324-340`).
    - Contexts live in a global hashtable keyed by id and protected by `g_ctx_table_lock` with `spin_lock_irqsave`.
    - Each context has its own `mutex` for state (`pex_main.c:29,48-49`).
    - Lifetime is `kref`-counted (`:28,59-67`). Holders are the table, each in-flight ioctl (`:69-80`), and the VMA (`:433,482`).
  - Key files: `kernel/pex_main.c`, `libpex/include/pex_uapi.h`, `libpex/src/pex.c`.
- **Feature B: Fault-gated protected memory.**
  - What: a region stays mapped in the process but is only accessible while the context is active.
  - How:
    - Memory comes from `vmalloc_user` (`pex_main.c:107`) and is inserted lazily, per page, by `vmf_insert_pfn` in the fault handler (`:381-414`).
    - On exit, `zap_vma_ptes` removes the PTEs so the next touch re-enters the fault handler (`:277-286`).
    - The VMA is `VM_DONTCOPY` (not inherited by fork) and `VM_DONTDUMP` (excluded from core dumps) (`:477`).
  - Key files: `kernel/pex_main.c`, `libpex/src/pex.c:128-151`.
- **Feature C: Owner process / owner-thread policy.**
  - What: only the creating process can enter, map, or destroy. With `PEX_POLICY_OWNER_THREAD_ONLY`, only the creating *thread* can enter.
  - How:
    - `owner_tgid` is checked in create/enter/mmap/destroy (`pex_main.c:157,201,455`).
    - `owner_tid` is checked in enter only when the policy flag is set (`:206-207`).
    - `owner_tid` is checked **unconditionally** in exit (`:255`) and in the fault handler (`:393`).
    - Violations increment counters and `pr_warn` (`:82-89`).
  - Key files: `kernel/pex_main.c`, `tests/test_multithread_violation.c`.
- **Feature D: Observability.**
  - What: live counters for entries, exits, faults, and protected nanoseconds, per context and globally.
  - How:
    - Per-context counters sit in `struct pex_context` (`pex_main.c:37-41`); globals are `atomic64_t` (`:55-57`).
    - They are exposed via `PEX_IOCTL_GET_CTX_INFO` (`:291-322`) and via world-readable `/proc/pex_stats` (mode `0444`, `:528`), which prints one page max (`:350,367`).
  - Key files: `kernel/pex_main.c`, `demo/pex_viewer.py:607-647`.
- **Feature E: Console proof of blocking.**
  - What: a six-step script that shows SIGSEGV on an inactive touch, success when active, cross-thread enter denied, and SIGSEGV again after exit. It exits non-zero on any unexpected result.
  - How: installs `SIGSEGV`/`SIGBUS` handlers that `siglongjmp` back (`examples/showcase_blocking.c:15-41,106-118`); steps at `:149-222`; return code at `:231`.
  - Key files: `examples/showcase_blocking.c`.
- **Feature F: Protected-reveal GUI demo.**
  - What: a Tkinter window with Enter / Exit / Rogue Thread buttons. It shows a lock placeholder or the image, plus live counters.
  - How:
    - At startup it reads `demo/assets/protected_image.enc.hex`, hex-decodes it, and XORs it with the static key `b"PEX-DEMO-KEY"` (`pex_viewer.py:20,176-188,335`).
    - On Enter it calls `pex_enter()`, copies the plaintext PPM into the 2 MiB mapping, and copies it back out into a display buffer (`:545-564`).
    - On Exit it zeroes the mapping *before* `pex_exit()`, then wipes the display buffer (`:566-586`).
    - Rogue Thread calls `pex_enter()` from a `threading.Thread` (`:588-605`).
    - The PPM parser is hand-written for P3 and P6 (`:233-297`).
    - Headless mode: `--self-check` (`:674-730`).
    - **Drafting check (x86-64 sandbox):** the decrypted asset is byte-identical to `assets/test.ppm` (P6, 1024×576, 1,769,488 bytes).
  - Key files: `demo/pex_viewer.py`, `demo/assets/protected_image.enc.hex`, `assets/test.ppm`.
- **Feature G: Bootable validation image.**
  - What: one command builds an aarch64 Linux image; booting it auto-loads `pex.ko` and runs the 5-item validation suite.
  - How:
    - `pex.mk` cross-builds the module, library, and apps, then installs them to `/lib/modules/pex.ko`, `/usr/lib/libpex.so`, and `/opt/pex/*` (`buildroot/package/pex/pex.mk:18-95`).
    - `S99pex` runs `dev_setup.sh` then `run_validation.sh` (`overlay/etc/init.d/S99pex:7-16`). The suite prints PASS/FAIL and a summary (`overlay/opt/pex/run_validation.sh:13-96`).
    - `run_qemu.sh` boots a temp copy of the rootfs. It first pads sparse images and runs a read-only `e2fsck` (`buildroot/run_qemu.sh:153-192`).
    - `--shell` adds `single` to the kernel cmdline (`buildroot/run_qemu.sh:123-126`). **CONFIRMED static behavior:** Linux v6.6 passes unrecognized command-line options to init (`linux-v6.6/init/main.c:495`), and BusyBox 1.36.1 treats `single` as single-user mode and starts a console shell instead of parsing `inittab` (`busybox-1.36.1/init/init.c:1061`).
  - Key files: `buildroot/build_image.sh`, `buildroot/run_qemu.sh`, `buildroot/package/pex/pex.mk`, `buildroot/overlay/`.
- **Feature H: macOS host support for the Buildroot build.**
  - What: lets the Buildroot build run on Darwin.
  - How:
    - Uses Homebrew GNU tools: bash, coreutils, gcc, gpatch, findutils, flock (`build_image.sh:460-640`).
    - Shims `/bin/true` (`:80-134`).
    - Patches host `util-linux`, `e2fsprogs`, `attr`, `acl`, and `fakeroot` recipes (`:136-425`).
    - Forces `-std=gnu17` for GCC 15+ (`:707-716`).
  - Key files: `buildroot/build_image.sh` (776 lines).

## 6. Data Model
There is no database. Everything below is in-memory kernel state or the ABI.
- **`struct pex_context`** (kernel, `kernel/pex_main.c:27-49`):
  - Identity and ownership: `ctx_id`, `owner_tgid`, `owner_tid`, `policy_flags`, `name[64]`.
  - State and memory: `active`, `size`, `kbuf` (vmalloc_user).
  - Counters: `total_entries`, `total_exits`, `total_faults`, `enter_ns`, `total_ns`.
  - Mapping: `mapped_start`, `mapped_len`, `mapped_mm`, `vma_refs`.
  - Plumbing: `hnode`, `file_node`, `refcount` (kref), `lock` (mutex).
- **Global state** (`pex_main.c:48-57`):
  - `g_ctx_table`: `DEFINE_HASHTABLE`, 2^6 = 64 buckets, `PEX_CTX_TABLE_BITS 6` at `:24`;
  - `g_ctx_table_lock` (spinlock);
  - `g_next_ctx_id`, which starts at 1, so the first id handed out is **2** (`:50,115`);
  - `g_live_contexts`, `g_active_contexts`, `g_total_faults` (`atomic64_t`);
  - chrdev/class/cdev/proc handles.
- **ABI structs** (`libpex/include/pex_uapi.h`):
  - `pex_create_req` (88 bytes on x86-64; in: size, policy, name; out: ctx_id) (`:39-46`);
  - `pex_ctx_req` (`:48-51`);
  - `pex_ctx_info` (64 bytes) (`:53-64`);
  - `pex_fault_event` is **defined but never used** (`:66-74`).
- **Enums:**
  - Policy flags `OWNER_THREAD_ONLY = 1` and `NO_FORK_INHERIT = 2`; the second is **never read by the kernel** (`pex_uapi.h:26-29`).
  - Fault types `NONE/MEM_ACCESS/CROSS_THREAD/BAD_STATE/BAD_OWNER` (`:31-37`).
- **Userspace handle** `pex_handle_t {fd, ctx_id, mapped_addr, mapped_size}` (`libpex/include/pex.h:13-18`), mirrored in Python as `PexHandle` (`demo/pex_viewer.py:70-76`).
- **Relationships:**
  - One process (tgid) owns 0..N contexts; nothing limits how many a process creates.
  - A context has 0..1 active mapping (`pex_main.c:555-565`).
  - A context belongs to the creating device file's list and is removed on that file's final close (`pex_main.c:591-619`).
  - A mapping holds one context reference per VMA and one `mm_count` reference (`pex_main.c:491-529,561-565`).

## 7. Key Files Map
- `kernel/pex_main.c` (722 lines): the kernel module. Context table, fd lifetime, ioctls, mmap/fault/VMA references, procfs, init/exit.
- `kernel/Makefile` (11): kbuild wrapper; `KDIR ?= /lib/modules/$(uname -r)/build`.
- `libpex/include/pex_uapi.h` (83): kernel↔user ABI (structs, enums, ioctl numbers); non-Linux type fallback at `:9-19`.
- `libpex/include/pex.h` (35): public C API.
- `libpex/src/pex.c` (165): thin wrappers over `open/ioctl/mmap/munmap`; returns `-errno`.
- `libpex/Makefile` (22): builds `libpex.a` + `libpex.so` with `-fPIC`.
- `examples/protected_workload.c` (69): minimal create → map → enter → write/compute → exit → info.
- `examples/showcase_blocking.c` (232): the six-step blocking proof with signal recovery.
- `tests/test_multithread_violation.c` (76): cross-thread enter must fail and the fault count must rise.
- `tests/benchmark_entry_exit.c` (58): 10,000 enter/exit pairs, prints average ns. No mapping, no pass/fail threshold.
- `demo/pex_viewer.py` (763): Tkinter viewer, ctypes bindings, XOR asset loader, PPM parser, `--self-check`.
- `demo/assets/protected_image.enc.hex` (~3.5 MB): XOR-obfuscated hex of `assets/test.ppm`.
- `assets/test.jpg`, `assets/test.ppm`: source images. **CONFIRMED:** no tracked C, header, Python, shell, or Makefile source references `test.jpg` (`experiments/logs/phase3-test-jpg-code-references.log`).
- `scripts/dev_setup.sh` (58): root check, build if missing, unload/insmod, `mknod /dev/pex`, and `root:<authorized-group>` mode `0660`.
- `scripts/run_all.sh` (29): host end-to-end build, load, and run of everything, then `cat /proc/pex_stats`.
- `scripts/run_demo.sh` (24): build, load, then GUI, or `--self-check` if `$DISPLAY` is empty.
- `Makefile` (55): top-level targets `all/lib/kernel/examples/tests/demo/load/unload/run-*`/`clean`.
- `buildroot/build_image.sh` (776): download/extract Buildroot, Darwin patches, defconfig, build, verify outputs.
- `buildroot/run_qemu.sh` (202): boot the image in QEMU with rootfs integrity checks.
- `buildroot/package/pex/pex.mk` (97), `Config.in`: Buildroot package recipe.
- `buildroot/configs/pex_aarch64_virt_defconfig` (46), `buildroot/configs/linux.config` (90): image and kernel config.
- `buildroot/overlay/etc/init.d/S99pex`, `overlay/opt/pex/dev_setup.sh`, `overlay/opt/pex/run_validation.sh`: boot-time load and validation.
- `buildroot/buildroot-2024.02.12.tar.xz` (5.5 MB): vendored Buildroot source.
- `docs/report.md` (263): project write-up.
- `samples/host` (17,984-byte x86-64 ELF): **stale binary from the pre-pivot design.** Its strings reference `libtee_sim.so`, `tee_create`, `./enclave.so`, and build path `/home/ubuntu/OS/SoftTEE`. Nothing builds or uses it. Added in `git:6513a83`.

## 8. Hardest Problems (STAR format)
The STAR prompts below are project-owner input. The git history provides the evidence candidates.

- **Problem 1: memory was not reliably re-blocked or stable after exit (candidate from `git:1685fb4`).**
  - Evidence of the change:
    - Before `1685fb4`, the fault handler did `get_page(page); vmf->page = page;` and the VMA lacked `VM_PFNMAP`.
    - After it, the handler uses `vmf_insert_pfn()` and the VMA sets `VM_PFNMAP | VM_DONTEXPAND` (`pex_main.c:411-413,477`).
    - The same commit moved `mmap_write_lock` / `zap_vma_ptes` to *after* `mutex_unlock(&ctx->lock)` (`pex_main.c:275-286`).
    - It also made `showcase_blocking` return 1 on any unexpected result; it previously always returned 0.
  - **CONFIRMED:** Linux v6.6 documents and implements `zap_vma_ptes()` as acting only on `VM_PFNMAP` VMAs (`linux-v6.6/mm/memory.c:1681`, `linux-v6.6/mm/memory.c:1686`). The pre-`1685fb4` VMA lacked that flag, so this source-level analysis establishes that its call would return without zapping PTEs. The commit's lock move removes the previously inverse ctx-mutex → mmap-lock order; this is an ordering correction, not proof that a deadlock occurred in a recorded run (`git:1685fb4`; `kernel/pex_main.c:392`, `kernel/pex_main.c:275`).
  - Situation: I found that the protected mapping needed a more reliable way to insert pages and revoke access after exit. The previous fault path returned a `struct page`, while the revised design uses PFN insertion and marks the VMA as `VM_PFNMAP`; the exit path was also reworked to avoid holding the context mutex while acquiring the mmap write lock.
  - What I tried that failed: I first used the normal `vmf->page` fault return path and attempted to revoke access with `zap_vma_ptes()` on exit. That combination did not match the PFN-mapped design: without `VM_PFNMAP`, the zap helper does nothing, so pages could remain accessible after exit.
  - What worked and why: I switched the fault path to `vmf_insert_pfn()` and set `VM_PFNMAP`, so `zap_vma_ptes()` could remove the inserted PTEs on exit. I also snapshot the mapping while holding `ctx->lock`, then release that mutex before taking `mmap_write_lock`; this removes the inverse lock ordering between the exit and fault paths.
  - Result: The blocking behavior became testable and reliable: after exit, a previously accessed page faulted again instead of remaining accessible. The showcase also began returning failure when an expected protection check did not hold.
- **Problem 2: building Buildroot on macOS (candidate from `git:ec888cb`, `git:8e47eb0`).**
  - Evidence: 545 added lines of Darwin host patches (`build_image.sh:80-640`) and a GCC 15/C23 workaround (`:707-716`).
    - `run_qemu.sh` handles *sparse* rootfs copies and runs fsck (`run_qemu.sh:158-192`).
    - `build_image.sh` warns to copy with `rsync -aS` (`build_image.sh:763-766`).
    - Not measured / not recorded: sparse-copy and fsck handling show that the scripts account for image transfer/integrity, but no repository evidence establishes that images were actually moved between machines.
  - Situation: I needed the Buildroot image workflow to run on macOS, where the original scripts assumed Linux host tools and behavior. (`buildroot/build_image.sh:80-640`)
  - What I tried that failed: Linux-oriented assumptions did not hold on macOS because host utilities, shell/tool versions, compilers, and package compatibility differ. (`buildroot/build_image.sh:80-640`, `buildroot/build_image.sh:707-716`)
  - What worked and why: I added Darwin detection, Homebrew dependency setup, compatibility shims, and Buildroot package workarounds to provision a suitable host build environment. (`buildroot/build_image.sh:80-640`)
  - Result: The repository gained macOS/Darwin support code. I do not claim a recorded successful macOS build or an Apple-Silicon host without separate run evidence. (`buildroot/build_image.sh:644-652`)
- **Problem 3: architecture pivot from `dlopen` enclave loader to kernel module (candidate from `git:6fcf5bf`).**
  - Evidence: the pre-pivot `tee_enter()` just called the enclave's function pointer in the same address space, with no isolation (`git:62f49d5:src/libtee.c`). The pivot replaced it wholesale.
  - Why I pivoted: I abandoned it because a `dlopen`-loaded enclave was invoked through a direct function pointer in the same address space, while `tee_exit()` did not revoke memory access. (`src/libtee.c:9-26` in `git:62f49d5`)
  - Situation: The original design loaded an enclave shared library with `dlopen` and called its function pointer directly. (`src/libtee.c:9-13` in `git:62f49d5`)
  - What I tried that failed: That approach did not provide an isolation boundary: caller and enclave shared an address space and the exit path did not revoke access. (`src/libtee.c:9-26` in `git:62f49d5`)
  - What worked and why: I replaced it with a kernel module, `/dev/pex`, explicit ioctl entry/exit transitions, and fault-gated mappings so the kernel controlled memory access. (`kernel/pex_main.c:324-340`, `kernel/pex_main.c:381-485`)
  - Result: PEX became a kernel-assisted isolation prototype rather than a userspace loader presented as an enclave. (`README.md:1-35`, `kernel/pex_main.c:324-485`)
- **Problem 4: one ABI header for kernel, Linux userspace, and non-Linux compile (candidate from `git:b8c481e`, `git:6513a83`).**
  - Evidence: `#ifdef __KERNEL__` / `__linux__` branches (`pex_uapi.h:4-20`).
  - STAR: Unknown. Do not claim.

## 9. Tradeoffs & Decisions
Decisions below are **visible in code**. CONFIRMED items have run evidence; the rest are design reasoning.
- **Decision:** loadable out-of-tree module instead of a new syscall or in-tree subsystem (`kernel/Makefile`; `docs/report.md:209`).
  - Gained: **CONFIRMED on the verified host:** PEX was built as an out-of-tree kbuild module and loaded into the already-running kernel; no host-kernel rebuild was performed (`experiments/logs/phase1-make-kernel.log`, `experiments/logs/phase1-device-listing.log`).
  - Gave up: upstream integration; needs matching headers and root.
  - Why: I needed kernel control of mapping faults and PTE revocation; a userspace function call cannot enforce that boundary. (`kernel/pex_main.c:275-286`, `kernel/pex_main.c:381-414`)
- **Decision:** lazy per-page `vmf_insert_pfn` plus `zap_vma_ptes` on exit, instead of mapping everything at mmap time (`pex_main.c:381-414,277-286`).
  - Gained: **CONFIRMED for the tested page:** after owner exit, the P1 page-0 touch faulted and was rejected in all three runs (`experiments/logs/phase2-p1-run-1.log`, `experiments/logs/phase2-p1-run-2.log`, `experiments/logs/phase2-p1-run-3.log`).
  - Gave up: extra fault-path work after exit. The stock benchmark does not measure it because it never maps memory (`tests/benchmark_entry_exit.c:27-47`); P4 measured the fault-inclusive path separately (§10; `experiments/logs/phase2-p4-sorted-values.log`).
  - Why: I used lazy page insertion so mapping occurs through the fault path, and PTEs can be revoked on exit. (`kernel/pex_main.c:277-286`, `kernel/pex_main.c:381-414`)
- **Decision:** one global spinlock-protected hashtable plus a per-context mutex (`pex_main.c:29,48-49`).
  - Gained: simple lookup.
  - Gave up: possible contention on the single global spinlock (not measured).
  - Why: I used a global table plus a per-context mutex for a simple initial lookup and state model. (`kernel/pex_main.c:24-29`, `kernel/pex_main.c:48-49`)
- **Decision:** context access remains bound to the creating tgid/tid, while lifetime is tied to the creating device file (`pex_main.c:219-220,225-228,591-619`).
  - Gained: It records the creating process and thread as the ownership identity used by enter, exit, and the fault handler, and source now removes remaining contexts on final fd close. (`kernel/pex_main.c:219-220,306-325,591-619`)
  - Gave up: the aarch64 Buildroot target has no recorded lifetime run. Historical P7 fd-close and P3 SIGKILL leaks remain confirmed for the pre-patch version, while the current patch passed the same cleanup scenarios on Ubuntu 24.04 / Linux 6.8.0-139-generic (§12).
- **Decision:** `/dev/pex` is `root:<authorized-group>` mode `0660` (`scripts/dev_setup.sh:7-14,54-58`; `overlay/opt/pex/dev_setup.sh:10,35-38`).
  - Gained: users outside the administrator-selected device group cannot open the allocation interface; the host setup still authorizes the invoking demo user's primary group by default.
  - Gave up: group membership is deployment configuration, not per-context identity authorization. Authorized users remain bounded by a 16 MiB context cap, 8 contexts / 16 MiB per process, and 64 contexts / 64 MiB globally (`pex_uapi.h:20-24`; `pex_main.c:168-203`).
- **Decision:** XOR with a static key in source for the demo asset (`demo/pex_viewer.py:20,176-177`).
  - Gained: no crypto dependency.
  - Gave up: real confidentiality at rest. The plaintext also lives in Python memory for the whole app lifetime (`:335`). `README.md:28-35` acknowledges the display-path limits.
  - Why: I kept the image demo dependency-free; this is a presentation mechanism, not cryptographic protection. (`demo/pex_viewer.py:20`, `demo/pex_viewer.py:176-177`, `README.md:28-35`)
- **Decision:** Python + ctypes GUI over the C library (`demo/pex_viewer.py:94-173`).
  - Potential gain: I used Python/Tkinter for quick visual iteration. (`demo/pex_viewer.py:94-173`)
  - Behavior: the viewer creates a `threading.Thread` for its Rogue Thread action (`demo/pex_viewer.py:588-605`), and `--self-check` observed its denied `pex_enter` with a fault-count increase (`experiments/logs/phase1-viewer-self-check.log`).
  - Why: I used Python/Tkinter for quick visual iteration while retaining the C runtime interface through `ctypes`. (`demo/pex_viewer.py:94-173`)
- **Decision:** vendoring the Buildroot tarball (5.5 MB) and image assets (~8.8 MB) directly in git; no LFS (`git:b8c481e`, `git:8ceb3b8`).
  - Potential gain: Not measured / not recorded: the tarball is vendored, but an offline reproducible Buildroot build has not been run and recorded.
  - Gave up: repo size.
  - Why: Unknown. Do not claim a personal rationale; an offline reproducible build was not recorded.
- **Decision:** aarch64 QEMU target only; no x86 defconfig (`buildroot/configs/`).
  - Why: I used the configured aarch64 QEMU `virt` target for the controlled Buildroot VM demonstration. No comparison with x86 is recorded. (`buildroot/configs/pex_aarch64_virt_defconfig:7-16`, `buildroot/run_qemu.sh:194-202`)

## 10. Metrics (only real ones)
| Metric | Value | How measured | When |
|--------|-------|--------------|------|
| Avg enter+exit latency | **423.89 ns median** (min 380.56 ns; max 756.35 ns) across seven runs | `tests/benchmark_entry_exit`: seven independent runs of 10,000 `pex_enter`/`pex_exit` pairs timed with `CLOCK_MONOTONIC`; it prints `avg_enter_exit_ns` (`tests/benchmark_entry_exit.c:18,34-53`). No mapping is touched. Sorted raw results: `experiments/logs/phase1-benchmark-sorted-values-corrected.log`. | 2026-09-16, host Linux `6.8.0-40-generic` on a 2-vCPU Parallels aarch64 VM (`experiments/logs/phase0-uname.log`, `experiments/logs/phase0-lscpu.log`, `experiments/logs/phase0-systemd-detect-virt.log`) |
| Avg enter+first-page-write+exit latency | **2126.75 ns median** (min 1723.79 ns; max 2235.60 ns) across seven runs | P4: a mapped 4096-byte context; 10,000 iterations of `pex_enter` → one-byte write to page 0 → `pex_exit`, timed with `CLOCK_MONOTONIC`. The prior exit zaps the PTE, so each following write takes the valid fault path. Sorted raw results: `experiments/logs/phase2-p4-sorted-values.log`. | 2026-09-16, same host as the row above (`experiments/logs/phase2-p4-sorted-values.log`) |
| Lines in listed source/script files | about 3,451 lines across kernel, lib, examples, tests, viewer, scripts, and Buildroot files (`wc -l`, see §7) | `wc -l` at `6513a83` | 2026-09-16 draft |

Numbers come from experiments/logs (not committed to the repo). They are VM microbenchmarks, not production metrics; always quote them with what they measure.

## 11. Testing & Quality
- **Tests (what exists):** integration programs only. They all require `pex.ko` loaded and `/dev/pex` present. There is no unit-test framework: no KUnit, kselftest, pytest, or gtest.
  1. `tests/test_multithread_violation.c`
     - Checks: a secondary thread's `pex_enter` returns <0, and `total_faults` increases (`:59-66`).
     - Does **not** check a rogue thread touching memory.
  2. `tests/benchmark_entry_exit.c`
     - Checks: timing only; exits 0 unless an ioctl fails (`:36-57`).
  3. `tests/test_lifetime_cleanup.c`
     - Checks: the initial `/proc/pex_stats` live/active counts are restored after close-without-destroy, SIGKILL of a mapped active child, and split-VMA teardown. Source compiles; target-kernel execution is not yet recorded.
  4. `examples/showcase_blocking.c`
     - Checks: inactive touch → signal; active touch → success; cross-thread enter denied; post-exit touch → signal. Returns 1 on any deviation (`:149-231`).
  5. `examples/protected_workload.c`
     - Checks: happy-path smoke test (`:21-68`).
  6. `demo/pex_viewer.py --self-check`
     - Checks: create/map/enter/copy asset, rogue thread denied with a fault-count increase, wipe, exit (`:674-730`).
- **How they are run:**
  - Host: `make run-tests` (`Makefile:40-43`) or `scripts/run_all.sh`.
    - Note: `run_all.sh` masks example failures with `|| true` (`scripts/run_all.sh:20-21`).
  - QEMU: `run_validation.sh` counts PASS/FAIL and exits 1 on any failure (`overlay/opt/pex/run_validation.sh:47-96`).
    - Its caller `S99pex` always `exit 0` (`overlay/etc/init.d/S99pex:28`), so boot never reflects a failure.
- **Coverage:** none measured.
- **Real run on 2026-09-16 (commit `6513a83`):** Host kernel-side execution was observed on the 2-vCPU Parallels aarch64 VM, Linux `6.8.0-40-generic` (`experiments/logs/phase0-uname.log`, `experiments/logs/phase0-lscpu.log`, `experiments/logs/phase0-systemd-detect-virt.log`). `/dev/pex` existed with mode `0666`, and initial `/proc/pex_stats` counters were zero (`experiments/logs/phase1-device-listing.log`, `experiments/logs/phase1-proc-stats-initial.log`).
  - `make all` and `make kernel` exited 0 (`experiments/logs/phase1-make-all.log`, `experiments/logs/phase1-make-kernel.log`). Kernel build warnings: compiler identity differs from the compiler recorded for the kernel, unused `pex_device`, and BTF generation skipped because `vmlinux` was unavailable (`experiments/logs/phase1-make-kernel.log`).
  - `./examples/protected_workload`, `./examples/showcase_blocking --sleep 0`, `./tests/test_multithread_violation`, and `python3 demo/pex_viewer.py --self-check` each exited 0 (`experiments/logs/phase1-protected-workload.log`, `experiments/logs/phase1-showcase-blocking.log`, `experiments/logs/phase1-test-multithread-violation.log`, `experiments/logs/phase1-viewer-self-check.log`).
  - The seven benchmark results were 380.56, 390.73, 402.49, 423.89, 483.92, 634.85, and 756.35 ns after sorting; median 423.89 ns (`experiments/logs/phase1-benchmark-sorted-values-corrected.log`).
  - Requested kernel-log capture could not be completed from the agent session because privileged `dmesg` requires an interactive sudo credential; unprivileged `dmesg` was denied. Consequently, `pr_warn` fault lines were not captured. (`experiments/logs/phase1-dmesg-pex.log`, `experiments/logs/phase1-dmesg-pex-unprivileged.log`)
- **Earlier draft sandbox run (2026-09-16, commit `6513a83`), done in a scratch copy of the repo:**
  - Environment: Firecracker VM, kernel `6.18.44-fc-v33`, booted with `nomodule`. No `/lib/modules`, no kernel headers, no QEMU, no tkinter. gcc 13.3.0.
  - `make all`: **rc=0, 0 warnings** under `-Wall -Wextra` (lib, examples, tests, `py_compile`).
  - `make kernel`: **rc=2**. Error: `/lib/modules/6.18.44-fc-v33/build: No such file or directory`.
  - `./tests/test_multithread_violation`: **rc=1**. Output: `pex_open failed: -2` (ENOENT, no `/dev/pex`).
  - `./tests/benchmark_entry_exit`: **rc=1**. Output: `pex_open failed: -2`.
  - `./examples/protected_workload`: **rc=1**. Output: `pex_open failed: -2`.
  - `./examples/showcase_blocking --sleep 0`: **rc=1**. Output: `pex_open failed rc=-2` at Step 1.
  - `python3 demo/pex_viewer.py --self-check`: **rc=1**. Output: `pex_open failed: -2`.
  - **Verdict:** these failures are environmental; the module could not be built or loaded here. They say nothing about kernel-side correctness. **Kernel-side behaviour was NOT exercised in this draft.**
  - The later verified host run is recorded above; no QEMU validation output is recorded. (`experiments/logs/phase1-protected-workload.log`, `experiments/logs/phase1-showcase-blocking.log`, `experiments/logs/phase1-test-multithread-violation.log`, `experiments/logs/phase1-viewer-self-check.log`)
- **Current workspace source build (2026-04-21, uncommitted lifetime patch):** `make all` exited 0 on macOS and compiled `tests/test_lifetime_cleanup.c` with `-Wall -Wextra`; `sh -n buildroot/overlay/opt/pex/run_validation.sh` and `bash -n scripts/run_all.sh` exited 0. `make kernel` exited 2 because macOS has no `/lib/modules/27.0.0/build`, so the module and the new lifetime test were not run here. This is build-only evidence, not kernel runtime validation.
- **Lifetime-patch VM run (2026-04-21):** On Ubuntu 24.04 with Linux `6.8.0-139-generic` and matching headers, `make kernel` and `make tests` exited 0 (with the pre-existing unused `pex_device` warning). After `sudo ./scripts/dev_setup.sh`, the baseline was `live_contexts=0`, `active_contexts=0`. `./tests/test_lifetime_cleanup` passed fd-close, active-map `SIGKILL`, and split-VMA scenarios; each restored the same zero baseline. `sudo rmmod pex` then succeeded. The manually created `/dev/pex` node was removed afterward. This validates the patch on that x86-64 VM; no aarch64 Buildroot/QEMU run is recorded.
- **Access-limit VM run (2026-04-21):** On the same Ubuntu 24.04 / Linux `6.8.0-139-generic` VM, the setup script created `/dev/pex` as `root:parallels` mode `0660`. `tests/test_access_limits` verified that a child dropped to UID/GID 65534 could not open it; per-process context and byte limits returned `-EDQUOT` after 8 and 2 successful creations respectively; global context and byte limits returned `-EDQUOT` at capacity and accepted a new allocation after the holder fds closed. Final stats were `live_contexts=0`, `live_bytes=0`, `active_contexts=0`. Existing non-root thread-policy and lifetime regressions still passed as user `parallels`. This is not an aarch64 Buildroot/QEMU run.
- **Drafting check (x86-64 sandbox):** C `sizeof(struct pex_ctx_info)=64`, `offsetof(size)=24`, which matches Python `ctypes.sizeof(PexCtxInfo)=64`, offset 24. `pex_handle_t` = 24 bytes on both sides (x86-64).
- **CI/CD:** none. There is no `.github/`, `.gitlab-ci.yml`, `.travis.yml`, `Jenkinsfile`, or CircleCI config.
- **Error handling / logging:**
  - libpex returns `-errno` or `NULL` (`libpex/src/pex.c`).
  - The kernel returns `-EFAULT/-EINVAL/-ENOMEM/-EPERM/-EBUSY/-ENOENT/-ENOTTY`, logs faults with `pr_warn` (`pex_main.c:87-88`), and logs load/unload with `pr_info` (`:534,569`).
  - The viewer raises `RuntimeError` and converts it to `SystemExit` with setup hints (`demo/pex_viewer.py:733-759`). It keeps an on-screen event log (`:516-521`).
- **Static analysis / lint / format config:** none found. No `.clang-format`, `.clang-tidy`, `.editorconfig`, pre-commit, or ruff/flake8/mypy config.

## 12. Known Limitations & Bugs
**Documented by the project itself:**
- Not hardware-backed. Does not secure the display path or prevent screenshots. Does not mediate syscalls. No multi-process sharing. Relies on a loadable module. (`docs/report.md:203-209`; `README.md:21,28-35`)
- The GUI decrypts the asset at startup, and the plaintext is copied out of protected memory into a normal display buffer (`README.md:28-35`; `demo/pex_viewer.py:335,557-559`).

**Review items, with status after the lifetime patch:**
| Item | Status at HEAD | Evidence |
|---|---|---|
| §1.1 context leaked if `copy_to_user` fails in create | Still present | `pex_main.c:123-132` |
| §1.2 first ctx id is 2 | **CONFIRMED:** ID was 2 in each of three independent fresh-unload/reload trials | `pex_main.c:50,115`; `experiments/logs/phase2-p5-fresh-run-1.log`, `experiments/logs/phase2-p5-fresh-run-2.log`, `experiments/logs/phase2-p5-fresh-run-3.log` |
| §1.3 ABBA deadlock between ctx mutex and mmap lock in exit | Lock order corrected in source; never run under lockdep (no log). | `pex_main.c:275-286`; `git:1685fb4` |
| §1.4 `zap_vma_ptes` not version-guarded | **CONFIRMED for the shipped Linux 6.6 target:** the API exists and only acts on `VM_PFNMAP` VMAs, which PEX sets before use. No version guard is required for that target. | `kernel/pex_main.c:283,477`; `linux-v6.6/mm/memory.c:1681`, `linux-v6.6/mm/memory.c:1686` |
| §1.6 no `.open` in `vm_ops` (VMA split refcount) | **Runtime verified on Ubuntu 24.04 / Linux 6.8.0-139-generic.** `pex_vma_open()` takes a kref and increments `vma_refs`; `pex_vma_close()` drops one ref and releases the `mm` only after the last VMA closes. The split-VMA regression restored zero live and active contexts. | `kernel/pex_main.c:491-529`; `tests/test_lifetime_cleanup.c`; 2026-04-21 VM run in §11 |
| §1.8 `kref_put` → `vfree`/`mmput` under spinlock with IRQs off in module exit | **Implemented in source; indirect runtime evidence.** Module exit detaches contexts under the spinlock, then deactivates and releases them after unlocking. After the P3 crash-cleanup regression, `rmmod pex` succeeded on Ubuntu 24.04 / Linux 6.8.0-139-generic. | `kernel/pex_main.c:685-715`; 2026-04-21 VM run in §11 |
| §2.3 `pex_fault_event` unused | Still present | `pex_uapi.h:66-74` |
| §3.1 `pex_map` assumes 4 KB pages (`ctx_id << 12`) | Still present. Harmless on the shipped target (4 KB) | `libpex/src/pex.c:143`; `buildroot/configs/linux.config:41` |
| §9.1 absolute doc links in README | Fixed: links are now relative | `README.md:179-180` |
| §9.2 "docs/report.md doesn't exist" | **Stale claim.** The file exists | `docs/report.md` |

**Runtime results (2026-09-16):**
- **Thread isolation is only enforced on the first touch of each page [CONFIRMED].** In every P1 run, after the owner faulted page 0 in while active, a second thread read page 0 successfully without a new fault; that same thread got SIGSEGV on untouched page 1, and again on page 0 after owner exit. `total_faults` rose only for the two blocked accesses per run (`experiments/logs/phase2-p1-run-1.log`, `experiments/logs/phase2-p1-run-2.log`, `experiments/logs/phase2-p1-run-3.log`). This conflicts with the absolute owner-thread access wording in `docs/report.md:92-97`.
- **The policy flag only gates enter [CONFIRMED].** With `policy_flags=0`, a secondary thread's enter returned 0, its mapped-memory touch received SIGSEGV, its exit returned -EPERM, and the owner's exit returned 0 in all three P2 runs (`experiments/logs/phase2-p2-run-1.log`, `experiments/logs/phase2-p2-run-2.log`, `experiments/logs/phase2-p2-run-3.log`). The code checks `owner_tid` unconditionally in exit and fault handling (`pex_main.c:255,393`). `docs/report.md:117,130` is therefore a conflict candidate.
- **Fd-close and process-death cleanup [PRE-PATCH FAILURE CONFIRMED; PATCH RUNTIME VERIFIED].** In all three historical P7 runs, a context created without mapping or destroy remained visible as `live_contexts=1` after the process closed its fd (`experiments/logs/phase2-p7-proc-after-leak-1.log`, `experiments/logs/phase2-p7-proc-after-leak-2.log`, `experiments/logs/phase2-p7-proc-after-leak-3.log`). In historical P3, after SIGKILL of a mapped, active child, `live_contexts=1`, `active_contexts=1`, and `rmmod` failed with "Module pex is in use" (`experiments/logs/phase2-p3-proc-after-kill-1.log`, `experiments/logs/phase2-p3-rmmod-1.log`). On 2026-04-21, the current patch passed the fd-close, active-map `SIGKILL`, and split-VMA scenarios on Ubuntu 24.04 / Linux 6.8.0-139-generic; each restored `live_contexts=0`, `active_contexts=0`, and `rmmod pex` succeeded afterward. The source adds fd `.release`, removes that file’s contexts from the table, deactivates active contexts, zaps mapping PTEs, and replaces the long-lived `mmget` with `mmgrab`/`mmdrop` (`kernel/pex_main.c:72-164,561-619`; `tests/test_lifetime_cleanup.c`). This is not an aarch64 Buildroot/QEMU result.
- **Mapped-active leak mechanism: outcome confirmed; exact causal chain remains unisolated.** The historical P3 outcome was consistent with an inferred `mmget`/context reference cycle, but the experiment did not independently prove that internal causal chain. The current regression verifies that the observed cleanup failure is fixed on Ubuntu 24.04 / Linux 6.8.0-139-generic; it does not prove the old causal explanation. (`experiments/logs/phase2-p3-run-1.log`, `experiments/logs/phase2-p3-rmmod-1.log`; `kernel/pex_main.c:72-79,491-529,561-565`)
- **Device registration error path.** `device_create` failure returns `-ENOMEM` instead of `PTR_ERR` (`pex_main.c:523-525`).
- **Unused local.** **CONFIRMED compiler warning:** `struct device *pex_device;` added in `git:ec888cb` (`pex_main.c:499`) triggered the unused-variable warning under kbuild. (`experiments/logs/phase1-make-kernel.log`)
- **`PEX_POLICY_NO_FORK_INHERIT` is a no-op.** `VM_DONTCOPY` is always applied regardless of the flag (`pex_uapi.h:28`; `pex_main.c:477`).
- **`/proc/pex_stats` limits.** It is world-readable and lists every process's context names and pids (`pex_main.c:528,363-366`). Output is capped at one page, so it truncates with many contexts (`:350,367`).
- **Allocation authorization and resource limits [PRE-PATCH FAILURE CONFIRMED; PATCH RUNTIME VERIFIED].** Historical P6 showed that an unprivileged UID 1000 could create a context through world-writable `/dev/pex` (`experiments/logs/phase2-p6-run-1.log`, `experiments/logs/phase2-p6-run-2.log`, `experiments/logs/phase2-p6-run-3.log`). The patch creates the device as `root:<authorized-group>` mode `0660`, caps a context at 16 MiB, caps each process at 8 contexts / 16 MiB, and caps the module at 64 contexts / 64 MiB (`pex_uapi.h:20-24`; `kernel/pex_main.c:168-203`; setup scripts). On Ubuntu 24.04 / Linux 6.8.0-139-generic, an unprivileged child was denied at open; all four quotas returned `-EDQUOT` at capacity and recovered after fd close. Buildroot/QEMU remains untested.
- **Viewer log text is inaccurate.**
  - It says "mapped a single protected page" (`demo/pex_viewer.py:512`), but `MAP_SIZE = 2097152`, which is 512 pages at 4 KB (`:18`).
  - It says "decrypted the PPM payload" on Enter (`:563`), but decryption happens at startup (`:335`). The README, report, and demo script were corrected; the viewer log itself still needs the small code cleanup.
- **Boot and host scripts hide failures.** `S99pex` always exits 0 (`overlay/etc/init.d/S99pex:28`). `scripts/run_all.sh` ignores example failures (`:20-21`).
- **Stale committed binary.** `samples/host` is an x86-64 ELF from the deleted design (§7).
- **Rootfs has an empty root password and DHCP on eth0** (`pex_aarch64_virt_defconfig:32-33`). Fine for a demo VM; worth knowing.
- Other bugs I know about: Unknown. Do not claim.

## 13. What This Project Does NOT Have   <-- most important anti-hallucination section
How this list was checked:
- `find` for manifest, container, CI, and env files;
- `git grep -i` for common technologies across tracked text files;
- reading every source file at `6513a83`.

- **No containers:** no `Dockerfile`, `Containerfile`, `docker-compose*`, `.dockerignore`, `Vagrantfile`. No Docker or Kubernetes mentions.
- **No CI/CD:** no `.github/` directory, GitLab/Travis/Circle/Jenkins/Azure config. No automated builds or tests on push.
- **No `.env` files.** The only env knobs are `LIBPEX_PATH`, `PEX_ASSET_PATH` (`demo/pex_viewer.py:33,51`), `JOBS` (`buildroot/build_image.sh:19`), `MEM` (`buildroot/run_qemu.sh:17`), `PEX_DEVICE_GROUP` (setup scripts), and make's `CC/CFLAGS/KDIR/PYTHON`.
- **No dependency manifests:**
  - Python: no `requirements*.txt`, `pyproject.toml`, `setup.py`, or `Pipfile`. The viewer uses the stdlib only.
  - C: no CMake, Meson, Conan, or vcpkg. Plain Make + kbuild.
- **No database or persistence of any kind.** State is in kernel memory only.
- **No network service:** no HTTP API, no sockets, no server, no web frontend.
- **No credential-level authentication.** Device access is restricted to root and the configured authorized group (`/dev/pex` mode `0660`), while context operations retain owner tgid/tid checks. There is no user database, ACL service, or per-context identity policy beyond those OS credentials.
- **No real cryptography in the current code.** The demo "encryption" is XOR with a hard-coded key (`demo/pex_viewer.py:20`).
  - OpenSSL SHA-256 existed only in the **deleted** pre-pivot loader (`git:40446fe`, removed in `git:6fcf5bf`).
  - The only current "openssl" mention is Buildroot's kernel host-build flag (`pex_aarch64_virt_defconfig:21`).
- **No attestation, measurement, or sealing.** The enclave hashing was removed in the pivot.
- **No hardware TEE:** no Intel SGX, TDX, AMD SEV, or ARM TrustZone (`README.md:21`).
- **No syscall filtering:** no seccomp or capability dropping (`docs/report.md:207`).
- **No per-thread memory isolation for already-mapped pages** (confirmed by P1; see §12 and `experiments/logs/phase2-p1-run-1.log`).
- **No multi-process sharing or delegation of contexts** (`docs/report.md:208`).
- **No secure display pipeline and no screenshot resistance** (`README.md:35`).
- **No fork-policy implementation** (`PEX_POLICY_NO_FORK_INHERIT` unused) and **no fault-event stream API** (`pex_fault_event` unused).
- **No aarch64 Buildroot/QEMU runtime result for the fd-close/process-exit cleanup hook.** The patch passed its regression on Ubuntu 24.04 / Linux 6.8.0-139-generic, but the shipped aarch64 image remains untested (`kernel/pex_main.c:592-619`; `tests/test_lifetime_cleanup.c`).
- **No unit tests, KUnit, kselftest, pytest, gtest; no coverage; no sanitizers or Valgrind; no lockdep/KASAN run recorded.**
- **No lint/format tooling config.**
- **No LICENSE file** at the repo root. Licence intent appears only in `MODULE_LICENSE("GPL")` (`pex_main.c:575`) and `PEX_LICENSE = GPL-2.0` (`pex.mk:12`).
- **No releases or git tags. No Git LFS** (large binaries are committed directly).
- **No x86 Buildroot image.** The aarch64 `virt` defconfig is the only one.
- **No caching layer, no message queue, no cloud deployment, no payments, no real users or production traffic.**
- **No production benchmark history.** Two host microbenchmark result sets are now recorded in §10; they are not production metrics.

## 14. What I'd Do Differently / Next
- **Scaling plan** (the realistic axis here is "many contexts / many threads", not users): I would replace the single global lookup lock with finer-grained or RCU-based lookup and benchmark many contexts and threads rather than only ioctl latency. The current per-process/global quotas are fixed teaching-prototype bounds, not adaptive production resource governance. (`kernel/pex_main.c:24-29,168-203`, `tests/benchmark_entry_exit.c:27-47`)
  - Facts to reason from:
    - fixed 64-bucket table under one IRQ-saving spinlock (`pex_main.c:24,48-49`);
    - `/proc` output capped at one page (`:350,367`);
    - fixed per-process/global quotas enforced during creation (`:168-203`);
    - benchmark measures only the ioctl round-trip (`tests/benchmark_entry_exit.c`).
- **Next validation and refactors:** Run `tests/test_lifetime_cleanup` and `tests/test_access_limits` on the shipped Linux 6.6 aarch64 target, including a debug-kernel/lockdep pass. Both patches are runtime-verified on Ubuntu 24.04 / Linux 6.8.0-139-generic, but that is not a Buildroot/QEMU result. (`kernel/pex_main.c:491-529,592-619,685-715`; `tests/test_lifetime_cleanup.c`; `tests/test_access_limits.c`)
  - Remaining candidates grounded in §12:
    - use `page_size` rather than `<< 12` in `pex_map`;
    - make `NO_FORK_INHERIT` real or remove it;
    - remove `pex_fault_event`, `samples/host`, and the unused `pex_device`;
    - have `S99pex` propagate failures;
    - add a CI job that at least runs `make all`.
- **Documented future work** (not personal opinion): upstreaming, richer ownership policies, syscall filtering, structured fault records, hardware-assisted secure display/memory (`docs/report.md:211-219`).

## 15. Resume Bullet -> Evidence
| Resume bullet (exact text) | Evidence (file / metric / demo) |
|----------------------------|---------------------------------|
| Built a Linux kernel module and C runtime that use explicit ioctls and page-fault-gated mappings to demonstrate intra-process protected execution. | `kernel/pex_main.c:324-340`, `kernel/pex_main.c:381-485`, `libpex/src/pex.c:17-165` |
| Created C validation programs and a Python/Tkinter demo; verified a 423.89 ns median enter/exit ioctl-pair latency and a 2126.75 ns median fault-inclusive path on a Parallels Ubuntu VM. | `demo/pex_viewer.py:94-173`, `experiments/logs/phase1-benchmark-sorted-values-corrected.log`, `experiments/logs/phase2-p4-sorted-values.log`, `experiments/logs/phase0-systemd-detect-virt.log` |
| Identified and documented limitations through probes, including first-touch-only same-process isolation and context leaks after abnormal process exit. | `experiments/logs/phase2-p1-run-1.log`, `experiments/logs/phase2-p1-run-2.log`, `experiments/logs/phase2-p1-run-3.log`, `experiments/logs/phase2-p3-proc-after-kill-1.log` |

**Claims the code supports (use as raw material):**
- Linux kernel module exposing a char device with 5 ioctls, `mmap`, a custom page-fault handler, and procfs stats: `kernel/pex_main.c:324-340,381-485,342-379`.
- Fault-gated memory: PTEs zapped on exit, SIGSEGV on inactive access: `pex_main.c:277-286,393-396`; `examples/showcase_blocking.c:149-222`.
- Owner-thread enforcement with fault accounting: `pex_main.c:206-210`; `tests/test_multithread_violation.c`.
- C runtime (static + shared) and a Python ctypes GUI: `libpex/`, `demo/pex_viewer.py`.
- Buildroot/QEMU support code exists for a cross-compiled aarch64 image (Linux 6.6.87) that auto-runs a validation suite; no successful run is recorded — do not claim a run. (`buildroot/`)
- macOS Buildroot support code exists; no successful run is recorded — do not claim a run. (`buildroot/build_image.sh:80-716`)

**Claims to AVOID unless you add evidence:**
- Any latency or overhead number other than the controlled host measurements in §10.
- "Secure", "encrypted", or "TEE-grade" without qualification: XOR demo key, no hardware backing.
- "Thread-isolated memory": only first-touch enforcement (confirmed in P1, §12).
- Universal tests "passing" or CI: there is no CI. The named host baseline programs passed on 2026-09-16 (§11), but QEMU validation and race/memory-debug test runs remain unrecorded.
- "Production", "users", "deployed".

## 16. Likely Interview Questions (my prepared answers)
- **Q: Why this stack?**
  - A: I used a kernel module because the kernel controls mapping faults and PTE revocation; userspace calls cannot enforce that boundary. I kept a small C runtime for the ioctl API and used Python/Tkinter plus `ctypes` for quick visual iteration. Buildroot and QEMU's aarch64 `virt` target provided a controlled bootable Linux demonstration environment. (`kernel/pex_main.c:275-286`, `kernel/pex_main.c:381-414`, `libpex/src/pex.c:17-165`, `demo/pex_viewer.py:94-173`, `buildroot/run_qemu.sh:194-202`)
- **Q: How does the core feature work end to end?**
  - A (code-derived draft, rewrite in your own words):
    1. The app opens `/dev/pex` and creates a context. The kernel allocates a `vmalloc_user` buffer and records my process and thread ids.
    2. I `mmap` it using the context id as the page offset. No pages are installed yet.
    3. Any touch then goes to my fault handler. If the context isn't active, or the toucher isn't the owner thread, it returns `VM_FAULT_SIGSEGV`. This check runs only on the first fault of each page; an inserted PTE is usable by any thread in the process until exit (P1). (`experiments/logs/phase2-p1-run-1.log`, `experiments/logs/phase2-p1-run-2.log`, `experiments/logs/phase2-p1-run-3.log`)
    4. `pex_enter` flips `active` after ownership and policy checks. The next touch inserts the page's PFN.
    5. `pex_exit` flips it back and calls `zap_vma_ptes`, so the next touch faults again.
    6. Counters are exposed through an info ioctl and `/proc/pex_stats`.
  - Evidence: §3 flow.
- **Q: What was the hardest bug?**
  - A: The hardest verified issue was making access revocation work after exit. I changed from returning `vmf->page` to `vmf_insert_pfn()` and marked the VMA `VM_PFNMAP`, which makes `zap_vma_ptes()` applicable; I also fixed the lock ordering. (`kernel/pex_main.c:275-286`, `kernel/pex_main.c:411-413`, `kernel/pex_main.c:477`, `linux-v6.6/mm/memory.c:1681-1693`)
- **Q: How would you scale it?**
  - A: I would replace the single global lookup lock with finer-grained or RCU-based lookup, add per-process quotas, and measure many contexts and threads instead of only the ioctl pair. (`kernel/pex_main.c:24-29`, `kernel/pex_main.c:48-49`, `tests/benchmark_entry_exit.c:27-47`)
- **Q: What would you change?**
  - A: I implemented an uncommitted lifetime patch: fd-close cleanup, `mmgrab/mmdrop` mapping ownership, module-exit frees outside the spinlock, and split-safe VMA references. The patch has a source-built regression test but no recorded Linux runtime result yet, so I would run that test under the shipped kernel and lockdep before claiming it fixed P3/P7. The P1 experiment still means I would redesign access control so it is enforced on every access, not only the first fault. (`kernel/pex_main.c:491-529,591-619,684-715`; `tests/test_lifetime_cleanup.c`; `experiments/logs/phase2-p1-run-1.log`)

**Project-specific probes a strict interviewer is likely to ask** (answers distinguish observed facts from project-owner explanations):
- "While the owner is active, can *another thread* in the same process read the page?"
  - Observed fact: in all three P1 trials, after the owner touched page 0, a second thread read it successfully without a new fault. The second thread got SIGSEGV on untouched page 1 and on page 0 after owner exit (`experiments/logs/phase2-p1-run-1.log`, `experiments/logs/phase2-p1-run-2.log`, `experiments/logs/phase2-p1-run-3.log`). My answer: Once the owner has faulted in a page while active, another thread in the same process can read that already-mapped page; untouched pages and pages after exit fault. That is a first-touch-only isolation flaw. (`experiments/logs/phase2-p1-run-1.log`, `experiments/logs/phase2-p1-run-2.log`, `experiments/logs/phase2-p1-run-3.log`)
- "Why `vmf_insert_pfn` + `VM_PFNMAP` instead of returning `vmf->page`?"
  - Code facts: see `git:1685fb4`. My answer: The buffer is mapped by PFN on demand, and `VM_PFNMAP` makes PTE zapping applicable on exit; the former `vmf->page` path lacked that VMA flag. (`kernel/pex_main.c:411-413`, `kernel/pex_main.c:477`, `linux-v6.6/mm/memory.c:1681-1693`)
- "Why drop `ctx->lock` before `mmap_write_lock` in exit?"
  - Code facts: `pex_main.c:275-286`; the fault path takes `ctx->lock` while holding the mmap read lock (`:392`). My answer: Dropping `ctx->lock` before `mmap_write_lock` prevents the inverse lock order between exit and the fault path. (`kernel/pex_main.c:275-286`, `kernel/pex_main.c:392`)
- "What happens if the process crashes while holding a context?"
  - Observed fact: before the lifetime patch, SIGKILL of a mapped, active child left `live_contexts=1` and `active_contexts=1`, and `rmmod pex` failed with "Module pex is in use" (`experiments/logs/phase2-p3-proc-after-kill-1.log`, `experiments/logs/phase2-p3-rmmod-1.log`). The current source adds a file-release teardown path and a regression test, but I have not run that patch on the target kernel. My answer: I fixed the ownership path in source and would show the P3 regression result before saying the crash leak is resolved. (`kernel/pex_main.c:591-619`; `tests/test_lifetime_cleanup.c`)
- "How is this different from SGX or TrustZone? What's your threat model?"
  - Code facts: software-only, root and the kernel are trusted (`README.md:21`; `docs/report.md:203-209`). My answer: PEX is software-only and kernel-assisted, not SGX or TrustZone. It does not protect against a compromised kernel or root, physical attacks, screenshots, or reads of already-faulted pages by another thread in the process. (`README.md:21-35`, `docs/report.md:203-209`, `experiments/logs/phase2-p1-run-1.log`)
- "Is the image actually protected?"
  - Code facts: XOR with a static key; plaintext held in Python memory from startup; copied to a display buffer (`demo/pex_viewer.py:20,335,559`; `README.md:28-35`). My answer: Only as a demo reveal: the static-key XOR is not cryptographic protection, and plaintext exists in Python memory and the display buffer. (`demo/pex_viewer.py:20`, `demo/pex_viewer.py:335`, `demo/pex_viewer.py:559`, `README.md:28-35`)
- "Why is the first context id 2?"
  - Code facts: `pex_main.c:50,115`. Observed in three fresh-load trials: `ctx_id=2` (`experiments/logs/phase2-p5-fresh-run-1.log`, `experiments/logs/phase2-p5-fresh-run-2.log`, `experiments/logs/phase2-p5-fresh-run-3.log`). My answer: `g_next_ctx_id` starts at 1 and context creation uses `atomic_inc_return`, so the first fresh-module ID is 2. (`kernel/pex_main.c:50`, `kernel/pex_main.c:115`, `experiments/logs/phase2-p5-fresh-run-1.log`)
- "What does the benchmark actually measure, and what is the number?"
  - Code facts: the stock benchmark measures the ioctl pair only, with no mapped-memory touch (`tests/benchmark_entry_exit.c`). Measured host median: 423.89 ns; P4's enter→first-page-write→exit median: 2126.75 ns (§10; `experiments/logs/phase1-benchmark-sorted-values-corrected.log`, `experiments/logs/phase2-p4-sorted-values.log`). My answer: The stock measurement is the enter/exit ioctl pair only, at a 423.89 ns median on the verified host. The P4 2126.75 ns median includes entering, the first-page write fault, and exit. (`tests/benchmark_entry_exit.c:27-47`, `experiments/logs/phase1-benchmark-sorted-values-corrected.log`, `experiments/logs/phase2-p4-sorted-values.log`)
- "Why did you abandon the `dlopen` enclave design?"
  - Code facts: `git:40446fe` → `git:6fcf5bf`. My answer: I abandoned it because it invoked a `dlopen`-loaded shared library through a direct function pointer in the same address space, and its exit path did not revoke access. (`src/libtee.c:9-26` in `git:62f49d5`)
- "Why aarch64 and Buildroot?"
  - My answer: I used Buildroot and QEMU's aarch64 `virt` target for a controlled bootable Linux demonstration environment. I do not claim an unrecorded comparison against x86 or another build system. (`buildroot/configs/pex_aarch64_virt_defconfig:7-16`, `buildroot/run_qemu.sh:194-202`)
- "How did you test the kernel code for races or memory bugs (lockdep, KASAN)?"
  - Code facts: no evidence in repo. My answer: I did not record lockdep, KASAN, or race-detector runs. I used the baseline programs and targeted behavioral probes, so I do not claim formal concurrency validation. (`experiments/logs/phase1-test-multithread-violation.log`, `experiments/logs/phase2-p1-run-1.log`, `experiments/logs/phase2-p3-run-1.log`)
- "Which review findings were verified or fixed?"
  - Code facts: §12 status table. My answer: I do not claim every listed finding was independently reproduced; P1, P3, and P7 are the specific findings backed by experiment logs. (`experiments/logs/phase2-p1-run-1.log`, `experiments/logs/phase2-p3-proc-after-kill-1.log`, `experiments/logs/phase2-p7-proc-after-leak-1.log`)

## 17. Glossary (project-specific terms)
- **PEX / SofTEE (also "SoftTEE"):** the project name: "Protected Execution" subsystem, a software TEE (`README.md:1`; `pex_main.c:576`).
- **Context (`pex_context`):** kernel object holding a protected buffer, owner ids, policy, active flag, and counters (`pex_main.c:26-46`).
- **Enter / Exit:** ioctls that flip a context to active or inactive (`PEX_IOCTL_ENTER_CTX` / `EXIT_CTX`, `pex_uapi.h:79-80`).
- **Owner tgid / tid:** the creating process id and creating thread id (`pex_main.c:117-118`).
- **`PEX_POLICY_OWNER_THREAD_ONLY`:** policy bit that restricts *enter* to the creating thread (`pex_uapi.h:27`; `pex_main.c:206`).
- **Fault types:** `MEM_ACCESS` (bad touch), `CROSS_THREAD` (wrong tid on enter/exit), `BAD_STATE` (double enter / exit while inactive), `BAD_OWNER` (wrong process) (`pex_uapi.h:31-37`).
- **VMA:** a kernel `vm_area_struct`, i.e. one mapped region of a process.
- **PTE zap:** removing page-table entries (`zap_vma_ptes`) so the next access faults.
- **`vm_pgoff`:** mmap offset in pages. PEX uses it to carry the context id (`pex_main.c:443`).
- **`VM_PFNMAP`:** VMA flag for raw page-frame-number mappings, set by PEX (`pex_main.c:477`).
- **kref:** kernel reference counter controlling context lifetime (`pex_main.c:28`).
- **`pex_file`:** per-open-file list that owns cleanup responsibility for contexts created through that device file (`pex_main.c:52-53,591-619`).
- **`/proc/pex_stats`:** read-only stats file (`pex_main.c:528`).
- **`libpex`:** userspace C wrapper library (`libpex/`).
- **Protected reveal:** the GUI demo flow of placeholder → image on enter → placeholder on exit (`demo/pex_viewer.py:545-586`).
- **PPM (P3/P6):** simple ASCII/binary image formats parsed by the viewer (`demo/pex_viewer.py:233-297`).
- **`BR2_EXTERNAL` / overlay / defconfig:** Buildroot mechanisms for an out-of-tree package, extra rootfs files, and saved config (`buildroot/`).
- **`S99pex`:** SysV-style init script run at boot in the QEMU image (`buildroot/overlay/etc/init.d/S99pex`).
- **tee_sim / enclave.so:** the **deleted** pre-pivot design; do not describe it as current (`git:40446fe`, `git:6fcf5bf`).

---

## Appendix: Experiment results

| Probe | Hypothesis | Result (CONFIRMED / REFUTED / INCONCLUSIVE) | Log file |
|---|---|---|---|
| P5 first context ID | A first context after a fresh module reload receives ID 2. | **CONFIRMED** — all three fresh-load trials printed `ctx_id=2`. | `experiments/logs/phase2-p5-fresh-run-1.log`, `experiments/logs/phase2-p5-fresh-run-2.log`, `experiments/logs/phase2-p5-fresh-run-3.log` |
| P1 rogue-thread memory access | A second thread can read an owner-faulted page while active, but faults on an untouched page and after exit. | **CONFIRMED** — page 0 read succeeded without a new fault; page 1 and post-exit page 0 each raised SIGSEGV in all three runs. | `experiments/logs/phase2-p1-run-1.log`, `experiments/logs/phase2-p1-run-2.log`, `experiments/logs/phase2-p1-run-3.log` |
| P2 policy scope | With policy 0, another thread can enter but cannot touch mapped memory or exit. | **CONFIRMED** — enter=0, touch=SIGSEGV, exit=-EPERM, owner exit=0 in all three runs. | `experiments/logs/phase2-p2-run-1.log`, `experiments/logs/phase2-p2-run-2.log`, `experiments/logs/phase2-p2-run-3.log` |
| P4 fault-inclusive cost | Enter→first-page-write→exit is slower than the stock enter/exit-only benchmark. | **CONFIRMED** — 2126.75 ns median versus 423.89 ns stock median. | `experiments/logs/phase2-p4-sorted-values.log`, `experiments/logs/phase1-benchmark-sorted-values-corrected.log` |
| P6 unprivileged access and quotas | **Pre-patch:** a non-root user can complete the 4096-byte lifecycle through mode `0666`. **Current patch:** `root:<authorized-group>` mode `0660`, bounded contexts and bytes. | **Historical failure CONFIRMED; patch RUNTIME VERIFIED** on Ubuntu 24.04 / Linux 6.8.0-139-generic: dropped UID/GID 65534 cannot open the device; per-process and global count/byte quotas return `-EDQUOT` and recover after close. | Historical logs; `pex_uapi.h:20-24`; `kernel/pex_main.c:168-203`; `tests/test_access_limits.c`; 2026-04-21 VM run in §11 |
| P7 leaked unmapped context | **Pre-patch:** closing the fd without map/destroy leaves the context live. **Current patch:** `.release` removes the creating file's contexts. | **Historical failure CONFIRMED; patch RUNTIME VERIFIED** on Ubuntu 24.04 / Linux 6.8.0-139-generic: fd-close returned to zero live and active contexts. | Historical logs; `kernel/pex_main.c:592-619`; `tests/test_lifetime_cleanup.c`; 2026-04-21 VM run in §11 |
| P3 killed mapped-active context | **Pre-patch:** SIGKILL leaves a live context and makes `rmmod` fail. **Current patch:** close teardown deactivates and releases the context, and the test kills an active mapped child. | **Historical failure CONFIRMED; patch RUNTIME VERIFIED** on Ubuntu 24.04 / Linux 6.8.0-139-generic: SIGKILL cleanup returned to zero live and active contexts, then `rmmod pex` succeeded. The old causal mechanism remains inconclusive. | Historical logs; `kernel/pex_main.c:592-619`; `tests/test_lifetime_cleanup.c`; 2026-04-21 VM run in §11 |

## Appendix: Static verification triage

| Dossier line | Claim | Verdict | Evidence |
|---|---|---|---|
| 25 | `OS/` implies an operating-systems course. | **INCONCLUSIVE from source alone** — directory naming cannot prove course context. | `samples/host` path. |
| 141 | Darwin/Homebrew code proves an Apple Silicon host. | **INCONCLUSIVE** — code proves Darwin/Homebrew support, not a host platform. | `buildroot/build_image.sh:644-652`; `git:62f49d5`. |
| 280 | Sparse-copy/fsck code means images were moved between machines. | **INCONCLUSIVE** — it shows defensive handling only. | `buildroot/build_image.sh:763-766`; `buildroot/run_qemu.sh:158-192`. |
| 302 | The global context-table spinlock causes measurable contention. | **INCONCLUSIVE** — plausible architecture risk, but unmeasured. | `kernel/pex_main.c:48-49`; no multi-context benchmark log. |
| 315 | Python/ctypes gave faster UI iteration. | **INCONCLUSIVE from source alone** — the rationale is stated in §4. | `demo/pex_viewer.py:94-173`. |
| 319 | Vendoring Buildroot gives an offline reproducible build. | **INCONCLUSIVE** — tarball is present, but no offline Buildroot build was recorded. | `buildroot/buildroot-2024.02.12.tar.xz`; no corresponding experiment log. |

## Appendix: Drafting checklist
1. Resolve every remaining verification tag (search for `VERIFY` in this file).
2. Set `Last verified by me` after personally reviewing this dossier; it is intentionally the only unresolved project-owner field.
3. Host run done; QEMU run still unrecorded.
4. Decide how to handle the **doc-vs-code CONFLICT candidates** before an interview:
   - `docs/report.md:117,130` vs `pex_main.c:255,393` (thread-policy scope);
   - `docs/report.md:92-97` vs first-touch-only enforcement;
   - the viewer log says it "decrypted the PPM payload" on entry (`demo/pex_viewer.py:563`), while decryption happens at startup (`demo/pex_viewer.py:335`; `README.md:39`).
5. Update "Last verified by me" and the commit hash whenever code changes.
