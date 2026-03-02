#!/bin/bash
#
# download_extensions.sh — Download all TCZ extensions with recursive dep resolution
#
set -euo pipefail

TCZ_DIR="/home/nickx/.gemini/antigravity/scratch/custom_iso/tc_extensions"
TCZ_URL="http://distro.ibiblio.org/tinycorelinux/15.x/x86_64/tcz"
DOWNLOADED=""

download_tcz() {
    local ext="$1"
    
    # Skip if already downloaded
    if echo "$DOWNLOADED" | grep -qF "$ext"; then
        return
    fi
    DOWNLOADED="$DOWNLOADED $ext"
    
    # Check if download is needed and verify checksum if file exists
    local needs_download=0
    if [ ! -f "$TCZ_DIR/$ext" ]; then
        needs_download=1
    else
        wget -q -O "$TCZ_DIR/$ext.md5.txt" "$TCZ_URL/$ext.md5.txt" || true
        if [ -f "$TCZ_DIR/$ext.md5.txt" ] && ! grep -q '<html>' "$TCZ_DIR/$ext.md5.txt"; then
            (cd "$TCZ_DIR" && md5sum -c "$ext.md5.txt" >/dev/null 2>&1) || needs_download=1
        fi
    fi
    
    if [ $needs_download -eq 1 ]; then
        echo "  Downloading $ext and verifying checksum..."
        local retries=5
        local success=0
        for ((i=1; i<=retries; i++)); do
            wget -q -O "$TCZ_DIR/$ext" "$TCZ_URL/$ext" || true
            wget -q -O "$TCZ_DIR/$ext.md5.txt" "$TCZ_URL/$ext.md5.txt" || true
            
            if [ -f "$TCZ_DIR/$ext" ] && [ -f "$TCZ_DIR/$ext.md5.txt" ] && ! grep -q '<html>' "$TCZ_DIR/$ext.md5.txt"; then
                if (cd "$TCZ_DIR" && md5sum -c "$ext.md5.txt" >/dev/null 2>&1); then
                    success=1
                    break
                else
                    echo "  Checksum failed for $ext, retry $i..."
                fi
            elif [ -f "$TCZ_DIR/$ext" ]; then
                # No md5 available
                success=1
                break
            fi
            sleep 1
        done
        if [ $success -eq 0 ]; then
            echo "  WARNING: Failed to download $ext correctly after $retries retries!"
            rm -f "$TCZ_DIR/$ext"
            return
        fi
    else
        echo "  Already have valid $ext"
    fi
    
    # Download and resolve dependencies
    local depfile="$TCZ_DIR/${ext}.dep"
    wget -q -O "$depfile" "$TCZ_URL/${ext}.dep" 2>/dev/null || true
    
    if [ -f "$depfile" ] && [ -s "$depfile" ]; then
        # Check it's not an HTML 404 page
        if ! grep -q '<html>' "$depfile" 2>/dev/null; then
            while IFS= read -r dep; do
                dep=$(echo "$dep" | tr -d '\r' | xargs)
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
    xf86-input-libinput.tcz \
    xf86-input-vmmouse.tcz \
    libinput.tcz \
    mtdev.tcz \
    libevdev.tcz \
    libwacom.tcz \
    flwm.tcz \
    aterm.tcz \
    dbus.tcz \
    gtk3.tcz \
    webkitgtk-gtk3.tcz \
    libwebp1.tcz \
    pcre21042.tcz \
    libXss.tcz \
    xf86-video-fbdev.tcz \
    xf86-video-vesa.tcz \
    nss.tcz \
    nspr.tcz \
    graphics-6.6.8-tinycore64.tcz \
    libmanette.tcz \
    brotli.tcz \
    gcc_libs.tcz \
    libEGL.tcz \
    libGLESv2.tcz \
    util-linux.tcz \
    wifi.tcz \
    wireless-6.6.8-tinycore64.tcz \
    wireless_tools.tcz \
    wpa_supplicant-dbus.tcz \
    libiw.tcz \
    libnl.tcz \
    modemmanager.tcz \
    libmbim.tcz \
    libqmi.tcz \
    pciutils.tcz \
    xf86-input-evdev.tcz \
    xf86-input-synaptics.tcz \
    xf86-input-keyboard.tcz \
    xf86-input-mouse.tcz \
    libinput.tcz \
    openbox.tcz \
    xcursor-themes.tcz \
    input-tablet-touchscreen-6.6.8-tinycore64.tcz \
    xdotool.tcz \
; do
    echo ">>> Resolving: $ext"
    download_tcz "$ext"
    echo ""
done

echo ""
echo "=== Download Complete ==="
echo "Total extensions: $(ls "$TCZ_DIR"/*.tcz 2>/dev/null | wc -l)"
echo "Total size: $(du -sh "$TCZ_DIR" | cut -f1)"
