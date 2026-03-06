#!/bin/sh
#
# remaster_tc.sh - Creates initramfs and prepares CDE folder for Tiny Core
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/tc_remaster"
EXT_DIR="$SCRIPT_DIR/tc_extensions"
BASE_DIR="$SCRIPT_DIR/tc_base"
ISO_ROOT="$SCRIPT_DIR/iso_root"

echo "=== Remastering Tiny Core Linux (CDE Mode) ==="

# 0. Cleanup legacy
rm -rf "$ISO_ROOT/isolinux"
rm -rf "$ISO_ROOT/cde"
mkdir -p "$ISO_ROOT/boot"

# 1. Prepare CDE folder structure in iso_root
echo "[1/4] Setting up CDE extensions..."
mkdir -p "$ISO_ROOT/cde/optional"
# Copy extensions and dep files
cp "$EXT_DIR"/*.tcz "$ISO_ROOT/cde/optional/"
cp "$EXT_DIR"/*.tcz.dep "$ISO_ROOT/cde/optional/" 2>/dev/null || true
chmod -R 755 "$ISO_ROOT/cde"

# Create onboot.lst dynamically
echo "Generating onboot.lst..."
ls -1 "$EXT_DIR"/*.tcz | xargs -n 1 basename > "$ISO_ROOT/cde/onboot.lst"

# 2. Unpack corepure64.gz to add startup scripts
echo "[2/4] Unpacking corepure64.gz..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
zcat "$BASE_DIR/corepure64.gz" | cpio -i -H newc -d 2>/dev/null

# 3. Configure Autostart
echo "[3/4] Configuring autostart..."

# Create graphical startup script
# FIX: Ensure /home/tc permissions are correct at runtime
cat > "$WORK_DIR/opt/bootlocal.sh" <<EOF
#!/bin/sh

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

# Create .xsession for the 'tc' user
mkdir -p "$WORK_DIR/home/tc"
cat > "$WORK_DIR/home/tc/.xsession" <<EOF
#!/bin/sh
# Load X environment
. /etc/init.d/tc-functions

# FIX: Force X cursor to be visible and defined
xsetroot -cursor_name left_ptr &

# Start window manager
flwm &

# Wait for X to settle
sleep 3

# Launch Dashboard
python3.9 /opt/dashboard.py &

# Fallback terminal
aterm &
EOF
chmod +x "$WORK_DIR/home/tc/.xsession"

# Copy dashboard app to /opt
cp "$SCRIPT_DIR/dashboard.py" "$WORK_DIR/opt/dashboard.py"
chmod +x "$WORK_DIR/opt/dashboard.py"

# Custom boot message
sed -i 's/Tiny Core Linux/Custom ISO with Dashboard/g' "$WORK_DIR/etc/init.d/rcS" 2>/dev/null || true

# 4. Repack into core_custom.gz
echo "[4/4] Repacking minimal initramfs..."

# FIX: Set ownership explicitly using fakeroot context
chown -R 0:0 .
chown -R 1001:50 home/tc

# Repack
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$ISO_ROOT/boot/core_custom.gz"

# Copy kernel (ensure fresh copy)
cp "$BASE_DIR/vmlinuz64" "$ISO_ROOT/boot/vmlinuz64"
cp "$BASE_DIR/modules64.gz" "$ISO_ROOT/boot/modules64.gz"

echo "Remaster complete: core_custom.gz ready"
