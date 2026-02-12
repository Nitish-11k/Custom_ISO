#!/bin/bash
#
# repair_deps.sh — Recursively find and download MISSING dependencies
#
set -euo pipefail

TCZ_DIR="/home/nickx/.gemini/antigravity/scratch/custom_iso/tc_extensions"
TCZ_URL="http://tinycorelinux.net/15.x/x86_64/tcz"

mkdir -p "$TCZ_DIR"
cd "$TCZ_DIR"

echo "=== Repairing Dependencies in $TCZ_DIR ==="

MISSING_FOUND=1
ITERATION=0

while [ $MISSING_FOUND -ne 0 ]; do
    ITERATION=$((ITERATION+1))
    MISSING_FOUND=0
    echo "--- Iteration $ITERATION ---"
    
    # 1. Ensure every .tcz has a .dep file (try to download it)
    for tcz in *.tcz; do
        if [ ! -f "${tcz}.dep" ]; then
            # suppress 404 output
            wget -q -O "${tcz}.dep" "$TCZ_URL/${tcz}.dep" 2>/dev/null || rm -f "${tcz}.dep"
        fi
    done

    # 2. Check all dependencies listed in .dep files
    # We use a temp file to store missing deps to avoid loop issues
    > missing_list.txt
    
    for depfile in *.dep; do
        [ -f "$depfile" ] || continue
        # Filter out empty lines/whitespace
        while IFS= read -r dep; do
            dep=$(echo "$dep" | tr -d '\r' | xargs)
            if [ -n "$dep" ]; then
                if [ ! -f "$dep" ]; then
                    echo "$dep" >> missing_list.txt
                fi
            fi
        done < "$depfile"
    done

    # 3. Download unique missing files
    if [ -s missing_list.txt ]; then
        MISSING_FOUND=1
        sort -u missing_list.txt | while read -r missing; do
            echo "MISSING: $missing ... Downloading"
            wget -q -O "$missing" "$TCZ_URL/$missing" || {
                echo "  FAILED to download $missing"
                rm -f "$missing"
            }
            # Also get its dep file immediately
            wget -q -O "${missing}.dep" "$TCZ_URL/${missing}.dep" 2>/dev/null || rm -f "${missing}.dep"
        done
    else
        echo "No missing dependencies found this pass."
    fi
done

echo "=== Dependency Repair Complete ==="
echo "Total Extensions: $(ls *.tcz | wc -l)"
