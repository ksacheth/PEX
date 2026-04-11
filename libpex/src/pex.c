#include "pex.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

int pex_open(pex_handle_t *h)
{
    if (!h)
        return -EINVAL;

    memset(h, 0, sizeof(*h));
    h->fd = -1;
    h->ctx_id = -1;
    h->mapped_addr = NULL;
    h->mapped_size = 0;

    h->fd = open(PEX_DEVICE_PATH, O_RDWR);
    if (h->fd < 0)
        return -errno;
    return 0;
}

void pex_close(pex_handle_t *h)
{
    if (!h)
        return;

    if (h->mapped_addr && h->mapped_size)
        munmap(h->mapped_addr, h->mapped_size);

    h->mapped_addr = NULL;
    h->mapped_size = 0;
    h->ctx_id = -1;

    if (h->fd >= 0)
        close(h->fd);
    h->fd = -1;
}

int pex_create(pex_handle_t *h, const char *name, size_t size, uint32_t policy_flags)
{
    struct pex_create_req req;

    if (!h || h->fd < 0)
        return -EINVAL;

    memset(&req, 0, sizeof(req));
    req.size = size;
    req.policy_flags = policy_flags;
    if (name)
        snprintf(req.name, sizeof(req.name), "%s", name);

    if (ioctl(h->fd, PEX_IOCTL_CREATE_CTX, &req) < 0)
        return -errno;

    h->ctx_id = req.out_ctx_id;
    return 0;
}

int pex_destroy(pex_handle_t *h)
{
    struct pex_ctx_req req;

    if (!h || h->fd < 0 || h->ctx_id <= 0)
        return -EINVAL;

    if (h->mapped_addr && h->mapped_size) {
        if (munmap(h->mapped_addr, h->mapped_size) < 0)
            return -errno;
        h->mapped_addr = NULL;
        h->mapped_size = 0;
    }

    req.ctx_id = h->ctx_id;
    req.reserved = 0;
    if (ioctl(h->fd, PEX_IOCTL_DESTROY_CTX, &req) < 0)
        return -errno;

    h->ctx_id = -1;
    return 0;
}

int pex_enter(const pex_handle_t *h)
{
    struct pex_ctx_req req;

    if (!h || h->fd < 0 || h->ctx_id <= 0)
        return -EINVAL;

    req.ctx_id = h->ctx_id;
    req.reserved = 0;
    if (ioctl(h->fd, PEX_IOCTL_ENTER_CTX, &req) < 0)
        return -errno;
    return 0;
}

int pex_exit(const pex_handle_t *h)
{
    struct pex_ctx_req req;

    if (!h || h->fd < 0 || h->ctx_id <= 0)
        return -EINVAL;

    req.ctx_id = h->ctx_id;
    req.reserved = 0;
    if (ioctl(h->fd, PEX_IOCTL_EXIT_CTX, &req) < 0)
        return -errno;
    return 0;
}

int pex_get_info(const pex_handle_t *h, struct pex_ctx_info *info)
{
    if (!h || h->fd < 0 || h->ctx_id <= 0 || !info)
        return -EINVAL;

    memset(info, 0, sizeof(*info));
    info->ctx_id = h->ctx_id;
    if (ioctl(h->fd, PEX_IOCTL_GET_CTX_INFO, info) < 0)
        return -errno;
    return 0;
}

void *pex_map(pex_handle_t *h, size_t size)
{
    long page_size;
    void *addr;
    off_t off;

    if (!h || h->fd < 0 || h->ctx_id <= 0 || size == 0)
        return NULL;
    if (h->mapped_addr)
        return h->mapped_addr;

    page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0 || (size % (size_t)page_size) != 0)
        return NULL;

    off = ((off_t)h->ctx_id) << 12;
    addr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, h->fd, off);
    if (addr == MAP_FAILED)
        return NULL;

    h->mapped_addr = addr;
    h->mapped_size = size;
    return addr;
}

int pex_unmap(pex_handle_t *h)
{
    if (!h)
        return -EINVAL;
    if (!h->mapped_addr || !h->mapped_size)
        return 0;
    if (munmap(h->mapped_addr, h->mapped_size) < 0)
        return -errno;

    h->mapped_addr = NULL;
    h->mapped_size = 0;
    return 0;
}
