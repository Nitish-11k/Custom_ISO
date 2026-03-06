#!/bin/bash
#
# download_extensions.sh — Download all TCZ extensions with recursive dep resolution
#
set -euo pipefail

TCZ_DIR="/home/nickx/.gemini/antigravity/scratch/custom_iso/tc_extensions"
TCZ_URL="http://tinycorelinux.net/17.x/x86_64/tcz"
DOWNLOADED=""

download_tcz() {
    local ext="$1"
    
    # Skip if already downloaded
    if echo "$DOWNLOADED" | grep -qwF "$ext"; then
        return
    fi
    DOWNLOADED="$DOWNLOADED $ext"
    
    # Download the extension
    if [ ! -f "$TCZ_DIR/$ext" ]; then
        echo "  Downloading $ext..."
        wget -q -O "$TCZ_DIR/$ext" "$TCZ_URL/$ext" 2>/dev/null || {
            echo "  WARNING: Failed to download $ext"
            rm -f "$TCZ_DIR/$ext"
            return
        }
    else
        echo "  Already have $ext"
    fi
    
    # Download and resolve dependencies
    local depfile="$TCZ_DIR/${ext}.dep"
    wget -q -O "$depfile" "$TCZ_URL/${ext}.dep" 2>/dev/null || true
    
    if [ -f "$depfile" ] && [ -s "$depfile" ]; then
        # Check it's not an HTML 404 page
        if ! grep -q '<html>' "$depfile" 2>/dev/null; then
            while IFS= read -r dep; do
                dep=$(echo "$dep" | tr -d '\r' | xargs | sed 's/-KERNEL/-6.18.2-tinycore64/')
                if [ -n "$dep" ]; then
                    download_tcz "$dep"
                fi
            done < "$depfile"
        fi
    fi
}

echo "=== Downloading TCZ Extensions ==="
echo "Target dir: $TCZ_DIR"
echo ""

# Core extensions needed
for ext in \
    Xorg-7.7.tcz \
    openbox.tcz \
    xdotool.tcz \
    python3.14.tcz \
    tk8.6.tcz \
    aterm.tcz \
    xf86-input-evdev.tcz \
    pciutils.tcz \
    usbutils.tcz \
    xf86-video-fbdev.tcz \
    xf86-video-vesa.tcz \
    gtk3.tcz \
    libwacom.tcz \
    fuse.tcz \
    nss.tcz \
    libasound.tcz \
    at-spi2-core.tcz \
    libXss.tcz \
    libcups.tcz \
    libsecret.tcz \
    mesa.tcz \
    libEGL.tcz \
    libGL.tcz \
    libGLESv2.tcz \
    libcanberra.tcz \
    input-tablet-touchscreen-6.18.2-tinycore64.tcz \
    graphics-6.18.2-tinycore64.tcz \
    libinput.tcz \
    xf86-input-libinput.tcz \
    bash.tcz \
    xkeyboard-config.tcz \
    iw.tcz \
    wpa_supplicant-dbus.tcz \
    net-tools.tcz \
    wireless-6.18.2-tinycore64.tcz \
    firmware-iwlwifi.tcz \
    firmware-rtlwifi.tcz \
    firmware-atheros.tcz \
    firmware-broadcom_bcm43xx.tcz \
    firmware-broadcom_bnx2.tcz \
    firmware-broadcom_bnx2x.tcz \
    firmware-rtl_nic.tcz \
    rfkill.tcz \
    wifi.tcz \
    wireless_tools.tcz \
    ncursesw.tcz \
; do
    echo ">>> Resolving: $ext"
    download_tcz "$ext"
    echo ""
done

echo ""
echo "=== Download Complete ==="
echo "Total extensions: $(ls "$TCZ_DIR"/*.tcz 2>/dev/null | wc -l)"
echo "Total size: $(du -sh "$TCZ_DIR" | cut -f1)"
