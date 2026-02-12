# Custom Dashboard ISO

This folder contains the build artifacts for a custom bootable ISO based on **Tiny Core Linux**.

## Features
- **Bootloader**: GRUB with graphical menu and custom background (`boot/grub/background.png`).
- **OS**: Tiny Core Linux 15.x (x86_64).
- **GUI**: Xorg server + FLWM window manager.
- **Dashboard**: Auto-starting Python 3.9 / Tkinter fullscreen app (`dashboard.py`).
- **Browser**: Firefox ESR pre-installed and launchable from the dashboard.

## Usage

### 1. Build
To rebuild the ISO from source (requires `wget`, `cpio`, `xorriso`, `grub-mkrescue`, `fakeroot`):
```bash
./build_iso.sh
```

### 2. Run in QEMU
To test the ISO with KVM acceleration and networking:
```bash
./run_qemu.sh
```

## Structure
- `build_iso.sh`: Main build script.
- `remaster_tc.sh`: Helper script to repack Tiny Core initramfs and prepare extensions.
- `tc_base/`: Base OS files (`vmlinuz64`, `corepure64.gz`).
- `tc_extensions/`: Downloaded TCZ extensions (Firefox, Python, Xorg, etc.).
- `iso_root/`: Staging directory for ISO creation.
- `dashboard.py`: The Python application source code.
