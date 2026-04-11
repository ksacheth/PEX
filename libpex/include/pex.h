#ifndef PEX_H
#define PEX_H

#include <stddef.h>
#include <stdint.h>

#include "pex_uapi.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pex_handle {
    int fd;
    int ctx_id;
    void *mapped_addr;
    size_t mapped_size;
} pex_handle_t;

int pex_open(pex_handle_t *h);
void pex_close(pex_handle_t *h);

int pex_create(pex_handle_t *h, const char *name, size_t size, uint32_t policy_flags);
int pex_destroy(pex_handle_t *h);
int pex_enter(const pex_handle_t *h);
int pex_exit(const pex_handle_t *h);
int pex_get_info(const pex_handle_t *h, struct pex_ctx_info *info);
void *pex_map(pex_handle_t *h, size_t size);
int pex_unmap(pex_handle_t *h);

#ifdef __cplusplus
}
#endif

#endif
