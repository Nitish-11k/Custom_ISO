/*
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║  KIOSK LAUNCHER — Debian Tauri Environment Bootstrap (C)            ║
 * ║                                                                      ║
 * ║  Sets up the COMPLETE environment for a Tauri/WebKit AppImage to     ║
 * ║  run on a minimal Debian live ISO (SETUP ONLY — does not start X):   ║
 * ║    1. Serial logging (/dev/ttyS0)                                    ║
 * ║    2. Device permissions (DRI, FB, serial, input, audio)             ║
 * ║    3. User runtime directories (XDG, X11, PulseAudio)               ║
 * ║    4. D-Bus session bus                                              ║
 * ║    5. Framebuffer splash screen (before X starts)                    ║
 * ║    6. X11 config files (.xinitrc, openbox autostart)                  ║
 * ║    7. System diagnostics dump to serial                               ║
 * ║                                                                      ║
 * ║  NOTE: X server is started by .bash_profile AFTER this exits,        ║
 * ║  because startx needs to run from the tty1 login session.            ║
 * ║                                                                      ║
 * ║  Compile:  gcc -O2 -o kiosk_launcher kiosk_launcher.c                ║
 * ║  Install:  runs as root via sudo from .bash_profile                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <stdarg.h>
#include <linux/fb.h>
#include <linux/kd.h>
#include <linux/vt.h>
#include <pwd.h>
#include <grp.h>

/* ── Configuration ─────────────────────────────────────────────────── */
#define LIVE_USER       "liveuser"
#define APPIMAGE_PATH   "/opt/app/app.AppImage"
#define SERIAL_DEV      "/dev/ttyS0"
#define LOG_FILE        "/tmp/kiosk-launcher.log"
#define SPLASH_DIR      "/opt/app/splash"
#define MAX_X_RETRIES   3
#define MAX_APP_RETRIES 10
#define SPLASH_FRAMES   20

/* ── Globals ───────────────────────────────────────────────────────── */
static volatile int g_stop = 0;
static int serial_fd = -1;
static FILE *log_fp = NULL;

/* ── Signal Handler ────────────────────────────────────────────────── */
static void signal_handler(int sig) {
    (void)sig;
    g_stop = 1;
}

/* ── Logging (dual: serial + file) ──────────────────────────────────── */
static void slog(const char *tag, const char *fmt, ...) {
    char timebuf[32];
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    snprintf(timebuf, sizeof(timebuf), "%02d:%02d:%02d",
             t->tm_hour, t->tm_min, t->tm_sec);

    char msg[1024];
    va_list ap;

    /* Format the user message */
    char user_msg[768];
    va_start(ap, fmt);
    vsnprintf(user_msg, sizeof(user_msg), fmt, ap);
    va_end(ap);

    snprintf(msg, sizeof(msg), "[%s] %s %s\n", tag, timebuf, user_msg);

    /* Write to log file */
    if (!log_fp) log_fp = fopen(LOG_FILE, "a");
    if (log_fp) {
        fputs(msg, log_fp);
        fflush(log_fp);
    }

    /* Write to serial */
    if (serial_fd >= 0) {
        if (write(serial_fd, msg, strlen(msg)) < 0) { /* ignore error */ }
    }

    /* Also stdout */
    fputs(msg, stdout);
    fflush(stdout);
}

/* va_list already included via stdarg.h at top */

/* ── Helper: run command and return exit code ───────────────────────── */
static int run_cmd(const char *cmd) {
    int ret = system(cmd);
    if (ret == -1) return -1;
    return WEXITSTATUS(ret);
}

/* ── Helper: run command and capture output ────────────────────────── */
static void run_cmd_log(const char *tag, const char *cmd) {
    char full_cmd[512];
    snprintf(full_cmd, sizeof(full_cmd), "%s 2>&1", cmd);
    FILE *fp = popen(full_cmd, "r");
    if (fp) {
        char line[256];
        while (fgets(line, sizeof(line), fp)) {
            /* Remove trailing newline */
            size_t len = strlen(line);
            if (len > 0 && line[len-1] == '\n') line[len-1] = '\0';
            slog(tag, "%s", line);
        }
        pclose(fp);
    }
}



/* ── Helper: mkdir -p equivalent ───────────────────────────────────── */
static void mkdirp(const char *path, mode_t mode) {
    char tmp[256];
    char *p = NULL;
    snprintf(tmp, sizeof(tmp), "%s", path);
    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, mode);
            *p = '/';
        }
    }
    mkdir(tmp, mode);
}

/* ══════════════════════════════════════════════════════════════════════
 *  PHASE 1: SETUP PERMISSIONS
 *  Chmod/chown all devices and dirs needed by Tauri/WebKit/X11
 * ══════════════════════════════════════════════════════════════════════ */
static void phase1_permissions(void) {
    slog("PHASE1", "=== Setting up device permissions ===");

    /* Serial port */
    chmod(SERIAL_DEV, 0666);
    slog("PHASE1", "Serial: chmod 666 %s", SERIAL_DEV);

    /* DRI (GPU) devices */
    run_cmd("chmod 666 /dev/dri/* 2>/dev/null");
    run_cmd_log("PHASE1", "ls -la /dev/dri/ 2>/dev/null || echo 'no /dev/dri'");

    /* Framebuffer */
    run_cmd("chmod 666 /dev/fb* 2>/dev/null");
    run_cmd_log("PHASE1", "ls -la /dev/fb* 2>/dev/null || echo 'no framebuffer'");

    /* Input devices (keyboard, mouse, touchscreen) */
    run_cmd("chmod 666 /dev/input/event* 2>/dev/null");
    run_cmd("chmod 666 /dev/input/mice 2>/dev/null");

    /* Audio devices */
    run_cmd("chmod 666 /dev/snd/* 2>/dev/null");

    /* TTY devices */
    run_cmd("chmod 666 /dev/tty[0-9] 2>/dev/null");

    slog("PHASE1", "Device permissions configured");
}

/* ══════════════════════════════════════════════════════════════════════
 *  PHASE 2: CREATE RUNTIME DIRECTORIES
 *  XDG_RUNTIME_DIR, X11 socket dir, PulseAudio, etc.
 * ══════════════════════════════════════════════════════════════════════ */
static void phase2_runtime_dirs(uid_t uid, gid_t gid) {
    slog("PHASE2", "=== Creating runtime directories ===");

    /* /tmp/.X11-unix — X11 socket directory */
    mkdirp("/tmp/.X11-unix", 01777);
    chmod("/tmp/.X11-unix", 01777);
    slog("PHASE2", "/tmp/.X11-unix created (1777)");

    /* XDG_RUNTIME_DIR for liveuser */
    mkdirp("/tmp/runtime-liveuser", 0700);
    if (chown("/tmp/runtime-liveuser", uid, gid) < 0) {}
    chmod("/tmp/runtime-liveuser", 0700);
    slog("PHASE2", "XDG_RUNTIME_DIR=/tmp/runtime-liveuser (uid=%d)", uid);

    /* PulseAudio runtime dir */
    char pa_dir[128];
    snprintf(pa_dir, sizeof(pa_dir), "/tmp/runtime-liveuser/pulse");
    mkdirp(pa_dir, 0700);
    if (chown(pa_dir, uid, gid) < 0) {}
    slog("PHASE2", "PulseAudio runtime dir created");

    /* D-Bus session directory */
    mkdirp("/tmp/runtime-liveuser/bus", 0700);
    if (chown("/tmp/runtime-liveuser/bus", uid, gid) < 0) {}

    /* App data directory */
    char app_data[128];
    snprintf(app_data, sizeof(app_data), "/home/%s/.local/share", LIVE_USER);
    mkdirp(app_data, 0755);
    run_cmd("chown -R liveuser:liveuser /home/liveuser/.local 2>/dev/null");

    /* WebKit cache */
    char webkit_cache[128];
    snprintf(webkit_cache, sizeof(webkit_cache), "/home/%s/.cache/webkit", LIVE_USER);
    mkdirp(webkit_cache, 0755);
    run_cmd("chown -R liveuser:liveuser /home/liveuser/.cache 2>/dev/null");

    slog("PHASE2", "Runtime directories ready");
}

/* ══════════════════════════════════════════════════════════════════════
 *  PHASE 3: SET UP TAURI/WEBKIT ENVIRONMENT
 *  All env vars and D-Bus needed by the Tauri AppImage
 * ══════════════════════════════════════════════════════════════════════ */
static void phase3_write_env_file(void) {
    slog("PHASE3", "=== Writing Tauri environment file ===");

    FILE *f = fopen("/tmp/tauri-env.sh", "w");
    if (!f) {
        slog("PHASE3", "ERROR: Cannot write /tmp/tauri-env.sh");
        return;
    }

    fprintf(f,
        "#!/bin/sh\n"
        "# Tauri/WebKit Environment — generated by kiosk_launcher\n"
        "\n"
        "# Display\n"
        "export DISPLAY=:0\n"
        "\n"
        "# XDG directories\n"
        "export XDG_RUNTIME_DIR=/tmp/runtime-liveuser\n"
        "export XDG_DATA_HOME=/home/%s/.local/share\n"
        "export XDG_CONFIG_HOME=/home/%s/.config\n"
        "export XDG_CACHE_HOME=/home/%s/.cache\n"
        "export XDG_SESSION_TYPE=x11\n"
        "\n"
        "# WebKit/GTK settings for kiosk mode\n"
        "export WEBKIT_DISABLE_COMPOSITING_MODE=1\n"
        "export GDK_BACKEND=x11\n"
        "export GTK_THEME=Adwaita:dark\n"
        "export GDK_SYNCHRONIZE=0\n"
        "\n"
        "# D-Bus\n"
        "if [ -z \"$DBUS_SESSION_BUS_ADDRESS\" ]; then\n"
        "    eval $(dbus-launch --sh-syntax 2>/dev/null) || true\n"
        "    export DBUS_SESSION_BUS_ADDRESS\n"
        "fi\n"
        "\n"
        "# AppImage\n"
        "export APPIMAGE_EXTRACT_AND_RUN=1\n"
        "\n"
        "# Locale\n"
        "export LANG=en_US.UTF-8\n"
        "export LC_ALL=en_US.UTF-8\n"
        "\n"
        "# GPU/rendering\n"
        "export LIBGL_ALWAYS_SOFTWARE=1\n"
        "export MESA_GL_VERSION_OVERRIDE=3.3\n"
        "\n"
        "# Disable GPU sandbox (needed for AppImage in live env)\n"
        "export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1\n"
        "\n",
        LIVE_USER, LIVE_USER, LIVE_USER
    );

    fclose(f);
    chmod("/tmp/tauri-env.sh", 0755);
    slog("PHASE3", "Tauri environment file written: /tmp/tauri-env.sh");
}

/* ══════════════════════════════════════════════════════════════════════
 *  PHASE 4: FRAMEBUFFER SPLASH SCREEN (before X starts)
 * ══════════════════════════════════════════════════════════════════════ */
static void phase4_splash(void) {
    slog("PHASE4", "=== Showing framebuffer splash ===");

    int fb_fd = open("/dev/fb0", O_RDWR);
    if (fb_fd < 0) {
        slog("PHASE4", "No framebuffer (/dev/fb0), skipping splash");
        return;
    }

    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) < 0 ||
        ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        slog("PHASE4", "Cannot read FB info, skipping splash");
        close(fb_fd);
        return;
    }

    long screensize = finfo.smem_len;
    if (screensize == 0) screensize = vinfo.xres * vinfo.yres * (vinfo.bits_per_pixel / 8);

    unsigned char *fbp = mmap(0, screensize, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fbp == MAP_FAILED) {
        slog("PHASE4", "mmap failed, skipping splash");
        close(fb_fd);
        return;
    }

    slog("PHASE4", "Framebuffer: %dx%d @ %dbpp", vinfo.xres, vinfo.yres, vinfo.bits_per_pixel);

    /* Set TTY to graphics mode to hide text cursor */
    int tty_fd = open("/dev/tty0", O_RDWR);
    if (tty_fd >= 0) ioctl(tty_fd, KDSETMODE, KD_GRAPHICS);

    /* Fill screen with dark blue/black gradient-ish color */
    unsigned int bpp = vinfo.bits_per_pixel / 8;
    for (unsigned int y = 0; y < vinfo.yres; y++) {
        for (unsigned int x = 0; x < vinfo.xres; x++) {
            long loc = (x + vinfo.xoffset) * bpp + (y + vinfo.yoffset) * finfo.line_length;
            if (loc + bpp > screensize) continue;

            /* Dark gradient: top is slightly lighter */
            unsigned char r = 5;
            unsigned char g = 10 + (y * 20 / vinfo.yres);
            unsigned char b = 30 + (y * 30 / vinfo.yres);

            if (vinfo.bits_per_pixel == 32) {
                unsigned int *pixel = (unsigned int *)(fbp + loc);
                *pixel = (r << vinfo.red.offset) | (g << vinfo.green.offset) | (b << vinfo.blue.offset) | (0xFF << 24);
            } else if (vinfo.bits_per_pixel == 16) {
                unsigned short *pixel = (unsigned short *)(fbp + loc);
                *pixel = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            }
        }
    }

    /* Draw a simple centered "loading" indicator — a white horizontal bar */
    unsigned int bar_w = vinfo.xres / 3;
    unsigned int bar_h = 4;
    unsigned int bar_x = (vinfo.xres - bar_w) / 2;
    unsigned int bar_y = vinfo.yres * 2 / 3;

    for (unsigned int y = bar_y; y < bar_y + bar_h && y < vinfo.yres; y++) {
        for (unsigned int x = bar_x; x < bar_x + bar_w && x < vinfo.xres; x++) {
            long loc = (x + vinfo.xoffset) * bpp + (y + vinfo.yoffset) * finfo.line_length;
            if (loc + bpp > screensize) continue;
            if (vinfo.bits_per_pixel == 32) {
                unsigned int *pixel = (unsigned int *)(fbp + loc);
                *pixel = (200 << vinfo.red.offset) | (200 << vinfo.green.offset) | (220 << vinfo.blue.offset) | (0xFF << 24);
            } else if (vinfo.bits_per_pixel == 16) {
                unsigned short *pixel = (unsigned short *)(fbp + loc);
                *pixel = ((200 >> 3) << 11) | ((200 >> 2) << 5) | (220 >> 3);
            }
        }
    }

    slog("PHASE4", "Splash screen displayed");

    /* Keep splash for a moment, then clean up (X will take over the display) */
    usleep(500000);  /* 500ms */

    /* Restore TTY to text mode */
    if (tty_fd >= 0) {
        ioctl(tty_fd, KDSETMODE, KD_TEXT);
        close(tty_fd);
    }

    munmap(fbp, screensize);
    close(fb_fd);
    slog("PHASE4", "Splash cleanup done, handing off to X");
}


/* ══════════════════════════════════════════════════════════════════════
 *  PHASE 7: SYSTEM DIAGNOSTICS
 *  Dump full system state to serial for debugging
 * ══════════════════════════════════════════════════════════════════════ */
static void phase7_diagnostics(void) {
    slog("DIAG", "=== Full System Diagnostics ===");

    run_cmd_log("DIAG", "uname -a");
    run_cmd_log("DIAG", "id liveuser 2>/dev/null || echo 'NO liveuser'");
    run_cmd_log("DIAG", "groups liveuser 2>/dev/null");
    run_cmd_log("DIAG", "cat /etc/X11/Xwrapper.config 2>/dev/null || echo 'No Xwrapper'");
    run_cmd_log("DIAG", "ls -la /home/liveuser/.xinitrc /home/liveuser/.bash_profile 2>/dev/null");
    run_cmd_log("DIAG", "ls -la /opt/app/app.AppImage 2>/dev/null || echo 'NO APPIMAGE'");
    run_cmd_log("DIAG", "lsmod 2>/dev/null | grep -iE 'drm|gpu|bochs|qxl|virtio|vga|fb|video|i915'");
    run_cmd_log("DIAG", "ls -la /dev/dri/ 2>/dev/null || echo 'no /dev/dri'");
    run_cmd_log("DIAG", "which Xorg 2>/dev/null && ls -la $(which Xorg 2>/dev/null) 2>/dev/null || echo 'Xorg NOT in PATH'");
    run_cmd_log("DIAG", "dmesg --level=err,warn 2>/dev/null | tail -20");
    run_cmd_log("DIAG", "dmesg 2>/dev/null | grep -i firmware | tail -10");
    run_cmd_log("DIAG", "df -h /tmp / 2>/dev/null");
    run_cmd_log("DIAG", "free -m 2>/dev/null");

    slog("DIAG", "=== Diagnostics complete ===");
}

/* ══════════════════════════════════════════════════════════════════════
 *  MAIN — Setup only, X is started by .bash_profile after we exit
 * ══════════════════════════════════════════════════════════════════════ */
int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    /* Install signal handlers */
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    signal(SIGCHLD, SIG_DFL);

    /* Open serial port */
    serial_fd = open(SERIAL_DEV, O_WRONLY | O_NOCTTY);
    if (serial_fd < 0) {
        /* Try to chmod first (might be permission issue on first boot) */
        chmod(SERIAL_DEV, 0666);
        serial_fd = open(SERIAL_DEV, O_WRONLY | O_NOCTTY);
    }

    /* Open log file */
    log_fp = fopen(LOG_FILE, "a");

    slog("MAIN", "════════════════════════════════════════════");
    slog("MAIN", "  KIOSK LAUNCHER v2.0 — Debian Tauri Setup ");
    slog("MAIN", "════════════════════════════════════════════");
    slog("MAIN", "PID=%d, UID=%d, EUID=%d", getpid(), getuid(), geteuid());

    /* Check we're running as root */
    if (geteuid() != 0) {
        slog("MAIN", "WARNING: Not running as root (euid=%d). Some operations may fail.", geteuid());
    }

    /* Resolve liveuser UID/GID */
    struct passwd *pw = getpwnam(LIVE_USER);
    if (!pw) {
        slog("MAIN", "FATAL: User '%s' not found!", LIVE_USER);
        return 1;
    }
    uid_t uid = pw->pw_uid;
    gid_t gid = pw->pw_gid;
    slog("MAIN", "User %s: uid=%d gid=%d", LIVE_USER, uid, gid);

    /* ── Execute setup phases ─────────────────────────────────────── */

    /* Phase 1: Permissions */
    phase1_permissions();

    /* Phase 2: Runtime directories */
    phase2_runtime_dirs(uid, gid);

    /* Phase 3: Tauri environment file */
    phase3_write_env_file();

    /* Phase 4: Splash screen */
    phase4_splash();

    /* NOTE: .xinitrc and openbox autostart are baked into ISO by build_live.sh
     * They source /tmp/tauri-env.sh which we created in Phase 3 */

    /* Phase 7: Diagnostics */
    phase7_diagnostics();

    slog("MAIN", "Setup complete. Returning to .bash_profile for startx.");

    /* Cleanup */
    if (serial_fd >= 0) close(serial_fd);
    if (log_fp) fclose(log_fp);

    return 0;
}