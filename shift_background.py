from PIL import Image
import os

IMG_PATH = "/home/nickx/.gemini/antigravity/scratch/custom_iso/iso_root/boot/grub/background.png"
SHIFT_X = 250  # Shift right by 250px to fill "negative space on right"

def shift_image():
    if not os.path.exists(IMG_PATH):
        print(f"Error: {IMG_PATH} not found.")
        return

    img = Image.open(IMG_PATH).convert("RGBA")
    width, height = img.size
    
    # Create new background (Black)
    new_img = Image.new("RGBA", (width, height), (228, 243, 235, 255))
    
    # Paste original image shifted right
    # (Checking if we need to crop the right side? Yes, to fit)
    new_img.paste(img, (SHIFT_X, 0))
    
    # Save back
    new_img.save(IMG_PATH)
    print(f"Shifted {IMG_PATH} right by {SHIFT_X}px.")

if __name__ == "__main__":
    shift_image()
