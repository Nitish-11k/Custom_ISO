#!/bin/bash
# Launch the kernel and initrd directly using QEMU to get verbose serial logs

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$SCRIPT_DIR/iso_root/boot/vmlinuz64"
INITRD="$SCRIPT_DIR/iso_root/boot/core_custom.gz"
MODULES="$SCRIPT_DIR/iso_root/boot/modules64.gz"
ISO="$SCRIPT_DIR/custom.iso"

if [ ! -f "$ISO" ]; then
    echo "ERROR: $ISO not found. Run build_iso.sh first."
    exit 1
fi

echo "Starting QEMU with serial console logging..."
echo "Logs will be written to qemu_debug.log"

exec qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRD,$MODULES" \
    -append "loglevel=7 debug earlyprintk=ttyS0 console=ttyS0 console=tty0 cde showapps" \
    -cdrom "$ISO" \
    -m 2048 \
    -vga std \
    -boot order=d,strict=on \
    -nic user,model=virtio-net-pci \
    -usb -device usb-tablet \
    -enable-kvm \
    -cpu host \
    -serial file:qemu_debug.log \
    "$@"
