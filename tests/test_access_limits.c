#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../libpex/include/pex_uapi.h"

static int create_context(int fd, const char *name, size_t size)
{
    struct pex_create_req req;

    memset(&req, 0, sizeof(req));
    req.size = size;
    snprintf(req.name, sizeof(req.name), "%s", name);
    if (ioctl(fd, PEX_IOCTL_CREATE_CTX, &req) == 0)
        return 0;
    return -errno;
}

static int expect_quota_limit(const char *name, size_t size, unsigned int successes)
{
    int fd;
    unsigned int index;
    int rc;

    fd = open(PEX_DEVICE_PATH, O_RDWR);
    if (fd < 0) {
        perror("open(" PEX_DEVICE_PATH ")");
        return -1;
    }

    for (index = 0; index < successes; index++) {
        rc = create_context(fd, name, size);
        if (rc) {
            fprintf(stderr, "%s create %u failed: %d\n", name, index + 1, rc);
            close(fd);
            return -1;
        }
    }

    rc = create_context(fd, name, size);
    close(fd);
    if (rc != -EDQUOT) {
        fprintf(stderr, "%s expected -EDQUOT, got %d\n", name, rc);
        return -1;
    }

    printf("%s: %u creations allowed, next returned -EDQUOT\n", name, successes);
    return 0;
}

static int expect_unprivileged_open_denied(void)
{
    pid_t child;
    int status;

    child = fork();
    if (child < 0) {
        perror("fork");
        return -1;
    }
    if (child == 0) {
        int fd;

        if (setgroups(0, NULL) || setgid(65534) || setuid(65534))
            _exit(2);
        fd = open(PEX_DEVICE_PATH, O_RDWR);
        if (fd >= 0) {
            close(fd);
            _exit(1);
        }
        _exit(errno == EACCES || errno == EPERM ? 0 : 3);
    }

    if (waitpid(child, &status, 0) < 0) {
        perror("waitpid");
        return -1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "unprivileged child unexpectedly opened " PEX_DEVICE_PATH
                        " (status %#x)\n", status);
        return -1;
    }

    puts("unprivileged open: denied");
    return 0;
}

struct holder {
    pid_t pid;
    int release_fd;
};

static int start_holder(const char *name, size_t size, unsigned int contexts,
                        struct holder *holder)
{
    int ready_pipe[2];
    int release_pipe[2];
    pid_t child;
    char ready;

    if (pipe(ready_pipe) || pipe(release_pipe)) {
        perror("pipe");
        return -1;
    }

    child = fork();
    if (child < 0) {
        perror("fork");
        return -1;
    }
    if (child == 0) {
        int fd;
        unsigned int index;

        close(ready_pipe[0]);
        close(release_pipe[1]);
        fd = open(PEX_DEVICE_PATH, O_RDWR);
        if (fd < 0)
            _exit(2);
        for (index = 0; index < contexts; index++) {
            if (create_context(fd, name, size)) {
                close(fd);
                _exit(3);
            }
        }
        if (write(ready_pipe[1], "R", 1) != 1) {
            close(fd);
            _exit(4);
        }
        if (read(release_pipe[0], &ready, 1) != 1) {
            close(fd);
            _exit(5);
        }
        close(fd);
        _exit(0);
    }

    close(ready_pipe[1]);
    close(release_pipe[0]);
    if (read(ready_pipe[0], &ready, 1) != 1 || ready != 'R') {
        close(ready_pipe[0]);
        close(release_pipe[1]);
        return -1;
    }
    close(ready_pipe[0]);
    holder->pid = child;
    holder->release_fd = release_pipe[1];
    return 0;
}

static int release_holders(struct holder *holders, unsigned int count)
{
    unsigned int index;
    int failed = 0;

    for (index = 0; index < count; index++) {
        if (write(holders[index].release_fd, "X", 1) != 1)
            failed = 1;
        close(holders[index].release_fd);
    }
    for (index = 0; index < count; index++) {
        int status;

        if (waitpid(holders[index].pid, &status, 0) < 0 ||
            !WIFEXITED(status) || WEXITSTATUS(status) != 0)
            failed = 1;
    }

    return failed ? -1 : 0;
}

static int expect_global_quota(const char *name, size_t holder_size,
                               unsigned int holder_count,
                               unsigned int contexts_per_holder,
                               size_t recovery_size)
{
    struct holder holders[PEX_MAX_CONTEXTS_GLOBAL];
    unsigned int started = 0;
    int fd = -1;
    int rc;
    int attempt;

    for (started = 0; started < holder_count; started++) {
        if (start_holder(name, holder_size, contexts_per_holder,
                         &holders[started])) {
            fprintf(stderr, "%s holder %u failed\n", name, started + 1);
            goto out_release;
        }
    }

    fd = open(PEX_DEVICE_PATH, O_RDWR);
    if (fd < 0) {
        perror("open(" PEX_DEVICE_PATH ")");
        goto out_release;
    }
    rc = create_context(fd, name, recovery_size);
    close(fd);
    fd = -1;
    if (rc != -EDQUOT) {
        fprintf(stderr, "%s expected -EDQUOT, got %d\n", name, rc);
        goto out_release;
    }

    if (release_holders(holders, started)) {
        fprintf(stderr, "%s holders did not clean up\n", name);
        return -1;
    }
    started = 0;

    /* The last fd release can lag the holder's exit; retry briefly. */
    for (attempt = 0; attempt < 50; attempt++) {
        fd = open(PEX_DEVICE_PATH, O_RDWR);
        if (fd >= 0 && !create_context(fd, "quota_recovery", recovery_size)) {
            close(fd);
            printf("%s: global quota denied, then recovered after close\n", name);
            return 0;
        }
        if (fd >= 0)
            close(fd);
        usleep(10000);
    }

    fprintf(stderr, "%s quota did not recover after close\n", name);
    return -1;

out_release:
    if (fd >= 0)
        close(fd);
    if (started)
        release_holders(holders, started);
    return -1;
}

int main(void)
{
    const size_t page_size = (size_t)sysconf(_SC_PAGESIZE);

    if (geteuid() != 0) {
        fprintf(stderr, "run this test as root so it can verify unprivileged access\n");
        return 1;
    }
    if (page_size == 0) {
        fputs("unable to determine page size\n", stderr);
        return 1;
    }

    if (expect_unprivileged_open_denied() ||
        expect_quota_limit("context-count", page_size, PEX_MAX_CONTEXTS_PER_TGID) ||
        expect_quota_limit("byte-quota", PEX_MAX_BYTES_PER_TGID / 2, 2) ||
        expect_global_quota("global-context-count", page_size,
                            PEX_MAX_CONTEXTS_GLOBAL / PEX_MAX_CONTEXTS_PER_TGID,
                            PEX_MAX_CONTEXTS_PER_TGID, page_size) ||
        expect_global_quota("global-byte-quota", PEX_MAX_BYTES_PER_TGID,
                            PEX_MAX_BYTES_GLOBAL / PEX_MAX_BYTES_PER_TGID,
                            1, page_size))
        return 1;

    return 0;
}
