#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../libpex/include/pex.h"

struct pex_stats {
    long long live_contexts;
    long long active_contexts;
};

static int read_stats(struct pex_stats *stats)
{
    FILE *file;
    char line[128];
    int have_live = 0;
    int have_active = 0;

    file = fopen("/proc/pex_stats", "r");
    if (!file) {
        perror("fopen(/proc/pex_stats)");
        return -1;
    }

    while (fgets(line, sizeof(line), file)) {
        if (sscanf(line, "live_contexts=%lld", &stats->live_contexts) == 1)
            have_live = 1;
        if (sscanf(line, "active_contexts=%lld", &stats->active_contexts) == 1)
            have_active = 1;
    }
    fclose(file);

    return have_live && have_active ? 0 : -1;
}

static int expect_baseline(const char *name, const struct pex_stats *baseline)
{
    struct pex_stats current;
    int attempt;

    for (attempt = 0; attempt < 50; attempt++) {
        if (!read_stats(&current) &&
            current.live_contexts == baseline->live_contexts &&
            current.active_contexts == baseline->active_contexts) {
            printf("%s: live_contexts=%lld active_contexts=%lld\n", name,
                   current.live_contexts, current.active_contexts);
            return 0;
        }
        usleep(10000);
    }

    fprintf(stderr, "%s did not restore the baseline context counts\n", name);
    return -1;
}

static void close_without_destroy(void)
{
    pex_handle_t handle;

    if (pex_open(&handle) ||
        pex_create(&handle, "close_cleanup", 4096, PEX_POLICY_OWNER_THREAD_ONLY))
        _exit(1);

    pex_close(&handle);
    _exit(0);
}

static void die_with_active_mapping(void)
{
    pex_handle_t handle;
    volatile unsigned char *mapping;

    if (pex_open(&handle) ||
        pex_create(&handle, "crash_cleanup", 4096, PEX_POLICY_OWNER_THREAD_ONLY))
        _exit(1);

    mapping = pex_map(&handle, 4096);
    if (!mapping || pex_enter(&handle)) {
        pex_close(&handle);
        _exit(1);
    }

    mapping[0] = 0x5a;
    kill(getpid(), SIGKILL);
    _exit(1);
}

static void split_then_destroy(void)
{
    pex_handle_t handle;
    volatile unsigned char *mapping;
    long page_size = sysconf(_SC_PAGESIZE);

    if (page_size <= 0 || pex_open(&handle) ||
        pex_create(&handle, "split_cleanup", 2 * (size_t)page_size,
                   PEX_POLICY_OWNER_THREAD_ONLY))
        _exit(1);

    mapping = pex_map(&handle, 2 * (size_t)page_size);
    if (!mapping ||
        mprotect((void *)(mapping + page_size), (size_t)page_size, PROT_READ) ||
        pex_enter(&handle)) {
        pex_close(&handle);
        _exit(1);
    }

    mapping[0] = 0x3c;
    (void)mapping[page_size];
    if (pex_exit(&handle) || pex_unmap(&handle) || pex_destroy(&handle)) {
        pex_close(&handle);
        _exit(1);
    }

    pex_close(&handle);
    _exit(0);
}

static int run_child(const char *name, void (*child_fn)(void), int expected_signal,
                     const struct pex_stats *baseline)
{
    pid_t child;
    int status;

    child = fork();
    if (child < 0) {
        perror("fork");
        return -1;
    }
    if (child == 0)
        child_fn();

    if (waitpid(child, &status, 0) < 0) {
        perror("waitpid");
        return -1;
    }
    if (expected_signal) {
        if (!WIFSIGNALED(status) || WTERMSIG(status) != expected_signal) {
            fprintf(stderr, "%s did not terminate with signal %d\n", name,
                    expected_signal);
            return -1;
        }
    } else if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "%s child failed with status %#x\n", name, status);
        return -1;
    }

    return expect_baseline(name, baseline);
}

int main(void)
{
    struct pex_stats baseline;

    if (read_stats(&baseline)) {
        fprintf(stderr, "unable to read initial PEX context counts\n");
        return 1;
    }

    if (run_child("fd-close cleanup", close_without_destroy, 0, &baseline) ||
        run_child("SIGKILL cleanup", die_with_active_mapping, SIGKILL, &baseline) ||
        run_child("split-VMA cleanup", split_then_destroy, 0, &baseline))
        return 1;

    return 0;
}
