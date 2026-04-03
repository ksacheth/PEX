CC = gcc
CFLAGS = -Wall -g -fPIC -Iinclude -I/opt/homebrew/opt/openssl@3/include
LDFLAGS = -shared
LDLIBS = -ldl -L/opt/homebrew/opt/openssl@3/lib

all: libtee_sim.so enclave.so samples/host

libtee_sim.so: src/libtee.c src/loader.c src/utils.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS) -lcrypto

enclave.so: samples/enclave.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

samples/host: samples/host.c libtee_sim.so
	$(CC) -Wall -g -Iinclude -Isrc -o $@ $< -L. -ltee_sim -Wl,-rpath,. -ldl
clean:
	rm -f libtee_sim.so enclave.so samples/host

.PHONY: all clean
