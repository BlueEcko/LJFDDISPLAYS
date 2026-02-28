# LJFD Kiosk Display System

Turns a Raspberry Pi 5 running Pi OS Lite into a full-screen web kiosk display.
No desktop environment, no window decorations, no cursor — just a webpage.

## What You Need

- Raspberry Pi 5 (also works with Pi 4)
- MicroSD card (8GB+ recommended)
- HDMI display
- Network connection (Ethernet or Wi-Fi configured via Raspberry Pi Imager)
- Raspberry Pi OS Lite (64-bit, Bookworm or later)

## Quick Start

### 1. Flash Pi OS Lite

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash
**Raspberry Pi OS Lite (64-bit)** to your SD card.

In Imager settings (gear icon), configure:
- **Hostname**: your choice (e.g., `ljfd-display-1`)
- **Enable SSH**: Yes, with password or public key
- **Set username/password**: Create an admin user (e.g., `pi`)
- **Configure Wi-Fi**: If not using Ethernet

### 2. Boot and Connect

Insert the SD card, connect HDMI and power. Once booted, SSH in:

```bash
ssh pi@ljfd-display-1.local
```

### 3. Install the Kiosk

```bash
git clone https://github.com/YOUR_ORG/LJFDDISPLAYS.git
cd LJFDDISPLAYS
sudo bash install.sh
```

### 4. Configure the URL

Edit the config file:

```bash
sudo nano /boot/firmware/kiosk.conf
```

Set your URLs and choose which one is active:

```ini
URL_1="https://your-display-url.com/screen1"
URL_2="https://your-display-url.com/screen2"
ACTIVE_URL="URL_1"
```

### 5. Reboot

```bash
sudo reboot
```

The Pi will boot directly into a full-screen display of your configured webpage.

## Architecture

```
Boot → systemd starts kiosk.service
     → startx (as 'kiosk' user, no cursor)
     → .xinitrc (kiosk.sh)
     → disable DPMS/screen blanking
     → clean Chromium crash flags
     → exec chromium --kiosk <URL>

If Chromium crashes → X session ends → systemd restarts (5s delay)
```

## Daily Operations

| Task | Command |
|------|---------|
| Change URL | Edit `/boot/firmware/kiosk.conf`, then `sudo systemctl restart kiosk` |
| View logs | `journalctl -u kiosk.service -f` |
| Restart display | `sudo systemctl restart kiosk` |
| Stop display | `sudo systemctl stop kiosk` |
| Check status | `sudo systemctl status kiosk` |
| SSH in | `ssh pi@<hostname>.local` |

## Changing the URL Without SSH

1. Power off the Pi
2. Remove the SD card
3. Insert it into any computer
4. Edit `kiosk.conf` on the `bootfs` partition
5. Reinsert the SD card and power on

The boot partition is FAT32, readable by Windows, Mac, and Linux.

## Installed Packages

Only 6 packages are installed (with `--no-install-recommends`):

| Package | Purpose |
|---------|---------|
| `xserver-xorg-core` | Minimal X11 display server |
| `xserver-xorg-video-fbdev` | Framebuffer video driver |
| `xserver-xorg-input-libinput` | Input driver (required for X to start) |
| `xinit` | Provides `startx` command |
| `x11-xserver-utils` | Provides `xset` for DPMS control |
| `chromium-browser` | Web browser |

No desktop environment. No window manager. No cursor utility.

## Troubleshooting

**Black screen, no browser:**
```bash
journalctl -u kiosk.service -n 50
cat /var/log/kiosk.log
```

**"Chromium didn't shut down correctly" bar:**
The kiosk script handles this automatically. If it persists:
```bash
rm -rf /home/kiosk/.config/chromium
sudo systemctl restart kiosk
```

**Screen goes blank after a while:**
Check that DPMS is disabled:
```bash
DISPLAY=:0 xset q | grep -i dpms
```
Check kernel param:
```bash
cat /proc/cmdline | grep consoleblank
```

**Display resolution wrong:**
Chromium uses `--start-fullscreen` which fills whatever resolution X detects.
To force a resolution, add to `/boot/firmware/config.txt`:
```ini
hdmi_group=2
hdmi_mode=82   # 1920x1080 60Hz
```
