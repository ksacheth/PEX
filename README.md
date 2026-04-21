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
- mapped pages fault when the context is inactive or the wrong thread touches them
- `PEX_POLICY_OWNER_THREAD_ONLY` enforces owner-thread entry
- `/proc/pex_stats` exposes global and per-context counters

## What This Project Actually Demonstrates

PEX demonstrates kernel-assisted intra-process isolation, not hardware-backed trusted execution.

- The console showcase proves that touching the mapped region while inactive triggers a real fault.
- The runtime only allows the owning thread to enter a protected context when owner-thread policy is enabled.
- The kernel tracks entries, exits, faults, and protected time.
- The Tkinter viewer ties those transitions to a visible "locked" and "revealed" image flow.

The viewer is a protected-reveal demo, not a secure display pipeline:

- the bundled image asset is decrypted in user space during startup
- on `pex_enter()`, the plaintext image bytes are copied into the protected mapping
- the UI then copies those bytes into a normal display buffer for rendering
- on `pex_exit()`, the protected buffer and display buffer are wiped and the placeholder returns

This means the demo is useful for showing protected execution state and fault-gated memory, but it is not screenshot-resistant and it does not keep the full display path inside protected memory.

## Repository Layout

- `kernel/`: `pex.ko` kernel module
- `libpex/`: C runtime library as `libpex.a` and `libpex.so`
- `examples/`: protected workload and blocked-access showcase
- `tests/`: policy validation and enter/exit benchmark
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
- sets device permissions for non-root demos

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
- Demo script: [docs/demo_script.md](docs/demo_script.md)
