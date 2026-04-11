CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Ilibpex/include
LDFLAGS ?=
PYTHON ?= python3

.PHONY: all lib kernel examples tests demo clean load unload run-demo run-showcase run-tests run-e2e

all: lib examples tests demo

lib:
	$(MAKE) -C libpex

kernel:
	$(MAKE) -C kernel

examples: lib
	$(CC) $(CFLAGS) -o examples/protected_workload examples/protected_workload.c libpex/libpex.a $(LDFLAGS)
	$(CC) $(CFLAGS) -pthread -o examples/showcase_blocking examples/showcase_blocking.c libpex/libpex.a $(LDFLAGS)

tests: lib
	$(CC) $(CFLAGS) -pthread -o tests/test_multithread_violation tests/test_multithread_violation.c libpex/libpex.a $(LDFLAGS)
	$(CC) $(CFLAGS) -o tests/benchmark_entry_exit tests/benchmark_entry_exit.c libpex/libpex.a $(LDFLAGS)

demo: lib
	$(PYTHON) -m py_compile demo/pex_viewer.py

load: kernel
	sudo bash ./scripts/dev_setup.sh

unload:
	sudo rmmod pex || true

run-demo: all kernel
	bash ./scripts/run_demo.sh

run-showcase: examples kernel
	sudo bash ./scripts/dev_setup.sh
	./examples/showcase_blocking

run-tests: tests kernel
	sudo bash ./scripts/dev_setup.sh
	./tests/test_multithread_violation
	./tests/benchmark_entry_exit

run-e2e: all kernel
	bash ./scripts/run_all.sh

clean:
	$(MAKE) -C libpex clean
	$(MAKE) -C kernel clean
	rm -f examples/protected_workload
	rm -f examples/showcase_blocking
	rm -f tests/test_multithread_violation
	rm -f tests/benchmark_entry_exit
	find demo -name '__pycache__' -type d -prune -exec rm -rf {} +
