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

> PEX is a kernel-assisted teaching prototype. The kernel owns the mapped buffer, the runtime exposes explicit entry and exit calls, and the page-fault path rejects an access after exit when that access faults. It is not a hardware TEE or complete thread-local memory isolation.

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

> The viewer decrypted the bundled image during startup. This button calls `pex_enter()`, then the owner thread copies those already-decrypted bytes into the 2 MiB protected mapping, copies them into a normal display buffer, and reveals the image.

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

> The application wipes the protected mapping, calls `pex_exit()`, and the image disappears. After this point, touching the mapped region again would fault.

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

> This is the hard proof path. The process has a mapping, but after `pex_exit()` invalidates its PTEs, touching the page while inactive makes the kernel fault handler reject the access and the process receives a signal. Inside protected mode, the owner thread can fault the page in. This proves fault-gated access after exit; it does not prove that another thread cannot use an already-present process-wide PTE before exit.

## 5. Cross-Thread Test

Run:

```bash
./tests/test_multithread_violation
```

Narrate:

> This test isolates the policy rule itself. A secondary thread tries `pex_enter()`, gets a negative return code, and the fault counter rises.

## 6. Context Lifetime Regression

Run:

```bash
./tests/test_lifetime_cleanup
```

Narrate:

> This regression test checks resource ownership rather than access policy. It verifies that closing an fd without an explicit destroy, killing a child while its mapping is active, and splitting a VMA do not leave live or active contexts behind.

## 7. Access Control And Resource Limits

Run:

```bash
sudo ./tests/test_access_limits
```

Narrate:

> The device is no longer world-writable: only root and the authorized device group can open it. This test drops a child to an unprivileged identity and confirms that open is denied. It then fills per-process and global context and byte quotas, observes `-EDQUOT`, and confirms capacity returns when the owning fds close.

## 8. Performance Measurement

Run:

```bash
./tests/benchmark_entry_exit
```

Narrate:

> This benchmark gives the average cost of entering and exiting the protected context, which helps quantify the software overhead of this kernel-mediated fault-gating model.

## 9. Closing Line

Use this finish:

> The important result is a programmable, kernel-enforced lifecycle and fault-gated access demonstration. The application chooses when to enter protected execution, but the kernel decides whether a faulting access is allowed; it is not a complete in-process security boundary.
