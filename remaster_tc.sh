#!/bin/sh
#
# remaster_tc.sh - D-Secure Edition (DIRECT MOUNT STRATEGY)
#
# Optimized for speed (< 30s boot) and reliability.
# Bypasses Tiny Core auto-detection bugs for Xorg and input devices.
# Supports QEMU, VirtualBox, and Real Hardware.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Use a unique work dir to avoid permission issues with previous runs
WORK_DIR="$SCRIPT_DIR/tc_work_$(date +%s)"
EXT_DIR="$SCRIPT_DIR/tc_extensions"
BASE_DIR="$SCRIPT_DIR/tc_base"
ISO_ROOT="$SCRIPT_DIR/iso_root"

echo "=== Remastering Tiny Core Linux (D-Secure Edition) ==="

# 1. Cleanup old ISO files (not the work dir yet)
rm -f "$ISO_ROOT/boot/core_custom.gz"
mkdir -p "$ISO_ROOT/boot"

# 2. Unpack base
echo "[1/4] Unpacking base system..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
zcat "$BASE_DIR/corepure64.gz" | cpio -i -H newc -d

# 3. Extract ALL extensions into the rootfs (The "Direct Mount" Fix)
echo "[2/4] Pre-extracting extensions..."
for ext in "$EXT_DIR"/*.tcz; do
    [ -s "$ext" ] && unsquashfs -f -d "$WORK_DIR" "$ext" >/dev/null 2>&1 || true
done

# Run ldconfig to fix library cache
echo "Running ldconfig in rootfs..."
ldconfig -r "$WORK_DIR" 2>/dev/null || true

# 4. Branding & UI Setup
echo "[3/4] Configuring UI and Autostart..."
cd "$WORK_DIR"

# Install tiny_splash
if [ -f "$SCRIPT_DIR/tiny_splash" ]; then
    cp "$SCRIPT_DIR/tiny_splash" "sbin/tiny_splash"
    chmod +x "sbin/tiny_splash"
fi
[ -f "$SCRIPT_DIR/splash_0.raw" ] && cp "$SCRIPT_DIR/splash_0.raw" . 2>/dev/null || true

# Direct login on TTY1
sed -i 's|tty1::respawn:/sbin/getty.*|tty1::once:/bin/login -f tc </dev/tty1 >/dev/tty1 2>\&1|' etc/inittab

# Xorg config bypass
echo "Xorg" > etc/sysconfig/Xserver
chmod 4755 usr/local/lib/xorg/Xorg 2>/dev/null || true
mkdir -p etc/X11
echo "allowed_users=anybody\nneeds_root_rights=yes" > etc/X11/Xwrapper.config

# Udev rules for hardware (Display, Input, Disks)
cat > etc/udev/rules.d/99-dsecure.rules << 'UDEV_EOF'
KERNEL=="console", MODE="0666"
KERNEL=="fb0", MODE="0666"
KERNEL=="tty[0-9]*", MODE="0666"
KERNEL=="event*", MODE="0666"
KERNEL=="mouse*", MODE="0666"
KERNEL=="uinput", MODE="0666"
KERNEL=="sd[a-z]*|nvme*", MODE="0666", GROUP="disk"
SUBSYSTEM=="input", MODE="0666"
SUBSYSTEM=="usb", MODE="0666"
SUBSYSTEM=="drm", MODE="0666"
SUBSYSTEM=="graphics", MODE="0666"
UDEV_EOF

# Openbox config (Perfect Fullscreen, No flickering margins/dots)
mkdir -p home/tc/.config/openbox
cat > home/tc/.config/openbox/rc.xml << 'OPENBOX_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme>
    <keepBorder>no</keepBorder>
  </theme>
  <margins>
    <top>0</top><bottom>0</bottom><left>0</left><right>0</right>
  </margins>
  <dock>
    <position>BottomRight</position>
    <autoHide>yes</autoHide>
    <hideDelay>10</hideDelay>
    <showDelay>10000</showDelay>
  </dock>
  <applications>
    <application name="*" class="*">
      <maximized>true</maximized>
      <decor>no</decor>
      <fullscreen>true</fullscreen>
      <border>no</border>
    </application>
  </applications>
</openbox_config>
OPENBOX_EOF

# .xsession — GUI Client Sequence
cat > home/tc/.xsession << 'XSESSION_EOF'
#!/bin/sh
# REDIRECT ALL LOGS
exec 2>&1 | tee /tmp/xsession.log

export HOME=/home/tc
export USER=tc
export DISPLAY=:0
export XDG_RUNTIME_DIR=/tmp/runtime-tc

# WebKit/Tauri compatibility flags
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_SANDBOX=1
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11

# WAIT FOR X SERVER (Improved)
echo "[GUI] Waiting for X server on $DISPLAY..." | tee /dev/console
RETRY=0
while [ $RETRY -lt 20 ]; do
    if xset q >/dev/null 2>&1; then
        echo "[GUI] X server detected!" | tee /dev/console
        break
    fi
    RETRY=$((RETRY+1))
    sleep 0.5
done

# Launch Window Manager
echo "[GUI] Starting Openbox..." | tee /dev/console
openbox --config-file $HOME/.config/openbox/rc.xml &
sleep 2

# Background and cleanup
xsetroot -cursor_name left_ptr -solid "#ffffff" || true
sudo pkill -TERM tiny_splash 2>/dev/null || true

APP_BIN="/opt/d-secure-ui/app"
LIB_PATH="/opt/d-secure-ui/lib"
SYSTEM_LIBS="/usr/local/lib:/usr/lib:/lib"
LOADER="$LIB_PATH/ld-linux-x86-64.so.2"

if [ -f "$APP_BIN" ]; then
    echo "[GUI] Launching D-Secure Dashboard..." | tee /dev/console
    cd /opt/d-secure-ui
    # Use bundled loader + combined library path (Bundle + System)
    if [ -f "$LOADER" ]; then
        dbus-run-session "$LOADER" --library-path "$LIB_PATH:$SYSTEM_LIBS" "$APP_BIN" 2>&1 | tee /tmp/app.log || {
            echo "[ERROR] App crashed. Logs below:" | tee /dev/console
            aterm -title "DEBUG: App Error" -e /bin/sh -c "cat /tmp/app.log; exec /bin/sh"
        }
    else
        dbus-run-session "$APP_BIN" 2>&1 | tee /tmp/app.log || aterm -title "ERROR" -e "cat /tmp/app.log; exec sh"
    fi
else
    echo "[ERROR] Dashboard binary missing at $APP_BIN" | tee /dev/console
    aterm -title "ERROR: Missing Binary"
fi
XSESSION_EOF
chmod +x home/tc/.xsession

# .profile — Autostart sequence
cat > home/tc/.profile << 'PROFILE_EOF'
#!/bin/sh
export PATH=/usr/local/bin:/usr/local/sbin:/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/home/tc
export USER=tc
export DISPLAY=:0

case "$(tty)" in
    /dev/tty1|/dev/vc/1)
        [ -f /tmp/.boot_done ] && return
        touch /tmp/.boot_done
        
        echo "[BOOT] Initializing D-Secure Tools..." | tee /dev/console
        
        # Load drivers
        sudo depmod -a
        for mod in ahci nvme sd_mod i8042 atkbd psmouse hid hid-generic usbhid evdev uinput vboxvideo vmwgfx virtio_gpu; do
            sudo modprobe "$mod" 2>/dev/null || true
        done
        sudo udevadm trigger && sudo udevadm settle --timeout=3
        
        # Start DBus
        [ -f /usr/local/etc/init.d/dbus ] && sudo /usr/local/etc/init.d/dbus start | tee /dev/console
        [ -f /etc/machine-id ] || sudo dbus-uuidgen --ensure=/etc/machine-id
        
        # Mandatory symlinks
        [ -d /lib64 ] || sudo ln -sf /lib /lib64
        
        # Permissions
        sudo chmod 666 /dev/input/event* /dev/dri/* /dev/fb0 2>/dev/null || true
        
        # Environment
        export XDG_RUNTIME_DIR=/tmp/runtime-tc
        mkdir -p $XDG_RUNTIME_DIR && chmod 700 $XDG_RUNTIME_DIR
        
        echo "[BOOT] Starting Graphical Subsystem..." | tee /dev/console
        startx -- :0 2>&1 | tee /tmp/startx.log
        
        echo "[BOOT] GUI exited. Fallback shell." | tee /dev/console
        exec /bin/sh
        ;;
esac
PROFILE_EOF
chmod +x home/tc/.profile
cp -p home/tc/.profile home/tc/.xsession etc/skel/
echo "tc ALL=(ALL) NOPASSWD: ALL" >> etc/sudoers

# 5. Install Tauri App
echo "Installing Dashboard..."
mkdir -p opt/d-secure-ui/lib
cp "/home/nickx/Downloads/d-secure-ui/src-tauri/target/release/app" "opt/d-secure-ui/app"
ln -sf lib lib64

# Bundle host libraries (GLIBC 2.39 + Support Libs)
echo "Bundling host libraries for compatibility..."
HOST_LIB_DIR="/lib/x86_64-linux-gnu"
HOST_USR_LIB="/usr/lib/x86_64-linux-gnu"

# Essential list to avoid "version not found" or "no such file"
LIBS="libc.so.6 ld-linux-x86-64.so.2 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 
      libatomic.so.1 libwebpdemux.so.2 libgdk-3.so.0 libgtk-3.so.0 libwebkit2gtk-4.1.so.0 
      libjavascriptcoregtk-4.1.so.0 libsoup-3.0.so.0 libenchant-2.so.2 libsecret-1.so.0
      libharfbuzz-icu.so.0 libopenjp2.so.7 liblcms2.so.2"

for lib in $LIBS; do
    if [ -f "$HOST_LIB_DIR/$lib" ]; then
        cp "$HOST_LIB_DIR/$lib" "opt/d-secure-ui/lib/$lib"
    elif [ -f "$HOST_USR_LIB/$lib" ]; then
        cp "$HOST_USR_LIB/$lib" "opt/d-secure-ui/lib/$lib"
    else
        echo "Warning: Host library $lib not found!"
    fi
done

chmod +x opt/d-secure-ui/app opt/d-secure-ui/lib/ld-linux-x86-64.so.2 2>/dev/null || true
chown -R 1000:50 home/tc etc/skel opt/d-secure-ui

# 6. Repack (XZ-2 for speed)
echo "[4/4] Repacking..."
find . | cpio -o -H newc 2>/dev/null | xz -2 --check=crc32 > "$ISO_ROOT/boot/core_custom.gz"
cd "$SCRIPT_DIR"
cp "$BASE_DIR/vmlinuz64" "$ISO_ROOT/boot/vmlinuz64"
cp "$BASE_DIR/modules64.gz" "$ISO_ROOT/boot/modules64.gz"

# 7. GRUB Prep (Center logo via compositing)
echo "Preparing GRUB..."
mkdir -p "$ISO_ROOT/boot/grub"

# Combine parrot background with centered logo
if [ -f "/home/nickx/Downloads/parrot.jpg" ] && [ -f "/home/nickx/Downloads/enhance.png" ]; then
    convert "/home/nickx/Downloads/parrot.jpg" \( "/home/nickx/Downloads/enhance.png" -resize 800x \) -gravity center -composite "$ISO_ROOT/boot/grub/background.jpg"
fi

# Use standard config file from Downloads but PATCH it for EFI compatibility
if [ -f "/home/nickx/Downloads/grub_cfg" ]; then
    cp "/home/nickx/Downloads/grub_cfg" "$ISO_ROOT/boot/grub/grub.cfg"
    # Ensure EFI modules are present for the background image
    sed -i 's/insmod vbe/insmod vbe\ninsmod efi_gop\ninsmod efi_uga/g' "$ISO_ROOT/boot/grub/grub.cfg"
    # Remove the 'nomodeset' and other flags that break modern VM/Laptop graphics
    sed -i 's/nomodeset acpi=off noapic nolapic intel_idle.max_cstate=0 idle=poll//g' "$ISO_ROOT/boot/grub/grub.cfg"
    # Enable Serial logging for host-side debug
    sed -i 's/linux \/boot\/vmlinuz64/linux \/boot\/vmlinuz64 console=tty0 console=ttyS0/g' "$ISO_ROOT/boot/grub/grub.cfg"
    # Remove quiet and vga bits
    sed -i 's/quiet//g' "$ISO_ROOT/boot/grub/grub.cfg"
    sed -i 's/vga=791//g' "$ISO_ROOT/boot/grub/grub.cfg"
else
    # Minimal fallback config if file missing
    cat > "$ISO_ROOT/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0
insmod all_video
insmod gfxterm
insmod png
insmod jpeg
insmod efi_gop
insmod efi_uga
terminal_output gfxterm
background_image /boot/grub/background.jpg
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "D-Secure Drive Eraser" {
    linux /boot/vmlinuz64 console=tty0 console=ttyS0 loglevel=7 noswap laptop
    initrd /boot/core_custom.gz /boot/modules64.gz
}
EOF
fi

echo "=== Remaster Complete! ==="
# Cleanup work dir
cd "$SCRIPT_DIR"
rm -rf "$WORK_DIR" || true