#include <stdio.h>

void enclave_main(int *arg) {
    printf("Hello from enclave! arg = %d\n", *arg);
}