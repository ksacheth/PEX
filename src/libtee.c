#include "tee_sim.h"
#include "tee_internal.h"
#include <stdlib.h>
#include <dlfcn.h>


tee_enclave_t* load_enclave(const char *path);

tee_enclave_t* tee_create(const char *path) {
    return load_enclave(path);
}

int tee_enter(tee_enclave_t *enclave, void *args) {
    if (!enclave) return -1;
    enclave->entry(args);
    return 0;
}

void tee_exit(tee_enclave_t *enclave) {
    
}

void tee_destroy(tee_enclave_t *enclave) {
    if (!enclave) {
        return ;
    }

    if (enclave->dl_handle) {
        dlclose(enclave->dl_handle);
    }

    free(enclave);
}

const unsigned char* tee_get_hash(tee_enclave_t *enclave) {
    if (!enclave) return NULL;
    return enclave->hash;
}