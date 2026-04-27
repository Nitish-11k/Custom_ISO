from PIL import Image
import os

def create_grub_background():
    # Grub is often 1024x768
    width, height = 1024, 768
    
    # Load parrot.jpg and resize to fit 1024x768
    parrot_path = "/home/nickx/Downloads/parrot.jpg"
    if os.path.exists(parrot_path):
        bg = Image.open(parrot_path).convert("RGBA")
        bg = bg.resize((width, height), Image.Resampling.LANCZOS)
    else:
        # Fallback to solid color if missing
        bg = Image.new('RGBA', (width, height), color='#030d2b')
    
    # Open logo
    try:
        logo_path = "/home/nickx/Downloads/enhance.png"
        if os.path.exists(logo_path):
            logo = Image.open(logo_path).convert("RGBA")
        else:
            # Fallback if enhance.png is missing
            logo = Image.new('RGBA', (300, 300), color=(255, 255, 255, 0))
            print(f"Warning: {logo_path} not found")
        
        # Resize logo to be small (e.g. max width 300, max height 300)
        logo.thumbnail((300, 300), Image.Resampling.LANCZOS)
        
        # Calculate center coordinates
        bg_w, bg_h = bg.size
        logo_w, logo_h = logo.size

        # Perfectly center the logo
        offset_x = (bg_w - logo_w) // 2
        offset_y = (bg_h - logo_h) // 2

        bg.paste(logo, (offset_x, offset_y), logo)
    except Exception as e:
        print(f"Could not load logo: {e}")
        
    bg.save('/home/nickx/.gemini/antigravity/scratch/custom_iso/iso_root/boot/grub/background.png')
    print("background.png generated successfully")

if __name__ == '__main__':
    create_grub_background()
