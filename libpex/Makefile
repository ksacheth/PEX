CC ?= gcc
AR ?= ar
CFLAGS ?= -O2 -Wall -Wextra -Iinclude
PIC_CFLAGS := $(CFLAGS) -fPIC

LIB_STATIC = libpex.a
LIB_SHARED = libpex.so
OBJ = src/pex.o

all: $(LIB_STATIC) $(LIB_SHARED)

$(OBJ): src/pex.c include/pex.h include/pex_uapi.h
	$(CC) $(PIC_CFLAGS) -c -o $@ $<

$(LIB_STATIC): $(OBJ)
	$(AR) rcs $@ $^

$(LIB_SHARED): $(OBJ)
	$(CC) -shared -o $@ $^

clean:
	rm -f $(OBJ) $(LIB_STATIC) $(LIB_SHARED)
