#!/bin/sh
#
# remaster_tc.sh - D-Secure Edition (DIRECT MOUNT STRATEGY)
#
# ROOT CAUSE: tce-load is too slow (2-3 min for 127 packages via CDROM in VM).
# FIX: Pre-extract ALL .tcz files directly into the squashfs initramfs.
#      Zero tce-load calls at boot. Everything is already installed.
#      Boot sequence: GRUB -> splash -> login -> startx -> dashboard
#      Total time to dashboard: < 30 seconds.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/tc_remaster"
EXT_DIR="$SCRIPT_DIR/tc_extensions"
BASE_DIR="$SCRIPT_DIR/tc_base"
ISO_ROOT="$SCRIPT_DIR/iso_root"

echo "=== Remastering Tiny Core Linux (D-Secure Edition) ==="

# 0. Cleanup
rm -rf "$ISO_ROOT/isolinux" "$ISO_ROOT/cde"
mkdir -p "$ISO_ROOT/boot"

# 2. Unpack base
echo "[2/4] Unpacking corepure64.gz..."
[ -d "$WORK_DIR" ] && mv "$WORK_DIR" "$WORK_DIR.old.$(date +%s)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
zcat "$BASE_DIR/corepure64.gz" | cpio -i -H newc -d 2>/dev/null

# Extract ALL extensions into the rootfs (The "Direct Mount" Fix)
echo "Pre-extracting extensions into initramfs..."
for ext in "$EXT_DIR"/*.tcz; do
    echo "  Extracting: $(basename "$ext")"
    if [ ! -s "$ext" ]; then
        echo "  WARNING: Skipping empty extension $ext"
        continue
    fi
    unsquashfs -f -d "$WORK_DIR" "$ext" || {
        echo "  WARNING: Failed to extract $ext correctly! Trying fallback..."
        unsquashfs -i -f -d "$WORK_DIR" "$ext" || true
    }
done

# Compatibility: Create symlink for Ubuntu-style library paths
# Tiny Core uses /usr/local/lib, but Ubuntu-built binaries expect /lib/x86_64-linux-gnu
echo "Creating library compatibility symlinks..."
mkdir -p "$WORK_DIR/lib/x86_64-linux-gnu" "$WORK_DIR/usr/lib/x86_64-linux-gnu"
for lib in "$WORK_DIR/usr/local/lib"/*; do
    [ -e "$lib" ] || continue
    fname=$(basename "$lib")
    ln -sf "/usr/local/lib/$fname" "$WORK_DIR/lib/x86_64-linux-gnu/$fname"
    ln -sf "/usr/local/lib/$fname" "$WORK_DIR/usr/lib/x86_64-linux-gnu/$fname"
done

if [ ! -L "$WORK_DIR/lib64" ] && [ ! -d "$WORK_DIR/lib64" ]; then
    ln -s lib "$WORK_DIR/lib64"
fi

# Fallback: Copy missing libraries directly from host if they are not in TCZ
echo "Copying host specific libraries as fallback..."
for lib in \
    libwoff2dec.so.1.0.2 \
    libwoff2common.so.1.0.2 \
; do
    if [ ! -f "$WORK_DIR/usr/local/lib/$lib" ]; then
        cp "/lib/x86_64-linux-gnu/$lib" "$WORK_DIR/usr/local/lib/" 2>/dev/null || \
        cp "/usr/lib/x86_64-linux-gnu/$lib" "$WORK_DIR/usr/local/lib/" 2>/dev/null || true
    fi
done

# Fix for missing libudev versions which Xorg/App might want
for libdir in "$WORK_DIR/usr/local/lib" "$WORK_DIR/usr/lib"; do
    if [ -f "$libdir/libudev.so.1" ] && [ ! -f "$libdir/libudev.so.0" ]; then
        ln -sf libudev.so.1 "$libdir/libudev.so.0"
    elif [ -f "$libdir/libudev.so" ] && [ ! -f "$libdir/libudev.so.1" ]; then
        ln -sf libudev.so "$libdir/libudev.so.1"
    fi
done

# Pre-installation complete. Run ldconfig in the WORK_DIR to fix library cache
echo "Running ldconfig in rootfs..."
ldconfig -r "$WORK_DIR" 2>/dev/null || true

# Back to WORK_DIR for rest of script
cd "$WORK_DIR"

# 3. Install tiny_splash
echo "Compiling tiny_splash..."
gcc -static -O3 "$SCRIPT_DIR/tiny_splash.c" -o "$SCRIPT_DIR/tiny_splash"
# IMPORTANT: Only copy splash_0.raw to save ~35MB of space
cp "$SCRIPT_DIR/splash_0.raw" "$WORK_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/tiny_splash" "$WORK_DIR/sbin/tiny_splash"
chmod +x "$WORK_DIR/sbin/tiny_splash"

# Start splash as first thing in rcS
if [ -f etc/init.d/rcS ]; then
    sed -i '/tiny_splash/d' etc/init.d/rcS
    # sed -i '1a /sbin/tiny_splash &' etc/init.d/rcS  # DISABLED FOR DEBUGGING
    
    # Enable verbose logging by removing redirections
    sed -i 's|> /dev/null 2>&1||g' etc/init.d/rcS
    sed -i 's|2>/dev/null||g' etc/init.d/rcS
    
    # Ensure system dbus is running before anything else
    echo "sudo /usr/local/etc/init.d/dbus start" >> etc/init.d/rcS
fi

# 4. Configure Autostart
echo "[3/4] Configuring Autostart Logic..."
sed -i 's|tty1::respawn:/sbin/getty.*|tty1::once:/bin/login -f tc </dev/tty1 >/dev/tty1 2>\&1|' "$WORK_DIR/etc/inittab"
> "$WORK_DIR/etc/motd"

mkdir -p "$WORK_DIR/home/tc" "$WORK_DIR/etc/skel"
mkdir -p "$WORK_DIR/etc/sysconfig"
echo "Xorg" > "$WORK_DIR/etc/sysconfig/Xserver"
echo "flwm" > "$WORK_DIR/etc/sysconfig/desktop"
echo "tc" > "$WORK_DIR/etc/sysconfig/tcuser"

# Silence tc-config wait prompt
if [ -f "$WORK_DIR/etc/init.d/tc-config" ]; then
    sed -i 's|read ans||g' "$WORK_DIR/etc/init.d/tc-config"
fi

# ============================================================
# CRITICAL: Bypass Xorg.wrap — it blocks non-root users
# Replace the wrapper script to call Xorg binary directly (suid)
# ============================================================
cat > "$WORK_DIR/usr/local/bin/Xorg" << 'XORG_WRAPPER_EOF'
#!/bin/sh
# Wrapper to ensure Xorg runs as root (setuid) and uses the right path
exec /usr/local/lib/xorg/Xorg "$@"
XORG_WRAPPER_EOF
chmod 4755 "$WORK_DIR/usr/local/lib/xorg/Xorg" 2>/dev/null || chmod +s "$WORK_DIR/usr/local/lib/xorg/Xorg" || true
chmod +x "$WORK_DIR/usr/local/bin/Xorg"

# Also allow anybody to run X (Xwrapper.config)
mkdir -p "$WORK_DIR/etc/X11"
echo "allowed_users=anybody" > "$WORK_DIR/etc/X11/Xwrapper.config"
echo "needs_root_rights=yes" >> "$WORK_DIR/etc/X11/Xwrapper.config"

# CRITICAL: udev rules for tc user graphics/input/usb
mkdir -p "$WORK_DIR/etc/udev/rules.d"
cat > "$WORK_DIR/etc/udev/rules.d/99-dsecure.rules" << 'UDEV_EOF'
KERNEL=="console", MODE="0666"
KERNEL=="fb0", MODE="0666"
KERNEL=="tty[0-9]*", MODE="0666"
KERNEL=="event*", MODE="0666"
KERNEL=="mouse*", MODE="0666"
KERNEL=="uinput", MODE="0666"
SUBSYSTEM=="input", MODE="0666"
SUBSYSTEM=="usb", MODE="0666"
UDEV_EOF

# Keep vmmouse driver for VirtualBox/VMware support
# rm -f "$WORK_DIR/usr/local/share/X11/xorg.conf.d/50-vmmouse.conf"
# rm -f "$WORK_DIR/usr/local/lib/xorg/modules/input/vmmouse_drv.so"
# rm -f "$WORK_DIR/usr/local/bin/vmmouse_detect"

# INPUT FIX: Xorg libinput config for real hardware
mkdir -p "$WORK_DIR/usr/local/share/X11/xorg.conf.d"
cat > "$WORK_DIR/usr/local/share/X11/xorg.conf.d/40-libinput.conf" << 'XORG_INPUT_EOF'
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
EndSection
XORG_INPUT_EOF

# No xorg.conf - rely on auto-configuration (modesetting takes priority)

# ============================================================
# .profile — Auto-login, auto-startx
# ============================================================
# Prepare the startup logic in .profile
cat > "$WORK_DIR/home/tc/.profile" << 'PROFILE_EOF'
#!/bin/sh
export PATH=/usr/local/bin:/usr/local/sbin:/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/home/tc
export USER=tc

# Ensure we only run this once on boot
case "$(tty)" in
    /dev/tty1|/dev/vc/1|/dev/ttyS0)
        [ -f /tmp/.boot_done ] && return
        touch /tmp/.boot_done
        
        echo "[BOOT] Dashboard Init (PID: $$) on $(tty)" | tee /dev/console
        
        # Kill splash
        echo "[BOOT] Stopping splash..." | tee /dev/console
        sudo pkill -TERM tiny_splash 2>/dev/null || true
        sleep 1
        sudo pkill -9 tiny_splash 2>/dev/null || true

        # Hardware setup
        echo "[BOOT] Probing hardware..." | tee /dev/console
        sudo depmod -a
        
        # Load input, network, and VM modules (Critical for VirtualBox, QEMU and real hardware)
        echo "[BOOT] Loading modules..." | tee /dev/console
        for mod in hid hid-generic usbhid i8042 atkbd psmouse evdev mousedev \
                   virtio_net virtio_pci virtio_input \
                   vboxguest vboxvideo vmwgfx \
                   e1000 pcnet32 8139cp 8139too ne2k_pci; do
            sudo modprobe "$mod" 2>/dev/null || true
        done
        
        sudo udevadm trigger
        sudo udevadm settle --timeout=5
        
        # NETWORK FIX: Attempt to get IP via DHCP
        echo "[BOOT] Starting network (DHCP)..." | tee /dev/console
        sudo udhcpc -b -i eth0 > /tmp/dhcp.log 2>&1 &
        
        echo "--- /dev/input status ---" | tee /dev/console
        ls -la /dev/input | tee /dev/console
        
        sudo chown tc:staff /dev/fb0 /dev/tty1 2>/dev/null || true
        sudo chmod 666 /dev/input/event* 2>/dev/null || true
        sudo chmod 666 /dev/input/mouse* 2>/dev/null || true
        sudo chmod 666 /dev/input/mice 2>/dev/null || true

        # Set up runtime env
        export HOME=/home/tc
        export USER=tc
        export XDG_RUNTIME_DIR=/tmp/runtime-tc
        mkdir -p $XDG_RUNTIME_DIR && chmod 700 $XDG_RUNTIME_DIR
        export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib:/lib:/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu
        export DISPLAY=:0
        export WEBKIT_DISABLE_COMPOSITING_MODE=1
        export WEBKIT_DISABLE_SANDBOX=1
        export GDK_BACKEND=x11
        export LIBGL_ALWAYS_SOFTWARE=1
        
        # Fix for network detection in some browsers/apps
        echo "127.0.0.1 localhost $(hostname)" | sudo tee /etc/hosts >/dev/null

        echo "[BOOT] Starting Xorg on vt1..." | tee /dev/console
        ( sudo sh -c "LD_LIBRARY_PATH=$LD_LIBRARY_PATH /usr/local/lib/xorg/Xorg :0 -ac -retro -nolisten tcp -allowMouseOpenFail -logverbose 6 > /tmp/xorg.log 2>&1"; echo $? > /tmp/xorg.exit ) &
        X_PID=$!

        # Wait for X
        echo "[BOOT] Waiting for server..." | tee /dev/console
        READY=0
        for i in $(seq 1 20); do
            if ! kill -0 $X_PID 2>/dev/null; then
               # Xorg exited
               X_EXIT=$(cat /tmp/xorg.exit 2>/dev/null || echo "unknown")
               echo "[BOOT] X failed! Exit status: $X_EXIT" | tee /dev/console
               echo "--- /tmp/xorg.log ---" | tee /dev/console
               cat /tmp/xorg.log | tee /dev/console
               if [ -f /var/log/Xorg.0.log ]; then
                   echo "--- /var/log/Xorg.0.log ---" | tee /dev/console
                   cat /var/log/Xorg.0.log | tee /dev/console
               fi
               break
            fi
            if DISPLAY=:0 xwininfo -root >/dev/null 2>&1 || DISPLAY=:0 xprop -root >/dev/null 2>&1; then
               READY=1
               break
            fi
            [ -f /tmp/.X0-lock ] && [ $i -gt 2 ] && READY=1 && break
            sleep 1
        done

        if [ "$READY" = "1" ]; then
           echo "[BOOT] X Server Ready! Launching Window Manager..." | tee /dev/console
           xsetroot -solid "#2c3e50" -display :0
           flwm &
           sleep 1

           # INPUT FIX: Re-set permissions after Xorg starts (it may re-enumerate)
           sudo chmod 666 /dev/input/event* 2>/dev/null || true
           sudo chmod 666 /dev/input/mice 2>/dev/null || true
           
           if [ -f /opt/d-secure-ui/app ]; then
               cd /opt/d-secure-ui
               echo "[BOOT] Launching Tauri Dashboard..." | tee /dev/console
               dbus-run-session ./app > /tmp/dashboard.log 2>&1 || {
                   EXIT_CODE=$?
                   echo "[FAILURE] Dashboard App exited code $EXIT_CODE" | tee /dev/console
                   echo "--- MISSING LIBRARIES ---" | tee /dev/console
                   ldd ./app | grep "not found" | tee /dev/console
                   echo "--- GLIBC CHECK ---" | tee /dev/console
                   strings /lib/libc.so.6 | grep GLIBC_ | tail -n 5 | tee /dev/console
                   echo "--- LAST 20 LINES OF LOG ---" | tee /dev/console
                   tail -n 20 /tmp/dashboard.log | tee /dev/console
                   
                   # Fallback Term
                   aterm -display :0 -title "DEBUG" -geometry 80x24+0+0 &
               }
           elif [ -f /opt/react_python/react_launcher.py ]; then
               echo "[BOOT] Tauri missing. Launching Python Fallback..." | tee /dev/console
               python3 /opt/react_python/react_launcher.py > /tmp/python_dashboard.log 2>&1 &
           else
               echo "[ERROR] No dashboard found in /opt!" | tee /dev/console
               aterm -display :0 -title "ERROR" -geometry 80x24+0+0 &
           fi
        else
           echo "[BOOT] X initialization failed after 20s. Check /tmp/xorg.log." | tee /dev/console
           cat /tmp/xorg.log | tee /dev/console
        fi
        wait $X_PID
        ;;
esac
PROFILE_EOF

# ============================================================
# Install Tauri Dashboard
# ============================================================
echo "Installing Tauri Dashboard..."
mkdir -p "$WORK_DIR/opt/d-secure-ui"
if [ -f "/home/nickx/Downloads/d-secure-ui/src-tauri/target/release/app" ]; then
    cp "/home/nickx/Downloads/d-secure-ui/src-tauri/target/release/app" "$WORK_DIR/opt/d-secure-ui/app"
    chmod +x "$WORK_DIR/opt/d-secure-ui/app"
else
    echo "WARNING: Tauri binary not found at release path!"
fi
chown -R 1001:50 "$WORK_DIR/opt/d-secure-ui"

# ============================================================
# Install Python Dashboard (Fallback)
# ============================================================
echo "Installing Python Dashboard..."
mkdir -p "$WORK_DIR/opt/react_python"
if [ -f "$SCRIPT_DIR/dashboard.py" ]; then
    cp "$SCRIPT_DIR/dashboard.py" "$WORK_DIR/opt/react_python/react_launcher.py"
    chmod +x "$WORK_DIR/opt/react_python/react_launcher.py"
fi
chown -R 1001:50 "$WORK_DIR/opt/react_python"

# Repack
echo "[4/4] Repacking..."
chmod +x "$WORK_DIR/home/tc/.profile"
chown -R 1001:50 "$WORK_DIR/home/tc"
cp -p "$WORK_DIR/home/tc/.profile" "$WORK_DIR/etc/skel/"
echo "tc ALL=(ALL) NOPASSWD: ALL" >> "$WORK_DIR/etc/sudoers"

find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$ISO_ROOT/boot/core_custom.gz"
cp "$BASE_DIR/vmlinuz64" "$ISO_ROOT/boot/vmlinuz64"
cp "$BASE_DIR/modules64.gz" "$ISO_ROOT/boot/modules64.gz"

echo "Remaster complete!"
# ============================================================
# Prepare Bootloader (GRUB)
# ============================================================
echo "Preparing GRUB Bootloader..."
mkdir -p "$ISO_ROOT/boot/grub"
cp -r /home/nickx/D-secureOS/iso/boot/grub/themes "$ISO_ROOT/boot/grub/" || true
cp -r /home/nickx/D-secureOS/iso/boot/grub/fonts "$ISO_ROOT/boot/grub/" || true
cp /home/nickx/D-secureOS/iso/boot/grub/*.png "$ISO_ROOT/boot/grub/" 2>/dev/null || true
cp /home/nickx/D-secureOS/iso/boot/grub/*.jpg "$ISO_ROOT/boot/grub/" 2>/dev/null || true

cat << 'GRUB_EOF' > "$ISO_ROOT/boot/grub/grub.cfg"
set default=0
set timeout=15

insmod all_video
insmod gfxterm
insmod png
insmod jpeg

set gfxmode=1024x768,auto
terminal_output gfxterm

set theme=($root)/boot/grub/themes/dsecure/theme.txt
export theme

background_image /boot/grub/background.png

menuentry "D-Secure Drive Eraser (64-bit)" {
    echo "Loading D-Secure System Core..."
    linux /boot/vmlinuz64 loglevel=3 cde tce=cde waitusb=20 vga=791 showapps noswap laptop
    initrd /boot/core_custom.gz /boot/modules64.gz
}

menuentry "System Tools (Reboot)" {
    reboot
}

menuentry "Power Off" {
    halt
}
GRUB_EOF

echo "Finalizing Branded ISO..."