from PIL import Image
import os
import shutil

IMG_PATH = "/home/nickx/.gemini/antigravity/scratch/custom_iso/iso_root/boot/grub/background.png"
# Only backup if we have one, otherwise we might have lost the original. 
# But assuming the shift script overwrote it. 
# Actually, the user might want us to use 'logo1.png' again if we have it?
# Let's check if we can just restore from logo1.png if it exists.

LOGO_PATH = "/home/nickx/.gemini/antigravity/scratch/custom_iso/logo1.png"

def restore_background():
    if os.path.exists(LOGO_PATH):
        # Convert to RGBA and save as background.png
        img = Image.open(LOGO_PATH).convert("RGBA")
        # Resize to 1024x768 or 800x600? 
        # Standard GRUB bg is usually 800x600 or 1024x768. 
        # logo1.png might be the source.
        # Let's just copy it back to reset the shift.
        img.save(IMG_PATH)
        print(f"Restored background from {LOGO_PATH}")
    else:
        print(f"Error: {LOGO_PATH} not found. Cannot restore.")

if __name__ == "__main__":
    restore_background()
