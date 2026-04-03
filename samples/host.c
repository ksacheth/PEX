#include "tee_sim.h"
#include "utils.h"
#include <stdio.h>
#include <stdint.h>

int main() {
    tee_enclave_t *enc = tee_create("./enclave.so");
    if (!enc) {
        printf("Failed to create enclave\n");
        return 1;
    }
    printf("Enclave created successfully. Hash: ");
    const unsigned char *hash = tee_get_hash(enc);
    if (hash) {
        hexdump(hash, 32);
    } else {
        printf("Hash not available\n");
    }

    int arg = 42;
    tee_enter(enc, &arg);

    tee_destroy(enc);

    return 0;
}