from PIL import Image

def generate_tk_logo():
    # Open logo
    try:
        logo = Image.open('/home/nickx/Downloads/default-monochrome.png').convert("RGBA")
        
        # Ensure it fits elegantly
        logo.thumbnail((250, 250), Image.Resampling.LANCZOS)
        
        # Create a background patch matching #030d2b because GIF does not like semi-transparency well
        bg = Image.new('RGB', logo.size, '#030d2b')
        bg.paste(logo, (0, 0), logo)
        
        # Save as GIF for Tkinter PhotoImage compatibility
        import os
        os.makedirs('/home/nickx/.gemini/antigravity/scratch/custom_iso/app_bin', exist_ok=True)
        bg.save('/home/nickx/.gemini/antigravity/scratch/custom_iso/app_bin/splash_logo.gif', format="GIF")
        print("splash_logo.gif generated successfully")
    except Exception as e:
        print(f"Failed to generate logo: {e}")

if __name__ == '__main__':
    generate_tk_logo()
