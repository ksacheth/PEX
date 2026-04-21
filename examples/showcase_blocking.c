#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../libpex/include/pex.h"

static sigjmp_buf g_jmp;
static volatile sig_atomic_t g_sig = 0;

static void fault_handler(int sig, siginfo_t *info, void *ucontext)
{
    (void)info;
    (void)ucontext;
    g_sig = sig;
    siglongjmp(g_jmp, 1);
}

static int guarded_write_ul(volatile unsigned long *addr, unsigned long v)
{
    g_sig = 0;
    if (sigsetjmp(g_jmp, 1) == 0) {
        *addr = v;
        return 0;
    }
    return (int)g_sig;
}

static int guarded_read_ul(volatile unsigned long *addr, unsigned long *out)
{
    g_sig = 0;
    if (sigsetjmp(g_jmp, 1) == 0) {
        *out = *addr;
        return 0;
    }
    return (int)g_sig;
}

static void print_ctx_info(pex_handle_t *h)
{
    struct pex_ctx_info info;
    int rc = pex_get_info(h, &info);

    if (rc) {
        printf("  [info] pex_get_info failed rc=%d\n", rc);
        return;
    }

    printf("  [info] ctx=%d active=%u faults=%llu entries=%llu exits=%llu time_ns=%llu\n",
        info.ctx_id, info.active, (unsigned long long)info.total_faults,
        (unsigned long long)info.total_entries, (unsigned long long)info.total_exits,
        (unsigned long long)info.total_ns);
}

static void dump_proc_stats(void)
{
    FILE *f = fopen("/proc/pex_stats", "r");
    char line[256];

    if (!f) {
        perror("fopen(/proc/pex_stats)");
        return;
    }

    printf("  [proc] /proc/pex_stats:\n");
    while (fgets(line, sizeof(line), f))
        printf("    %s", line);
    fclose(f);
}

struct thread_args {
    pex_handle_t *h;
    int *thread_rc;
};

static void *cross_thread_enter(void *arg)
{
    struct thread_args *a = (struct thread_args *)arg;
    int rc = pex_enter(a->h);

    if (a->thread_rc)
        *a->thread_rc = rc;
    printf("[thread] pex_enter rc=%d (expected < 0 due to owner-thread policy)\n", rc);
    return NULL;
}

int main(int argc, char **argv)
{
    int sleep_s = 1;
    int rc;
    int failed = 0;
    pex_handle_t h;
    volatile unsigned long *region;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--sleep") && i + 1 < argc) {
            sleep_s = atoi(argv[i + 1]);
            i++;
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = fault_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) < 0) {
        perror("sigaction(SIGSEGV)");
        return 1;
    }
    if (sigaction(SIGBUS, &sa, NULL) < 0) {
        perror("sigaction(SIGBUS)");
        return 1;
    }

    printf("PEX Showcase (blocked memory access visible in userspace)\n");
    printf("Config: sleep_s=%d\n", sleep_s);
    printf("Step 1: open /dev/pex\n");
    rc = pex_open(&h);
    if (rc) {
        printf("  pex_open failed rc=%d\n", rc);
        return 1;
    }

    printf("Step 2: create ctx + map 1 page\n");
    rc = pex_create(&h, "showcase_ctx", 4096, PEX_POLICY_OWNER_THREAD_ONLY);
    if (rc) {
        printf("  pex_create failed rc=%d\n", rc);
        pex_close(&h);
        return 1;
    }

    region = (volatile unsigned long *)pex_map(&h, 4096);
    if (!region) {
        printf("  pex_map failed\n");
        pex_destroy(&h);
        pex_close(&h);
        return 1;
    }

    print_ctx_info(&h);
    dump_proc_stats();
    sleep(sleep_s);

    printf("Step 3: touch mapped region while INACTIVE (should SIGSEGV)\n");
    int fault_sig = guarded_write_ul(region, 0x1111UL);
    if (fault_sig == 0) {
        printf("  Unexpected: write succeeded while context inactive\n");
        failed = 1;
    } else {
        printf("  Blocked: got signal %d (%s) from kernel fault gating\n",
            fault_sig,
            fault_sig == SIGSEGV ? "SIGSEGV" : (fault_sig == SIGBUS ? "SIGBUS" : "other"));
    }
    print_ctx_info(&h);
    dump_proc_stats();
    sleep(sleep_s);

    printf("Step 4: enter context (writes should succeed)\n");
    rc = pex_enter(&h);
    if (rc) {
        printf("  pex_enter failed rc=%d\n", rc);
        pex_unmap(&h);
        pex_destroy(&h);
        pex_close(&h);
        return 1;
    }

    unsigned long v = 0;
    fault_sig = guarded_write_ul(region, 0x2222UL);
    if (fault_sig == 0) {
        if (guarded_read_ul(region, &v) == 0)
            printf("  Allowed: region[0]=0x%lx\n", v);
        else {
            printf("  Unexpected: read blocked inside active context (sig=%d)\n", (int)g_sig);
            failed = 1;
        }
    } else {
        printf("  Unexpected: write blocked inside active context (sig=%d)\n", fault_sig);
        failed = 1;
    }
    print_ctx_info(&h);
    dump_proc_stats();
    sleep(sleep_s);

    printf("Step 5: start cross-thread pex_enter while active (should be denied)\n");
    pthread_t t;
    int thread_rc = 0;
    struct thread_args a = {.h = &h, .thread_rc = &thread_rc};
    rc = pthread_create(&t, NULL, cross_thread_enter, &a);
    if (rc) {
        printf("  pthread_create failed rc=%d\n", rc);
        failed = 1;
    } else {
        pthread_join(t, NULL);
        if (thread_rc >= 0) {
            printf("  Unexpected: secondary thread entered protected mode\n");
            failed = 1;
        }
    }
    print_ctx_info(&h);
    dump_proc_stats();
    sleep(sleep_s);

    printf("Step 6: exit context and touch again (should SIGSEGV)\n");
    rc = pex_exit(&h);
    if (rc) {
        printf("  pex_exit failed rc=%d\n", rc);
        failed = 1;
    }

    fault_sig = guarded_write_ul(region, 0x3333UL);
    if (fault_sig == 0) {
        printf("  Unexpected: write succeeded while context inactive after exit\n");
        failed = 1;
    } else {
        printf("  Blocked again: got signal %d\n", fault_sig);
    }

    print_ctx_info(&h);
    dump_proc_stats();
    printf("Done.\n");

    pex_unmap(&h);
    pex_destroy(&h);
    pex_close(&h);
    return failed ? 1 : 0;
}
