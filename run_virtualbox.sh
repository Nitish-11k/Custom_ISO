#!/bin/bash
# run_virtualbox.sh - Automatically create and launch the custom ISO in VirtualBox
#
# Usage: ./run_virtualbox.sh [vm_name]

VM_NAME="${1:-DSecure_OS_Test}"
ISO_PATH="$(pwd)/custom.iso"

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
