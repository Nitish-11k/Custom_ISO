#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║          KIOSK LIVE ISO + PXE BUILDER  v3.0                             ║
# ║          Pure Debian Bookworm · Tauri v2 · BIOS/UEFI Hybrid             ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# 0. EARLY HELPERS  (needed before config loads)
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_START=$(date +%s)

# Colour palette
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
need_cmd()     { command -v "$1" &>/dev/null || die "Missing: $1  →  apt-get install $2"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. CONFIGURATION  (override via build.conf or env vars)
# ─────────────────────────────────────────────────────────────────────────────
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"
BUILD_DIR="${BUILD_DIR:-$WORKDIR/pxe_build}"

# Debian
DEBIAN_RELEASE="${DEBIAN_RELEASE:-bookworm}"
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

# Image identity
ISO_LABEL="${ISO_LABEL:-LIVE_OS}"
ISO_VERSION="${ISO_VERSION:-$(date +%Y%m%d)}"
HOSTNAME_LIVE="${HOSTNAME_LIVE:-live-system}"

# Compression  (xz | zstd | lz4 | gzip)
SQUASHFS_COMP="${SQUASHFS_COMP:-xz}"
SQUASHFS_BLOCK="${SQUASHFS_BLOCK:-1M}"

# Features
ENABLE_SSH="${ENABLE_SSH:-0}"
ENABLE_PERSISTENCE="${ENABLE_PERSISTENCE:-0}"
KIOSK_MODE="${KIOSK_MODE:-1}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-5}"
DRY_RUN="${DRY_RUN:-0}"
PARALLEL_JOBS="${PARALLEL_JOBS:-$(nproc)}"

# Load user overrides
[[ -f "$WORKDIR/build.conf" ]] && { log "Loading build.conf"; source "$WORKDIR/build.conf"; }

# Derived paths (read-only after config)
readonly ROOTFS_DIR="$BUILD_DIR/rootfs"
readonly ISO_DIR="$BUILD_DIR/iso"
readonly PXE_DIR="$BUILD_DIR/pxe"
readonly APP_DIR="$ROOTFS_DIR/opt/app"
readonly SQUASHFS_IMG="$ISO_DIR/live/filesystem.squashfs"
readonly ISO_OUT="$WORKDIR/${ISO_LABEL,,}-${ISO_VERSION}-${ARCH}.iso"
readonly LOG_FILE="$WORKDIR/build-${ISO_VERSION}.log"

# ─────────────────────────────────────────────────────────────────────────────
# 2. TRAP — guaranteed cleanup on any exit
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
# 2b. CLEANUP OLD BUILDS
# ─────────────────────────────────────────────────────────────────────────────
cleanup_old_builds() {
    step "CLEANUP OLD BUILDS"

    # Unmount any stale mounts from previous failed builds
    if [[ -d "$ROOTFS_DIR" ]]; then
        for mp in "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys"; do
            mountpoint -q "$mp" 2>/dev/null && {
                log "Unmounting stale: $mp"
                umount -lf "$mp" 2>/dev/null || true
            }
        done
    fi

    # Archive previous build log
    if [[ -f "$LOG_FILE" ]]; then
        local prev_log="${LOG_FILE%.log}-prev.log"
        mv "$LOG_FILE" "$prev_log" 2>/dev/null || true
        log "Previous log archived → $(basename "$prev_log")"
    fi

    # Remove old ISOs with same label
    local old_isos
    old_isos=$(find "$WORKDIR" -maxdepth 1 -name "${ISO_LABEL,,}-*.iso" -type f 2>/dev/null)
    if [[ -n "$old_isos" ]]; then
        echo "$old_isos" | while read -r f; do
            log "Removing old ISO: $(basename "$f")"
            rm -f "$f"
        done
    fi

    # Remove old checksums
    rm -f "$WORKDIR"/${ISO_LABEL,,}-*.sha256 2>/dev/null || true

    # Remove old build directory
    if [[ -d "$BUILD_DIR" ]]; then
        log "Removing old build dir: $BUILD_DIR"
        rm -rf "$BUILD_DIR"
    fi

    ok "Cleanup complete — fresh build environment"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
    step "PRE-FLIGHT"
    require_root

    # Detect AppImage (search up to 2 levels deep)
    APPIMAGE=$(find "$WORKDIR" -maxdepth 2 -name "*.AppImage" -type f | sort | head -n1 || true)
    [[ -z "$APPIMAGE" ]] && die "No *.AppImage found in $WORKDIR (searched 2 levels)"
    ok "AppImage : $APPIMAGE"

    # Detect optional assets
    BACKGROUND=$(find "$WORKDIR" -maxdepth 2 -name "background.png" 2>/dev/null | head -n1 || true)
    SPLASH=$(find "$WORKDIR" -maxdepth 2 -name "splash.png"     2>/dev/null | head -n1 || true)
    [[ -n "$BACKGROUND" ]] && ok "Background: $BACKGROUND"
    [[ -n "$SPLASH"     ]] && ok "Splash    : $SPLASH"

    # Required host tools — auto-install if missing
    local tools=(debootstrap mksquashfs xorriso grub-mkstandalone mtools file sha256sum)
    local MISSING_TOOLS=()
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || MISSING_TOOLS+=("$t")
    done

    # Also check GRUB modules exist
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
            curl file ca-certificates
    fi

    # Verify GRUB modules
    [[ -f /usr/lib/grub/i386-pc/cdboot.img ]] || die "Missing GRUB BIOS modules — apt install grub-pc-bin"
    [[ -d /usr/lib/grub/x86_64-efi ]]        || die "Missing GRUB EFI modules — apt install grub-efi-amd64-bin"

    # AppImage sanity
    file "$APPIMAGE" | grep -qiE 'ELF|executable' || \
        warn "AppImage may not be executable — check it manually"

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

    # Bind mounts
    bind_mount /dev     "$ROOTFS_DIR/dev"
    bind_mount /dev/pts "$ROOTFS_DIR/dev/pts"
    bind_mount /proc    "$ROOTFS_DIR/proc"
    bind_mount /sys     "$ROOTFS_DIR/sys"

    # Inject resolv.conf for network access inside chroot
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    # Build chroot payload
    cat > "$BUILD_DIR/chroot_setup.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

# ── SMART PACKAGE INSTALLER ──────────────────────────────────────
# Verifies each package exists before installing. Tries alternatives.
# Usage: safe_install pkg1 pkg2 ...
# Usage with alternatives: safe_install "primary|fallback1|fallback2" pkg2 ...
INSTALL_LOG="/tmp/pkg-install.log"
FAILED_PKGS=""

safe_install() {
    local verified=()
    for spec in "$@"; do
        # Support alternatives: "pkg1|pkg2|pkg3"
        local found=""
        IFS='|' read -ra alternatives <<< "$spec"
        for candidate in "${alternatives[@]}"; do
            candidate=$(echo "$candidate" | xargs)  # trim whitespace
            if apt-cache show "$candidate" >/dev/null 2>&1; then
                verified+=("$candidate")
                found=1
                break
            fi
        done
        if [[ -z "$found" ]]; then
            echo "  [SKIP] None of these found: $spec" | tee -a "$INSTALL_LOG"
            FAILED_PKGS="$FAILED_PKGS $spec"
        fi
    done
    if [[ ${#verified[@]} -gt 0 ]]; then
        apt-get -qq install -y --no-install-recommends "${verified[@]}" 2>&1 || {
            echo "  [WARN] Batch install failed, trying one-by-one..." | tee -a "$INSTALL_LOG"
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
echo "=== Package verification & install ==="

# ── CORE SYSTEM ──────────────────────────────────────────────────
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

# ── GENERATE LOCALE ──────────────────────────────────────────────
echo "[1.5/8] Generating locales..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# ── XORG + DISPLAY ──────────────────────────────────────────────
echo "[2/8] Display server + drivers..."
safe_install \
    xserver-xorg \
    xserver-xorg-core \
    xserver-xorg-input-all \
    xserver-xorg-video-all \
    xinit x11-xserver-utils \
    openbox \
    unclutter \
    fuse3 libfuse2 \
    fonts-dejavu-core fonts-liberation2

# ── TAURI v2.10 RUNTIME (verified against official tauri.app docs) ─────
echo "[3/8] Tauri v2.10 / WebKitGTK runtime..."
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
    libva2 \
    libnss3 libnspr4 \
    "libwebp7|libwebp6" \
    "libwebpdemux2|libwebpdemux" \
    "libwebpmux3|libwebpmux2" \
    "libwoff1|libwoff-dev" \
    libgudev-1.0-0 \
    liborc-0.4-0 \
    gsettings-desktop-schemas \
    libssl3 \
    librsvg2-2 librsvg2-common \
    "libxdo3|libxdo-dev" \
    "libayatana-appindicator3-1|libappindicator3-1" \
    libdbus-1-3

# ── BACKPORTS UPGRADE — GLIBC 2.38 FIX ──────────────────────────
# The AppImage bundles libs built against GLIBC 2.38+, but Bookworm
# ships GLIBC 2.36. Upgrading these 4 libs from backports provides
# GLIBC 2.38-compatible versions so bundled libs can be stripped safely.
echo "[3.5/8] Upgrading critical libs from backports (GLIBC fix)..."
apt-get -qq install -y -t RELEASE_PLACEHOLDER-backports \
    libglib2.0-0 \
    libgtk-3-0 \
    libcairo2 \
    libgdk-pixbuf-2.0-0 \
    2>&1 || echo "  [WARN] Backports upgrade failed — bundled lib stripping may not work"

# Rebuild ldconfig cache after all installs so runtime can find system libs
ldconfig 2>/dev/null || true

# ── NETWORK ──────────────────────────────────────────────────────
echo "[4/8] Network manager..."
safe_install network-manager

# ── STORAGE ──────────────────────────────────────────────────────
echo "[5/8] Storage support..."
safe_install udisks2 ntfs-3g dosfstools e2fsprogs

# ── AUDIO ────────────────────────────────────────────────────────
echo "[6/8] Audio..."
safe_install pulseaudio alsa-utils

# ── FIRMWARE (i915, tg3, etc.) ───────────────────────────────────
echo "[7/8] Firmware..."
safe_install \
    firmware-linux-free \
    "firmware-misc-nonfree|firmware-linux-nonfree" \
    "firmware-intel-sound|firmware-sof-signed"

# ── PLYMOUTH SPLASH ──────────────────────────────────────────────
echo "[7.5/8] Plymouth splash..."
safe_install plymouth plymouth-themes
mkdir -p /usr/share/plymouth/themes/kiosk-spinner
# Files are copied from host into this dir before chroot
plymouth-set-default-theme -R kiosk-spinner || true
update-initramfs -u || true


# ── AUTO-DOWNLOAD MISSING FIRMWARE ───────────────────────────────
# Run update-initramfs, capture firmware warnings, try to download
echo "    Checking for missing firmware..."
FW_WARNINGS=$(update-initramfs -u 2>&1 | grep 'W: Possible missing firmware' || true)
if [[ -n "$FW_WARNINGS" ]]; then
    echo "$FW_WARNINGS" | while IFS= read -r line; do
        FW_PATH=$(echo "$line" | grep -oP '/lib/firmware/\S+')
        if [[ -n "$FW_PATH" ]] && [[ ! -f "$FW_PATH" ]]; then
            FW_NAME=$(echo "$FW_PATH" | sed 's|/lib/firmware/||')
            echo "    [DL] Trying: $FW_NAME"
            mkdir -p "$(dirname "$FW_PATH")"
            # Try kernel.org linux-firmware repo
            curl -sL --max-time 10 \
                "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/${FW_NAME}" \
                -o "$FW_PATH" 2>/dev/null && {
                    # Verify it's not an HTML error page
                    if file "$FW_PATH" | grep -qiE 'HTML|text'; then
                        rm -f "$FW_PATH"
                        echo "    [SKIP] $FW_NAME (not in kernel.org repo)"
                    else
                        echo "    [OK] Downloaded: $FW_NAME"
                    fi
                } || echo "    [SKIP] $FW_NAME (download failed)"
        fi
    done
    # Rebuild initramfs with any new firmware
    update-initramfs -u 2>/dev/null || true
fi

# ── Report skipped packages ──────────────────────────────────────
if [[ -n "$FAILED_PKGS" ]]; then
    echo ""
    echo "=== SKIPPED PACKAGES (not in repo) ==="
    echo "$FAILED_PKGS"
    echo "======================================="
fi

# ── SYSTEM CONFIGURATION ────────────────────────────────────────
echo "[8/8] Configuring system..."

# ── DBUS MACHINE-ID ──────────────────────────────────────────────
dbus-uuidgen > /etc/machine-id 2>/dev/null || true
mkdir -p /var/lib/dbus
cp /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

# ── AUTO-LOGIN (TTY1) ────────────────────────────────────────────
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'SVC'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin liveuser --noclear %I $TERM
SVC

# ── DISABLE EXTRA TTYs (kiosk lockdown) ──────────────────────────
for tty in tty2 tty3 tty4 tty5 tty6; do
    systemctl mask "getty@${tty}.service" 2>/dev/null || true
done

# ── LIVE USER ────────────────────────────────────────────────────
useradd -m -s /bin/bash -G sudo,video,audio,input,plugdev,dialout,tty liveuser 2>/dev/null || true
echo 'liveuser:live' | chpasswd
mkdir -p /etc/sudoers.d
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/liveuser
chmod 0440 /etc/sudoers.d/liveuser

# ── OPENBOX KIOSK CONFIG ────────────────────────────────────────
mkdir -p /home/liveuser/.config/openbox

# rc.xml — fullscreen, no decorations, block shortcuts
cat > /home/liveuser/.config/openbox/rc.xml << 'OBRC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance><strength>0</strength><screen_edge_strength>0</screen_edge_strength></resistance>
  <focus><followMouse>no</followMouse></focus>
  <theme><name>Clearlooks</name><titleLayout></titleLayout></theme>
  <desktops><number>1</number></desktops>
  <keyboard>
    <!-- Block all dangerous shortcuts -->
    <keybind key="A-F4"><action name="Execute"><command>/bin/true</command></action></keybind>
    <keybind key="A-Tab"><action name="Execute"><command>/bin/true</command></action></keybind>
    <keybind key="A-F2"><action name="Execute"><command>/bin/true</command></action></keybind>
    <keybind key="C-A-Delete"><action name="Execute"><command>/bin/true</command></action></keybind>
    <keybind key="A-space"><action name="Execute"><command>/bin/true</command></action></keybind>
    <keybind key="S-A-Tab"><action name="Execute"><command>/bin/true</command></action></keybind>
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

# autostart — launch app with crash-restart loop + serial logging
cat > /home/liveuser/.config/openbox/autostart << 'OBSTART'
slog() { echo "[AUTOSTART] $(date '+%H:%M:%S') $*" >> /tmp/liveuser-boot.log; [ -w /dev/ttyS0 ] && echo "[AUTOSTART] $(date '+%H:%M:%S') $*" > /dev/ttyS0; }
slog "Openbox autostart running"

# Disable screen blanking
xset s off 2>/dev/null
xset -dpms 2>/dev/null
xset s noblank 2>/dev/null
slog "Screen blanking disabled"

# Hide cursor after 3 seconds idle
unclutter -idle 3 -root &

# Set black background
xsetroot -solid black 2>/dev/null

# Source Tauri Environment
if [ -f /tmp/tauri-env.sh ]; then
    . /tmp/tauri-env.sh
else
    # AppImage fallback: extract-and-run if FUSE unavailable
    export APPIMAGE_EXTRACT_AND_RUN=1
fi

# Check AppImage exists
if [ ! -f /opt/app/app.AppImage ]; then
    slog "FATAL: /opt/app/app.AppImage NOT FOUND"
else
    slog "AppImage found: $(ls -la /opt/app/app.AppImage)"
fi

# ══════════════════════════════════════════════════════════════════
# BULLETPROOF GLIBC FIX v2 — smart scan + system replacement check
# ══════════════════════════════════════════════════════════════════
# The AppImage was built on a newer glibc system (2.38+). We:
#   1. Extract the AppImage
#   2. Auto-detect bundled libs needing higher GLIBC than system
#   3. ONLY remove them if system has a matching replacement
#   4. Keep bundled libs the system doesn't have (e.g. libicuuc.so.74)
#   5. Set LD_LIBRARY_PATH so system GLIBC is used but app libs are kept
#   6. Verify with ldd before launching
# ══════════════════════════════════════════════════════════════════
EXTRACT_DIR="/tmp/app_extracted"

# Step 1: Extract
slog "Pre-extracting AppImage to $EXTRACT_DIR..."
rm -rf "$EXTRACT_DIR" /tmp/squashfs-root
cd /tmp && /opt/app/app.AppImage --appimage-extract > /dev/null 2>&1
if [ -d /tmp/squashfs-root ]; then
    mv /tmp/squashfs-root "$EXTRACT_DIR"
    slog "AppImage extracted OK: $(du -sh $EXTRACT_DIR | cut -f1)"
else
    slog "FATAL: AppImage extraction failed!"
fi

# Step 2: Detect system GLIBC version
SYS_GLIBC_VER=$(ldd --version 2>&1 | head -1 | grep -oP '[0-9]+\.[0-9]+$' || echo "2.36")
slog "System GLIBC: $SYS_GLIBC_VER"

# Step 3: Build system library cache for fast lookups
# CRITICAL: Rebuild ldconfig first — live overlay may have empty cache
ldconfig 2>/dev/null || true
ldconfig -p 2>/dev/null > /tmp/ldconfig_cache.txt
slog "System lib cache: $(wc -l < /tmp/ldconfig_cache.txt) entries"

# Step 4: Smart scan — only strip if system has a replacement
slog "Smart-scanning bundled libs for GLIBC conflicts..."
STRIPPED=0
KEPT=0
find "$EXTRACT_DIR" -name '*.so*' -type f 2>/dev/null | while read -r so_file; do
    LIB_NAME=$(basename "$so_file")
    # Check what GLIBC versions this .so needs
    NEEDED=$(objdump -p "$so_file" 2>/dev/null | grep -oP 'GLIBC_\K[0-9]+\.[0-9]+' | sort -V | tail -1)
    if [ -n "$NEEDED" ]; then
        # Only act if bundled lib needs higher GLIBC than system
        if [ "$(printf '%s\n%s' "$SYS_GLIBC_VER" "$NEEDED" | sort -V | tail -1)" != "$SYS_GLIBC_VER" ]; then
            # Check if system has this EXACT lib name (matching soname)
            if grep -qF "$LIB_NAME" /tmp/ldconfig_cache.txt 2>/dev/null; then
                # System has it — safe to strip, system version will be used
                rm -f "$so_file"
                slog "Stripped: $LIB_NAME (system has replacement)"
                STRIPPED=$((STRIPPED + 1))
            else
                # System does NOT have this lib — keep the bundled copy!
                # But it needs GLIBC 2.38+ which we don't have.
                # Solution: check if it's a core lib or just a dependency
                slog "KEPT: $LIB_NAME (needs GLIBC_$NEEDED, no system replacement)"
                KEPT=$((KEPT + 1))
            fi
        fi
    fi
done
slog "Stripped $STRIPPED libs (system replacements exist)"
slog "Kept $KEPT libs (no system replacement available)"

# Step 5: For kept libs that need higher GLIBC, we need to provide
# a compatible environment. Set LD_LIBRARY_PATH so:
#   - System's libc/ld-linux are found first (GLIBC 2.36)
#   - AppImage's own libs are found next for app-specific deps
# This works because the kept libs may have sub-deps already in the bundle
APP_LIB_DIRS=$(find "$EXTRACT_DIR" -name '*.so*' -type f -printf '%h\n' 2>/dev/null | sort -u | tr '\n' ':')
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:${APP_LIB_DIRS%:}"
slog "LD_LIBRARY_PATH set: $(echo $LD_LIBRARY_PATH | tr ':' '\n' | wc -l) dirs"

# Step 6: Find the main executable binary
MAIN_BIN=""
if [ -f "$EXTRACT_DIR/AppRun" ]; then
    if file "$EXTRACT_DIR/AppRun" 2>/dev/null | grep -qi "elf"; then
        MAIN_BIN="$EXTRACT_DIR/AppRun"
    else
        # AppRun is a script — find the actual binary
        MAIN_BIN=$(find "$EXTRACT_DIR/usr/bin" -type f -executable 2>/dev/null | head -1)
        [ -z "$MAIN_BIN" ] && MAIN_BIN=$(find "$EXTRACT_DIR" -maxdepth 2 -type f -executable \( -name '*.bin' -o -name 'app' -o -name 'App' \) 2>/dev/null | head -1)
    fi
fi
[ -z "$MAIN_BIN" ] && MAIN_BIN="$EXTRACT_DIR/AppRun"
slog "Main binary: $MAIN_BIN"

# Step 7: Pre-launch ldd check
slog "Running pre-launch library validation..."
MISSING_LIBS=$(LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ldd "$MAIN_BIN" 2>&1 | grep "not found" | awk '{print $1}' || true)
if [ -n "$MISSING_LIBS" ]; then
    slog "Missing libs detected, attempting auto-fix..."
    for lib in $MISSING_LIBS; do
        # Search system AND extracted dirs for this lib
        SYS_LIB=$(find /usr/lib /lib -name "$lib" -type f 2>/dev/null | head -1)
        if [ -z "$SYS_LIB" ]; then
            # Try without exact version (libfoo.so.1 -> libfoo.so.*)
            LIB_STEM=$(echo "$lib" | sed 's/\.[0-9]*$//')
            SYS_LIB=$(find /usr/lib /lib -name "${LIB_STEM}*" -type f 2>/dev/null | head -1)
        fi
        if [ -n "$SYS_LIB" ]; then
            APP_LIB_DIR="$EXTRACT_DIR/usr/lib"
            mkdir -p "$APP_LIB_DIR"
            ln -sf "$SYS_LIB" "$APP_LIB_DIR/$lib" 2>/dev/null
            slog "Fixed: $lib -> $SYS_LIB"
        else
            slog "WARNING: $lib missing everywhere — app may fail on this"
        fi
    done
else
    slog "All libraries resolved OK"
fi

# Step 8: Final validation
FINAL_MISSING=$(LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ldd "$MAIN_BIN" 2>&1 | grep "not found" | wc -l || echo 0)
slog "Final check: $FINAL_MISSING missing libs"
rm -f /tmp/ldconfig_cache.txt

# App crash-restart loop (kiosk watchdog) with serial logging
MAX_CRASHES=10
CRASH_COUNT=0
while true; do
    slog "Launching app (attempt $((CRASH_COUNT+1))/$MAX_CRASHES)..."
    "$EXTRACT_DIR/AppRun" --no-sandbox 2>/tmp/app-stderr.log | tee -a /tmp/app-crash.log &
    APP_PID=$!
    wait $APP_PID
    EXIT_CODE=$?
    slog "App exited with code $EXIT_CODE"
    # Log stderr
    if [ -s /tmp/app-stderr.log ]; then
        slog "App stderr: $(head -5 /tmp/app-stderr.log)"
        # Auto-detect NEW glibc errors and strip them on-the-fly
        # Extract lib names from errors like: "required by /tmp/app_extracted/usr/lib/libgdk-3.so.0"
        NEW_GLIBC_LIBS=$(grep -oP 'required by \K/[^)]+' /tmp/app-stderr.log 2>/dev/null | sort -u)
        if [ -n "$NEW_GLIBC_LIBS" ]; then
            slog "Auto-stripping newly discovered conflicting libs..."
            for lib_path in $NEW_GLIBC_LIBS; do
                if [ -f "$lib_path" ]; then
                    LIB_BASE=$(basename "$lib_path")
                    # Only strip if system has a replacement
                    if ldconfig -p 2>/dev/null | grep -qF "$LIB_BASE"; then
                        rm -f "$lib_path" && slog "Hot-stripped: $lib_path (system has $LIB_BASE)"
                    else
                        slog "KEPT: $lib_path (no system replacement for $LIB_BASE)"
                    fi
                fi
            done
        fi
    fi
    echo "[KIOSK] App exited with code $EXIT_CODE at $(date)" >> /tmp/app-crash.log
    CRASH_COUNT=$((CRASH_COUNT + 1))
    if [ $CRASH_COUNT -ge $MAX_CRASHES ]; then
        slog "FATAL: App crashed $MAX_CRASHES times, giving up"
        break
    fi
    sleep 2
done &
OBSTART

chown -R liveuser:liveuser /home/liveuser/.config

# ── .XINITRC ─────────────────────────────────────────────────────
cat > /home/liveuser/.xinitrc << 'XI'
#!/bin/sh
slog() { echo "[XINITRC] $(date '+%H:%M:%S') $*" >> /tmp/liveuser-boot.log; [ -w /dev/ttyS0 ] && echo "[XINITRC] $(date '+%H:%M:%S') $*" > /dev/ttyS0; }
slog "xinitrc starting"

# Environment for Tauri/WebKit
if [ -f /tmp/tauri-env.sh ]; then
    . /tmp/tauri-env.sh
    slog "Sourced /tmp/tauri-env.sh"
else
    export DISPLAY=:0
    export XDG_RUNTIME_DIR=/tmp/runtime-liveuser
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
fi
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
sudo mkdir -p /tmp/.X11-unix && sudo chmod 1777 /tmp/.X11-unix
slog "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR, DISPLAY=$DISPLAY"

# Check Xorg binary
if command -v Xorg >/dev/null 2>&1; then
    slog "Xorg binary: $(which Xorg) — $(file $(which Xorg) 2>/dev/null | head -c 80)"
else
    slog "WARNING: Xorg binary NOT found in PATH"
fi

# Start PulseAudio (after XDG_RUNTIME_DIR exists)
pulseaudio --start 2>/dev/null || true
slog "PulseAudio started"

slog "Launching openbox-session..."
exec openbox-session
XI
chmod +x /home/liveuser/.xinitrc

# ── BASH_PROFILE → kiosk_launcher setup + startx ─────────────
cat > /home/liveuser/.bash_profile << 'BP'
if [[ -z $DISPLAY ]] && [[ $(tty) == /dev/tty1 ]]; then
    # Phase 1: Use kiosk_launcher for environment setup (permissions, dirs, env)
    if [[ -x /usr/local/bin/kiosk_launcher ]]; then
        echo "[BOOT] Running kiosk_launcher setup..." >> /tmp/liveuser-boot.log
        sudo /usr/local/bin/kiosk_launcher
    else
        echo "[BOOT] kiosk_launcher not found, manual setup" >> /tmp/liveuser-boot.log
        sudo chmod 666 /dev/ttyS0 2>/dev/null || true
        sudo mkdir -p /tmp/.X11-unix && sudo chmod 1777 /tmp/.X11-unix
    fi

    # Phase 2: Source the Tauri environment
    [[ -f /tmp/tauri-env.sh ]] && . /tmp/tauri-env.sh

    # Phase 3: Start X as the logged-in tty1 user (THIS fixes VT switch)
    echo "[BOOT] Starting X as $(whoami) on $(tty)..." >> /tmp/liveuser-boot.log
    echo "[BOOT] Starting X as $(whoami) on $(tty)..." >> /tmp/liveuser-boot.log
    # Removed serial echo to keep screen clean

    
    # Run startx WITHOUT exec, so we can catch errors if it exits
    startx -- -nolisten tcp vt1 >/tmp/xorg.log 2>&1
    X_EXIT=$?
    
    # If we reach here, X exited or crashed
    if [ -w /dev/ttyS0 ]; then
        echo "======================================" > /dev/ttyS0
        echo " XORG EXITED WITH CODE: $X_EXIT" > /dev/ttyS0
        echo "======================================" > /dev/ttyS0
        echo "--- /tmp/xorg.log ---" > /dev/ttyS0
        tail -n 40 /tmp/xorg.log > /dev/ttyS0
        
        # Openbox/AppImage logs might be in liveuser-boot.log
        echo "--- /tmp/liveuser-boot.log ---" > /dev/ttyS0
        tail -n 20 /tmp/liveuser-boot.log > /dev/ttyS0
        
        # Look for the actual Xorg server log (.local/share/xorg/Xorg.0.log)
        XORG_SERVER_LOG=$(ls -t /home/liveuser/.local/share/xorg/Xorg.*.log 2>/dev/null | head -1)
        if [ -n "$XORG_SERVER_LOG" ]; then
            echo "--- $XORG_SERVER_LOG (ERRORS) ---" > /dev/ttyS0
            grep -E '\(EE\)|Fatal|failed' "$XORG_SERVER_LOG" | tail -n 20 > /dev/ttyS0
        fi
        echo "======================================" > /dev/ttyS0
    fi
    # Sleep to allow reading the log before login prompt restarts
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
tmpfs /tmp tmpfs defaults,noatime 0 0
tmpfs /var/log tmpfs defaults,noatime,size=128M 0 0
FSTAB

# ── ENABLE FUSE (AppImage) ────────────────────────────────────────
modprobe fuse 2>/dev/null || true
echo 'fuse' >> /etc/modules

# ── NETWORKMANAGER — auto-connect ─────────────────────────────────
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

# NM auto-DHCP is default — no extra config needed

# ── TMPFILES — create /tmp/.X11-unix at boot with correct perms ──
mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/x11.conf << 'TMPF'
d /tmp/.X11-unix 1777 root root -
TMPF

# ── UDEV RULE — make serial ports world-writable ──────────────────
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-serial-access.rules << 'UDEV'
KERNEL=="ttyS[0-9]*", MODE="0666"
KERNEL=="ttyUSB[0-9]*", MODE="0666"
UDEV

# ── BOOT-INIT SERVICE — fix permissions at boot before user login ─
cat > /usr/local/bin/boot-init.sh << 'BINIT'
#!/bin/bash
# Boot initialization — run as root before user login
# Ensures serial port, X11, and runtime dirs are ready

# Make serial port writable by all users
chmod 666 /dev/ttyS0 2>/dev/null || true

SERIAL=/dev/ttyS0
BLOG=/tmp/boot-serial.log

slog() {
    echo "[BOOT-INIT] $(date '+%H:%M:%S') $*" >> "$BLOG"
    [ -w "$SERIAL" ] && echo "[BOOT-INIT] $(date '+%H:%M:%S') $*" > "$SERIAL"
}

slog "Boot initialization starting"
slog "Serial port: $(ls -la /dev/ttyS0 2>/dev/null)"

# Ensure X11 socket dir
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# Ensure runtime dir for liveuser
mkdir -p /tmp/runtime-liveuser
chown liveuser:liveuser /tmp/runtime-liveuser 2>/dev/null || true
chmod 700 /tmp/runtime-liveuser

# Log kernel GPU/DRM info
slog "Kernel: $(uname -r)"
slog "GPU modules: $(lsmod 2>/dev/null | grep -iE 'drm|gpu|bochs|qxl|virtio|vga|fb|video|i915' | awk '{print $1}' | tr '\n' ' ')"
slog "DRI devices: $(ls /dev/dri/ 2>/dev/null || echo 'none')"
slog "Framebuffer: $(ls /dev/fb* 2>/dev/null || echo 'none')"
slog "Xorg: $(which Xorg 2>/dev/null || echo 'NOT FOUND')"
slog "startx: $(which startx 2>/dev/null || echo 'NOT FOUND')"
slog "openbox: $(which openbox 2>/dev/null || echo 'NOT FOUND')"
slog "AppImage: $(ls -la /opt/app/app.AppImage 2>/dev/null || echo 'NOT FOUND')"
slog "User: $(id liveuser 2>/dev/null || echo 'liveuser NOT FOUND')"
slog "Xwrapper: $(cat /etc/X11/Xwrapper.config 2>/dev/null | tr '\n' ' ')"
slog "Boot initialization complete"
BINIT
chmod +x /usr/local/bin/boot-init.sh

cat > /etc/systemd/system/boot-init.service << 'BISVC'
[Unit]
Description=Boot Initialization (serial + permissions)
DefaultDependencies=no
Before=getty@tty1.service autologin@tty1.service
After=systemd-udev-settle.service systemd-tmpfiles-setup.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/boot-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BISVC
systemctl enable boot-init.service 2>/dev/null || true

# ── SYSTEMD SERVICES ─────────────────────────────────────────────
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable udisks2 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable systemd-timesyncd 2>/dev/null || true

# ── ISO RUNTIME LOGGER (captures everything → SERIAL + local log) ─
mkdir -p /var/log/kiosk
cat > /usr/local/bin/kiosk-logger.sh << 'KLOG'
#!/bin/bash
# Kiosk Runtime Logger — outputs to BOTH serial (/dev/ttyS0) and local log
LOGDIR=/var/log/kiosk
DEBIAN_LOG="$LOGDIR/debian-runtime.log"
SERIAL=/dev/ttyS0
mkdir -p "$LOGDIR"

# Dual-output: serial + file
slog() {
    local msg="[KIOSK-LOG] $(date '+%H:%M:%S') $*"
    echo "$msg" >> "$DEBIAN_LOG" 2>/dev/null
    echo "$msg" > "$SERIAL" 2>/dev/null
}

# ── Initial boot diagnostics (all go to serial) ──
{
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "KIOSK BOOT DIAGNOSTIC — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════════"
    echo ""

    echo "── SYSTEM INFO ──"
    uname -a
    cat /etc/live-build-info 2>/dev/null
    echo ""

    echo "── KERNEL MODULES (video/gpu) ──"
    lsmod 2>/dev/null | grep -iE 'drm|gpu|bochs|qxl|virtio|vga|fb|video|i915|nouveau|amdgpu' || echo "No GPU modules loaded"
    echo ""

    echo "── DRI DEVICES ──"
    ls -la /dev/dri/ 2>/dev/null || echo "/dev/dri not found"
    echo ""

    echo "── FRAMEBUFFER ──"
    ls -la /dev/fb* 2>/dev/null || echo "No framebuffer device"
    echo ""

    echo "── XORG BINARY CHECK ──"
    which Xorg 2>/dev/null && file $(which Xorg) 2>/dev/null || echo "Xorg NOT in PATH"
    which startx 2>/dev/null || echo "startx NOT in PATH"
    which openbox 2>/dev/null || echo "openbox NOT in PATH"
    echo ""

    echo "── XWRAPPER CONFIG ──"
    cat /etc/X11/Xwrapper.config 2>/dev/null || echo "No Xwrapper.config"
    echo ""

    echo "── USER CHECK ──"
    id liveuser 2>/dev/null || echo "liveuser does not exist"
    ls -la /home/liveuser/.bash_profile /home/liveuser/.xinitrc 2>/dev/null || echo "Missing profile/xinitrc"
    echo ""

    echo "── DMESG (errors/warnings) ──"
    dmesg --level=err,warn 2>/dev/null | tail -50
    echo ""

    echo "── MISSING FIRMWARE (from dmesg) ──"
    dmesg 2>/dev/null | grep -i firmware | tail -20
    echo ""

    echo "── DISPLAY ──"
    echo "DISPLAY=${DISPLAY:-unset}"
    xrandr 2>/dev/null || echo "xrandr not available (X not running yet)"
    echo ""

    echo "── NETWORK ──"
    nmcli -t device status 2>/dev/null || echo "NM not running"
    ip -br addr 2>/dev/null
    echo ""

    echo "── AUDIO ──"
    pactl info 2>/dev/null | head -5 || echo "PulseAudio not running"
    echo ""

    echo "── APP STATUS ──"
    pgrep -la AppImage 2>/dev/null || echo "AppImage not running yet"
    ls -la /opt/app/app.AppImage 2>/dev/null || echo "/opt/app/app.AppImage NOT FOUND"
    echo ""

    echo "── STORAGE ──"
    df -h 2>/dev/null
    echo ""

    echo "── XORG LOG ──"
    cat /tmp/xorg.log 2>/dev/null | tail -30 || echo "No xorg.log yet"
    echo ""

    echo "── XORG SERVER LOG ──"
    XORG_LOG=$(ls -t /var/log/Xorg.*.log 2>/dev/null | head -1)
    if [[ -n "$XORG_LOG" ]]; then
        grep -E '\(EE\)|\(WW\)|Fatal|error|failed' "$XORG_LOG" 2>/dev/null | tail -30
    else
        echo "No Xorg server log found"
    fi
    echo ""

    echo "── APP CRASH LOG ──"
    cat /tmp/app-crash.log 2>/dev/null | tail -20 || echo "No crash log yet"
    echo ""

    echo "── STARTX ATTEMPTS LOG ──"
    cat /tmp/startx-attempts.log 2>/dev/null || echo "No startx attempts log yet"
    echo ""

    echo "═══════════════════════════════════════════════════"

} 2>&1 >> "$DEBIAN_LOG" 
# Removed redirect to $SERIAL here to keep the screen clean during boot


# ── Continuous monitoring loop (heartbeat to serial every 30s) ──
while true; do
    sleep 30
    {
        echo "── HEARTBEAT $(date '+%H:%M:%S') ──"
        echo "LOAD: $(cat /proc/loadavg 2>/dev/null)"
        echo "MEM: $(free -m 2>/dev/null | awk '/^Mem:/{printf "%dM/%dM (%.0f%%)", $3, $2, $3/$2*100}')"
        APP_PID=$(pgrep -f AppImage 2>/dev/null || true)
        if [[ -n "$APP_PID" ]]; then
            echo "APP PID=$APP_PID RSS=$(ps -o rss= -p $APP_PID 2>/dev/null | awk '{printf "%.0fM", $1/1024}')"
        else
            echo "APP: NOT RUNNING"
            # Dump any new crash/xorg errors
            tail -5 /tmp/app-crash.log 2>/dev/null
            tail -5 /tmp/xorg.log 2>/dev/null
        fi
    } >> "$DEBIAN_LOG" 2>/dev/null
done
KLOG
chmod +x /usr/local/bin/kiosk-logger.sh

# Systemd service for kiosk logger
cat > /etc/systemd/system/kiosk-logger.service << 'KSVC'
[Unit]
Description=Kiosk Runtime Logger (serial + file)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/kiosk-logger.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
KSVC
systemctl enable kiosk-logger.service 2>/dev/null || true

# ── OPTIONAL: SSH ─────────────────────────────────────────────────
if [[ "ENABLE_SSH_PLACEHOLDER" == "1" ]]; then
    apt-get -qq install -y openssh-server
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl enable ssh
fi

# ── Xorg config — allow any user to start X ──────────────────────
mkdir -p /etc/X11/Xwrapper.config.d
cat > /etc/X11/Xwrapper.config << 'XWRAP'
allowed_users=anybody
needs_root_rights=yes
XWRAP

# ── PACKAGE MANIFEST (before cleanup removes dpkg data) ────────
dpkg-query -W --showformat='${Package}\t${Version}\n' > /tmp/filesystem.manifest 2>/dev/null || true

# ── ULTRA-AGGRESSIVE SIZE REDUCTION ──────────────────────────────
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
    /usr/share/lintian/* \
    /usr/share/linda/* \
    /usr/share/locale/[!en]* \
    /usr/share/i18n/locales/[!en]* \
    /usr/share/groff \
    /usr/share/bug \
    /usr/share/pixmaps \
    /usr/share/sounds \
    /usr/share/ghostscript \
    /usr/lib/python3*/test \
    /usr/lib/python3*/__pycache__ \
    /var/lib/dpkg/*-old \
    /tmp/* \
    /root/.bash_history \
    2>/dev/null || true

# Strip unused kernel modules (keep essential: fs, net, input, usb, gpu, storage, video)
find /lib/modules -name '*.ko' | while read mod; do
    case "$mod" in
        *net/*|*fs/*|*input/*|*usb/*|*gpu/*|*drm/*|*hid/*|*block/*|*scsi/*|*nvme/*|*fuse*|*loop*|*overlay*|*ata/*|*libata*) ;;
        *sound/*|*snd*|*i915*|*amdgpu*|*nouveau*|*virtio*|*e1000*|*r8169*|*cdrom*|*sr_mod*) ;;
        *video/*|*bochs*|*qxl*|*cirrus*|*vmwgfx*|*vgem*|*fb*|*backlight*|*acpi/*) ;;
        *) rm -f "$mod" ;;
    esac
done 2>/dev/null || true

# Rebuild module deps + initramfs after pruning
KERN_VER=$(ls /lib/modules | head -1)
if [[ -n "$KERN_VER" ]]; then
    depmod -a "$KERN_VER" 2>/dev/null || true
    update-initramfs -u -k "$KERN_VER" 2>/dev/null || true
fi

# Strip binaries (exclude WebKit/JSC/Xorg AND critical runtime libs)
# IMPORTANT: bash, libc, ld-linux etc. are memory-mapped by this running
# chroot shell — stripping them causes Bus error (core dumped)
find /usr/bin /usr/sbin /usr/lib -type f -executable \
    -not -name '*webkit*' -not -name '*javascript*' -not -name '*jsc*' \
    -not -name '*Xorg*' -not -name '*Xwayland*' -not -name '*X11*' \
    -not -name '*modesetting*' -not -name '*glamor*' \
    -not -name 'bash' -not -name 'dash' -not -name 'sh' \
    -not -name 'libc.so*' -not -name 'libc-*' \
    -not -name 'ld-linux*' -not -name 'ld-*' \
    -not -name 'libdl*' -not -name 'libpthread*' \
    -not -name 'librt*' -not -name 'libm.so*' \
    -not -name 'libresolv*' -not -name 'libnss*' \
    -not -name 'libgcc_s*' -not -name 'libstdc++*' \
    -not -name 'coreutils' -not -name 'strip' \
    -exec strip --strip-unneeded {} 2>/dev/null \;

# Keep essential locale
mkdir -p /usr/share/locale/en_US
echo "OK — chroot setup complete ($(du -sh / 2>/dev/null | cut -f1) rootfs)"
CHROOT_EOF

    # Replace placeholders with actual values
    sed -i "s/RELEASE_PLACEHOLDER/${DEBIAN_RELEASE}/g" "$BUILD_DIR/chroot_setup.sh"
    sed -i "s/ARCH_PLACEHOLDER/${ARCH}/g" "$BUILD_DIR/chroot_setup.sh"
    sed -i "s/HOSTNAME_PLACEHOLDER/${HOSTNAME_LIVE}/g" "$BUILD_DIR/chroot_setup.sh"
    sed -i "s/ENABLE_SSH_PLACEHOLDER/${ENABLE_SSH}/g" "$BUILD_DIR/chroot_setup.sh"

    # If kiosk mode is off, simplify the autostart (no crash-loop, allow WM shortcuts)
    if [[ "$KIOSK_MODE" != "1" ]]; then
        log "Kiosk mode disabled — using simple autostart"
        sed -i 's|while true; do|# Kiosk mode off — single launch\n|' "$BUILD_DIR/chroot_setup.sh"
        sed -i 's|done \&|/opt/app/app.AppImage --no-sandbox \&|' "$BUILD_DIR/chroot_setup.sh"
    fi

    chmod +x "$BUILD_DIR/chroot_setup.sh"
    
    # Copy custom Plymouth theme into rootfs before chroot
    log "Injecting custom Plymouth theme..."
    mkdir -p "$ROOTFS_DIR/usr/share/plymouth/themes/kiosk-spinner"
    cp -r "$WORKDIR/plymouth_theme/kiosk-spinner/"* "$ROOTFS_DIR/usr/share/plymouth/themes/kiosk-spinner/"
    
    cp "$BUILD_DIR/chroot_setup.sh" "$ROOTFS_DIR/chroot_setup.sh"
    chroot "$ROOTFS_DIR" /bin/bash /chroot_setup.sh 2>&1 | tee -a "$LOG_FILE"
    rm -f "$ROOTFS_DIR/chroot_setup.sh"

    # Copy manifest from chroot (generated before cleanup)
    [[ -f "$ROOTFS_DIR/tmp/filesystem.manifest" ]] && \
        cp "$ROOTFS_DIR/tmp/filesystem.manifest" "$ISO_DIR/live/filesystem.manifest"

    # Unmount binds
    for p in "${_MOUNTED_PATHS[@]:-}"; do
        mountpoint -q "$p" 2>/dev/null && umount -lf "$p" 2>/dev/null || true
    done
    _MOUNTED_PATHS=()

    ok "Rootfs configured  →  $(du -sh "$ROOTFS_DIR" | cut -f1)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. INJECT APP
# ─────────────────────────────────────────────────────────────────────────────
inject_app() {
    step "INJECT APP"

    cp "$APPIMAGE" "$APP_DIR/app.AppImage"
    chmod +x    "$APP_DIR/app.AppImage"

    # Compile and install kiosk_launcher (C boot environment creator)
    local LAUNCHER_SRC="$WORKDIR/kiosk_launcher.c"
    if [[ -f "$LAUNCHER_SRC" ]]; then
        ok "Compiling kiosk_launcher.c on host..."
        gcc -O2 -o "$WORKDIR/kiosk_launcher" "$LAUNCHER_SRC" 2>&1 || {
            warn "kiosk_launcher compilation failed, skipping"
            LAUNCHER_SRC=""
        }
        if [[ -f "$WORKDIR/kiosk_launcher" ]]; then
            cp "$WORKDIR/kiosk_launcher" "$ROOTFS_DIR/usr/local/bin/kiosk_launcher"
            chmod 4755 "$ROOTFS_DIR/usr/local/bin/kiosk_launcher"  # setuid root
            ok "kiosk_launcher compiled and installed (setuid root)"
        fi
    else
        warn "kiosk_launcher.c not found, skipping"
    fi

    # Embed build metadata
    cat > "$ROOTFS_DIR/etc/live-build-info" << META
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ISO_LABEL=${ISO_LABEL}
ISO_VERSION=${ISO_VERSION}
DEBIAN_RELEASE=${DEBIAN_RELEASE}
ARCH=${ARCH}
APPIMAGE=$(basename "$APPIMAGE")
SQUASHFS_COMP=${SQUASHFS_COMP}
KIOSK_MODE=${KIOSK_MODE}
META

    ok "App injected: $(basename "$APPIMAGE")  ($(du -sh "$APPIMAGE" | cut -f1))"
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

    # Ultra-aggressive compression options per algorithm
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
# 9. BOOTLOADERS
# ─────────────────────────────────────────────────────────────────────────────
build_grub() {
    step "GRUB  (BIOS + UEFI)"

    local cmdline="boot=live quiet splash loglevel=0 vt.global_cursor_default=0"
    [[ "$ENABLE_PERSISTENCE" == "1" ]] && cmdline+=" persistence"

    # ── grub.cfg ─────────────────────────────────────────────────
    cat > "$ISO_DIR/boot/grub/grub.cfg" << GCFG
set timeout=20
set default=0

# ── Graphics setup ──────────────────────────────
insmod all_video
insmod gfxterm
insmod png
insmod jpeg
insmod tga
insmod echo
insmod font
insmod video_bochs
insmod video_cirrus

set gfxmode=1024x768x32,800x600x32,auto
terminal_output gfxterm

# Find the partition containing our live files and set root
search --no-floppy --set=root --file /live/vmlinuz
set prefix=(\$root)/boot/grub

# Load fonts
if [ -f (\$root)/boot/grub/fonts/unicode.pf2 ]; then
    loadfont (\$root)/boot/grub/fonts/unicode.pf2
fi

# Set desktop image variable (needed for theme.txt)
set desktop_image="/boot/grub/background.png"

# ── GRUB Graphical Theme ────────────────────────────
if [ -f (\$root)/boot/grub/themes/custom/theme.txt ]; then
    if [ -f (\$root)/boot/grub/themes/custom/font.pf2 ]; then
        loadfont (\$root)/boot/grub/themes/custom/font.pf2
    fi
    set theme=(\$root)/boot/grub/themes/custom/theme.txt
else
    # Fallback background if theme fails to load
    if [ -f (\$root)/boot/grub/background.png ]; then
        background_image (\$root)/boot/grub/background.png
    fi
fi

# ── Menu Entries ────────────────────────────────
menuentry "D-Secure Drive Eraser" {
    echo "Loading D-Secure System..."
    linux /live/vmlinuz ${cmdline}
    initrd /live/initrd
}

menuentry "Reboot" {
    reboot
}

menuentry "Shutdown" {
    halt
}
GCFG

    # ── Copy assets ───────────────────────────────────────────
    log "Copying GRUB assets and theme..."
    
    mkdir -p "$ISO_DIR/boot/grub/fonts"
    [ -f /usr/share/grub/unicode.pf2 ] && cp /usr/share/grub/unicode.pf2 "$ISO_DIR/boot/grub/fonts/"

    # Copy background
    if [[ -f "$WORKDIR/background.png" ]]; then
        cp "$WORKDIR/background.png" "$ISO_DIR/boot/grub/background.png"
    elif [[ -f "$WORKDIR/iso_root/boot/grub/background.png" ]]; then
        cp "$WORKDIR/iso_root/boot/grub/background.png" "$ISO_DIR/boot/grub/background.png"
    fi

    # Copy theme
    mkdir -p "$ISO_DIR/boot/grub/themes"
    if [[ -d "$WORKDIR/iso_root/boot/grub/themes/custom" ]]; then
        cp -r "$WORKDIR/iso_root/boot/grub/themes/custom" "$ISO_DIR/boot/grub/themes/"
    fi

    # ── BIOS eltorito image ───────────────────────────────────────
    mkdir -p "$ISO_DIR/boot/grub/i386-pc"
    log "Building GRUB BIOS image..."
    # BIOS has a size limit, do NOT embed themes/fonts here. 
    # They will be loaded from the disk partition instead.
    grub-mkstandalone \
        --format=i386-pc \
        --output="$ISO_DIR/boot/grub/core.img" \
        --install-modules="linux normal iso9660 biosdisk memdisk search tar ls part_gpt part_msdos all_video gfxterm png jpeg tga echo font video_bochs video_cirrus" \
        --modules="linux normal iso9660 biosdisk search part_gpt part_msdos all_video gfxterm png echo font video_bochs video_cirrus" \
        --locales="" --fonts="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg" \
        || die "grub-mkstandalone BIOS failed"

    # Create bios boot image (512 B cdboot + core.img)
    cat /usr/lib/grub/i386-pc/cdboot.img "$ISO_DIR/boot/grub/core.img" \
        > "$ISO_DIR/boot/grub/bios.img" \
        || die "bios.img concatenation failed"

    # ── UEFI standalone .efi ──────────────────────────────────────
    log "Building GRUB UEFI image..."
    # UEFI does NOT have a strict size limit, we can embed assets for extra robustness
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$ISO_DIR/EFI/BOOT/BOOTx64.EFI" \
        --install-modules="linux normal iso9660 efi_gop efi_uga all_video search part_gpt part_msdos gfxterm gfxterm_background png echo font video_bochs video_cirrus" \
        --locales="" --fonts="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg" \
        "boot/grub/background.png=$ISO_DIR/boot/grub/background.png" \
        "boot/grub/themes/custom=$ISO_DIR/boot/grub/themes/custom" \
        || die "grub-mkstandalone UEFI failed"

    # FAT EFI image (needed by xorriso for UEFI boot)
    log "Creating EFI FAT image..."
    local efi_img="$ISO_DIR/boot/grub/efi.img"
    dd if=/dev/zero of="$efi_img" bs=1M count=4 status=none
    mkfs.fat -F 12 -n "EFI" "$efi_img" &>/dev/null \
        || die "mkfs.fat EFI image failed"
    mmd    -i "$efi_img" ::/EFI ::/EFI/BOOT \
        || die "mmd EFI dirs failed"
    mcopy  -i "$efi_img" "$ISO_DIR/EFI/BOOT/BOOTx64.EFI" ::/EFI/BOOT/ \
        || die "mcopy EFI binary failed"

    ok "GRUB BIOS + UEFI images ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. PXE TFTP CONFIG
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

    # iPXE script
    cat > "$PXE_DIR/boot.ipxe" << IPXE
#!ipxe
set base-url tftp://\${next-server}
kernel \${base-url}/vmlinuz boot=live quiet splash loglevel=0 vt.global_cursor_default=0 fetch=\${base-url}/filesystem.squashfs
initrd \${base-url}/initrd
boot
IPXE

    ok "PXE config written  →  $PXE_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. BUILD ISO  (hybrid BIOS + UEFI)
# ─────────────────────────────────────────────────────────────────────────────
build_iso() {
    step "BUILD ISO  →  $ISO_OUT"

    # Try hybrid ISO first (with isohdpfx.bin for USB boot)
    local isohdpfx="/usr/lib/ISOLINUX/isohdpfx.bin"
    local hybrid_args=()
    [[ -f "$isohdpfx" ]] && hybrid_args=(-isohybrid-mbr "$isohdpfx")

    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "$ISO_LABEL" \
        -preparer "kiosk-builder v3.0" \
        -publisher "$ISO_LABEL $ISO_VERSION" \
        \
        -eltorito-boot boot/grub/bios.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --eltorito-catalog boot/grub/boot.cat \
        \
        -eltorito-alt-boot \
            -e boot/grub/efi.img \
            -no-emul-boot \
        \
        "${hybrid_args[@]}" \
        -o "$ISO_OUT" \
        "$ISO_DIR"

    [[ -f "$ISO_OUT" ]] || die "ISO creation failed"
    ok "ISO created: $ISO_OUT  ($(du -sh "$ISO_OUT" | cut -f1))"
}

# ─────────────────────────────────────────────────────────────────────────────
# 12. CHECKSUMS & MANIFEST
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
    printf "  %-20s %s\n" "ISO"         "$ISO_OUT"
    printf "  %-20s %s\n" "ISO size"    "$(du -sh "$ISO_OUT" | cut -f1)"
    printf "  %-20s %s\n" "SquashFS"    "$(du -sh "$SQUASHFS_IMG" | cut -f1)"
    printf "  %-20s %s\n" "PXE files"   "$PXE_DIR/"
    printf "  %-20s %s\n" "Build log"   "$LOG_FILE"
    printf "  %-20s %s\n" "Kiosk mode"  "$( [[ "$KIOSK_MODE" == "1" ]] && echo 'ENABLED' || echo 'disabled' )"
    printf "  %-20s %dm %ds\n" "Build time" "$mins" "$secs"
    hr
    printf "\n  ${CYN}Test with QEMU:${RST}\n"
    printf "  qemu-system-x86_64 -cdrom %s -m 2G -enable-kvm -vga virtio\n\n" \
        "$(basename "$ISO_OUT")"
}

# ─────────────────────────────────────────────────────────────────────────────
# 14. MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    # Initialize build log with header
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1

    printf "${BOLD}${BLU}"
    cat << 'BANNER'
  ╔═══════════════════════════════════════════╗
  ║   KIOSK LIVE ISO + PXE BUILDER  v3.1      ║
  ║   Pure Debian · Tauri v2 · BIOS/UEFI      ║
  ╚═══════════════════════════════════════════╝
BANNER
    printf "${RST}"

    # Build metadata header in log
    {
        echo "═══════════════════════════════════════════════════════════"
        echo "BUILD LOG — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "═══════════════════════════════════════════════════════════"
        echo "Host: $(uname -a)"
        echo "Debian: $DEBIAN_RELEASE / $ARCH"
        echo "Compression: $SQUASHFS_COMP / $SQUASHFS_BLOCK"
        echo "Kiosk: $( [[ "$KIOSK_MODE" == "1" ]] && echo 'ENABLED' || echo 'disabled' )"
        echo "Mirror: $MIRROR"
        echo "Parallel: $PARALLEL_JOBS cores"
        echo "═══════════════════════════════════════════════════════════"
    } >> "$LOG_FILE"

    log "Build started at $(date)"
    log "Log file: $LOG_FILE"
    log "Kiosk mode: $( [[ "$KIOSK_MODE" == "1" ]] && echo 'ENABLED' || echo 'disabled' )"

    # Pipeline: cleanup → preflight → build
    cleanup_old_builds
    preflight
    bootstrap_rootfs
    configure_rootfs
    inject_app
    extract_kernel
    make_squashfs
    build_grub
    build_pxe_config
    build_iso
    generate_checksums
    print_summary

    # Final log entry
    echo "" >> "$LOG_FILE"
    echo "BUILD COMPLETED SUCCESSFULLY at $(date)" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat << HELP
Usage: sudo $0 [OPTIONS]

  --release RELEASE   Debian release  (default: bookworm)
  --arch    ARCH      Architecture    (default: amd64)
  --mirror  URL       Apt mirror
  --label   LABEL     ISO volume label (default: LIVE_OS)
  --comp    ALGO      SquashFS compression: xz|zstd|lz4|gzip  (default: xz)
  --ssh               Enable SSH server
  --persistence       Enable live persistence support
  --kiosk             Enable kiosk mode (default: on)
  --no-kiosk          Disable kiosk mode
  --timeout N         GRUB timeout in seconds (default: 5)
  --dry-run           Show plan, no build
  --help              Show this help

Environment overrides: DRY_RUN, PARALLEL_JOBS, SQUASHFS_COMP, KIOSK_MODE, etc.
Config file: build.conf in script directory

HELP
}

# Parse args
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

[[ "$DRY_RUN" == "1" ]] && {
    log "DRY RUN — config dump:"
    declare -p DEBIAN_RELEASE ARCH MIRROR ISO_LABEL SQUASHFS_COMP \
               ENABLE_SSH ENABLE_PERSISTENCE KIOSK_MODE BUILD_DIR
    exit 0
}

main