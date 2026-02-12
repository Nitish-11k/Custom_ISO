#!/bin/bash
#
# build_iso.sh — Build the Custom Python Dashboard ISO (fakeroot fix + Verification)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO_ROOT="$SCRIPT_DIR/iso_root"
OUTPUT_ISO="$SCRIPT_DIR/custom.iso"

echo "=== Building Custom Dashboard ISO ==="

# 1. Remaster Tiny Core
echo "[1/3] Running remaster_tc.sh (with fakeroot)..."
if command -v fakeroot >/dev/null; then
    fakeroot bash "$SCRIPT_DIR/remaster_tc.sh"
else
    echo "WARNING: fakeroot not found! Remaster might fail on /dev nodes."
    bash "$SCRIPT_DIR/remaster_tc.sh"
fi

# 2. Verify ISO tree and vital extensions
echo "[2/3] Verifying ISO tree..."
REQUIRED_FILES="
boot/vmlinuz64
boot/core_custom.gz
boot/grub/grub.cfg
cde/optional/gtk3.tcz
cde/optional/libwacom.tcz
cde/optional/Xorg-7.7.tcz
cde/onboot.lst
"

for f in $REQUIRED_FILES; do
    if [ ! -f "$ISO_ROOT/$f" ]; then
        echo "ERROR: Missing $f in iso_root!"
        ls -lh "$ISO_ROOT/cde/optional/" | head -5
        exit 1
    fi
done
echo "   Tree verification passed (gtk3, libwacom, Xorg present)."

# 3. Build the ISO with grub-mkrescue
echo "[3/3] Building ISO with grub-mkrescue..."
rm -f "$OUTPUT_ISO"
grub-mkrescue -o "$OUTPUT_ISO" "$ISO_ROOT" -- \
    -volid "CUSTOM_ISO" 2>&1 | tail -5

echo ""
echo "=== BUILD COMPLETE ==="
echo "ISO: $OUTPUT_ISO"
echo "Size: $(du -sh "$OUTPUT_ISO" | cut -f1)"
echo ""
echo "To test in QEMU:"
echo "  bash run_qemu.sh"
echo ""
