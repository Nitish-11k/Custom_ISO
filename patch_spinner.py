from PIL import Image, ImageDraw

def patch_image():
    img_path = "/home/nickx/.gemini/antigravity/scratch/custom_iso/iso_root/boot/grub/background.png"
    
    try:
        img = Image.open(img_path).convert("RGB")
        
        # 1. Get Background Color (Sample from top-left corner)
        bg_color = img.getpixel((0, 0))
        print(f"Detected Background Color: {bg_color}")
        
        # 2. Define Spinner Area to Patch
        # Based on convert_splash.py: center=(512, 650), radius=30
        # We'll cover a 100x100 box around it to be safe.
        x1, y1 = 512 - 50, 650 - 50
        x2, y2 = 512 + 50, 650 + 50
        
        # 3. Draw Patch
        draw = ImageDraw.Draw(img)
        draw.rectangle([x1, y1, x2, y2], fill=bg_color)
        
        # 4. Save
        img.save(img_path)
        print(f"Successfully removed spinner from {img_path}")
        
    except Exception as e:
        print(f"Error patching image: {e}")

if __name__ == "__main__":
    patch_image()
