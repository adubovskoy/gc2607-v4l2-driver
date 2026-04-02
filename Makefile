# SPDX-License-Identifier: GPL-2.0
#
# Makefile for GC2607 V4L2 driver (out-of-tree build)
#

# Module name
obj-m := gc2607.o

# Kernel headers directory (auto-detect running kernel)
KDIR ?= /lib/modules/$(shell uname -r)/build

# Build directory
PWD := $(shell pwd)

# Userspace ISP program
ISP_SRC := gc2607_isp.c
ISP_BIN := gc2607_isp
CC_USER ?= gcc
CFLAGS_USER ?= -O2 -Wall -Wextra -march=native

# Default target: build the module and ISP
all: modules isp

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

isp: $(ISP_BIN)

$(ISP_BIN): $(ISP_SRC)
	$(CC_USER) $(CFLAGS_USER) -o $@ $< -lm

# Install module to system
install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

# Clean build artifacts
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f Module.symvers modules.order $(ISP_BIN)

# Help target
help:
	@echo "GC2607 V4L2 Driver Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all      - Build kernel module and userspace ISP (default)"
	@echo "  modules  - Build only the gc2607.ko kernel module"
	@echo "  isp      - Build only the gc2607_isp userspace program"
	@echo "  install  - Build and install module to system (requires sudo)"
	@echo "  clean    - Remove all build artifacts"
	@echo "  help     - Show this help message"
	@echo ""
	@echo "Current kernel: $(shell uname -r)"
	@echo "Kernel headers: $(KDIR)"
	@echo ""
	@echo "Testing commands:"
	@echo "  sudo insmod gc2607.ko          - Load the driver"
	@echo "  dmesg | grep gc2607            - Check driver messages"
	@echo "  sudo rmmod gc2607              - Unload the driver"
	@echo "  lsmod | grep gc2607            - Check if module is loaded"

.PHONY: all modules isp install clean help
