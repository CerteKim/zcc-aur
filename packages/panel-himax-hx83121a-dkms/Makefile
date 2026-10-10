# SPDX-License-Identifier: GPL-2.0-only
#
# Himax HX83121A DSI panel driver - out-of-tree build.
#
# panel-himax-hx83121a.c here is a copy of
# drivers/gpu/drm/panel/panel-himax-hx83121a.c from CerteKim/linux-a51
# (the commit is recorded as _kcommit in PKGBUILD).  Everything it calls is
# exported to modules - drm_panel_of_backlight(), __devm_drm_panel_alloc(),
# the MIPI-DSI "..._multi" write helpers and drm_dsc_pps_payload_pack() - so
# no in-tree change is needed to build it here.  Do not add kernel-internal
# headers or non-exported symbols.  Verify by building out of tree:
#
#     make                                  # /lib/modules/$(uname -r)/build
#     make KDIR=/path/to/built/kernel/tree
#     make clean
#
# DKMS drives the same two commands through MAKE[0]/CLEAN in dkms.conf and
# expects the built panel-himax-hx83121a.ko in this directory.

ifneq ($(KERNELRELEASE),)
# Kbuild, included by the kernel's build system.
obj-m += panel-himax-hx83121a.o
else
KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
endif
