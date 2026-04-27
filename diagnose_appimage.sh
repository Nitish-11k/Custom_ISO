#!/bin/sh
# ══════════════════════════════════════════════════════════════════════════
#  AppImage Diagnosis Script for Tiny Core Linux
#  Purpose: Verify system compatibility for Tauri/WebKitGTK AppImage
# ══════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TAURI APPIMAGE DIAGNOSIS (Target: Tiny Core)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Check GLIBC Version
echo -n "[*] Checking GLIBC Version... "
GLIBC_VER=$(ldd --version | head -n1 | grep -oP '\d+\.\d+' | head -n1)
REQUIRED_GLIBC="2.38"

# Compare versions (simple string comparison for major.minor)
if [ "$(echo "$GLIBC_VER $REQUIRED_GLIBC" | awk '{if ($1 >= $2) print "ok"; else print "fail"}')" = "ok" ]; then
    echo -e "${GREEN}OK (Found $GLIBC_VER)${NC}"
else
    echo -e "${RED}FAIL (Found $GLIBC_VER, Need $REQUIRED_GLIBC)${NC}"
    echo "    Tip: You must use a newer Tiny Core or provide a GLIBC 2.38+ shim."
fi

# 2. Check Critical System Libraries (Not bundled in AppImage)
LIBS="libgbm.so.1 libdrm.so.2 libstdc++.so.6 libgcc_s.so.1 libbz2.so.1.0 libXau.so.6 libXdmcp.so.6 libgraphite2.so.3 libGL.so.1 libEGL.so.1 libX11-xcb.so.1 libcom_err.so.2 libbsd.so.0 libGLdispatch.so.0 libGLX.so.0 libresolv.so.2 libmd.so.0"

echo ""
echo "[*] Checking System Libraries (TCE requirements):"
MISSING_COUNT=0
for lib in $LIBS; do
    echo -n "    - $lib ... "
    if ldconfig -p | grep -q "$lib"; then
        echo -e "${GREEN}FOUND${NC}"
    elif [ -f "/usr/lib/$lib" ] || [ -f "/lib/$lib" ] || [ -f "/usr/local/lib/$lib" ]; then
        echo -e "${GREEN}FOUND (Path)${NC}"
    else
        echo -e "${RED}MISSING${NC}"
        MISSING_COUNT=$((MISSING_COUNT + 1))
    fi
done

# 3. Check for FUSE (Needed for normal AppImage mount)
echo ""
echo -n "[*] Checking FUSE module... "
if lsmod | grep -q fuse; then
    echo -e "${GREEN}LOADED${NC}"
elif [ -c /dev/fuse ]; then
    echo -e "${GREEN}DEVICE PRESENT${NC}"
else
    echo -e "${YELLOW}NOT FOUND${NC}"
    echo "    Note: AppImage can still run with '--appimage-extract-and-run'."
fi

# 4. Check for X11 / Display
echo ""
echo -n "[*] Checking X11 Support... "
if command -v Xorg >/dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}MISSING Xorg${NC}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $MISSING_COUNT -eq 0 ]; then
    echo -e "${GREEN}SUCCESS: Environment looks compatible!${NC}"
else
    echo -e "${RED}WARNING: $MISSING_COUNT libraries are missing.${NC}"
    echo "Identify the missing libraries and install their .tcz equivalents."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
