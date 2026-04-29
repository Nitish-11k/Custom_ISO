#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║          KIOSK LIVE ISO + PXE BUILDER  v3.2  (AppImage Fixed)            ║
# ║          Pure Debian Bookworm · Tauri v2 · BIOS/UEFI Hybrid              ║
# ║                                                                          ║
# ║  KEY FIXES vs v3.1:                                                      ║
# ║  1. AppImage pre-extracted at BUILD TIME (not runtime) → no FUSE needed  ║
# ║  2. Smart lib strip: only removes if system has verified replacement      ║
# ║  3. Clean crash-restart loop: AppRun --no-sandbox, correct paths         ║
# ║  4. WEBKIT_EXEC_PATH set correctly for extracted layout                  ║
# ║  5. DEBIAN_RELEASE fixed to bookworm (GLIBC 2.36 + backports → 2.38)    ║
# ║  6. XDG / dbus / display env correctly exported before X starts          ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# 0. EARLY HELPERS
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_START=$(date +%s)

_C() { printf '\033[%sm' "$1"; }
RED=$(_C 31); GRN=$(_C 32); YLW=$(_C 33); BLU=$(_C 34)
CYN=$(_C 36); WHT=$(_C 37); DIM=$(_C 2);  RST=$(_C 0); BOLD=$(_C 1)

log()  { printf "${DIM}[%s]${RST} ${BLU}[*]${RST} %s\n"  "$(date +%H:%M:%S)" "$*"; }
ok()   { printf "${DIM}[%s]${RST} ${GRN}[✓]${RST} %s\n"  "$(date +%H:%M:%S)" "$*"; }
warn() { printf "${DIM}[%s]${RST} ${YLW}[!]${RST} %s\n"  "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf "${DIM}[%s]${RST} ${RED}[✗]${RST} %s\n"  "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
step() { printf "\n${BOLD}${CYN}━━━  %s  ━━━${RST}\n\n" "$*"; }
hr()   { printf "${DIM}%s${RST}\n" "$(printf '─%.0s' {1..72})"; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo $0)"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"
BUILD_DIR="${BUILD_DIR:-$WORKDIR/pxe_build}"

# FIX #5: bookworm has better GLIBC backport support than trixie for AppImages
DEBIAN_RELEASE="${DEBIAN_RELEASE:-bookworm}"
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

ISO_LABEL="${ISO_LABEL:-LIVE_OS}"
ISO_VERSION="${ISO_VERSION:-$(date +%Y%m%d)}"
HOSTNAME_LIVE="${HOSTNAME_LIVE:-live-system}"

SQUASHFS_COMP="${SQUASHFS_COMP:-xz}"
SQUASHFS_BLOCK="${SQUASHFS_BLOCK:-1M}"

ENABLE_SSH="${ENABLE_SSH:-0}"
ENABLE_PERSISTENCE="${ENABLE_PERSISTENCE:-0}"
KIOSK_MODE="${KIOSK_MODE:-1}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-5}"
DRY_RUN="${DRY_RUN:-0}"
PARALLEL_JOBS="${PARALLEL_JOBS:-$(nproc)}"

# FIX #1: AppImage extraction directory (build-time, inside rootfs)
# App will live at /opt/app/app_extracted/ — no runtime extraction needed
APP_EXTRACT_DIR="/opt/app/app_extracted"

[[ -f "$WORKDIR/build.conf" ]] && { log "Loading build.conf"; source "$WORKDIR/build.conf"; }

readonly ROOTFS_DIR="$BUILD_DIR/rootfs"
readonly ISO_DIR="$BUILD_DIR/iso"
readonly PXE_DIR="$BUILD_DIR/pxe"
readonly APP_DIR="$ROOTFS_DIR/opt/app"
readonly SQUASHFS_IMG="$ISO_DIR/live/filesystem.squashfs"
readonly ISO_OUT="$WORKDIR/${ISO_LABEL,,}-${ISO_VERSION}-${ARCH}.iso"
readonly LOG_FILE="$WORKDIR/build-${ISO_VERSION}.log"

# ─────────────────────────────────────────────────────────────────────────────
# 2. TRAP
# ─────────────────────────────────────────────────────────────────────────────
_MOUNTED_PATHS=()

unmount_all() {
    local rc=$?
    for p in "${_MOUNTED_PATHS[@]:-}"; do
        mountpoint -q "$p" 2>/dev/null && sudo umount -lf "$p" 2>/dev/null || true
    done
    [[ $rc -ne 0 ]] && warn "Build failed — partial artefacts in $BUILD_DIR"
}
trap unmount_all EXIT

bind_mount() {
    local src=$1 dst=$2
    mkdir -p "$dst"
    sudo mount --bind "$src" "$dst"
    _MOUNTED_PATHS+=("$dst")
}

# ─────────────────────────────────────────────────────────────────────────────
# 2b. CLEANUP
# ─────────────────────────────────────────────────────────────────────────────
cleanup_old_builds() {
    step "CLEANUP OLD BUILDS"

    if [[ -d "$ROOTFS_DIR" ]]; then
        for mp in "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys"; do
            mountpoint -q "$mp" 2>/dev/null && {
                log "Unmounting stale: $mp"
                umount -lf "$mp" 2>/dev/null || true
            }
        done
    fi

    [[ -f "$LOG_FILE" ]] && mv "$LOG_FILE" "${LOG_FILE%.log}-prev.log" 2>/dev/null || true

    find "$WORKDIR" -maxdepth 1 -name "${ISO_LABEL,,}-*.iso" -type f 2>/dev/null | while read -r f; do
        log "Removing old ISO: $(basename "$f")"; rm -f "$f"
    done

    rm -f "$WORKDIR"/${ISO_LABEL,,}-*.sha256 2>/dev/null || true

    if [[ -d "$BUILD_DIR" ]]; then
        log "Removing old build dir: $BUILD_DIR"
        rm -rf "$BUILD_DIR"
    fi

    ok "Cleanup complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
    step "PRE-FLIGHT"
    require_root

    APPIMAGE=$(find "$WORKDIR" -maxdepth 2 -name "*.AppImage" -type f | sort | head -n1 || true)
    [[ -z "$APPIMAGE" ]] && die "No *.AppImage found in $WORKDIR"
    ok "AppImage : $APPIMAGE"

    BACKGROUND=$(find "$WORKDIR" -maxdepth 2 -name "background.png" 2>/dev/null | head -n1 || true)
    SPLASH=$(find "$WORKDIR" -maxdepth 2 -name "splash.png"     2>/dev/null | head -n1 || true)
    [[ -n "$BACKGROUND" ]] && ok "Background: $BACKGROUND"
    [[ -n "$SPLASH"     ]] && ok "Splash    : $SPLASH"

    local tools=(debootstrap mksquashfs xorriso grub-mkstandalone mtools file sha256sum squashfs-tools)
    local MISSING_TOOLS=()
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || MISSING_TOOLS+=("$t")
    done

    if [[ ! -d /usr/lib/grub/i386-pc ]] || [[ ! -d /usr/lib/grub/x86_64-efi ]]; then
        MISSING_TOOLS+=(grub-modules)
    fi

    if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
        warn "Installing missing host tools: ${MISSING_TOOLS[*]}"
        apt-get -qq update
        apt-get -qq install -y \
            debootstrap squashfs-tools xorriso \
            grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed \
            mtools isolinux syslinux-common \
            curl file ca-certificates binutils
    fi

    [[ -f /usr/lib/grub/i386-pc/cdboot.img ]] || die "Missing GRUB BIOS modules"
    [[ -d /usr/lib/grub/x86_64-efi ]]        || die "Missing GRUB EFI modules"

    # FIX #1: squashfs-tools needed on HOST to extract AppImage at build time
    command -v unsquashfs &>/dev/null || die "unsquashfs missing — apt-get install squashfs-tools"

    ok "Pre-flight passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. BOOTSTRAP ROOTFS
# ─────────────────────────────────────────────────────────────────────────────
bootstrap_rootfs() {
    step "BOOTSTRAP ROOTFS  ($DEBIAN_RELEASE / $ARCH)"
    rm -rf "$BUILD_DIR"
    mkdir -p "$ROOTFS_DIR" "$ISO_DIR/live" "$ISO_DIR/boot/grub" \
             "$ISO_DIR/EFI/BOOT" "$PXE_DIR" "$APP_DIR"

    log "Running debootstrap (variant=minbase)..."
    debootstrap \
        --arch="$ARCH" \
        --variant=minbase \
        --components=main,contrib,non-free,non-free-firmware \
        --include=ca-certificates,apt-transport-https \
        "$DEBIAN_RELEASE" "$ROOTFS_DIR" "$MIRROR" \
        2>&1 | tee -a "$LOG_FILE" | grep -E '(I:|W:|E:)' || true

    ok "Bootstrap complete  →  $(du -sh "$ROOTFS_DIR" | cut -f1)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. CHROOT CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
configure_rootfs() {
    step "CONFIGURE ROOTFS"

    bind_mount /dev     "$ROOTFS_DIR/dev"
    bind_mount /dev/pts "$ROOTFS_DIR/dev/pts"
    bind_mount /proc    "$ROOTFS_DIR/proc"
    bind_mount /sys     "$ROOTFS_DIR/sys"

    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    cat > "$BUILD_DIR/chroot_setup.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

INSTALL_LOG="/tmp/pkg-install.log"
FAILED_PKGS=""

safe_install() {
    local verified=()
    for spec in "$@"; do
        local found=""
        IFS='|' read -ra alternatives <<< "$spec"
        for candidate in "${alternatives[@]}"; do
            candidate=$(echo "$candidate" | xargs)
            if apt-cache show "$candidate" >/dev/null 2>&1; then
                verified+=("$candidate")
                found=1
                break
            fi
        done
        if [[ -z "$found" ]]; then
            echo "  [SKIP] None found: $spec" | tee -a "$INSTALL_LOG"
            FAILED_PKGS="$FAILED_PKGS $spec"
        fi
    done
    if [[ ${#verified[@]} -gt 0 ]]; then
        apt-get -qq install -y --no-install-recommends "${verified[@]}" 2>&1 || {
            for pkg in "${verified[@]}"; do
                apt-get -qq install -y --no-install-recommends "$pkg" 2>&1 || \
                    echo "  [FAIL] $pkg" | tee -a "$INSTALL_LOG"
            done
        }
    fi
}

# ── APT SOURCES ──────────────────────────────────────────────────
cat > /etc/apt/sources.list << 'APT'
deb http://deb.debian.org/debian RELEASE_PLACEHOLDER main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security RELEASE_PLACEHOLDER-security main contrib non-free
deb http://deb.debian.org/debian RELEASE_PLACEHOLDER-backports main contrib non-free non-free-firmware
APT

apt-get -qq update

echo "[1/8] Core system..."
safe_install \
    systemd systemd-sysv dbus dbus-x11 \
    sudo \
    udev kmod iproute2 iputils-ping \
    live-boot live-boot-initramfs-tools initramfs-tools \
    "linux-image-ARCH_PLACEHOLDER" \
    bash coreutils util-linux procps \
    locales curl wget ca-certificates \
    binutils file python3-xdg

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

echo "[2/8] Display server..."
safe_install \
    xserver-xorg \
    xserver-xorg-legacy \
    xserver-xorg-core \
    xserver-xorg-input-all \
    xserver-xorg-video-all \
    xinit x11-xserver-utils \
    openbox \
    feh \
    unclutter \
    fuse3 libfuse2 \
    fonts-dejavu-core fonts-liberation2

echo "[3/8] Tauri v2 / WebKitGTK runtime..."
safe_install \
    libwebkit2gtk-4.1-0 \
    libgtk-3-0 libglib2.0-0 \
    libsoup-3.0-0 \
    libjavascriptcoregtk-4.1-0 \
    libgdk-pixbuf-2.0-0 \
    libcairo2 libcairo-gobject2 \
    libpango-1.0-0 libpangocairo-1.0-0 libpangoft2-1.0-0 \
    libharfbuzz0b libharfbuzz-icu0 \
    libatk1.0-0 \
    "libatk-bridge2.0-0|libatk-bridge-2.0-0" \
    libenchant-2-2 \
    libsecret-1-0 \
    libmanette-0.2-0 \
    libhyphen0 \
    libxslt1.1 libxml2 \
    libsqlite3-0 \
    libseccomp2 \
    "libicu72|libicu71|libicu67" \
    glib-networking \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    "gstreamer1.0-gl|libgstreamer-gl1.0-0" \
    libgles2 libegl1 libgl1 libgbm1 libdrm2 \
    libepoxy0 \
    libasound2 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libx11-xcb1 libxcb1 libxcb-dri3-0 \
    "libxss1|libxss-dev" \
    libxcursor1 libxinerama1 libxi6 \
    libnss3 libnspr4 \
    "libwebp7|libwebp6" \
    "libwebpdemux2|libwebpdemux" \
    "libwebpmux3|libwebpmux2" \
    libgudev-1.0-0 \
    liborc-0.4-0 \
    gsettings-desktop-schemas \
    libssl3 \
    librsvg2-2 librsvg2-common \
    "libayatana-appindicator3-1|libappindicator3-1" \
    libdbus-1-3

# FIX #5: GLIBC 2.38 fix — upgrade key libs from backports
echo "[3.5/8] Upgrading libs from backports (GLIBC 2.38 compatibility)..."
apt-get -qq install -y -t RELEASE_PLACEHOLDER-backports \
    libglib2.0-0 \
    libgtk-3-0 \
    libcairo2 \
    libgdk-pixbuf-2.0-0 \
    libwebkit2gtk-4.1-0 \
    2>&1 || echo "  [WARN] Backports upgrade partial — app may still work"

# Rebuild ldconfig after all installs
ldconfig

echo "[4/8] Network..."
safe_install network-manager

echo "[5/8] Storage..."
safe_install udisks2 ntfs-3g dosfstools e2fsprogs

echo "[6/8] Audio..."
safe_install pulseaudio alsa-utils

echo "[7/8] Firmware..."
safe_install \
    firmware-linux-free \
    "firmware-misc-nonfree|firmware-linux-nonfree" \
    "firmware-intel-sound|firmware-sof-signed"

echo "[7.5/8] Plymouth..."
safe_install plymouth plymouth-themes
mkdir -p /usr/share/plymouth/themes/kiosk-spinner
plymouth-set-default-theme -R kiosk-spinner 2>/dev/null || true
update-initramfs -u 2>/dev/null || true

echo "[8/8] Configuring system..."

dbus-uuidgen > /etc/machine-id 2>/dev/null || true
mkdir -p /var/lib/dbus
cp /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

# ── AUTO-LOGIN ────────────────────────────────────────────────────
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'SVC'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin liveuser --noclear %I $TERM
SVC

for tty in tty2 tty3 tty4 tty5 tty6; do
    systemctl mask "getty@${tty}.service" 2>/dev/null || true
done

# ── LIVE USER ────────────────────────────────────────────────────
useradd -m -s /bin/bash -G sudo,video,audio,input,plugdev,dialout,tty liveuser 2>/dev/null || true
echo 'liveuser:live' | chpasswd
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/liveuser
chmod 0440 /etc/sudoers.d/liveuser

# ── OPENBOX KIOSK CONFIG ─────────────────────────────────────────
mkdir -p /home/liveuser/.config/openbox

cat > /home/liveuser/.config/openbox/rc.xml << 'OBRC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance><strength>0</strength><screen_edge_strength>0</screen_edge_strength></resistance>
  <focus><followMouse>no</followMouse></focus>
  <theme><name>Clearlooks</name><titleLayout></titleLayout></theme>
  <desktops><number>1</number></desktops>
  <keyboard>
    <keybind key="A-F4"><action name="Execute"><command>/bin/true</command></action></keybind>
    <keybind key="A-Tab"><action name="Execute"><command>/bin/true</command></action></keybind>
    <keybind key="A-F2"><action name="Execute"><command>/bin/true</command></action></keybind>
    <keybind key="C-A-Delete"><action name="Execute"><command>/bin/true</command></action></keybind>
    <keybind key="A-space"><action name="Execute"><command>/bin/true</command></action></keybind>
  </keyboard>
  <mouse>
    <context name="Root"><mousebind button="Right" action="Press"></mousebind></context>
  </mouse>
  <applications>
    <application class="*">
      <decor>no</decor>
      <maximized>true</maximized>
      <fullscreen>yes</fullscreen>
    </application>
  </applications>
</openbox_config>
OBRC

# ── OPENBOX AUTOSTART ─────────────────────────────────────────────
cat > /home/liveuser/.config/openbox/autostart << 'OBSTART'
#!/bin/bash
LOG=/tmp/kiosk-autostart.log
SERIAL=/dev/ttyS0

slog() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"
    [ -w "$SERIAL" ] && echo "[KIOSK] $*" > "$SERIAL" 2>/dev/null || true
}

slog "=== Openbox autostart begin ==="

# ── SCREEN SETUP ──────────────────────────────────────────────────
# Force resolution to match GRUB's preferred 1024x768 (ensures consistency)
xrandr -s 1024x768 || xrandr --auto || true
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true
xset s noblank 2>/dev/null || true

# Apply background image (same as GRUB)
if [ -f "/usr/share/backgrounds/background.png" ]; then
    feh --bg-fill "/usr/share/backgrounds/background.png" 2>/dev/null || xsetroot -solid "#e0f7fa"
else
    xsetroot -solid "#e0f7fa"
fi

unclutter -idle 3 -root &
slog "Screen setup complete (1024x768 + background)"

# ── ENVIRONMENT ───────────────────────────────────────────────────
export DISPLAY=:0
export XDG_RUNTIME_DIR=/tmp/runtime-liveuser
export XDG_DATA_HOME=/home/liveuser/.local/share
export XDG_CONFIG_HOME=/home/liveuser/.config
export XDG_CACHE_HOME=/home/liveuser/.cache
export XDG_SESSION_TYPE=x11
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
export GDK_BACKEND=x11
export GTK_THEME=Adwaita
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# D-Bus
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
fi
slog "DBUS=${DBUS_SESSION_BUS_ADDRESS:-not set}"

# PulseAudio
pulseaudio --start --daemonize 2>/dev/null || true

# ── EXTRACT DIR & AppRun SETUP ────────────────────────────────────
EXTRACT_DIR="/opt/app/app_extracted"
APPIMAGE_ORIG="/opt/app/app.AppImage"
APP_RUN="${EXTRACT_DIR}/AppRun"

# WebKit exec path
if [ -d "${EXTRACT_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1" ]; then
    export WEBKIT_EXEC_PATH="${EXTRACT_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1"
elif [ -d "/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1" ]; then
    export WEBKIT_EXEC_PATH="/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1"
fi
slog "WEBKIT_EXEC_PATH=${WEBKIT_EXEC_PATH:-not set}"

# ── FIX 126: DIAGNOSE AND REPAIR PERMISSIONS ──────────────────────
# Exit code 126 = file exists but cannot be executed.
# Root causes: squashfs unpacked without exec bits, AppRun is a shell
# script whose interpreter is missing, or /opt has noexec mount.
# We fix all three here before the first launch attempt.

slog "--- Diagnosing AppRun (exit 126 prevention) ---"

if [ ! -d "$EXTRACT_DIR" ]; then
    slog "WARN: $EXTRACT_DIR missing — will use AppImage directly"
    APP_RUN="$APPIMAGE_ORIG"
else
    # 1. Log what AppRun actually is
    APPRUN_TYPE=$(file "$APP_RUN" 2>/dev/null || echo "file cmd failed")
    slog "AppRun type: $APPRUN_TYPE"

    # 2. Log permissions before fix
    APPRUN_PERMS=$(ls -la "$APP_RUN" 2>/dev/null || echo "ls failed")
    slog "AppRun perms before fix: $APPRUN_PERMS"

    # 3. FIX: chmod +x on AppRun AND every ELF binary in the extracted dir
    #    squashfs sometimes loses exec bits on extraction
    chmod +x "$APP_RUN" 2>/dev/null && slog "chmod +x AppRun: OK" || slog "chmod +x AppRun: FAILED (read-only?)"

    # Fix exec bits on all ELF binaries inside extracted dir
    find "$EXTRACT_DIR" -type f \( -name "*.so*" -o -perm /111 \) -exec chmod +x {} \; 2>/dev/null || true
    slog "chmod +x on all ELF files: done"

    # 4. Check if /opt is read-only or noexec
    # If chmod failed on a file we know should be writable/executable, we need to move to /tmp
    IS_READONLY=0
    touch "${EXTRACT_DIR}/.writable_test" 2>/dev/null && rm "${EXTRACT_DIR}/.writable_test" || IS_READONLY=1
    
    OPT_MOUNT_NOEXEC=$(mount | grep " /opt " | grep noexec || true)
    
    if [ $IS_READONLY -eq 1 ] || [ -n "$OPT_MOUNT_NOEXEC" ]; then
        slog "NOTICE: /opt is read-only or noexec. Copying to /tmp for execution..."
        cp -a "$EXTRACT_DIR" /tmp/app_extracted_tmp
        EXTRACT_DIR="/tmp/app_extracted_tmp"
        APP_RUN="${EXTRACT_DIR}/AppRun"
        chmod -R a+rX "$EXTRACT_DIR" 2>/dev/null || true
        slog "Using writable tmp copy: $EXTRACT_DIR"
    else
        slog "/opt mount: OK (writable and exec allowed)"
    fi

    # 5. Check AppRun shebang interpreter exists
    if file "$APP_RUN" 2>/dev/null | grep -qi "shell script\|text"; then
        SHEBANG=$(head -1 "$APP_RUN" 2>/dev/null || true)
        INTERP=$(echo "$SHEBANG" | sed 's|^#!||;s| .*||')
        slog "AppRun is a script, shebang: $SHEBANG"
        if [ -n "$INTERP" ] && [ ! -x "$INTERP" ]; then
            slog "ERROR: Interpreter missing: $INTERP"
            # Try to find alternative
            INTERP_NAME=$(basename "$INTERP")
            ALT=$(command -v "$INTERP_NAME" 2>/dev/null || true)
            if [ -n "$ALT" ]; then
                slog "Found alternative: $ALT — patching AppRun shebang"
                # Create a wrapper that calls the right interpreter
                ORIG_APPRUN="${APP_RUN}.orig"
                cp "$APP_RUN" "$ORIG_APPRUN"
                {
                    echo "#!${ALT}"
                    tail -n +2 "$ORIG_APPRUN"
                } > "$APP_RUN"
                chmod +x "$APP_RUN"
                slog "AppRun shebang patched to: $ALT"
            else
                slog "WARN: No alternative interpreter found for $INTERP_NAME"
            fi
        elif [ -n "$INTERP" ]; then
            slog "Interpreter exists: $INTERP OK"
        fi
    fi

    # 6. Log final permissions after fix
    APPRUN_PERMS_AFTER=$(ls -la "$APP_RUN" 2>/dev/null || echo "ls failed")
    slog "AppRun perms after fix:  $APPRUN_PERMS_AFTER"

    # 7. Final executable check
    if [ ! -x "$APP_RUN" ]; then
        slog "CRITICAL: AppRun still not executable after all fixes!"
        slog "Falling back to: $APPIMAGE_ORIG --appimage-extract-and-run"
        APP_RUN="$APPIMAGE_ORIG"
        export APPIMAGE_EXTRACT_AND_RUN=1
    fi
fi

slog "--- Diagnosis complete ---"
slog "Final APP_RUN: $APP_RUN"
slog "Is executable: $([ -x "$APP_RUN" ] && echo YES || echo NO)"

# ── SMART LIB STRIP (Re-enabled for WebKit/GLIBC compatibility) ──
# We MUST strip the bundled WebKit/JavaScriptCore because they require GLIBC 2.42
# while Debian 13 only has 2.41. Stripping forces the app to use system libs.
STRIP_DONE_FLAG="${EXTRACT_DIR}/.strip_done"
if [ -d "$EXTRACT_DIR" ] && [ ! -f "$STRIP_DONE_FLAG" ]; then
    slog "Running compatibility lib strip (targeting WebKit/GLIBC)..."
    # Target libraries that often have GLIBC version mismatches
    TARGET_STRIP="webkit|javascript|jsc|gst|soup|icu|webp"
    
    find "$EXTRACT_DIR" \( -name '*.so' -o -name '*.so.*' \) -type f 2>/dev/null | \
    grep -iE "$TARGET_STRIP" | \
    while read -r so_file; do
        LIB_NAME=$(basename "$so_file")
        if ldconfig -p 2>/dev/null | grep -qF "$LIB_NAME"; then
            slog "  Stripping incompatible bundled lib: $LIB_NAME"
            rm -f "$so_file"
        fi
    done
    touch "$STRIP_DONE_FLAG"
    slog "Compatibility strip done."
fi

# ── DYNAMIC LIBRARY PATH ──────────────────────────────────────────
# Ensure the app can find its own bundled libraries
if [ -d "$EXTRACT_DIR" ]; then
    # Find all directories containing .so files and add them to LD_LIBRARY_PATH
    SO_DIRS=$(find "$EXTRACT_DIR" -name "*.so*" -type f -printf '%h\n' 2>/dev/null | sort -u | tr '\n' ':')
    if [ -n "$SO_DIRS" ]; then
        export LD_LIBRARY_PATH="${SO_DIRS%:}:$LD_LIBRARY_PATH"
        slog "LD_LIBRARY_PATH updated"
    fi
fi

# ── CRASH-RESTART LOOP ────────────────────────────────────────────
MAX_CRASHES=15
CRASH_COUNT=0
CRASH_LOG=/tmp/app-crash.log

slog "Starting crash-restart loop (max $MAX_CRASHES)"

while [ $CRASH_COUNT -lt $MAX_CRASHES ]; do
    ATTEMPT=$((CRASH_COUNT + 1))
    slog "Launch attempt $ATTEMPT/$MAX_CRASHES: $APP_RUN"

    # Run with --no-sandbox (required in live env, no user namespaces)
    # Redirect both stdout and stderr to serial AND crash log
    "$APP_RUN" --no-sandbox 2>&1 | tee "$CRASH_LOG" | while IFS= read -r line; do
        echo "[APP] $line" >> "$LOG"
        [ -w "$SERIAL" ] && echo "[APP] $line" > "$SERIAL" 2>/dev/null || true
    done
    EXIT_CODE=${PIPESTATUS[0]}
    slog "Exited: code=$EXIT_CODE"

    # Capture crash output for diagnosis
    if [ -s "$CRASH_LOG" ]; then
        slog "--- last crash output ---"
        tail -20 "$CRASH_LOG" | while IFS= read -r line; do slog "  $line"; done
        > "$CRASH_LOG"
    fi

    # Exit code 126 special handling: re-run permission fix then retry once
    if [ $EXIT_CODE -eq 126 ] && [ $CRASH_COUNT -eq 0 ]; then
        slog "Exit 126 on first try — forcing chmod fix and retry"
        chmod -R +x "${EXTRACT_DIR}" 2>/dev/null || true
        sleep 1
        CRASH_COUNT=$((CRASH_COUNT + 1))
        continue
    fi

    [ $EXIT_CODE -eq 0 ] && { slog "App exited cleanly"; break; }

    CRASH_COUNT=$((CRASH_COUNT + 1))
    [ $CRASH_COUNT -ge $MAX_CRASHES ] && {
        slog "FATAL: $MAX_CRASHES crashes reached"
        command -v xterm >/dev/null && xterm -title "Kiosk Error - check $LOG" -geometry 120x40 &
        break
    }
    sleep 3
done &

slog "=== Autostart complete ==="
OBSTART

chown -R liveuser:liveuser /home/liveuser/.config

# ── .XINITRC ─────────────────────────────────────────────────────
cat > /home/liveuser/.xinitrc << 'XI'
#!/bin/sh
LOG=/tmp/liveuser-xinitrc.log

slog() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }
slog "xinitrc starting"

export DISPLAY=:0
export XDG_RUNTIME_DIR=/tmp/runtime-liveuser
export XDG_SESSION_TYPE=x11
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export GDK_BACKEND=x11

mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
sudo mkdir -p /tmp/.X11-unix && sudo chmod 1777 /tmp/.X11-unix

pulseaudio --start 2>/dev/null || true

slog "Launching openbox-session..."
exec openbox-session
XI
chmod +x /home/liveuser/.xinitrc

# ── BASH_PROFILE ─────────────────────────────────────────────────
cat > /home/liveuser/.bash_profile << 'BP'
if [[ -z $DISPLAY ]] && [[ $(tty) == /dev/tty1 ]]; then
    # Serial + X11 setup
    sudo chmod 666 /dev/ttyS0 2>/dev/null || true
    sudo mkdir -p /tmp/.X11-unix && sudo chmod 1777 /tmp/.X11-unix

    echo "[$(date '+%H:%M:%S')] Starting X from .bash_profile" > /dev/ttyS0 2>/dev/null || true

    startx -- -nolisten tcp vt1 >/tmp/xorg.log 2>&1
    X_EXIT=$?

    echo "[$(date '+%H:%M:%S')] X exited with code $X_EXIT" > /dev/ttyS0 2>/dev/null || true
    sleep 30
fi
BP
chown liveuser:liveuser /home/liveuser/.bash_profile /home/liveuser/.xinitrc

# ── HOSTNAME ─────────────────────────────────────────────────────
echo "HOSTNAME_PLACEHOLDER" > /etc/hostname
cat > /etc/hosts << 'HST'
127.0.0.1   localhost
127.0.1.1   HOSTNAME_PLACEHOLDER
HST

# ── FSTAB ────────────────────────────────────────────────────────
cat > /etc/fstab << 'FSTAB'
tmpfs /tmp     tmpfs defaults,noatime        0 0
tmpfs /var/log tmpfs defaults,noatime,size=128M 0 0
FSTAB

# FIX #6: Ensure fuse module loads at boot
echo 'fuse' >> /etc/modules

# ── NETWORKMANAGER ────────────────────────────────────────────────
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-auto-connect.conf << 'NM'
[main]
plugins=ifupdown,keyfile
autoconnect-retries-default=3

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
NM

mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/x11.conf << 'TMPF'
d /tmp/.X11-unix 1777 root root -
TMPF

mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-serial-access.rules << 'UDEV'
KERNEL=="ttyS[0-9]*", MODE="0666"
KERNEL=="ttyUSB[0-9]*", MODE="0666"
UDEV

# ── BOOT INIT SERVICE ─────────────────────────────────────────────
cat > /usr/local/bin/boot-init.sh << 'BINIT'
#!/bin/bash
chmod 666 /dev/ttyS0 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
mkdir -p /tmp/runtime-liveuser
chown liveuser:liveuser /tmp/runtime-liveuser 2>/dev/null || true
chmod 700 /tmp/runtime-liveuser
# Ensure fuse device exists for any AppImage fallback
modprobe fuse 2>/dev/null || true
chmod 666 /dev/fuse 2>/dev/null || true
BINIT
chmod +x /usr/local/bin/boot-init.sh

cat > /etc/systemd/system/boot-init.service << 'BISVC'
[Unit]
Description=Boot Initialization (Kiosk)
DefaultDependencies=no
Before=getty@tty1.service
After=systemd-udev-settle.service systemd-tmpfiles-setup.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/boot-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BISVC
systemctl enable boot-init.service 2>/dev/null || true

# ── OPTIONAL SSH ──────────────────────────────────────────────────
if [[ "ENABLE_SSH_PLACEHOLDER" == "1" ]]; then
    apt-get -qq install -y openssh-server
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl enable ssh
fi

# ── XWRAPPER ──────────────────────────────────────────────────────
cat > /etc/X11/Xwrapper.config << 'XWRAP'
allowed_users=anybody
needs_root_rights=yes
XWRAP

dpkg-query -W --showformat='${Package}\t${Version}\n' > /tmp/filesystem.manifest 2>/dev/null || true

# ── CLEANUP ───────────────────────────────────────────────────────
apt-get -qq autoremove --purge -y
apt-get -qq clean
rm -rf \
    /var/lib/apt/lists/* \
    /var/cache/apt/*.bin \
    /var/cache/debconf/* \
    /var/log/*.log /var/log/apt /var/log/journal \
    /usr/share/doc/* \
    /usr/share/man/* \
    /usr/share/info/* \
    /usr/share/locale/[!en]* \
    /usr/share/i18n/locales/[!en]* \
    /usr/share/pixmaps \
    /usr/share/sounds \
    /tmp/* \
    2>/dev/null || true

KERN_VER=$(ls /lib/modules 2>/dev/null | head -1)
if [[ -n "$KERN_VER" ]]; then
    depmod -a "$KERN_VER" 2>/dev/null || true
    update-initramfs -u -k "$KERN_VER" 2>/dev/null || true
fi

echo "OK — chroot setup complete"
CHROOT_EOF

    sed -i "s/RELEASE_PLACEHOLDER/${DEBIAN_RELEASE}/g" "$BUILD_DIR/chroot_setup.sh"
    sed -i "s/ARCH_PLACEHOLDER/${ARCH}/g"             "$BUILD_DIR/chroot_setup.sh"
    sed -i "s/HOSTNAME_PLACEHOLDER/${HOSTNAME_LIVE}/g" "$BUILD_DIR/chroot_setup.sh"
    sed -i "s/ENABLE_SSH_PLACEHOLDER/${ENABLE_SSH}/g"  "$BUILD_DIR/chroot_setup.sh"

    chmod +x "$BUILD_DIR/chroot_setup.sh"

    log "Injecting Plymouth theme..."
    mkdir -p "$ROOTFS_DIR/usr/share/plymouth/themes/kiosk-spinner"
    if [[ -d "$WORKDIR/plymouth_theme/kiosk-spinner" ]]; then
        cp -r "$WORKDIR/plymouth_theme/kiosk-spinner/"* \
              "$ROOTFS_DIR/usr/share/plymouth/themes/kiosk-spinner/"
    fi

    cp "$BUILD_DIR/chroot_setup.sh" "$ROOTFS_DIR/chroot_setup.sh"
    
    # Copy background image to rootfs for Openbox/feh
    mkdir -p "$ROOTFS_DIR/usr/share/backgrounds"
    if [[ -f "$WORKDIR/background.png" ]]; then
        cp "$WORKDIR/background.png" "$ROOTFS_DIR/usr/share/backgrounds/background.png"
    elif [[ -f "$WORKDIR/plymouth_theme/kiosk-spinner/background.png" ]]; then
        cp "$WORKDIR/plymouth_theme/kiosk-spinner/background.png" "$ROOTFS_DIR/usr/share/backgrounds/background.png"
    fi

    chroot "$ROOTFS_DIR" /bin/bash /chroot_setup.sh 2>&1 | tee -a "$LOG_FILE"
    rm -f "$ROOTFS_DIR/chroot_setup.sh"

    [[ -f "$ROOTFS_DIR/tmp/filesystem.manifest" ]] && \
        cp "$ROOTFS_DIR/tmp/filesystem.manifest" "$ISO_DIR/live/filesystem.manifest"

    for p in "${_MOUNTED_PATHS[@]:-}"; do
        mountpoint -q "$p" 2>/dev/null && umount -lf "$p" 2>/dev/null || true
    done
    _MOUNTED_PATHS=()

    ok "Rootfs configured  →  $(du -sh "$ROOTFS_DIR" | cut -f1)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. INJECT APP  ← KEY FIX: pre-extract AppImage at BUILD TIME
# ─────────────────────────────────────────────────────────────────────────────
inject_app() {
    step "INJECT APP  (pre-extracting AppImage at build time)"

    # Copy original AppImage (kept as fallback)
    cp "$APPIMAGE" "$APP_DIR/app.AppImage"
    chmod +x "$APP_DIR/app.AppImage"
    ok "AppImage copied: $(basename "$APPIMAGE")  ($(du -sh "$APPIMAGE" | cut -f1))"

    # ── FIX #1: PRE-EXTRACT at build time ─────────────────────────
    # This means the live system NEVER needs FUSE or runtime extraction.
    # The extracted files go into rootfs/opt/app/app_extracted/
    local EXTRACT_HOST_DIR="$APP_DIR/app_extracted"
    local EXTRACT_WORK_DIR="/tmp/appimage_extract_work_$$"

    log "Pre-extracting AppImage (this may take 2-5 min)..."
    mkdir -p "$EXTRACT_WORK_DIR"

    # Extract into a temp dir so we control the output location
    (
        cd "$EXTRACT_WORK_DIR"
        # unsquashfs extracts the AppImage's squashfs filesystem
        # AppImage format: ELF header + squashfs at offset
        # We use --appimage-extract via the AppImage itself
        chmod +x "$APPIMAGE"
        "$APPIMAGE" --appimage-extract 2>&1 || true
    )

    if [[ -d "$EXTRACT_WORK_DIR/squashfs-root" ]]; then
        log "Extraction successful via --appimage-extract"
        mv "$EXTRACT_WORK_DIR/squashfs-root" "$EXTRACT_HOST_DIR"
    else
        # Fallback: try unsquashfs directly (find squashfs offset)
        warn "Standard extraction failed, trying unsquashfs offset method..."
        local OFFSET
        OFFSET=$(grep -c "" /dev/null 2>/dev/null; \
                 od -A d -t x1 "$APPIMAGE" 2>/dev/null | \
                 grep "73 71 73 68" | head -1 | awk '{print $1}' || echo "")

        if [[ -n "$OFFSET" ]]; then
            unsquashfs -o "$OFFSET" -d "$EXTRACT_HOST_DIR" "$APPIMAGE" 2>&1 || {
                warn "unsquashfs with offset failed too"
            }
        fi

        if [[ ! -d "$EXTRACT_HOST_DIR" ]]; then
            warn "Pre-extraction failed completely — AppImage will run directly (needs FUSE at runtime)"
            warn "Set APPIMAGE_EXTRACT_AND_RUN=1 in autostart as fallback"
            rm -rf "$EXTRACT_WORK_DIR"
            # Patch autostart to use APPIMAGE_EXTRACT_AND_RUN=1 fallback
            sed -i 's/export APPIMAGE_EXTRACT_AND_RUN=0/export APPIMAGE_EXTRACT_AND_RUN=1/' \
                "$ROOTFS_DIR/home/liveuser/.config/openbox/autostart"
            return 0
        fi
    fi

    rm -rf "$EXTRACT_WORK_DIR"

    # Verify AppRun exists
    if [[ ! -f "$EXTRACT_HOST_DIR/AppRun" ]]; then
        warn "AppRun not found in extracted dir — checking for alternative entry points..."
        # Look for main binary
        local ALT_BIN
        ALT_BIN=$(find "$EXTRACT_HOST_DIR/usr/bin" -maxdepth 1 -type f -executable 2>/dev/null | head -1 || true)
        if [[ -n "$ALT_BIN" ]]; then
            warn "Creating AppRun wrapper pointing to: $ALT_BIN"
            # Use absolute path to the binary relative to the extraction root
            local REL_BIN_PATH="${ALT_BIN#$EXTRACT_HOST_DIR/}"
            cat > "$EXTRACT_HOST_DIR/AppRun" << APPRUN_EOF
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
exec "\$HERE/$REL_BIN_PATH" "\$@"
APPRUN_EOF
            chmod +x "$EXTRACT_HOST_DIR/AppRun"
        fi
    fi

    # Ensure EVERY file in the extracted directory is READABLE and EXECUTABLE.
    # This is critical because SquashFS is read-only at runtime.
    log "Setting recursive read/execution permissions..."
    chmod -R a+rX "$EXTRACT_HOST_DIR" 2>/dev/null || true

    ok "Pre-extracted: $EXTRACT_HOST_DIR  ($(du -sh "$EXTRACT_HOST_DIR" | cut -f1))"

    # ── COMPILE kiosk_launcher ─────────────────────────────────────
    local LAUNCHER_SRC="$WORKDIR/kiosk_launcher.c"
    if [[ -f "$LAUNCHER_SRC" ]]; then
        log "Compiling kiosk_launcher.c..."
        gcc -O2 -o "$WORKDIR/kiosk_launcher" "$LAUNCHER_SRC" 2>&1 && {
            cp "$WORKDIR/kiosk_launcher" "$ROOTFS_DIR/usr/local/bin/kiosk_launcher"
            chmod 4755 "$ROOTFS_DIR/usr/local/bin/kiosk_launcher"
            ok "kiosk_launcher compiled and installed (setuid root)"
        } || warn "kiosk_launcher compilation failed, skipping"
    fi

    # ── BUILD INFO ────────────────────────────────────────────────
    cat > "$ROOTFS_DIR/etc/live-build-info" << META
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ISO_LABEL=${ISO_LABEL}
ISO_VERSION=${ISO_VERSION}
DEBIAN_RELEASE=${DEBIAN_RELEASE}
ARCH=${ARCH}
APPIMAGE=$(basename "$APPIMAGE")
APPIMAGE_EXTRACTED=yes
EXTRACT_DIR=${APP_EXTRACT_DIR}
SQUASHFS_COMP=${SQUASHFS_COMP}
KIOSK_MODE=${KIOSK_MODE}
META

    ok "App injection complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. KERNEL & INITRD
# ─────────────────────────────────────────────────────────────────────────────
extract_kernel() {
    step "KERNEL + INITRD"

    local vmlinuz initrd
    vmlinuz=$(find "$ROOTFS_DIR/boot" -name 'vmlinuz-*' | sort -V | tail -1)
    initrd=$(find  "$ROOTFS_DIR/boot" -name 'initrd.img-*' | sort -V | tail -1)

    [[ -z "$vmlinuz" ]] && die "No kernel found in rootfs/boot"
    [[ -z "$initrd"  ]] && die "No initrd found in rootfs/boot"

    cp "$vmlinuz" "$ISO_DIR/live/vmlinuz"
    cp "$initrd"  "$ISO_DIR/live/initrd"
    cp "$vmlinuz" "$PXE_DIR/vmlinuz"
    cp "$initrd"  "$PXE_DIR/initrd"

    ok "Kernel : $(basename "$vmlinuz")"
    ok "Initrd : $(basename "$initrd")"
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. SQUASHFS
# ─────────────────────────────────────────────────────────────────────────────
make_squashfs() {
    step "SQUASHFS  (comp=$SQUASHFS_COMP)"

    local comp_opts=()
    case "$SQUASHFS_COMP" in
        xz)   comp_opts=(-Xdict-size 100% -Xbcj x86) ;;
        zstd) comp_opts=(-Xcompression-level 22) ;;
    esac

    mksquashfs "$ROOTFS_DIR" "$SQUASHFS_IMG" \
        -noappend \
        -e boot \
        -comp "$SQUASHFS_COMP" \
        -b "$SQUASHFS_BLOCK" \
        -processors "$PARALLEL_JOBS" \
        -no-exports \
        -no-xattrs \
        "${comp_opts[@]}" \
        2>&1 | tail -5

    cp "$SQUASHFS_IMG" "$PXE_DIR/filesystem.squashfs"
    ok "SquashFS: $(du -sh "$SQUASHFS_IMG" | cut -f1)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. GRUB  (BIOS + UEFI)
# ─────────────────────────────────────────────────────────────────────────────
build_grub() {
    step "GRUB  (BIOS + UEFI)"

    # Redirection for serial console + removal of quiet splash to debug black screen
    local cmdline="boot=live loglevel=7 console=ttyS0,115200 console=tty0 vt.global_cursor_default=0"
    [[ "$ENABLE_PERSISTENCE" == "1" ]] && cmdline+=" persistence"

    mkdir -p "$ISO_DIR/boot/grub/fonts"
    mkdir -p "$ISO_DIR/boot/grub/themes/custom"

    [ -f /usr/share/grub/unicode.pf2 ] && cp /usr/share/grub/unicode.pf2 "$ISO_DIR/boot/grub/fonts/"

    if [[ -d "$WORKDIR/iso_root/boot/grub/themes/custom" ]]; then
        cp -r "$WORKDIR/iso_root/boot/grub/themes/custom/"* "$ISO_DIR/boot/grub/themes/custom/"
    fi

    if [[ -f "$WORKDIR/plymouth_theme/kiosk-spinner/background.png" ]]; then
        cp "$WORKDIR/plymouth_theme/kiosk-spinner/background.png" "$ISO_DIR/boot/grub/background.png"
    elif [[ -f "$WORKDIR/background.png" ]]; then
        cp "$WORKDIR/background.png" "$ISO_DIR/boot/grub/background.png"
    fi

    local grub_embed_dir="$BUILD_DIR/grub_embed/boot/grub"
    mkdir -p "$grub_embed_dir"

    cat > "$grub_embed_dir/grub.cfg" << GCFG
search --no-floppy --set=root --file /live/vmlinuz
set prefix=(\$root)/boot/grub

set timeout=${BOOT_TIMEOUT}
set default=0

insmod all_video
insmod gfxterm
insmod gfxmenu
insmod png
insmod jpeg

loadfont (\$root)/boot/grub/fonts/unicode.pf2

set gfxmode=1024x768x32,800x600x32,auto
terminal_output gfxterm

set theme=(\$root)/boot/grub/themes/custom/theme.txt
export theme
background_image (\$root)/boot/grub/background.png

menuentry "D-Secure Drive Eraser" {
    set gfxpayload=keep
    linux (\$root)/live/vmlinuz ${cmdline}
    initrd (\$root)/live/initrd
}

menuentry "Shutdown" {
    halt
}

menuentry "Reboot" {
    reboot
}
GCFG

    log "Building GRUB BIOS image..."
    grub-mkstandalone \
        --format=i386-pc \
        --output="$ISO_DIR/boot/grub/core.img" \
        --install-modules="linux normal iso9660 biosdisk memdisk search tar ls part_gpt part_msdos all_video gfxterm gfxmenu png jpeg font video_bochs video_cirrus" \
        --modules="linux normal iso9660 biosdisk search part_gpt part_msdos all_video gfxterm gfxmenu png font" \
        --locales="" --fonts="" --themes="" \
        "boot/grub/grub.cfg=$grub_embed_dir/grub.cfg" || die "grub-mkstandalone BIOS failed"

    cat /usr/lib/grub/i386-pc/cdboot.img "$ISO_DIR/boot/grub/core.img" \
        > "$ISO_DIR/boot/grub/bios.img"

    log "Building GRUB EFI image..."
    mkdir -p "$ISO_DIR/EFI/BOOT"
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$ISO_DIR/EFI/BOOT/BOOTx64.EFI" \
        --install-modules="linux normal iso9660 efi_gop efi_uga all_video search part_gpt part_msdos gfxterm gfxmenu gfxterm_background png font video_bochs video_cirrus" \
        --locales="" --fonts="" --themes="" \
        "boot/grub/grub.cfg=$grub_embed_dir/grub.cfg" || die "grub-mkstandalone UEFI failed"

    local efi_img="$ISO_DIR/boot/grub/efi.img"
    dd if=/dev/zero of="$efi_img" bs=1M count=4 status=none
    mkfs.fat -F 12 -n "EFI" "$efi_img" &>/dev/null
    mmd -i "$efi_img" ::/EFI ::/EFI/BOOT
    mcopy -i "$efi_img" "$ISO_DIR/EFI/BOOT/BOOTx64.EFI" ::/EFI/BOOT/

    ok "GRUB BIOS + UEFI ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. PXE CONFIG
# ─────────────────────────────────────────────────────────────────────────────
build_pxe_config() {
    step "PXE CONFIG"
    mkdir -p "$PXE_DIR/pxelinux.cfg"
    local cmdline="boot=live quiet splash loglevel=0 vt.global_cursor_default=0 fetch=tftp://TFTP_SERVER_IP/filesystem.squashfs"

    cat > "$PXE_DIR/pxelinux.cfg/default" << PXE
DEFAULT live
TIMEOUT 50
PROMPT 0

LABEL live
  MENU LABEL ${ISO_LABEL} ${ISO_VERSION} (Live)
  LINUX  vmlinuz
  APPEND initrd=initrd ${cmdline}
  IPAPPEND 2

LABEL verbose
  MENU LABEL ${ISO_LABEL} (verbose)
  LINUX  vmlinuz
  APPEND initrd=initrd ${cmdline/quiet/} loglevel=7
  IPAPPEND 2
PXE

    cat > "$PXE_DIR/boot.ipxe" << IPXE
#!ipxe
set base-url tftp://\${next-server}
kernel \${base-url}/vmlinuz boot=live quiet splash loglevel=0 vt.global_cursor_default=0 fetch=\${base-url}/filesystem.squashfs
initrd \${base-url}/initrd
boot
IPXE

    ok "PXE config written"
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. BUILD ISO
# ─────────────────────────────────────────────────────────────────────────────
build_iso() {
    step "BUILD ISO  →  $ISO_OUT"
    local isohdpfx="/usr/lib/ISOLINUX/isohdpfx.bin"
    local hybrid_args=()
    [[ -f "$isohdpfx" ]] && hybrid_args=(-isohybrid-mbr "$isohdpfx")

    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "$ISO_LABEL" \
        -preparer "kiosk-builder v3.2" \
        -publisher "$ISO_LABEL $ISO_VERSION" \
        -eltorito-boot boot/grub/bios.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --eltorito-catalog boot/grub/boot.cat \
        -eltorito-alt-boot \
            -e boot/grub/efi.img \
            -no-emul-boot \
        "${hybrid_args[@]}" \
        -o "$ISO_OUT" \
        "$ISO_DIR"

    [[ -f "$ISO_OUT" ]] || die "ISO creation failed"
    ok "ISO created: $ISO_OUT  ($(du -sh "$ISO_OUT" | cut -f1))"
}

# ─────────────────────────────────────────────────────────────────────────────
# 12. CHECKSUMS
# ─────────────────────────────────────────────────────────────────────────────
generate_checksums() {
    step "CHECKSUMS"
    local cs_file="$WORKDIR/${ISO_LABEL,,}-${ISO_VERSION}.sha256"
    {
        sha256sum "$ISO_OUT"
        sha256sum "$PXE_DIR/vmlinuz"
        sha256sum "$PXE_DIR/initrd"
        sha256sum "$PXE_DIR/filesystem.squashfs"
    } | tee "$cs_file"
    ok "Checksums → $cs_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# 13. SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
    local elapsed=$(( $(date +%s) - BUILD_START ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))

    hr
    printf "${BOLD}${GRN}  BUILD COMPLETE  ${RST}\n\n"
    printf "  %-22s %s\n" "ISO"            "$ISO_OUT"
    printf "  %-22s %s\n" "ISO size"       "$(du -sh "$ISO_OUT" | cut -f1)"
    printf "  %-22s %s\n" "SquashFS"       "$(du -sh "$SQUASHFS_IMG" | cut -f1)"
    printf "  %-22s %s\n" "PXE files"      "$PXE_DIR/"
    printf "  %-22s %s\n" "Build log"      "$LOG_FILE"
    printf "  %-22s %s\n" "Kiosk mode"     "$( [[ "$KIOSK_MODE" == "1" ]] && echo 'ENABLED' || echo 'disabled' )"
    printf "  %-22s %s\n" "AppImage mode"  "pre-extracted (no FUSE needed)"
    printf "  %-22s %dm %ds\n" "Build time" "$mins" "$secs"
    hr
    printf "\n  ${CYN}Test with QEMU:${RST}\n"
    printf "  qemu-system-x86_64 -cdrom %s -m 3G -enable-kvm -vga std -serial stdio\n\n" \
        "$(basename "$ISO_OUT")"
    printf "  ${CYN}Debug: watch serial output for crash logs${RST}\n\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# 14. MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1

    printf "${BOLD}${BLU}"
    cat << 'BANNER'
  ╔════════════════════════════════════════════╗
  ║   KIOSK LIVE ISO + PXE BUILDER  v3.2       ║
  ║   AppImage Fixed · No FUSE · Debian        ║
  ╚════════════════════════════════════════════╝
BANNER
    printf "${RST}"

    {
        echo "═══════════════════════════════════════════════════════════"
        echo "BUILD LOG — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "═══════════════════════════════════════════════════════════"
        echo "Host     : $(uname -a)"
        echo "Debian   : $DEBIAN_RELEASE / $ARCH"
        echo "Compress : $SQUASHFS_COMP / $SQUASHFS_BLOCK"
        echo "Kiosk    : $( [[ "$KIOSK_MODE" == "1" ]] && echo 'ENABLED' || echo 'disabled' )"
        echo "Mirror   : $MIRROR"
        echo "Parallel : $PARALLEL_JOBS cores"
        echo "AppImage : pre-extract at build time (FIX #1)"
        echo "═══════════════════════════════════════════════════════════"
    } >> "$LOG_FILE"

    log "Build started at $(date)"

    cleanup_old_builds
    preflight
    bootstrap_rootfs
    configure_rootfs
    inject_app        # ← AppImage extracted here, not at runtime
    extract_kernel
    make_squashfs
    build_grub
    build_pxe_config
    build_iso
    generate_checksums
    print_summary

    echo "BUILD COMPLETED SUCCESSFULLY at $(date)" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI ARGS
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat << HELP
Usage: sudo $0 [OPTIONS]
  --release RELEASE   Debian release  (default: bookworm)
  --arch    ARCH      Architecture    (default: amd64)
  --mirror  URL       Apt mirror
  --label   LABEL     ISO volume label
  --comp    ALGO      SquashFS: xz|zstd|lz4|gzip  (default: xz)
  --ssh               Enable SSH server
  --persistence       Enable live persistence
  --kiosk             Enable kiosk mode (default: on)
  --no-kiosk          Disable kiosk mode
  --timeout N         GRUB timeout seconds (default: 5)
  --dry-run           Show plan only
  --help              This help
HELP
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --release)     DEBIAN_RELEASE="$2"; shift 2 ;;
        --arch)        ARCH="$2"; shift 2 ;;
        --mirror)      MIRROR="$2"; shift 2 ;;
        --label)       ISO_LABEL="$2"; shift 2 ;;
        --comp)        SQUASHFS_COMP="$2"; shift 2 ;;
        --ssh)         ENABLE_SSH=1; shift ;;
        --persistence) ENABLE_PERSISTENCE=1; shift ;;
        --kiosk)       KIOSK_MODE=1; shift ;;
        --no-kiosk)    KIOSK_MODE=0; shift ;;
        --timeout)     BOOT_TIMEOUT="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --help|-h)     usage; exit 0 ;;
        *) die "Unknown option: $1  (use --help)" ;;
    esac
done

[[ "$DRY_RUN" == "1" ]] && { log "Dry run — exiting"; exit 0; }
main