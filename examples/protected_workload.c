#include <stdio.h>

#include "../libpex/include/pex.h"

static int do_sensitive_compute(void)
{
    volatile unsigned long sum = 0;

    for (unsigned long i = 0; i < 1000000UL; i++)
        sum += (i ^ 0x5a5aUL);
    return (int)(sum & 0xffff);
}

int main(void)
{
    pex_handle_t h;
    struct pex_ctx_info info;
    volatile unsigned long *secret_region;
    int rc;

    rc = pex_open(&h);
    if (rc) {
        fprintf(stderr, "pex_open failed: %d\n", rc);
        return 1;
    }

    rc = pex_create(&h, "demo_ctx", 4096, PEX_POLICY_OWNER_THREAD_ONLY);
    if (rc) {
        fprintf(stderr, "pex_create failed: %d\n", rc);
        pex_close(&h);
        return 1;
    }

    secret_region = (volatile unsigned long *)pex_map(&h, 4096);
    if (!secret_region) {
        fprintf(stderr, "pex_map failed\n");
        rc = 1;
        goto cleanup;
    }

    rc = pex_enter(&h);
    if (rc) {
        fprintf(stderr, "pex_enter failed: %d\n", rc);
        goto cleanup;
    }

    secret_region[0] = 0xabcdefUL;
    secret_region[1] = (unsigned long)do_sensitive_compute();
    printf("Sensitive result: %lu (guard=%lu)\n", secret_region[1], secret_region[0]);

    rc = pex_exit(&h);
    if (rc) {
        fprintf(stderr, "pex_exit failed: %d\n", rc);
        goto cleanup;
    }

    rc = pex_get_info(&h, &info);
    if (!rc) {
        printf("ctx=%d entries=%llu exits=%llu faults=%llu ns=%llu\n",
            info.ctx_id, info.total_entries, info.total_exits,
            info.total_faults, info.total_ns);
    }

cleanup:
    pex_unmap(&h);
    pex_destroy(&h);
    pex_close(&h);
    return rc ? 1 : 0;
}
