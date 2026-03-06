#!/bin/bash
# Launch the Debian live ISO in QEMU — auto-detects KVM
#   -nic user    → user-mode networking
#   -vga std     → VBE graphics (best Xorg compat)
#   -boot order=d,strict=on → boot CD first

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-detect the ISO built by build_live.sh
ISO=$(find "$SCRIPT_DIR" -maxdepth 1 -name '*.iso' ! -name 'custom.iso' -type f | sort -t- -k2 -V | tail -1)

# Fallback to custom.iso if nothing else found
[[ -z "$ISO" ]] && ISO="$SCRIPT_DIR/custom.iso"

if [ ! -f "$ISO" ]; then
    echo "ERROR: No ISO found. Run: sudo bash build_live.sh"
    exit 1
fi

echo "Booting: $(basename "$ISO")  ($(du -sh "$ISO" | cut -f1))"

# Clear old serial log
> "$SCRIPT_DIR/serial.log"
echo "Serial log: $SCRIPT_DIR/serial.log (cleared)"

ACCEL=""
if [ -e /dev/kvm ] && [ -r /dev/kvm ]; then
    ACCEL="-enable-kvm -cpu host"
    echo "KVM: enabled"
else
    ACCEL="-cpu qemu64"
    echo "KVM: not available (using TCG)"
fi

# VGA mode: use -vga std for best Xorg compatibility
# Use -vga virtio for better performance once working
VGA="${QEMU_VGA:-std}"
echo "VGA: $VGA (set QEMU_VGA=virtio to change)"

exec qemu-system-x86_64 \
    -cdrom "$ISO" \
    -m 3072 \
    -vga "$VGA" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial file:"$SCRIPT_DIR/serial.log" \
    -boot order=d,strict=on \
    -nic user,model=e1000 \
    $ACCEL \
    "$@"