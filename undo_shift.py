from PIL import Image
import os

IMG_PATH = "/home/nickx/.gemini/antigravity/scratch/custom_iso/iso_root/boot/grub/background.png"

def shift_undo():
    if not os.path.exists(IMG_PATH):
        print(f"Error: {IMG_PATH} not found.")
        return

    img = Image.open(IMG_PATH).convert("RGBA")
    width, height = img.size
    
    # Sample color from pixel 260 (valid area)
    bg_color = img.getpixel((260, 10))
    print(f"Detected Background Color: {bg_color}")
    
    new_img = Image.new("RGBA", (width, height), bg_color)
    
    # Paste shifted left (-250)
    new_img.paste(img, (-250, 0))
    
    new_img.save(IMG_PATH)
    print(f"Restored background with fill color {bg_color}")

if __name__ == "__main__":
    shift_undo()
