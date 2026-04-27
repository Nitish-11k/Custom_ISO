# ISO Size & AppImage Footprint Report

## 1. Why is the ISO 700+ MB?

Our analysis of the `pxe_build` environment reveals that while the compressed SquashFS is ~460MB, the uncompressed rootfs is **1.4 GiB**. 

### Major Contributors:
- **System Libraries (`/usr/lib`)**: **606 MiB**. 
  - This is primarily driven by the full **WebKitGTK 4.1** stack and its transitive dependencies (GTK3, GStreamer, ICU, etc.).
  - `libicu` (International Components for Unicode) alone can take up ~30-50MB.
- **AppImage Footprint (`/opt/app`)**: **92 MiB**.
  - The `build_live.sh` script extracts the AppImage during build. This results in the app's internal binaries and bundled libs being uncompressed in the rootfs *before* the entire rootfs is squashed.
- **Firmware (`/lib/firmware`)**: Despite pruning, keeping modern drivers for WiFi and GPU (Mesa/LLVM) adds significant weight.
- **Initrd Overhead**: The initial RAM disk (initrd) contributes ~60MB to the boot payload.

---

## 2. Size Reduction Strategies for AppImage

To shrink the **92MB** AppImage footprint:
1.  **Prune Bundled Libs**: If a library is already provided by the system (Debian/TinyCore) and the versions match, the bundled copy in the AppImage's `lib` directory should be removed. (Wait: we disabled this for stability, so use caution).
2.  **Strip Binaries**: Ensure the main binary and all `.so` files have symbols stripped (`strip --strip-unneeded`).
3.  **Tauri Shrinking**: In `tauri.conf.json`, ensure `bundle > appimage > extract-and-run` is tuned, and use `sidecars` only if absolutely necessary.

---

## 3. ISO Size Reduction (Target: < 300MB)

### Strategy A: The "Pruning" Approach (Debian)
- **Aggressive ICU data stripping**: Use `icu-data` to only include the locales you need.
- **Font pruning**: Standard `fonts-dejavu-core` is small, but others can grow quickly.
- **Xorg Module Pruning**: Remove unused Xorg drivers (e.g., keep only `modesetting` and `intel`).
- **Optimization in `mksquashfs`**: Use `-comp xz -Xbcj x86` for maximal compression ratio (though it increases build time).

### Strategy B: Transition to Tiny Core (Best Result)
As demonstrated in our previous report, Tiny Core reduces the footprint to **~300MB** even with full hardware support because it avoids the "Debian Standard" bloat. 
- **Debian Base**: ~200MB (minimal)
- **Tiny Core Base**: **~12MB** (minimal)

---

## 4. Final Diagnosis Checklist
- [ ] **Check for apt cache**: ensure `apt-get clean` is run (it is in `build_live.sh`).
- [ ] **Check for leftover logs**: `/var/log` should be empty or a tmpfs.
- [ ] **Check for man/docs**: `chroot_setup.sh` already removes these, saving ~50MB.
- [ ] **Check for duplicate libs**: Compare `/usr/lib` vs `/opt/app/lib`.

---
**Report generated for:** `Custom_ISO` Project
**Date:** March 26, 2026
