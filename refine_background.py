from PIL import Image, ImageOps
import os

# Paths
SOURCE_LOGO = "/home/nickx/.gemini/antigravity/scratch/custom_iso/enhance.png"
SOURCE_BG = "/home/nickx/.gemini/antigravity/scratch/custom_iso/parrot.jpg"
DEST_BG = "/home/nickx/.gemini/antigravity/scratch/custom_iso/iso_root/boot/grub/background.png"

# Config
CANVAS_SIZE = (1024, 768)

def refine_background():
    if not os.path.exists(SOURCE_LOGO):
        print(f"Error: {SOURCE_LOGO} not found.")
        return
    
    if not os.path.exists(SOURCE_BG):
        print(f"Error: {SOURCE_BG} not found.")
        return

    # 1. Prepare Background (Parrot)
    print(f"Opening background: {SOURCE_BG}")
    bg = Image.open(SOURCE_BG).convert("RGBA")
    bg = ImageOps.fit(bg, CANVAS_SIZE, method=Image.LANCZOS, centering=(0.5, 0.5))

    # 2. Prepare Logo
    print(f"Opening logo: {SOURCE_LOGO}")
    logo = Image.open(SOURCE_LOGO).convert("RGBA")
    
    # Scale logo to reasonable size (e.g., 500px width)
    target_w = 500
    scale = target_w / logo.width
    new_h = int(logo.height * scale)
    logo = logo.resize((target_w, new_h), Image.LANCZOS)
    
    # 3. Composite (Centered)
    bg_w, bg_h = CANVAS_SIZE
    logo_w, logo_h = logo.size
    x = (bg_w - logo_w) // 2
    y = (bg_h - logo_h) // 2
    
    bg.paste(logo, (x, y), logo)
    
    # 4. Save
    bg.convert("RGB").save(DEST_BG)
    print(f"Created background: Parrot + Center Logo")

if __name__ == "__main__":
    refine_background()
