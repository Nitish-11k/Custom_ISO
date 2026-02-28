#!/bin/bash
mkdir -p test_ext
cd test_ext
zcat ../iso_root/boot/core_custom.gz | sudo cpio -id > /dev/null 2>&1
sudo chroot . /sbin/ldconfig
sudo chroot . /bin/sh -c 'LD_LIBRARY_PATH=/usr/local/lib:/usr/lib:/lib ldd /opt/dsecure/app' || true
cd ..
sudo rm -rf test_ext
