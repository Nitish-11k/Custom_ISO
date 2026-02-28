#!/bin/bash
#
# download_browser.sh — Download Midori browser + all deps for React UI rendering
#
set -euo pipefail

TCZ_DIR="/home/nickx/.gemini/antigravity/scratch/custom_iso/tc_extensions"
TCZ_URL="http://tinycorelinux.net/15.x/x86_64/tcz"
DOWNLOADED=""

download_tcz() {
    local ext="$1"
    
    # Skip if already downloaded
    if echo "$DOWNLOADED" | grep -qF "$ext"; then
        return
    fi
    DOWNLOADED="$DOWNLOADED $ext"
    
    # Download the extension
    if [ ! -f "$TCZ_DIR/$ext" ]; then
        echo "  Downloading $ext..."
        wget -q -O "$TCZ_DIR/$ext" "$TCZ_URL/$ext" 2>/dev/null || {
            echo "  WARNING: Failed to download $ext"
            rm -f "$TCZ_DIR/$ext"
            return
        }
    else
        echo "  Already have $ext"
    fi
    
    # Download and resolve dependencies
    local depfile="$TCZ_DIR/${ext}.dep"
    wget -q -O "$depfile" "$TCZ_URL/${ext}.dep" 2>/dev/null || true
    
    if [ -f "$depfile" ] && [ -s "$depfile" ]; then
        # Check it's not an HTML 404 page
        if ! grep -q '<html>' "$depfile" 2>/dev/null; then
            while IFS= read -r dep; do
                dep=$(echo "$dep" | tr -d '\r' | xargs)
                if [ -n "$dep" ]; then
                    download_tcz "$dep"
                fi
            done < "$depfile"
        fi
    fi
}

echo "=== Downloading Midori Browser + Dependencies ==="
echo "Target dir: $TCZ_DIR"
echo ""

for ext in \
    midori.tcz \
; do
    echo ">>> Resolving: $ext"
    download_tcz "$ext"
    echo ""
done

echo ""
echo "=== Browser Download Complete ==="
echo "Total extensions: $(ls "$TCZ_DIR"/*.tcz 2>/dev/null | wc -l)"
echo "Total size: $(du -sh "$TCZ_DIR" | cut -f1)"
