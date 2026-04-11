# PEX: Kernel-Assisted Protected Execution Subsystem

PEX is a software trusted execution environment prototype that adds fine-grained, kernel-enforced execution isolation inside a single process. It combines a Linux kernel module, a small user-space runtime, console validation programs, and a Tkinter demo that reveals a protected image only while the owning thread is inside protected mode.

The implementation is intentionally operating-system-centric:

- Protected memory is allocated by the kernel and exposed through `/dev/pex`.
- Page faults are used to gate access to mapped memory outside active protected execution.
- Entry and exit are explicit `ioctl` transitions enforced by the kernel.
- Thread ownership is enforced with `PEX_POLICY_OWNER_THREAD_ONLY`.
- Runtime state is observable through `/proc/pex_stats` and per-context counters.

## What The Demo Shows

- The window starts in a locked state with a placeholder image.
- `Enter Protected Mode` calls `pex_enter()`, decrypts a bundled PPM payload into the protected page, copies it into a display buffer, and reveals the image.
- `Exit Protected Mode` wipes the protected buffer, calls `pex_exit()`, and returns the window to the locked state.
- `Rogue Thread Access` spawns a secondary thread that attempts `pex_enter()` on the same context; the kernel denies it and fault counters increase.
- The console showcase demonstrates real blocked memory access by touching the mapped page outside protected mode and observing `SIGSEGV` or `SIGBUS`.

This is a protected-reveal simulation, not hardware-backed secure display or screenshot prevention.

## Repository Layout

- `kernel/`: `pex.ko` kernel module and `Makefile`
- `libpex/`: C runtime API as both `libpex.a` and `libpex.so`
- `examples/`: protected workload and blocked-memory showcase
- `tests/`: cross-thread policy test and enter/exit benchmark
- `demo/`: Tkinter viewer and encrypted PPM asset
- `scripts/`: module/device setup and demo runners
- `docs/`: report text and live-demo script

## Build

```bash
make lib
make kernel
make examples
make tests
make demo
```

Or build everything except the kernel module with:

```bash
make all
```

## Runtime Setup

Loading the module requires root privileges:

```bash
sudo bash ./scripts/dev_setup.sh
```

That script:

- builds `kernel/pex.ko` if needed
- unloads any previous `pex` module
- inserts the module
- recreates `/dev/pex`
- sets device permissions for non-root demos

## Run The Demos

Windowed demo on a desktop session:

```bash
bash ./scripts/run_demo.sh
```

Console showcase of blocked inactive-memory access:

```bash
make run-showcase
```

Console tests and benchmark:

```bash
make run-tests
```

Full end-to-end script:

```bash
bash ./scripts/run_all.sh
```

Headless validation when no display is available:

```bash
python3 demo/pex_viewer.py --self-check
```

## Observability

The kernel publishes summary state and per-context lines through `/proc/pex_stats`:

```text
live_contexts=1
active_contexts=0
total_faults=2
ctx=1 owner=1234:1234 active=0 entries=1 exits=1 faults=2 ns=123456 size=4096 name=viewer_ctx
```

You can also inspect recent kernel fault logs with:

```bash
dmesg | tail -n 50
```

## Assumptions

- Linux with matching kernel headers installed
- root or `sudo` access for module loading
- Python 3 with Tkinter available
- no simulation fallback mode in the core design

## Documentation

- Project/report writeup: [docs/report.md](/home/ubuntu/OS/PEX/docs/report.md)
- Live narration and demo checklist: [docs/demo_script.md](/home/ubuntu/OS/PEX/docs/demo_script.md)
