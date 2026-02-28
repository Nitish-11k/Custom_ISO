from PIL import Image, ImageDraw
import struct
import os
import math

def create_spinner_frame(bg_img, frame_idx, total_frames, output_path):
    # Create a copy of background
    frame = bg_img.copy()
    draw = ImageDraw.Draw(frame)
    
    # Spinner configuration (Even smaller and compact)
    center_x, center_y = 512, 550
    radius = 28
    dot_radius = 5
    num_dots = 12
    
    # Draw 12 dots in a perfect circle
    for i in range(num_dots):
        # Angle for this specific dot
        angle_deg = (i * 360 / num_dots) - 90 # Start from top
        angle_rad = math.radians(angle_deg)
        
        # Position
        px = center_x + radius * math.cos(angle_rad)
        py = center_y + radius * math.sin(angle_rad)
        
        # Color: The "current" dot is brightest white, others fade out
        # Using a simple fade-out trail effect
        diff = (i - frame_idx) % num_dots
        if diff == 0:
            color = (255, 255, 255) # Brightest
            r = dot_radius + 1
        elif diff >= num_dots - 3: # Trail of 3 dots
            alpha = (diff - (num_dots - 4)) / 4.0
            val = int(100 + 155 * alpha)
            color = (val, val, val)
            r = dot_radius
        else:
            color = (80, 80, 80) # Dim dots
            r = dot_radius - 1
            
        draw.ellipse([px - r, py - r, px + r, py + r], fill=color)

    # Convert to 32-bit BGRX and save
    with open(output_path, "wb") as f:
        # BGRX is common for Linux framebuffers
        # 'BGRX' means [B, G, R, X] where X is padding
        bgrx_data = frame.convert('RGB').tobytes("raw", "BGRX")
        f.write(bgrx_data)

def generate_animation():
    bg_logo_path = "/home/nickx/Downloads/default-monochrome.png"
    # Even darker blue background: #030a21
    bg_color = (3, 10, 33) 
    print(f"Opening {bg_logo_path}...")
    try:
        logo = Image.open(bg_logo_path).convert('RGBA')
        
        # Create full-screen background
        img = Image.new('RGB', (1024, 768), bg_color)
        
        # Center and move slightly above
        lw, lh = logo.size
        # Make the logo larger for visibility (200px max)
        max_dim = 200
        if lw > max_dim or lh > max_dim:
            scale = min(max_dim/lw, max_dim/lh)
            logo = logo.resize((int(lw*scale), int(lh*scale)), Image.Resampling.LANCZOS)
            lw, lh = logo.size

        x = (1024 - lw) // 2
        # Center vertically
        y = (768 - lh) // 2
        img.paste(logo, (x, y), logo)
        
        # Save the clean background (Logo Only, No Dots) for GRUB transition
        # This avoids the "frozen dots" look while eliminating the black screen
        bg_output = "/home/nickx/.gemini/antigravity/scratch/custom_iso/splash_bg.png"
        img.save(bg_output)
        print(f"Generated clean background: {bg_output}")
            
        # Generate 12 frames
        for i in range(12):
            output = f"/home/nickx/.gemini/antigravity/scratch/custom_iso/splash_{i}.raw"
            # Create the frame with dots
            frame = img.copy()
            draw = ImageDraw.Draw(frame)
            
            # Spinner configuration (Match create_spinner_frame logic but inline for bridge capture)
            center_x, center_y = 512, 550
            radius = 28
            dot_radius = 5
            num_dots = 12
            
            for j in range(num_dots):
                angle_deg = (j * 360 / num_dots) - 90
                angle_rad = math.radians(angle_deg)
                px = center_x + radius * math.cos(angle_rad)
                py = center_y + radius * math.sin(angle_rad)
                
                diff = (j - i) % num_dots
                if diff == 0:
                    color = (255, 255, 255)
                    r = dot_radius + 1
                elif diff >= num_dots - 3:
                    alpha = (diff - (num_dots - 4)) / 4.0
                    val = int(100 + 155 * alpha)
                    color = (val, val, val)
                    r = dot_radius
                else:
                    color = (80, 80, 80)
                    r = dot_radius - 1
                draw.ellipse([px - r, py - r, px + r, py + r], fill=color)

            # Save the raw BGRX data
            bgrx_data = frame.convert('RGB').tobytes("raw", "BGRX")
            with open(output, "wb") as f:
                f.write(bgrx_data)
            
            # Save the very first frame as a PNG for GRUB to use as a "bridge"
            if i == 0:
                bridge_path = "/home/nickx/.gemini/antigravity/scratch/custom_iso/splash_grub_bridge.png"
                frame.save(bridge_path)
                print(f"Generated GRUB bridge: {bridge_path}")
            
            print(f"Generated dot frame {i}")
            
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    generate_animation()