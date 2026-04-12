#!/bin/sh
#
# run_validation.sh -- Full PEX subsystem validation suite
#
# Runs all console-mode demos and tests, printing pass/fail for each.
# Exits with 0 if all pass, 1 otherwise.
#

PASS=0
FAIL=0
TOTAL=0

run_test() {
    name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    echo ""
    echo "──────────────────────────────────────────────"
    echo "[${TOTAL}] ${name}"
    echo "──────────────────────────────────────────────"

    if "$@"; then
        echo "  ✓ PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "  ✗ FAIL: ${name} (exit code $?)"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   PEX Subsystem Validation Suite                 ║"
echo "║   Kernel-Assisted Protected Execution            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Verify module is loaded
if ! grep -q '^pex ' /proc/modules 2>/dev/null; then
    echo "ERROR: PEX module not loaded. Run dev_setup.sh first."
    exit 1
fi

echo "[pre] Module loaded, /dev/pex ready."
echo ""

# ── Test 1: Protected Workload ──
run_test "protected_workload (basic create/enter/compute/exit)" \
    /opt/pex/protected_workload

# ── Test 2: Showcase Blocking ──
run_test "showcase_blocking (fault gating, SIGSEGV, cross-thread)" \
    /opt/pex/showcase_blocking --sleep 0

# ── Test 3: Multi-thread Violation ──
run_test "test_multithread_violation (owner-thread policy enforcement)" \
    /opt/pex/test_multithread_violation

# ── Test 4: Benchmark ──
run_test "benchmark_entry_exit (10000 enter/exit cycles)" \
    /opt/pex/benchmark_entry_exit

# ── Test 5: Python self-check (if python3 available) ──
if command -v python3 >/dev/null 2>&1; then
    run_test "pex_viewer.py --self-check (Python bindings)" \
        python3 /opt/pex/pex_viewer.py --self-check
else
    echo ""
    echo "[skip] python3 not available, skipping pex_viewer.py --self-check"
fi

# ── Summary ──
echo ""
echo "══════════════════════════════════════════════════"
echo "  /proc/pex_stats:"
echo "══════════════════════════════════════════════════"
cat /proc/pex_stats 2>/dev/null || echo "  (not available)"

echo ""
echo "══════════════════════════════════════════════════"
echo "  Kernel log (PEX entries):"
echo "══════════════════════════════════════════════════"
dmesg 2>/dev/null | grep -i pex | tail -20 || echo "  (dmesg not available)"

echo ""
echo "══════════════════════════════════════════════════"
echo "  RESULTS: ${PASS} passed, ${FAIL} failed out of ${TOTAL} tests"
echo "══════════════════════════════════════════════════"

if [ "${FAIL}" -gt 0 ]; then
    echo "  ✗ SOME TESTS FAILED"
    exit 1
else
    echo "  ✓ ALL TESTS PASSED"
    exit 0
fi
