#!/bin/bash
# Generate GRUB Theme Assets (Fallback/Robust)
# Uses ImageMagick if available, otherwise creates simple dummies

THEME_DIR="/home/nickx/.gemini/antigravity/scratch/custom_iso/iso_root/boot/grub"
mkdir -p "$THEME_DIR"

# Function to create a solid color PNG
create_png() {
    local name=$1
    local color=$2
    local width=${3:-5}
    local height=${4:-5}
    
    if command -v convert >/dev/null; then
        convert -size ${width}x${height} xc:"$color" "$THEME_DIR/$name"
    else
        # Fallback: Just touch the file so GRUB doesn't crash on missing file check
        # (Though GRUB needs valid PNGs, so we really hope python script ran first)
        echo "Warning: ImageMagick not found. Using empty files (might fail)."
        touch "$THEME_DIR/$name"
    fi
}

echo "Generating GRUB Theme Assets..."

# 1. Menu Box (Black Border, Transparent Center)
# Center (Transparent)
create_png "menu_c.png" "xc:none"
# Borders (Black)
for part in n s e w nw ne sw se; do
    create_png "menu_$part.png" "black"
done

# 2. Selection Box (Solid Gray) - NOW UNUSED in favor of solid color, but kept for safety
create_png "select_c.png" "#808080"
for part in n s e w nw ne sw se; do
    create_png "select_$part.png" "#808080"
done

# 3. Progress Bar (White Border, Black Center)
create_png "progress_bar_c.png" "#000000"
for part in n s e w nw ne sw se; do
    create_png "progress_bar_$part.png" "white"
done

# 4. Progress Compliment (Cyan Highlight)
create_png "progress_highlight_c.png" "cyan"
for part in n s e w nw ne sw se; do
    create_png "progress_highlight_$part.png" "cyan"
done

echo "Assets match 'menu_*.png', 'select_*.png', 'progress_bar_*.png'."
