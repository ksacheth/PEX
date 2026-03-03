#ifndef TEE_SIM_H
#define TEE_SIM_H

#include <stddef.h>

typedef struct tee_enclave tee_enclave_t;

// Create an enclave
tee_enclave_t* tee_create(const char *path);

// Enter the enclave 
int tee_enter(tee_enclave_t *enclave, void *args);

// Exit the enclave
void tee_exit(tee_enclave_t *enclave);

const unsigned char* tee_get_hash(tee_enclave_t *enclave);

#endif