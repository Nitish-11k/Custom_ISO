from PIL import Image
import struct
import os

def recover_image():
    raw_path = "/home/nickx/.gemini/antigravity/scratch/custom_iso/splash_0.raw"
    output_path = "/home/nickx/.gemini/antigravity/scratch/custom_iso/iso_root/boot/grub/background.png"
    
    if not os.path.exists(raw_path):
        print(f"Error: {raw_path} not found.")
        return

    width, height = 1024, 768
    img = Image.new("RGB", (width, height))
    pixels = []

    with open(raw_path, "rb") as f:
        while True:
            bytes_read = f.read(2)
            if not bytes_read:
                break
            val = struct.unpack("<H", bytes_read)[0]
            
            # Extract RGB565
            r5 = (val >> 11) & 0x1F
            g6 = (val >> 5) & 0x3F
            b5 = val & 0x1F
            
            # Scale to 8-bit
            r = (r5 * 255) // 31
            g = (g6 * 255) // 63
            b = (b5 * 255) // 31
            
            pixels.append((r, g, b))

    img.putdata(pixels)
    img.save(output_path)
    print(f"Recovered {output_path}")

if __name__ == "__main__":
    recover_image()
