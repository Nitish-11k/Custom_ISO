#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║          KIOSK LIVE ISO + PXE BUILDER  v3.1                              ║
# ║          Pure Debian Bookworm · Tauri v2 · BIOS/UEFI Hybrid              ║
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
    xserver-xorg-legacy \
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
ldconfig 2>/dev/null || true
ldconfig -p 2>/dev/null > /tmp/ldconfig_cache.txt
slog "System lib cache: $(wc -l < /tmp/ldconfig_cache.txt) entries"

# Step 4: Smart scan
slog "Smart-scanning bundled libs for GLIBC conflicts..."
STRIPPED=0
KEPT=0
find "$EXTRACT_DIR" -name '*.so*' -type f 2>/dev/null | while read -r so_file; do
    LIB_NAME=$(basename "$so_file")
    NEEDED=$(objdump -p "$so_file" 2>/dev/null | grep -oP 'GLIBC_\K[0-9]+\.[0-9]+' | sort -V | tail -1)
    if [ -n "$NEEDED" ]; then
        if [ "$(printf '%s\n%s' "$SYS_GLIBC_VER" "$NEEDED" | sort -V | tail -1)" != "$SYS_GLIBC_VER" ]; then
            if grep -qF "$LIB_NAME" /tmp/ldconfig_cache.txt 2>/dev/null; then
                rm -f "$so_file"
                slog "Stripped: $LIB_NAME (system has replacement)"
                STRIPPED=$((STRIPPED + 1))
            else
                slog "KEPT: $LIB_NAME (needs GLIBC_$NEEDED, no system replacement)"
                KEPT=$((KEPT + 1))
            fi
        fi
    fi
done

APP_LIB_DIRS=$(find "$EXTRACT_DIR" -name '*.so*' -type f -printf '%h\n' 2>/dev/null | sort -u | tr '\n' ':')
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:${APP_LIB_DIRS%:}"

MAIN_BIN=""
if [ -f "$EXTRACT_DIR/AppRun" ]; then
    if file "$EXTRACT_DIR/AppRun" 2>/dev/null | grep -qi "elf"; then
        MAIN_BIN="$EXTRACT_DIR/AppRun"
    else
        MAIN_BIN=$(find "$EXTRACT_DIR/usr/bin" -type f -executable 2>/dev/null | head -1)
        [ -z "$MAIN_BIN" ] && MAIN_BIN=$(find "$EXTRACT_DIR" -maxdepth 2 -type f -executable \( -name '*.bin' -o -name 'app' -o -name 'App' \) 2>/dev/null | head -1)
    fi
fi
[ -z "$MAIN_BIN" ] && MAIN_BIN="$EXTRACT_DIR/AppRun"

# App crash-restart loop
MAX_CRASHES=10
CRASH_COUNT=0
while true; do
    slog "Launching app (attempt $((CRASH_COUNT+1))/$MAX_CRASHES)..."
    "$EXTRACT_DIR/AppRun" --no-sandbox 2>/tmp/app-stderr.log | tee -a /tmp/app-crash.log &
    APP_PID=$!
    wait $APP_PID
    EXIT_CODE=$?
    slog "App exited with code $EXIT_CODE"
    
    if [ -s /tmp/app-stderr.log ]; then
        NEW_GLIBC_LIBS=$(grep -oP 'required by \K/[^)]+' /tmp/app-stderr.log 2>/dev/null | sort -u)
        if [ -n "$NEW_GLIBC_LIBS" ]; then
            for lib_path in $NEW_GLIBC_LIBS; do
                if [ -f "$lib_path" ]; then
                    LIB_BASE=$(basename "$lib_path")
                    if ldconfig -p 2>/dev/null | grep -qF "$LIB_BASE"; then
                        rm -f "$lib_path" && slog "Hot-stripped: $lib_path (system has $LIB_BASE)"
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

if [ -f /tmp/tauri-env.sh ]; then
    . /tmp/tauri-env.sh
else
    export DISPLAY=:0
    export XDG_RUNTIME_DIR=/tmp/runtime-liveuser
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
fi
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
sudo mkdir -p /tmp/.X11-unix && sudo chmod 1777 /tmp/.X11-unix

pulseaudio --start 2>/dev/null || true
slog "Launching openbox-session..."
exec openbox-session
XI
chmod +x /home/liveuser/.xinitrc

# ── BASH_PROFILE ─────────────────────────────────────────────
cat > /home/liveuser/.bash_profile << 'BP'
if [[ -z $DISPLAY ]] && [[ $(tty) == /dev/tty1 ]]; then
    if [[ -x /usr/local/bin/kiosk_launcher ]]; then
        sudo /usr/local/bin/kiosk_launcher
    else
        sudo chmod 666 /dev/ttyS0 2>/dev/null || true
        sudo mkdir -p /tmp/.X11-unix && sudo chmod 1777 /tmp/.X11-unix
    fi

    [[ -f /tmp/tauri-env.sh ]] && . /tmp/tauri-env.sh
    startx -- -nolisten tcp vt1 >/tmp/xorg.log 2>&1
    X_EXIT=$?
    
    if [ -w /dev/ttyS0 ]; then
        echo "======================================" > /dev/ttyS0
        echo " XORG EXITED WITH CODE: $X_EXIT" > /dev/ttyS0
    fi
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

mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/x11.conf << 'TMPF'
d /tmp/.X11-unix 1777 root root -
TMPF

mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-serial-access.rules << 'UDEV'
KERNEL=="ttyS[0-9]*", MODE="0666"
KERNEL=="ttyUSB[0-9]*", MODE="0666"
UDEV

cat > /usr/local/bin/boot-init.sh << 'BINIT'
#!/bin/bash
chmod 666 /dev/ttyS0 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
mkdir -p /tmp/runtime-liveuser
chown liveuser:liveuser /tmp/runtime-liveuser 2>/dev/null || true
chmod 700 /tmp/runtime-liveuser
BINIT
chmod +x /usr/local/bin/boot-init.sh

cat > /etc/systemd/system/boot-init.service << 'BISVC'
[Unit]
Description=Boot Initialization
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

# ── OPTIONAL: SSH ─────────────────────────────────────────────────
if [[ "ENABLE_SSH_PLACEHOLDER" == "1" ]]; then
    apt-get -qq install -y openssh-server
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl enable ssh
fi

mkdir -p /etc/X11/Xwrapper.config.d
cat > /etc/X11/Xwrapper.config << 'XWRAP'
allowed_users=anybody
needs_root_rights=yes
XWRAP

dpkg-query -W --showformat='${Package}\t${Version}\n' > /tmp/filesystem.manifest 2>/dev/null || true

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
    /usr/lib/python3*/test \
    /tmp/* \
    2>/dev/null || true

KERN_VER=$(ls /lib/modules | head -1)
if [[ -n "$KERN_VER" ]]; then
    depmod -a "$KERN_VER" 2>/dev/null || true
    update-initramfs -u -k "$KERN_VER" 2>/dev/null || true
fi

find /usr/bin /usr/sbin /usr/lib -type f -executable \
    -not -name '*webkit*' -not -name '*javascript*' -not -name '*jsc*' \
    -not -name '*Xorg*' -not -name '*Xwayland*' -not -name '*X11*' \
    -not -name 'bash' -not -name 'dash' -not -name 'sh' \
    -not -name 'libc.so*' -not -name 'libc-*' \
    -not -name 'ld-linux*' -not -name 'ld-*' \
    -not -name 'coreutils' -not -name 'strip' \
    -exec strip --strip-unneeded {} 2>/dev/null \;

echo "OK — chroot setup complete"
CHROOT_EOF

    sed -i "s/RELEASE_PLACEHOLDER/${DEBIAN_RELEASE}/g" "$BUILD_DIR/chroot_setup.sh"
    sed -i "s/ARCH_PLACEHOLDER/${ARCH}/g" "$BUILD_DIR/chroot_setup.sh"
    sed -i "s/HOSTNAME_PLACEHOLDER/${HOSTNAME_LIVE}/g" "$BUILD_DIR/chroot_setup.sh"
    sed -i "s/ENABLE_SSH_PLACEHOLDER/${ENABLE_SSH}/g" "$BUILD_DIR/chroot_setup.sh"

    if [[ "$KIOSK_MODE" != "1" ]]; then
        log "Kiosk mode disabled — using simple autostart"
        sed -i 's|while true; do|# Kiosk mode off — single launch\n|' "$BUILD_DIR/chroot_setup.sh"
        sed -i 's|done \&|/opt/app/app.AppImage --no-sandbox \&|' "$BUILD_DIR/chroot_setup.sh"
    fi

    chmod +x "$BUILD_DIR/chroot_setup.sh"
    
    log "Injecting custom Plymouth theme..."
    mkdir -p "$ROOTFS_DIR/usr/share/plymouth/themes/kiosk-spinner"
    cp -r "$WORKDIR/plymouth_theme/kiosk-spinner/"* "$ROOTFS_DIR/usr/share/plymouth/themes/kiosk-spinner/"
    
    cp "$BUILD_DIR/chroot_setup.sh" "$ROOTFS_DIR/chroot_setup.sh"
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
# 6. INJECT APP
# ─────────────────────────────────────────────────────────────────────────────
inject_app() {
    step "INJECT APP"

    cp "$APPIMAGE" "$APP_DIR/app.AppImage"
    chmod +x    "$APP_DIR/app.AppImage"

    local LAUNCHER_SRC="$WORKDIR/kiosk_launcher.c"
    if [[ -f "$LAUNCHER_SRC" ]]; then
        ok "Compiling kiosk_launcher.c on host..."
        gcc -O2 -o "$WORKDIR/kiosk_launcher" "$LAUNCHER_SRC" 2>&1 || {
            warn "kiosk_launcher compilation failed, skipping"
            LAUNCHER_SRC=""
        }
        if [[ -f "$WORKDIR/kiosk_launcher" ]]; then
            cp "$WORKDIR/kiosk_launcher" "$ROOTFS_DIR/usr/local/bin/kiosk_launcher"
            chmod 4755 "$ROOTFS_DIR/usr/local/bin/kiosk_launcher"
            ok "kiosk_launcher compiled and installed (setuid root)"
        fi
    else
        warn "kiosk_launcher.c not found, skipping"
    fi

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
# 9. BOOTLOADERS (ISO File System Approach to Fix BIOS Limits)
# ─────────────────────────────────────────────────────────────────────────────
build_grub() {
    step "GRUB  (BIOS + UEFI)"

    local cmdline="boot=live quiet splash loglevel=0 vt.global_cursor_default=0"
    [[ "$ENABLE_PERSISTENCE" == "1" ]] && cmdline+=" persistence"

    log "Placing GRUB assets onto ISO filesystem..."
    mkdir -p "$ISO_DIR/boot/grub/fonts"
    mkdir -p "$ISO_DIR/boot/grub/themes/custom"

    [ -f /usr/share/grub/unicode.pf2 ] && cp /usr/share/grub/unicode.pf2 "$ISO_DIR/boot/grub/fonts/"

    if [[ -d "$WORKDIR/iso_root/boot/grub/themes/custom" ]]; then
        cp -r "$WORKDIR/iso_root/boot/grub/themes/custom/"* "$ISO_DIR/boot/grub/themes/custom/"
    fi
    
    # FIX: Copy Plymouth Splash background directly to GRUB
    if [[ -f "$WORKDIR/plymouth_theme/kiosk-spinner/background.png" ]]; then
        cp "$WORKDIR/plymouth_theme/kiosk-spinner/background.png" "$ISO_DIR/boot/grub/background.png"
    elif [[ -f "$WORKDIR/background.png" ]]; then
        cp "$WORKDIR/background.png" "$ISO_DIR/boot/grub/background.png"
    fi

    local grub_embed_dir="$BUILD_DIR/grub_embed/boot/grub"
    mkdir -p "$grub_embed_dir"

    # FIX: menutry to menuentry and ensure proper shutdown command
    cat > "$grub_embed_dir/grub.cfg" << GCFG
# Find the OS partition immediately
search --no-floppy --set=root --file /live/vmlinuz
set prefix=(\$root)/boot/grub

set timeout=10
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

    log "Building GRUB BIOS & UEFI images..."

    mkdir -p "$ISO_DIR/boot/grub/i386-pc"
    grub-mkstandalone \
        --format=i386-pc \
        --output="$ISO_DIR/boot/grub/core.img" \
        --install-modules="linux normal iso9660 biosdisk memdisk search tar ls part_gpt part_msdos all_video gfxterm gfxmenu png jpeg font video_bochs video_cirrus" \
        --modules="linux normal iso9660 biosdisk search part_gpt part_msdos all_video gfxterm gfxmenu png font" \
        --locales="" --fonts="" --themes="" \
        "boot/grub/grub.cfg=$grub_embed_dir/grub.cfg" || die "grub-mkstandalone BIOS failed"

    cat /usr/lib/grub/i386-pc/cdboot.img "$ISO_DIR/boot/grub/core.img" \
        > "$ISO_DIR/boot/grub/bios.img"

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
    local isohdpfx="/usr/lib/ISOLINUX/isohdpfx.bin"
    local hybrid_args=()
    [[ -f "$isohdpfx" ]] && hybrid_args=(-isohybrid-mbr "$isohdpfx")

    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "$ISO_LABEL" \
        -preparer "kiosk-builder v3.1" \
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
    printf "  %-20s %s\n" "ISO"          "$ISO_OUT"
    printf "  %-20s %s\n" "ISO size"     "$(du -sh "$ISO_OUT" | cut -f1)"
    printf "  %-20s %s\n" "SquashFS"     "$(du -sh "$SQUASHFS_IMG" | cut -f1)"
    printf "  %-20s %s\n" "PXE files"    "$PXE_DIR/"
    printf "  %-20s %s\n" "Build log"    "$LOG_FILE"
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

    echo "" >> "$LOG_FILE"
    echo "BUILD COMPLETED SUCCESSFULLY at $(date)" >> "$LOG_FILE"
}

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

[[ "$DRY_RUN" == "1" ]] && exit 0
main