#include "tee_sim.h"
#include <stdio.h>

int main() {
    tee_enclave_t *enc = tee_create("enclave.so");
    if (!enc) {
        printf("Failed to create enclave\n");
        return 1;
    }
    printf("Enclave created successfully\n");
    return 0;
}