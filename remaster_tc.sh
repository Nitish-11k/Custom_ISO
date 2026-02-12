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
# Fix permissions for tc home (critical fix)
chown -R 1001:50 /home/tc
chmod -R u+rwX /home/tc

# Load all other extensions (as user tc)
echo "Loading extensions (as user tc)..." >> /tmp/tce.log
su - tc -c "tce-load -i /cde/optional/*.tcz" >> /tmp/tce.log 2>&1


# Start DBus (CRITICAL for Firefox speed)
[ -x /usr/local/etc/init.d/dbus ] && /usr/local/etc/init.d/dbus start

# Start networking (Robust for eth0, ens3, etc)
pkill -9 udhcpc 2>/dev/null
for iface in $(ls /sys/class/net | grep ^e); do
    echo "Starting DHCP on $iface..." >> /tmp/bootlog.txt
    ifconfig "$iface" up
    udhcpc -b -i "$iface" &
done
EOF
chmod +x "$WORK_DIR/opt/bootlocal.sh"

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
