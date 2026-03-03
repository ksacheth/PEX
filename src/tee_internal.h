#ifndef TEE_INTERNAL_H
#define TEE_INTERNAL_H

#include <stddef.h>

struct tee_enclave {
    void *dl_handle;           // from dlopen
    void (*entry)(void*);       // function pointer to enclave_main
    unsigned char hash[32];     // SHA-256 hash
};

#endif