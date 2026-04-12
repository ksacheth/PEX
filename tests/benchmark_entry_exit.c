#include <stdio.h>
#include <time.h>

#include "../libpex/include/pex.h"

static unsigned long long now_ns(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000000000ULL + (unsigned long long)ts.tv_nsec;
}

int main(void)
{
    pex_handle_t h;
    int rc;
    const int iters = 10000;
    unsigned long long t0;
    unsigned long long t1;

    rc = pex_open(&h);
    if (rc) {
        fprintf(stderr, "pex_open failed: %d\n", rc);
        return 1;
    }
    rc = pex_create(&h, "bench_ctx", 4096, PEX_POLICY_OWNER_THREAD_ONLY);
    if (rc) {
        fprintf(stderr, "pex_create failed: %d\n", rc);
        pex_close(&h);
        return 1;
    }

    t0 = now_ns();
    for (int i = 0; i < iters; i++) {
        rc = pex_enter(&h);
        if (rc) {
            fprintf(stderr, "pex_enter failed at iter %d: %d\n", i, rc);
            break;
        }
        rc = pex_exit(&h);
        if (rc) {
            fprintf(stderr, "pex_exit failed at iter %d: %d\n", i, rc);
            break;
        }
    }
    t1 = now_ns();

    if (!rc) {
        double avg_ns = (double)(t1 - t0) / (double)iters;
        printf("iterations=%d total_ns=%llu avg_enter_exit_ns=%.2f\n",
            iters, (t1 - t0), avg_ns);
    }

    pex_destroy(&h);
    pex_close(&h);
    return rc ? 1 : 0;
}
