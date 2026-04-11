# PEX SofTEE Demo Script

## 1. Setup Before The Talk

From the project root:

```bash
make all
make kernel
sudo bash ./scripts/dev_setup.sh
```

Desktop session for the full viewer:

```bash
python3 demo/pex_viewer.py
```

Headless fallback for verification only:

```bash
python3 demo/pex_viewer.py --self-check
```

## 2. Opening Narrative

Use this framing:

> PEX is a software trusted execution environment built as an operating-system subsystem. The kernel owns the protected memory, the runtime exposes explicit entry and exit calls, and the page-fault path enforces that the mapped region is inaccessible outside protected execution.

## 3. Windowed Demo Flow

### Initial State

Say:

> The application has already created and mapped a protected context, but the context is inactive. The window is showing a locked placeholder, and the stats panel shows `active=0`.

Call out:

- locked placeholder image
- current context id
- zero or low fault counts
- `/proc`-backed global counters

### Enter Protected Mode

Press `Enter Protected Mode`.

Say:

> This button calls `pex_enter()`. While the owner thread is active, the application decrypts the bundled image into the protected page, copies it into a display buffer, and reveals it.

Call out:

- visible image appears
- entry counter increases
- `active=1`

### Rogue Thread Access

Press `Rogue Thread Access`.

Say:

> Now a secondary thread in the same process attempts to enter the protected context. The kernel rejects it because this context is owner-thread-only.

Call out:

- status banner reports denial
- context fault counter increases
- global `/proc/pex_stats` fault counter increases

### Exit Protected Mode

Press `Exit Protected Mode`.

Say:

> The application wipes the protected page, calls `pex_exit()`, and the image disappears. After this point, touching the mapped region again would fault.

Call out:

- placeholder returns
- exit counter increases
- `active=0`

## 4. Console Proof

Run:

```bash
./examples/showcase_blocking --sleep 1
```

Narrate:

> This is the hard proof path. The process has a mapping, but when it touches the page while inactive, the kernel fault handler rejects the access and the process receives a signal. Inside protected mode, the same access succeeds. After `pex_exit()`, the access is blocked again.

## 5. Cross-Thread Test

Run:

```bash
./tests/test_multithread_violation
```

Narrate:

> This test isolates the policy rule itself. A secondary thread tries `pex_enter()`, gets a negative return code, and the fault counter rises.

## 6. Performance Measurement

Run:

```bash
./tests/benchmark_entry_exit
```

Narrate:

> This benchmark gives the average cost of entering and exiting the protected context, which helps quantify the software overhead of this kernel-enforced isolation model.

## 7. Closing Line

Use this finish:

> The important result is that the operating system is enforcing a programmable, intra-process protection boundary. The application chooses when to enter protected execution, but the kernel decides when memory access is actually allowed.
