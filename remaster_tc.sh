#!/bin/sh
#
# remaster_tc.sh - Creates initramfs and prepares CDE folder for Tiny Core
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/tc_remaster_opt"
EXT_DIR="$SCRIPT_DIR/tc_extensions"
BASE_DIR="$SCRIPT_DIR/tc_base"
ISO_ROOT="$SCRIPT_DIR/iso_root_opt"

echo "=== Remastering Tiny Core Linux (CDE Mode) ==="

# 0. Cleanup legacy
sudo rm -rf "$ISO_ROOT" "$WORK_DIR"
mkdir -p "$ISO_ROOT/boot"

# 0.1 Copy GRUB and assets from existing iso_root (if available)
if [ -d "$SCRIPT_DIR/iso_root" ]; then
    echo "Migrating GRUB and assets from iso_root..."
    mkdir -p "$ISO_ROOT"
    cp -r "$SCRIPT_DIR/iso_root/boot/grub" "$ISO_ROOT/boot/" 2>/dev/null || true
    # Also verify background image
    [ -f "$ISO_ROOT/boot/grub/background.png" ] || cp "$SCRIPT_DIR/background.png" "$ISO_ROOT/boot/grub/background.png" 2>/dev/null || true
fi

# 1. Prepare CDE folder structure in iso_root
echo "[1/4] Setting up CDE extensions (Optimized)..."
mkdir -p "$ISO_ROOT/cde/optional"

# HARDWARE SUPPORT TOGGLE (1 = Include all WiFi/LAN firmware, 0 = Extreme Minimal)
INCLUDE_ALL_FIRMWARE=1

# EXCLUSION LIST: Saves ~150MB+ if firmware is excluded
# WE ARE NOW INCLUDING MESA AND LLVM as per diagnosis report (Required for WebKitGTK)
# REMOVED python3.14, tcl8.6, tk8.6, and spirv-tools from exclusion for Dashboard migration
EXCLUDE_PATTERN="none_to_exclude"

if [ "$INCLUDE_ALL_FIRMWARE" -eq 0 ]; then
    EXCLUDE_PATTERN="$EXCLUDE_PATTERN\|firmware-iwlwifi\|firmware-atheros\|firmware-broadcom\|firmware-rtlwifi\|firmware-rtl_nic"
fi

# Copy extensions and dep files, excluding the large ones
ls -1 "$EXT_DIR"/*.tcz | grep -v "$EXCLUDE_PATTERN" | while read -r ext; do
    cp "$ext" "$ISO_ROOT/cde/optional/"
    base=$(basename "$ext")
    [ -f "$EXT_DIR/$base.dep" ] && cp "$EXT_DIR/$base.dep" "$ISO_ROOT/cde/optional/" 2>/dev/null || true
done
find "$ISO_ROOT/cde" -type d -exec chmod 755 {} +
find "$ISO_ROOT/cde" -type f -exec chmod 644 {} +

# Create onboot.lst dynamically from the filtered list
echo "Generating onboot.lst..."
ls -1 "$ISO_ROOT/cde/optional"/*.tcz | xargs -n 1 basename > "$ISO_ROOT/cde/onboot.lst"

# 2. Unpack corepure64.gz
echo "[2/4] Unpacking primary rootfs..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
zcat "$BASE_DIR/corepure64.gz" | cpio -i -H newc -d 2>/dev/null

# 2.1 EMBED VITAL DRIVERS (Ensures hardware detection even if ISO mount fails)
echo "   Embedding network, graphics, and firmware..."
# Find all firmware and wireless/graphics cores
VITAL_EXTS=$(ls "$EXT_DIR"/firmware-*.tcz "$EXT_DIR"/wireless-*.tcz "$EXT_DIR"/graphics-*.tcz "$EXT_DIR"/alsa-modules-*.tcz "$EXT_DIR"/ca-certificates.tcz 2>/dev/null | xargs -n 1 basename)
for ext in $VITAL_EXTS; do
    if [ -f "$EXT_DIR/$ext" ]; then
        echo "     -> Unpacking $ext..."
        # Use -f to overwrite, and || true to skip corrupted ones without failing the build
        unsquashfs -f -d . "$EXT_DIR/$ext" >/dev/null 2>&1 || echo "        [!] Warning: $ext is corrupted or invalid, skipping."
    fi
done

# 2.2 Add Power/Audio Management Permissions for 'tc' user
mkdir -p "$WORK_DIR/etc/sudoers.d"
echo "tc ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/poweroff, /sbin/halt, /sbin/shutdown" > "$WORK_DIR/etc/sudoers.d/tc"
chmod 0440 "$WORK_DIR/etc/sudoers.d/tc"

# Create Sudo wrappers so app's 'reboot' call works automatically
mkdir -p "$WORK_DIR/usr/local/bin"
printf "#!/bin/sh\nsudo /sbin/reboot\n" > "$WORK_DIR/usr/local/bin/reboot"
printf "#!/bin/sh\nsudo /sbin/poweroff\n" > "$WORK_DIR/usr/local/bin/poweroff"
chmod +x "$WORK_DIR/usr/local/bin/reboot" "$WORK_DIR/usr/local/bin/poweroff"

# Hardware group association
sed -i 's/staff:x:50:tc/staff:x:50:tc,video,audio,input/g' "$WORK_DIR/etc/group"

# 2.2 Add lib64 symlinks for binary compatibility
ln -s lib "$WORK_DIR/lib64" 2>/dev/null || true
mkdir -p "$WORK_DIR/usr"
ln -s lib "$WORK_DIR/usr/lib64" 2>/dev/null || true

# 2.2 Inject Framebuffer Splash at the very start of boot (before init text)
echo "Injecting early splash into /init..."
sed -i 's|^#!/bin/sh|#!/bin/sh\n/opt/fb_splash.sh \&|' "$WORK_DIR/init"

# 3. Configure Autostart
echo "[3/4] Configuring autostart..."

# Create graphical startup script
# FIX: Ensure /home/tc permissions are correct at runtime
cat > "$WORK_DIR/opt/bootlocal.sh" <<EOF
#!/bin/sh

# 0. Launch Framebuffer Splash IMMEDIATELY (hides kernel text)
echo "Launching FB splash..." >> /tmp/bootlog.txt
/opt/fb_splash.sh &
FB_SPLASH_PID=\$!
echo "FB Splash PID: \$FB_SPLASH_PID" >> /tmp/bootlog.txt

# Also hide cursor and clear console
printf '\033[?25l' > /dev/tty1 2>/dev/null || true
printf '\033[2J\033[H' > /dev/tty1 2>/dev/null || true

# 1. Hardware discovery and module loading (Laptop Touchpad Fix)
echo "Forcing hardware discovery..." >> /tmp/bootlog.txt
/sbin/udevadm trigger
/sbin/udevadm settle --timeout=10

# Force load HID and I2C modules just in case (Critical for touchpads)
modprobe i2c-hid-acpi 2>/dev/null || true
modprobe hid-multitouch 2>/dev/null || true
modprobe hid-generic 2>/dev/null || true
modprobe evdev 2>/dev/null || true

# 2. Fix permissions for input nodes and home
echo "Setting permissions..." >> /tmp/bootlog.txt
chmod 666 /dev/input/event* 2>/dev/null || true
chown -R 1001:50 /home/tc
chmod -R u+rwX /home/tc

# Load specific vital extensions if not already loaded (Safe guard)
# Note: Tiny Core usually loads onboot.lst automatically via 'cde' boot param
[ ! -f /usr/local/bin/Xorg ] && su - tc -c "tce-load -i Xorg-7.7" >> /tmp/tce.log 2>&1

# 3. Start DBus
[ -x /usr/local/etc/init.d/dbus ] && /usr/local/etc/init.d/dbus start

# 4. Start networking (Robust for eth0, ens3, etc)
pkill -9 udhcpc 2>/dev/null
for iface in \$(ls /sys/class/net | grep ^e); do
    echo "Starting DHCP on \$iface..." >> /tmp/bootlog.txt
    ifconfig "\$iface" up
    udhcpc -b -i "\$iface" &
done

# --- AUTO LOG COLLECTOR (FIX FOR USB BOOT DEBUGGING) ---
# This background task waits for the system to boot, then bundles logs
# and saves them to the USB drive (where /cde is).
(
    echo "Starting Auto-Log Collector in 60s..." >> /tmp/bootlog.txt
    sleep 60
    LOG_BUNDLE="/tmp/debug_logs_\$(date +%Y%m%d_%H%M%S)"
    mkdir -p "\$LOG_BUNDLE"
    dmesg > "\$LOG_BUNDLE/dmesg.txt"
    lspci -vv > "\$LOG_BUNDLE/lspci.txt" 2>&1
    lsusb -vv > "\$LOG_BUNDLE/lsusb.txt" 2>&1
    cp /var/log/Xorg.0.log "\$LOG_BUNDLE/" 2>/dev/null
    cp /tmp/tce.log "\$LOG_BUNDLE/" 2>/dev/null
    cp /tmp/xsession-errors "\$LOG_BUNDLE/" 2>/dev/null
    
    # Identify USB boot media (look for /cde mount)
    USB_PATH=\$(mount | grep 'on /cde' | awk '{print \$3}')
    [ -z "\$USB_PATH" ] && USB_PATH=\$(mount | grep '/mnt/sd' | head -n1 | awk '{print \$3}')
    
    if [ -n "\$USB_PATH" ] && [ -d "\$USB_PATH" ]; then
        tar -czf "\$USB_PATH/debug_bundle_\$(hostname)_\$(date +%H%M%S).tar.gz" -C /tmp "\$(basename "\$LOG_BUNDLE")"
        echo "Logs saved to \$USB_PATH" >> /tmp/bootlog.txt
    else
        echo "Could not find USB path to save logs!" >> /tmp/bootlog.txt
    fi
) &
EOF
chmod +x "$WORK_DIR/opt/bootlocal.sh"

# 3.1 Force libinput for all pointers and keyboards (Laptop fix)
mkdir -p "$WORK_DIR/usr/local/share/X11/xorg.conf.d"
cat > "$WORK_DIR/usr/local/share/X11/xorg.conf.d/10-input.conf" <<EOF
Section "InputClass"
    Identifier "libinput pointer catchall"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "libinput keyboard catchall"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "libinput touchpad catchall"
    MatchIsTouchpad "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
    Option "Tapping" "on"
EndSection
EOF

# Create Openbox config to force maximization and remove decorations (Kiosk Mode)
echo "Configuring Openbox Kiosk Mode..."
mkdir -p "$WORK_DIR/home/tc/.config/openbox"
cat > "$WORK_DIR/home/tc/.config/openbox/rc.xml" << 'OB_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application name="*">
      <decor>no</decor>
      <maximized>yes</maximized>
      <fullscreen>yes</fullscreen>
    </application>
  </applications>
  <keyboard>
    <keybind key="A-F4"><action name="Close"/></keybind>
  </keyboard>
</openbox_config>
OB_EOF
chown -R 1001:50 "$WORK_DIR/home/tc/.config"

# Create .xsession for the 'tc' user
mkdir -p "$WORK_DIR/home/tc"
cat > "$WORK_DIR/home/tc/.xsession" << 'EOF'
#!/bin/sh
# Load X environment
. /etc/init.d/tc-functions

# === Environment Setup ===
export DISPLAY=:0
export XAUTHORITY=/home/tc/.Xauthority
export GDK_BACKEND=x11
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export LD_LIBRARY_PATH="/opt/libs_private:$LD_LIBRARY_PATH"

# Prevent double-execution
if [ -f /tmp/.xsession_started ]; then
    exit 0
fi
touch /tmp/.xsession_started

# Wait for X server socket to be ready
echo "[XSESSION] Waiting for X server..." > /dev/ttyS0
for i in $(seq 1 10); do
    [ -S /tmp/.X11-unix/X0 ] && break
    sleep 0.5
done

# Kill framebuffer splash now that X is taking over
killall fb_splash.sh 2>/dev/null || true

# Set X background to our brand color immediately + hide cursor
xsetroot -solid '#030d2b'
xsetroot -cursor_name left_ptr
xset s off 2>/dev/null
xset -dpms 2>/dev/null
xset s noblank 2>/dev/null

# Start window manager (Openbox)
echo "[XSESSION] Starting Openbox..." > /dev/ttyS0
openbox-session &
sleep 1

# Environment setup for Tauri / WebKitGTK (Maximum Compatibility Mode)
export GDK_BACKEND=x11
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export WEBKIT_DISABLE_GPU_PROCESS=1
export LIBGL_ALWAYS_SOFTWARE=1
export DISPLAY=:0
export XAUTHORITY=/home/tc/.Xauthority
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket

# Launch App.AppImage (Tauri/React Kiosk)
echo "[XSESSION] Launching App.AppImage (Logging to app.log)..." > /dev/ttyS0
# Redirect to a file so the user can 'cat' it from the fallback terminal
/opt/App.AppImage --no-sandbox > /home/tc/app.log 2>&1 &
APP_PID=$!

# Watchdog / Wait for kiosk window
(
    WID=""
    for i in $(seq 1 30); do
        # Search for any window (Tauri apps usually have a generic name initially)
        WID=$(xdotool search --all --name ".*" 2>/dev/null | tail -n 1)
        if [ -n "$WID" ]; then
            echo "[BOOT] Kiosk window found (WID: $WID), focusing..." > /dev/ttyS0
            xdotool windowactivate "$WID" 2>/dev/null || true
            xdotool windowraise "$WID" 2>/dev/null || true
            break
        fi
        sleep 1
    done
) &

# Keep session alive by waiting for the AppImage process
wait $APP_PID 2>/dev/null

# If app exits, start a terminal so user isn't stranded
aterm &
wait
EOF
chmod +x "$WORK_DIR/home/tc/.xsession"

# 3.2 Ensure Autostart into X
cat > "$WORK_DIR/home/tc/.profile" << 'EOF'
if [ -z "$DISPLAY" ] && [ $(tty) = /dev/tty1 ]; then
    startx
fi
EOF
chown 1001:50 "$WORK_DIR/home/tc/.profile"

# Copy binary App.AppImage to /opt
cp "$SCRIPT_DIR/app_bin/App.AppImage" "$WORK_DIR/opt/App.AppImage"
chmod +x "$WORK_DIR/opt/App.AppImage"

# Copy the Python Dashboard
cp "$SCRIPT_DIR/dashboard.py" "$WORK_DIR/opt/dashboard.py"
chmod +x "$WORK_DIR/opt/dashboard.py"

# Copy Splash Screen dependencies
cp "$SCRIPT_DIR/app_bin/splash_minimal.sh" "$WORK_DIR/opt/splash_minimal.sh"
cp "$SCRIPT_DIR/app_bin/fb_splash.sh" "$WORK_DIR/opt/fb_splash.sh"
chmod +x "$WORK_DIR/opt/splash_minimal.sh"
chmod +x "$WORK_DIR/opt/fb_splash.sh"

# Custom boot message
sed -i 's/Tiny Core Linux/Custom ISO with Dashboard/g' "$WORK_DIR/etc/init.d/rcS" 2>/dev/null || true

# 5. BOOTLOADER GENERATION (GRUB BIOS + UEFI)
echo "[5/5] Generating bootloaders..."

# Update grub.cfg to match TinyCore kernel/initrd names
cat > "$ISO_ROOT/boot/grub/grub.cfg" << GCFG
set timeout=20
set default=0

insmod all_video
insmod gfxterm
insmod png
insmod font

set gfxmode=1024x768x32,800x600x32,auto
terminal_output gfxterm

# Use label-based search for TC
search --no-floppy --set=root --file /boot/vmlinuz64
set prefix=(\$root)/boot/grub

# Set desktop image variable (needed for theme.txt)
set desktop_image="/boot/grub/background.png"

# Load labels/themes
if [ -f (\$root)/boot/grub/themes/custom/theme.txt ]; then
    [ -f (\$root)/boot/grub/themes/custom/font.pf2 ] && loadfont (\$root)/boot/grub/themes/custom/font.pf2
    set theme=(\$root)/boot/grub/themes/custom/theme.txt
else
    [ -f (\$root)/boot/grub/background.png ] && background_image (\$root)/boot/grub/background.png
fi

menuentry "D-Secure Drive Eraser" {
    echo "Loading D-Secure (Tiny Core Edition)..."
    linux /boot/vmlinuz64 quiet loglevel=0 cde waitusb=20 vt.global_cursor_default=0 vga=791
    initrd /boot/core_custom.gz /boot/modules64.gz
}

menuentry "Reboot" {
    reboot
}
GCFG

# BIOS Image (Safe size)
mkdir -p "$ISO_ROOT/boot/grub/i386-pc"
grub-mkstandalone \
    --format=i386-pc \
    --output="$ISO_ROOT/boot/grub/core.img" \
    --install-modules="linux normal iso9660 biosdisk search all_video gfxterm png font" \
    --modules="linux normal iso9660 biosdisk search all_video gfxterm png font" \
    "boot/grub/grub.cfg=$ISO_ROOT/boot/grub/grub.cfg"

cat /usr/lib/grub/i386-pc/cdboot.img "$ISO_ROOT/boot/grub/core.img" > "$ISO_ROOT/boot/grub/bios.img"

# UEFI Image (Embedded assets)
mkdir -p "$ISO_ROOT/EFI/BOOT"
grub-mkstandalone \
    --format=x86_64-efi \
    --output="$ISO_ROOT/EFI/BOOT/BOOTx64.EFI" \
    --install-modules="linux normal iso9660 efi_gop efi_uga all_video search gfxterm png font" \
    "boot/grub/grub.cfg=$ISO_ROOT/boot/grub/grub.cfg" \
    "boot/grub/background.png=$ISO_ROOT/boot/grub/background.png" \
    "boot/grub/themes/custom=$ISO_ROOT/boot/grub/themes/custom"

# FAT EFI image for xorriso
EFI_IMG="$ISO_ROOT/boot/grub/efi.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=4 status=none
mkfs.fat -F 12 -n "EFI" "$EFI_IMG" &>/dev/null
mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$ISO_ROOT/EFI/BOOT/BOOTx64.EFI" ::/EFI/BOOT/

# 6. BUILD FINAL ISO
echo "Building final ISO..."
ISO_OUT="$SCRIPT_DIR/d-secure-tc-$(date +%Y%m%d).iso"
xorriso -as mkisofs \
    -iso-level 3 \
    -volid "DSECURE_TC" \
    -eltorito-boot boot/grub/bios.img \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
        -e boot/grub/efi.img -no-emul-boot \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohybrid.bin -isohybrid-gpt-basdat \
    -o "$ISO_OUT" \
    "$ISO_ROOT"

echo "=== Remaster Complete: $ISO_OUT ==="
