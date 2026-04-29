import os
from PIL import Image

def generate_theme_files():
    # Use absolute path relative to current directory
    base_dir = os.path.dirname(os.path.abspath(__file__))
    theme_dir = os.path.join(base_dir, "iso_root/boot/grub/themes/custom")
    os.makedirs(theme_dir, exist_ok=True)

    # 1. Create menu box images (Fully transparent to match background)
    dirs = ['nw', 'n', 'ne', 'w', 'c', 'e', 'sw', 's', 'se']
    for d in dirs:
        # Transparent background for the whole menu box
        img = Image.new('RGBA', (4, 4), color=(0, 0, 0, 0))
        img.save(os.path.join(theme_dir, f'menu_{d}.png'))

    # 2. Create selected item background (Dark blue)
    for d in dirs:
        img = Image.new('RGBA', (4, 4), color='#1e3799') # dark blue
        img.save(os.path.join(theme_dir, f'select_{d}.png'))

    # 3. Create theme.txt
    theme_content = """# D-Secure GRUB Theme
desktop-image: "/boot/grub/background.png"
terminal-font: "DejaVu Sans Mono Regular 18"
title-text: ""
title-font: "DejaVu Sans Mono Regular 18"

+ label {
    text = "D-Secure Boot Menu"
    font = "DejaVu Sans Mono Regular 18"
    color = "black"
    left = 0
    top = 5%
    width = 100%
    align = "center"
}

+ boot_menu {
    left = 25%
    width = 50%
    top = 10%
    height = 25%
    item_font = "DejaVu Sans Mono Regular 18"
    item_color = "black"
    selected_item_color = "white"
    item_height = 40
    item_padding = 10
    item_spacing = 15
    menu_pixmap_style = "menu_*.png"
    selected_item_pixmap_style = "select_*.png"
}

+ label {
    text = "Use ↑ ↓ arrows symbol for up and down"
    font = "DejaVu Sans Mono Regular 18"
    color = "black"
    left = 0
    top = 92%
    width = 100%
    align = "center"
}

+ progress_bar {
    id = "__timeout__"
    left = 25%
    top = 80%
    width = 50%
    height = 10
    fg_color = "#1e3799"
    bg_color = "white"
    border_color = "black"
}
"""
    with open(os.path.join(theme_dir, "theme.txt"), "w") as f:
        f.write(theme_content)
        
    print(f"Theme assets generated in {theme_dir}")

if __name__ == '__main__':
    generate_theme_files()
