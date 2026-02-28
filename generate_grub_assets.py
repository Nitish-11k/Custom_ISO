import os
from PIL import Image, ImageDraw

GRUB_DIR = "/home/nickx/.gemini/antigravity/scratch/custom_iso/iso_root/boot/grub"
os.makedirs(GRUB_DIR, exist_ok=True)

def create_solid_color(filename, color, size=(5, 5)):
    img = Image.new("RGBA", size, color)
    img.save(os.path.join(GRUB_DIR, filename))
    print(f"Created {filename}")

def create_box_set(prefix, border_color, fill_color=None, size=(5, 5)):
    # standard 9-slice naming: n, s, e, w, nw, ne, sw, se, c
    c_color = fill_color if fill_color else (0,0,0,0) # Transparent if None
    create_solid_color(f"{prefix}_c.png", c_color, size)
    
    # Borders
    create_solid_color(f"{prefix}_n.png", border_color, size)
    create_solid_color(f"{prefix}_s.png", border_color, size)
    create_solid_color(f"{prefix}_e.png", border_color, size)
    create_solid_color(f"{prefix}_w.png", border_color, size)
    
    # Corners (Should typically be same size as borders)
    create_solid_color(f"{prefix}_nw.png", border_color, size)
    create_solid_color(f"{prefix}_ne.png", border_color, size)
    create_solid_color(f"{prefix}_sw.png", border_color, size)
    create_solid_color(f"{prefix}_se.png", border_color, size)

# 1. Menu Box: "menu_box_*.png" (User request: Thinner border)
# 5px was "very thick". Let's try 1px for sleek look.
create_box_set("menu_box", (0, 0, 0, 255), (0, 0, 0, 0), size=(1, 1))

# 2. Selection: "select_*.png"
# Solid Gray
create_box_set("select", (128, 128, 128, 255), (128, 128, 128, 255))

# 3. Progress Bar: "progress_bar_*.png"
# Black Border, thin?
create_box_set("progress_bar", (0, 0, 0, 255), (0, 0, 0, 0), size=(1, 1))

# 4. Progress Highlight: "progress_highlight_*.png"
# User request: "color make it greying"
create_box_set("progress_highlight", (128, 128, 128, 255), (128, 128, 128, 255))

# 5. Terminal Box: "terminal_box_*.png"
# Black Border, Semi-transparent Black Background
create_box_set("terminal_box", (0, 0, 0, 255), (0, 0, 0, 128), size=(1, 1))
