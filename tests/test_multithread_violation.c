#include <pthread.h>
#include <stdio.h>

#include "../libpex/include/pex.h"

static pex_handle_t g_handle;
static int g_thread_rc = 0;

static void *thread_fn(void *arg)
{
    (void)arg;
    g_thread_rc = pex_enter(&g_handle);
    return NULL;
}

int main(void)
{
    pthread_t t;
    struct pex_ctx_info before;
    struct pex_ctx_info after;
    int rc;

    rc = pex_open(&g_handle);
    if (rc) {
        fprintf(stderr, "pex_open failed: %d\n", rc);
        return 1;
    }
    rc = pex_create(&g_handle, "thread_test", 4096, PEX_POLICY_OWNER_THREAD_ONLY);
    if (rc) {
        fprintf(stderr, "pex_create failed: %d\n", rc);
        pex_close(&g_handle);
        return 1;
    }

    rc = pex_get_info(&g_handle, &before);
    if (rc) {
        fprintf(stderr, "pex_get_info(before) failed: %d\n", rc);
        goto fail;
    }

    rc = pthread_create(&t, NULL, thread_fn, NULL);
    if (rc) {
        fprintf(stderr, "pthread_create failed: %d\n", rc);
        goto fail;
    }
    pthread_join(t, NULL);

    rc = pex_get_info(&g_handle, &after);
    if (rc) {
        fprintf(stderr, "pex_get_info(after) failed: %d\n", rc);
        goto fail;
    }

    printf("secondary thread pex_enter rc=%d (expected < 0)\n", g_thread_rc);
    printf("faults_before=%llu faults_after=%llu\n",
        (unsigned long long)before.total_faults,
        (unsigned long long)after.total_faults);

    if (g_thread_rc >= 0) {
        fprintf(stderr, "expected cross-thread pex_enter to fail\n");
        goto fail;
    }
    if (after.total_faults <= before.total_faults) {
        fprintf(stderr, "expected fault counter to increase\n");
        goto fail;
    }

    pex_destroy(&g_handle);
    pex_close(&g_handle);
    return 0;

fail:
    pex_destroy(&g_handle);
    pex_close(&g_handle);
    return 1;
}
