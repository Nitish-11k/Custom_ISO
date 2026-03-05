#!/bin/bash
# Launch the custom ISO in QEMU — fast boot + network
#   -enable-kvm  → hardware acceleration
#   -nic user    → user-mode networking (for Firefox)
#   -vga std     → VBE graphics
#   -boot order=d,strict=on → boot CD first, skip iPXE delay

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO="$SCRIPT_DIR/custom.iso"

if [ ! -f "$ISO" ]; then
    echo "ERROR: $ISO not found. Run build_iso.sh first."
    exit 1
fi

# --- KVM Check ---
if ! lsmod | grep -q "kvm"; then
    echo "KVM module not detected. Attempting to load..."
    sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    if ! lsmod | grep -q "kvm"; then
        echo "WARNING: Failed to load KVM. QEMU might be slow!"
    fi
fi
# -----------------

exec qemu-system-x86_64 \
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
