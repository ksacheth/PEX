#include "tee_sim.h"
#include "tee_internal.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <openssl/evp.h>

tee_enclave_t* load_enclave(const char *path) {
    // Allocate memory for the enclave structure
    tee_enclave_t *enc = malloc(sizeof(tee_enclave_t));
    if (!enc) {
        perror("malloc");
        return NULL;
    }

    // Load the shared object using dlopen
    enc->dl_handle = dlopen(path, RTLD_LAZY);
    if (!enc->dl_handle) {
        fprintf(stderr, "dlopen error: %s\n", dlerror());
        free(enc);
        return NULL;
    }

    // Find the entry point function "enclave_main"
    enc->entry = (void(*)(void*)) dlsym(enc->dl_handle, "enclave_main");
    if (!enc->entry) {
        fprintf(stderr, "dlsym error: %s\n", dlerror());
        dlclose(enc->dl_handle);
        free(enc);
        return NULL;
    }

    // Compute SHA-256 hash of the enclave file
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror("fopen");
        dlclose(enc->dl_handle);
        free(enc);
        return NULL;
    }

    // Get file size
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);

    // Allocate buffer to hold the whole file
    unsigned char *buffer = malloc(fsize);
    if (!buffer) {
        perror("malloc");
        fclose(f);
        dlclose(enc->dl_handle);
        free(enc);
        return NULL;
    }

    // Read the file into buffer
    size_t read_len = fread(buffer, 1, fsize, f);
    if (read_len != (size_t)fsize) {
        fprintf(stderr, "fread error: short read\n");
        fclose(f);
        free(buffer);
        dlclose(enc->dl_handle);
        free(enc);
        return NULL;
    }
    fclose(f);

    // Compute SHA-256 using OpenSSL EVP interface
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
    EVP_DigestUpdate(ctx, buffer, fsize);
    EVP_DigestFinal_ex(ctx, enc->hash, NULL);
    EVP_MD_CTX_free(ctx);

    free(buffer);
    return enc;
}