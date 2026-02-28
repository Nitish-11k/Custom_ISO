#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <string.h>
#include <signal.h>
#include <linux/vt.h>
#include <linux/kd.h>
#include <linux/fb.h>
#include <errno.h>

#define LOG_PATH "/tmp/splash.log"

static volatile int g_stop = 0;
struct fb_var_screeninfo vinfo;
struct fb_fix_screeninfo finfo;
long screensize = 0;
unsigned char *fbp = NULL;

void log_msg(const char *msg) {
    FILE *f = fopen(LOG_PATH, "a");
    if (f) {
        fprintf(f, "[splash] %s\n", msg);
        fclose(f);
    }
}

void log_error(const char *msg, int err) {
    FILE *f = fopen(LOG_PATH, "a");
    if (f) {
        fprintf(f, "[splash] ERROR: %s (errno: %d, %s)\n", msg, err, strerror(err));
        fclose(f);
    }
}

static void signal_handler(int sig) {
    g_stop = 1;
}

static void fill_color(unsigned int r, unsigned int g, unsigned int b) {
    if (!fbp) return;
    for (unsigned int y = 0; y < vinfo.yres; y++) {
        for (unsigned int x = 0; x < vinfo.xres; x++) {
            long location = (x + vinfo.xoffset) * (vinfo.bits_per_pixel / 8) +
                           (y + vinfo.yoffset) * finfo.line_length;
            
            if (vinfo.bits_per_pixel == 32) {
                unsigned char *pixel = &fbp[location];
                pixel[vinfo.red.offset / 8] = r;
                pixel[vinfo.green.offset / 8] = g;
                pixel[vinfo.blue.offset / 8] = b;
                pixel[vinfo.transp.offset / 8] = 0xFF;
            } else if (vinfo.bits_per_pixel == 16) {
                unsigned short *pixel = (unsigned short *)&fbp[location];
                *pixel = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            }
        }
    }
}

int main(int argc, char *argv[]) {
    remove(LOG_PATH);
    log_msg("Starting robust splash (static v2)...");

    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);

    int fb_fd = -1;
    for (int i = 0; i < 500; i++) { // Wait up to 5s, but check every 10ms
        fb_fd = open("/dev/fb0", O_RDWR);
        if (fb_fd >= 0) break;
        usleep(1000); // 1ms poll
    }

    if (fb_fd < 0) {
        log_error("Failed to open /dev/fb0", errno);
        return 1;
    }

    if (ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo) < 0 ||
        ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
        log_error("Error reading FB info", errno);
        close(fb_fd);
        return 1;
    }

    screensize = finfo.smem_len;
    if (screensize == 0) screensize = vinfo.xres * vinfo.yres * (vinfo.bits_per_pixel / 8);

    fbp = (unsigned char *)mmap(0, screensize, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fbp == MAP_FAILED) {
        log_error("mmap failed", errno);
        close(fb_fd);
        return 1;
    }

    char setup_msg[256];
    sprintf(setup_msg, "Detect: %dx%d, %dbpp, LL:%d, R:%d G:%d B:%d", 
            vinfo.xres, vinfo.yres, vinfo.bits_per_pixel, finfo.line_length,
            vinfo.red.offset, vinfo.green.offset, vinfo.blue.offset);
    log_msg(setup_msg);

    int tty_fd = open("/dev/tty0", O_RDWR);
    if (tty_fd >= 0) ioctl(tty_fd, KDSETMODE, KD_GRAPHICS);

    // Initial clear to ultra-dark blue
    fill_color(3, 10, 33);

    #define MAX_FRAMES 100
    unsigned char *frames[MAX_FRAMES];
    int loaded_count = 0;
    long frame_size = vinfo.xres * vinfo.yres * (vinfo.bits_per_pixel / 8);

    for (int i = 0; i < MAX_FRAMES; i++) {
        char path[128];
        // Priority to current directory as requested
        sprintf(path, "./splash_%d.raw", i);
        int fd = open(path, O_RDONLY);
        if (fd < 0) {
            // Fallback to absolute root
            sprintf(path, "/splash_%d.raw", i);
            fd = open(path, O_RDONLY);
        }
        
        if (fd >= 0) {
            frames[i] = malloc(frame_size);
            if (read(fd, frames[i], frame_size) == frame_size) {
                loaded_count++;
            } else {
                free(frames[i]);
                frames[i] = NULL;
                close(fd);
                break;
            }
            close(fd);
        } else {
            break; // Stop sequence at first missing frame
        }
    }

    if (loaded_count == 0) {
        log_error("CRITICAL: 0 frames loaded from . or /", 0);
        // Debug mark: red dot in corner
        if (screensize > 4) { fbp[0] = 0; fbp[1] = 0; fbp[2] = 255; }
    }

    int persistent = (argc > 1);
    
    // SAFETY TIMEOUT: 90 seconds
    // Outer loop runs once per 1.2s (12 frames * 100ms)
    // 90s / 1.2s = 75 loops
    int safety_timeout = 75; 

    while (!g_stop) {
        if (!persistent && access("/tmp/splash.stop", F_OK) == 0) break;
        
        // Timeout Info
        if (safety_timeout-- <= 0) {
            log_msg("SAFETY TIMEOUT EXPIRED. Auto-terminating.");
            break; 
        }

        for (int i = 0; i < loaded_count && !g_stop; i++) {
            if (!frames[i]) continue;
            
            if (finfo.line_length == vinfo.xres * (vinfo.bits_per_pixel / 8)) {
                memcpy(fbp, frames[i], frame_size);
            } else {
                for(unsigned int y=0; y<vinfo.yres; y++) {
                    memcpy(fbp + y*finfo.line_length, frames[i] + y*vinfo.xres*(vinfo.bits_per_pixel/8), vinfo.xres*(vinfo.bits_per_pixel/8));
                }
            }
            usleep(100000);
            if (!persistent && access("/tmp/splash.stop", F_OK) == 0) goto done;
        }
        if (loaded_count == 0) usleep(500000);
    }

done:
    fill_color(3, 10, 33);
    if (tty_fd >= 0) {
        ioctl(tty_fd, KDSETMODE, KD_TEXT);
        close(tty_fd);
    }
    munmap(fbp, screensize);
    close(fb_fd);
    return 0;
}
