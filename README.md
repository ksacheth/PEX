# PEX SofTEE: Kernel-Assisted Protected Execution Subsystem

PEX is a software trusted execution environment prototype for Linux. It adds a kernel-enforced protected execution context inside a single process by combining:

- a kernel module that exposes `/dev/pex`
- a small C runtime library in `libpex/`
- console examples and tests
- a Tkinter viewer demo
- a Buildroot package and QEMU image for end-to-end validation

The design is intentionally operating-system-centric:

- protected memory is kernel-owned and mapped through `/dev/pex`
- `ioctl` transitions control context create, enter, exit, destroy, and info queries
- a first access to an unmapped page faults when the context is inactive or the
  faulting thread is not the creator thread
- `PEX_POLICY_OWNER_THREAD_ONLY` gates owner-thread entry
- contexts are tied to their creating device-file lifetime and are cleaned up on
  the final file-descriptor close
- `/dev/pex` is accessible only to root and its configured authorized group, and
  context allocations are quota-limited
- `/proc/pex_stats` exposes global and per-context counters

## What This Project Actually Demonstrates

PEX demonstrates kernel-assisted, fault-gated access control within a process,
not hardware-backed trusted execution or complete in-process isolation.

- The console showcase proves that touching an invalidated mapped page while inactive triggers a real fault.
- With `PEX_POLICY_OWNER_THREAD_ONLY`, the kernel rejects `pex_enter()` from a non-owner thread.
- The kernel tracks entries, exits, faults, and protected time.
- Closing a context's creating device file removes its remaining contexts; an
  active mapping is deactivated and its PTEs are revoked before its references
  are dropped.
- The Tkinter viewer ties those transitions to a visible "locked" and "revealed" image flow.

The viewer is a protected-reveal demo, not a secure display pipeline:

- the bundled image asset is decrypted in user space during startup
- on `pex_enter()`, the plaintext image bytes are copied into the protected mapping
- the UI then copies those bytes into a normal display buffer for rendering
- on `pex_exit()`, the protected buffer and display buffer are wiped and the placeholder returns

This means the demo is useful for showing protected execution state and fault-gated memory, but it is not screenshot-resistant and it does not keep the full display path inside protected memory.

It is also not a general thread-local memory-isolation mechanism. The VMA fault
handler checks the creator thread only when a page faults. Once that fault
installs a PTE while the context is active, Linux's process-wide page tables can
let another thread in the same process use that already-present page until
`pex_exit()` invalidates the mapping again. The viewer maps a 2 MiB region, not
a single page. Finally, `PEX_POLICY_OWNER_THREAD_ONLY` only gates
`pex_enter()` today: the fault and exit paths require the creator thread even
when that flag is absent. Treat the project as a teaching prototype, not a
security boundary for secrets shared with untrusted in-process threads.

## Repository Layout

- `kernel/`: `pex.ko` kernel module
- `libpex/`: C runtime library as `libpex.a` and `libpex.so`
- `examples/`: protected workload and blocked-access showcase
- `tests/`: thread-policy validation, lifetime cleanup regression coverage, and
  an enter/exit benchmark
- `demo/`: Tkinter viewer and protected image asset
- `scripts/`: local host setup and demo runners
- `buildroot/`: Buildroot packaging, rootfs overlay, and QEMU boot scripts
- `docs/`: report and live-demo notes

## Host Build

Build the host-side components from the repo root:

```bash
make lib
make kernel
make examples
make tests
make demo
```

Or build everything except the kernel module:

```bash
make all
```

Top-level helpers are also available:

```bash
make run-showcase
make run-tests
make run-e2e
```

## Host Runtime Setup

Loading the module requires root:

```bash
sudo bash ./scripts/dev_setup.sh
```

That script:

- builds `kernel/pex.ko` if needed
- unloads a previous `pex` module when possible
- inserts the module
- recreates `/dev/pex`
- sets `/dev/pex` to `root:<authorized-group>` mode `0660`; by default the
  authorized group is the primary group of the user who invoked `sudo`

Users outside that group cannot open `/dev/pex`. To select an existing shared
group explicitly, set `PEX_DEVICE_GROUP` when loading the module:

```bash
sudo PEX_DEVICE_GROUP=pexusers bash ./scripts/dev_setup.sh
```

The kernel rejects allocations above these limits: 16 MiB per context, 8
contexts or 16 MiB per process, and 64 contexts or 64 MiB globally. Rejected
quota requests return `-EDQUOT`; an oversized single context returns `-E2BIG`.

## Host Demo Flow

Run the windowed viewer on a desktop Linux session:

```bash
bash ./scripts/run_demo.sh
```

Run the blocked-access console showcase:

```bash
make run-showcase
```

Run the console validation tests:

```bash
make run-tests
```

The lifetime regression test can also be run directly on a Linux host with PEX
loaded:

```bash
./tests/test_lifetime_cleanup
```

It checks cleanup after closing an fd without `pex_destroy()`, after `SIGKILL`
of an active mapped child, and after a split VMA is unmapped and destroyed.

Run the access-control and resource-limit regression as root:

```bash
sudo ./tests/test_access_limits
```

It confirms that an unprivileged child cannot open `/dev/pex`, then exercises
per-process and global context/byte quotas and confirms capacity is reclaimed
when the owning fds close.

Run the full host-side end-to-end flow:

```bash
bash ./scripts/run_all.sh
```

Run the Python viewer self-check when no display is available:

```bash
python3 demo/pex_viewer.py --self-check
```

## Buildroot And QEMU Flow

This repo also packages PEX into a Buildroot image that boots under QEMU and runs validation automatically through the rootfs overlay init script.

Build the image:

```bash
./buildroot/build_image.sh
```

Boot it in QEMU:

```bash
./buildroot/run_qemu.sh
```

Boot directly to a shell without the auto-validation path:

```bash
./buildroot/run_qemu.sh --shell
```

Inside that environment, the overlay scripts load `pex.ko`, create `/dev/pex`, and run the validation suite from `/opt/pex/`.

## Observability

PEX exposes summary and per-context state through `/proc/pex_stats`:

```text
live_contexts=1
active_contexts=0
total_faults=2
ctx=1 owner=1234:1234 active=0 entries=1 exits=1 faults=2 ns=123456 size=4096 name=viewer_ctx
```

You can also inspect recent kernel messages:

```bash
dmesg | tail -n 50
```

## Requirements

For the host workflow:

- Linux with matching kernel headers
- `make`, a C compiler, and standard build tools
- root or `sudo` access for module loading
- Python 3 with Tkinter for the viewer

For the Buildroot/QEMU workflow:

- `qemu-system-aarch64`
- the host tools needed by `buildroot/build_image.sh`

## Documentation

- Project writeup: [docs/report.md](docs/report.md)
