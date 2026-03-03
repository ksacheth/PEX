#include "utils.h"
#include <stdio.h>

void hexdump(const void *data, size_t len) {
    const unsigned char *p = data;
    for (size_t i = 0; i < len; i++) {
        printf("%02x ", p[i]);
        if ((i + 1) % 16 == 0)
            printf("\n");
    }
    printf("\n");
}