import os
from PIL import Image

def generate_theme_files():
    # Automatically get the directory where this script is running
    base_dir = os.path.dirname(os.path.abspath(__file__))
    theme_dir = os.path.join(base_dir, "iso_root", "boot", "grub", "themes", "custom")
    
    os.makedirs(theme_dir, exist_ok=True)

    dirs = ['nw', 'n', 'ne', 'w', 'c', 'e', 'sw', 's', 'se']
    
    # 1. Menu box images (Black borders, transparent center)
    for d in dirs:
        if d == 'c':
            img = Image.new('RGBA', (4, 4), color=(0, 0, 0, 0))
        else:
            img = Image.new('RGBA', (4, 4), color=(0, 0, 0, 255))
        img.save(os.path.join(theme_dir, f'menu_{d}.png'))

    # 2. Selected item background (Dark blue)
    for d in dirs:
        img = Image.new('RGBA', (4, 4), color='#1e3799')
        img.save(os.path.join(theme_dir, f'select_{d}.png'))

    # 3. Transparent Terminal Box
    for d in dirs:
        img = Image.new('RGBA', (4, 4), color=(0, 0, 0, 0)) # 100% transparent
        img.save(os.path.join(theme_dir, f'term_{d}.png'))

    # 4. Create theme.txt (FIXED SYNTAX)
    theme_content = """# D-Secure GRUB Theme
desktop-image: "/boot/grub/background.png"
terminal-font: "DejaVu Sans Mono Regular 18"
title-text: ""
title-font: "DejaVu Sans Mono Regular 18"
terminal-box: "term_*.png"
terminal-left: "25%"
terminal-top: "50%"
terminal-width: "50%"
terminal-height: "20%"

+ label {
    text = "D-Secure Boot Menu"
    font = "DejaVu Sans Mono Regular 18"
    color = "black"
    left = 0
    top = 8%
    width = 100%
    align = "center"
}

+ boot_menu {
    left = 25%
    width = 50%
    top = 15%
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
"""
    with open(os.path.join(theme_dir, "theme.txt"), "w") as f:
        f.write(theme_content)
        
    print("Theme assets generated successfully in:", theme_dir)

if __name__ == '__main__':
    generate_theme_files()