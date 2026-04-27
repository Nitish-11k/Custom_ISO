# Technical Report: Running Tauri AppImage on Tiny Core Linux

## Overview
This report analyzes the requirements for running a **Tauri + React** application (provided as an AppImage) within a **Tiny Core Linux (TCL)** environment, specifically for a PXE-booted kiosk system.

## 1. Current Environment Analysis

### Debian Build (`build_live.sh`)
The existing Debian-based build uses **Bookworm** or **Trixie**. It installs a wide array of dependencies for the Tauri runtime:
- **Tauri Runtime**: `libwebkit2gtk-4.1-0`, `libgtk-3-0`, `libsoup-3.0-0`.
- **GLIBC Fix**: The script explicitly upgrades `libglib2.0-0`, `libgtk-3-0`, `libcairo2`, and `libgdk-pixbuf-2.0-0` from **backports** to provide **GLIBC 2.38** compatibility.
- **Kiosk Mode**: Uses `openbox` and `unclutter` to provide a fullscreen, cursor-less environment.

### Tiny Core Build (`remaster_tc.sh`)
The Tiny Core script is currently optimized for a minimal footprint:
- **Exclusions**: It excludes heavy graphics libs like `mesa`, `llvm`, and `firmware` to save ~150MB.
- **Execution**: It launches the AppImage using `--appimage-extract-and-run` to avoid the FUSE requirement.
- **Optimization**: Uses a custom `core_custom.gz` initramfs.

---

## 2. Requirements for `app.appimage` (Tauri + React)

To run a Tauri AppImage on Tiny Core, the following categories of requirements must be met:

### A. Shared Libraries (Tauri/WebKitGTK Stack)
Tiny Core must provide the equivalent `.tcz` extensions for the Debian packages listed in `build_live.sh`.

| Debian Package | Tiny Core Extension (`.tcz`) | Role |
| :--- | :--- | :--- |
| `libwebkit2gtk-4.1-0` | `webkit2gtk.tcz` | Core Tauri engine (WebView) |
| `libgtk-3-0` | `gtk3.tcz` | UI Framework |
| `libsoup-3.0-0` | `libsoup3.tcz` | Network/HTTP support |
| `libjavascriptcoregtk-4.1-0` | Included in `webkit2gtk.tcz` | JS Engine |
| `libepoxy0` | `libepoxy.tcz` | OpenGL function pointer management |
| `libsecret-1-0` | `libsecret.tcz` | Password/Secret storage |
| `libnss3` | `nss.tcz` | Network Security Services |
| `libasound2` | `alsa.tcz` | Audio support |

### B. The GLIBC Hurdle
**CRITICAL:** Tauri AppImages built on modern systems often require **GLIBC 2.38+**. 
- Standard Tiny Core 15.x typically ships with an older GLIBC (e.g., 2.34 or 2.36).
- **Solution**: You may need to use a version of Tiny Core that matches the AppImage's GLIBC requirements or bundle the necessary `libc.so.6` within the AppImage extraction path (LD_LIBRARY_PATH).

### C. System Components
- **X11 Server**: `Xorg-7.7.tcz` is required for the graphical environment.
- **Window Manager**: `openbox.tcz` for the kiosk window management.
- **Utilities**: `xdotool.tcz` (used in your script for window positioning), `ca-certificates.tcz` (for HTTPS).

---

## 3. PXE Build Considerations

The `pxe_build/pxe` directory shows a structure consisting of:
- `vmlinuz`: The Linux kernel.
- `initrd`: The initial RAM disk (likely `corepure64.gz` + `core_custom.gz`).
- `filesystem.squashfs`: The root file system.

### Transitioning to Tiny Core PXE:
1.  **RootFS**: Instead of a 480MB `filesystem.squashfs`, Tiny Core uses the `cde` folder on the boot media to load extensions. 
2.  **Kernel/Initrd**: You will provide `vmlinuz64` and the concatenated `corepure64.gz` + `core_custom.gz`.
3.  **Boot Parameters**: Use `waitusb=5 tce=nfs:/path/to/cde` or embed the extensions directly into the initramfs for a "copy-to-ram" experience.

---

## 4. Recommendations for Tiny Core Build

1.  **Check GLIBC Version**: Run `strings /lib/libc.so.6 | grep GLIBC_` on the target Tiny Core version. If the AppImage requires a higher version, the app will fail to launch with a "GLIBC_X.XX not found" error.
2.  **Don't Over-Exclude**: The `EXCLUDE_PATTERN` in `remaster_tc.sh` removes `mesa`. WebKitGTK (Tauri) **requires** some form of GL acceleration (either hardware or software/LLVMpipe). Removing `mesa` and `llvm` may cause WebKit to crash or display a blank screen.
3.  **Use `ldd` for Verification**: Before finalizing the ISO, run `ldd` on the extracted binary inside the AppImage to ensure all shared objects are resolved in the Tiny Core environment.

---
**Report generated for:** `Custom_ISO` Project
**Date:** March 26, 2026
