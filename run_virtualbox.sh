#!/bin/bash
# run_virtualbox.sh - Automatically create and launch the custom ISO in VirtualBox
#
# Usage: ./run_virtualbox.sh [vm_name]

VM_NAME="${1:-DSecure_OS_Test}"
ISO_PATH="$(pwd)/custom.iso"

# --- KVM Conflict Check ---
if lsmod | grep -q "kvm_intel" || lsmod | grep -q "kvm_amd"; then
    echo "!!! CONFLICT DETECTED: KVM is currently active !!!"
    echo "VirtualBox cannot run while QEMU/KVM is active."
    echo ""
    echo "To fix this, please run these commands:"
    echo "  1. Close QEMU if it's open"
    echo "  2. Run: sudo modprobe -r kvm_intel  (or kvm_amd)"
    echo "  3. Run: sudo modprobe -r kvm"
    echo ""
    read -p "Would you like me to try killing QEMU and unloading KVM for you? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Stopping QEMU..."
        pkill -f qemu-system-x86_64 || true
        echo "Unloading KVM modules..."
        sudo modprobe -r kvm_intel 2>/dev/null || sudo modprobe -r kvm_amd 2>/dev/null || true
        sudo modprobe -r kvm 2>/dev/null || true
    else
        echo "Continuing with VirtualBox might fail..."
    fi
fi
# --------------------------

if [ ! -f "$ISO_PATH" ]; then
    echo "ERROR: custom.iso not found! Run ./remaster_tc.sh first."
    exit 1
fi

echo "=== Creating VirtualBox VM: $VM_NAME ==="

# 1. Unregister existing VM if it exists
if vboxmanage list vms | grep -q "\"$VM_NAME\""; then
    echo "Removing existing VM..."
    vboxmanage unregistervm "$VM_NAME" --delete
fi

# 2. Create the VM
vboxmanage createvm --name "$VM_NAME" --ostype "Linux26_64" --register

# 3. Configure Hardware
echo "Configuring hardware (EFI, 2GB RAM, VMSVGA)..."
vboxmanage modifyvm "$VM_NAME" \
    --memory 2048 \
    --vram 128 \
    --firmware efi \
    --graphicscontroller vmsvga \
    --mouse usbtablet \
    --keyboard ps2 \
    --nic1 nat \
    --nictype1 82540EM \
    --boot1 dvd

# 4. Add Storage Controller
vboxmanage storagectl "$VM_NAME" --name "IDE Controller" --add ide

# 5. Attach the ISO
vboxmanage storageattach "$VM_NAME" \
    --storagectl "IDE Controller" \
    --port 0 --device 0 \
    --type dvddrive \
    --medium "$ISO_PATH"

# 6. Start the VM
echo "Launching VM..."
vboxmanage startvm "$VM_NAME" --type gui
