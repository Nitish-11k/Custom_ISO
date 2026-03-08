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
cp "$SCRIPT_DIR"/splash_*.raw "$WORK_DIR/" 2>/dev/null || true
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
    
    # Load input drivers early
    echo "modprobe i8042 || true" >> etc/init.d/rcS
    echo "modprobe atkbd || true" >> etc/init.d/rcS
    echo "modprobe psmouse || true" >> etc/init.d/rcS
    echo "modprobe hid-generic || true" >> etc/init.d/rcS
    echo "modprobe usbhid || true" >> etc/init.d/rcS
    echo "modprobe evdev || true" >> etc/init.d/rcS
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
# Xorg Setup & Permissions
# ============================================================
echo "Configuring Xorg Permissions and Fallback..."

# Find the real Xorg binary if it moved during extraction
XORG_BIN=$(find "$WORK_DIR/usr/local" -name Xorg -type f -executable | head -n 1)
if [ -n "$XORG_BIN" ]; then
    chmod 4755 "$XORG_BIN" || true
fi

# Allow anybody to run X
mkdir -p "$WORK_DIR/etc/X11"
echo "allowed_users=anybody" > "$WORK_DIR/etc/X11/Xwrapper.config"
echo "needs_root_rights=yes" >> "$WORK_DIR/etc/X11/Xwrapper.config"



# CRITICAL: udev rules for tc user graphics/input
mkdir -p "$WORK_DIR/etc/udev/rules.d"
cat > "$WORK_DIR/etc/udev/rules.d/99-dsecure.rules" << 'UDEV_EOF'
KERNEL=="console", MODE="0666"
KERNEL=="fb0", MODE="0666"
KERNEL=="tty[0-9]*", MODE="0666"
KERNEL=="event*", MODE="0666"
KERNEL=="mouse*", MODE="0666"
KERNEL=="uinput", MODE="0666"
UDEV_EOF

# No xorg.conf - rely on auto-configuration (modesetting takes priority)

# ============================================================
# .profile — Auto-login, auto-startx
# ============================================================
# Prepare the startup logic in .profile
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
        
        echo "[BOOT] Dashboard Init (PID: $$) on $(tty)" | sudo tee /dev/ttyS0
        
        # Debug hardware state
        echo "[DEBUG] dev/fb0: $(ls -l /dev/fb0 2>/dev/null)" | sudo tee /dev/ttyS0
        echo "[DEBUG] dev/input: $(ls /dev/input 2>/dev/null)" | sudo tee /dev/ttyS0
        
        # Hardware setup

        # Load Input Drivers
        echo "[BOOT] Loading input drivers..." | sudo tee /dev/ttyS0
        sudo modprobe i8042 || true
        sudo modprobe atkbd || true
        sudo modprobe psmouse || true
        sudo modprobe hid-generic || true
        sudo modprobe usbhid || true
        sudo modprobe evdev || true

        sudo udevadm trigger 2>/dev/null || true
        sudo udevadm settle --timeout=5 2>/dev/null || true
        sudo chown tc:staff /dev/fb0 /dev/tty1 /dev/input/event* 2>/dev/null || true

        # Set up runtime env
        export XDG_RUNTIME_DIR=/tmp/runtime-tc
        mkdir -p $XDG_RUNTIME_DIR && chmod 700 $XDG_RUNTIME_DIR
        export DISPLAY=:0
        export WEBKIT_DISABLE_COMPOSITING_MODE=1
        export WEBKIT_DISABLE_SANDBOX=1
        export GDK_BACKEND=x11
        export LIBGL_ALWAYS_SOFTWARE=1

        echo "[BOOT] Starting Xorg..." | sudo tee /dev/ttyS0
        ( sudo Xorg :0 -ac -nolisten tcp -allowMouseOpenFail > /tmp/xorg.log 2>&1 ) &
        X_PID=$!

        # Wait for X
        READY=0
        for i in $(seq 1 15); do
            if DISPLAY=:0 xwininfo -root >/dev/null 2>&1; then
               READY=1 && break
            fi
            sleep 1
        done

        if [ "$READY" = "1" ]; then
           echo "[BOOT] X Server Ready! Detecting Resolution..." | sudo tee /dev/ttyS0 /dev/tty1
           
           # Use xrandr to set native resolution (adaptive step)
           DISPLAY=:0 xrandr --auto || echo "[WARN] xrandr --auto failed" | sudo tee /dev/ttyS0 /dev/tty1
           
           # Set background and cursor for the root window
           DISPLAY=:0 xsetroot -solid "#03132e" -cursor_name left_ptr
           
           # Reduced sleep for faster boot
           sleep 0.5
           
            if [ -f /opt/d-secure-ui/app ]; then
                cd /opt/d-secure-ui
                echo "[BOOT] Launching Tauri Dashboard (Fullscreen)..." | sudo tee /dev/ttyS0 /dev/tty1
                
                export PRIVATE_LIBS="/opt/d-secure-ui/.libs_private"
                export PRIVATE_LOADER="$PRIVATE_LIBS/ld-linux-x86-64.so.2"
                export GDK_SCALE=1
                export GDK_DPI_SCALE=1
               
               if [ -f "$PRIVATE_LOADER" ]; then
                   dbus-run-session "$PRIVATE_LOADER" --library-path "$PRIVATE_LIBS:/usr/local/lib:/usr/lib:/lib" ./app > /tmp/dashboard.log 2>&1 || {
                       echo "[FAILURE] Dashboard App exited. Checking libs..." | sudo tee /dev/ttyS0 /dev/tty1
                       ldd ./app | grep "not found" | sudo tee /dev/ttyS0 /dev/tty1
                       tail -n 10 /tmp/dashboard.log | sudo tee /dev/ttyS0 /dev/tty1
                       aterm -display :0 -title "DEBUG" -geometry 80x24+0+0 &
                   }
               else
                   dbus-run-session ./app > /tmp/dashboard.log 2>&1 || {
                       aterm -display :0 -title "DEBUG" -geometry 80x24+0+0 &
                   }
               fi
            elif [ -f /opt/react_python/react_launcher.py ]; then
                echo "[BOOT] Tauri missing. Launching Python Fallback..." | sudo tee /dev/ttyS0 /dev/tty1
                python3 /opt/react_python/react_launcher.py > /tmp/python_dashboard.log 2>&1 &
            else
                echo "[ERROR] No dashboard found in /opt!" | sudo tee /dev/ttyS0 /dev/tty1
                aterm -display :0 -title "ERROR" -geometry 80x24+0+0 &
            fi
        else
           echo "[ERROR] X initialization failed. Printing /tmp/xorg.log:" | sudo tee /dev/ttyS0 /dev/tty1
           cat /tmp/xorg.log | tail -n 20 | sudo tee /dev/ttyS0 /dev/tty1
        fi


        wait $X_PID
        ;;
esac
PROFILE_EOF

# ============================================================
# Install Tauri Dashboard and Bundle GLIBC 2.39
# ============================================================
echo "Installing Tauri Dashboard..."
mkdir -p "$WORK_DIR/opt/d-secure-ui"
TAURI_SOURCE="/home/nickx/Downloads/d-secure-ui/src-tauri/target/release/app"
if [ -f "$TAURI_SOURCE" ]; then
    cp "$TAURI_SOURCE" "$WORK_DIR/opt/d-secure-ui/app"
    chmod +x "$WORK_DIR/opt/d-secure-ui/app"
    
    # Also copy assets if they exist
    DIST_SOURCE="/home/nickx/Downloads/d-secure-ui/src/dist"
    if [ -d "$DIST_SOURCE" ]; then
        cp -r "$DIST_SOURCE" "$WORK_DIR/opt/d-secure-ui/"
    fi
    
    # Bundle host GLIBC 2.39 libraries for compatibility
    echo "  Bundling host GLIBC 2.39 libraries..."
    PRIVATE_LIBS_DIR="$WORK_DIR/opt/d-secure-ui/.libs_private"
    mkdir -p "$PRIVATE_LIBS_DIR"
    LIBS="libc.so.6 libm.so.6 libresolv.so.2 librt.so.1 libdl.so.2 libpthread.so.0 libgcc_s.so.1 libstdc++.so.6 ld-linux-x86-64.so.2 libatomic.so.1 libwebpdemux.so.2"
    for lib in $LIBS; do
        # Seek from host /lib/x86_64-linux-gnu first (Ubuntu standard)
        if [ -f "/lib/x86_64-linux-gnu/$lib" ]; then
            cp -L "/lib/x86_64-linux-gnu/$lib" "$PRIVATE_LIBS_DIR/"
        # Fallback to general lib paths
        elif [ -f "/usr/lib/x86_64-linux-gnu/$lib" ]; then
            cp -L "/usr/lib/x86_64-linux-gnu/$lib" "$PRIVATE_LIBS_DIR/"
        elif [ -f "/lib/$lib" ]; then
            cp -L "/lib/$lib" "$PRIVATE_LIBS_DIR/"
        fi
    done
else
    echo "WARNING: Tauri binary not found!"
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

find . | cpio -o -H newc 2>/dev/null | gzip -1 > "$ISO_ROOT/boot/core_custom.gz"
cp "$BASE_DIR/vmlinuz64" "$ISO_ROOT/boot/vmlinuz64"
cp "$BASE_DIR/modules64.gz" "$ISO_ROOT/boot/modules64.gz"

echo "Remaster complete!"