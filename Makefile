CC = gcc
CFLAGS = -Wall -g -fPIC -Iinclude
LDFLAGS = -shared
LDLIBS = -ldl

all: libtee_sim.so samples/host

libtee_sim.so: src/libtee.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

samples/host: samples/host.c libtee_sim.so
	$(CC) -Wall -g -Iinclude -o $@ $< -L. -ltee_sim -Wl,-rpath=. -ldl
clean:
	rm -f libtee_sim.so samples/host

.PHONY: all clean
