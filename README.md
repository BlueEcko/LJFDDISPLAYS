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
sudo apt-get install -y git
git clone https://github.com/BlueEcko/LJFDDISPLAYS.git
cd LJFDDISPLAYS
sudo bash install.sh
```

Note: Git is not included in Pi OS Lite by default and must be installed first.
The repo is private — Git will prompt for GitHub credentials (use a [Personal Access Token](https://github.com/settings/tokens) as the password).

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
     → detect screen resolution via xrandr
     → clean Chromium crash flags
     → exec chromium --kiosk --window-size=WxH <URL>

If Chromium crashes → X session ends → systemd restarts (5s delay)
```

## USDD Alert Switcher (optional)

For sites where a **USDD station-alerting device** must take over the TV during a
call, fit a **52pi TC358743 HDMI-to-CSI2 board** on the Pi's CAM/DISP1 connector
and feed the USDD's HDMI into it. The Pi then acts as a software HDMI switcher:
it shows the dashboard normally, and overlays the live USDD screen full-screen
when an alert appears, handing back when it clears. No TV CEC and no USDD
passthrough required — the TV only ever sees the Pi.

`install.sh` deploys the whole switcher automatically (scripts, services, the
1080p30 EDID, `dtoverlay=tc358743,cam1`, and enables both services). On a Pi with
**no board fitted** it stays dormant and safe — `usdd-capture-setup` just finds no
capture device and the switcher never starts; the dashboard runs normally.

### Bringing up a device that has the board

1. **With the Pi powered off**, fit the 52pi board on **CAM/DISP1** (seat the CSI
   ribbon firmly at both ends), and run the USDD's HDMI into the board. Power on.
2. Install and reboot so the `tc358743` overlay loads:
   ```bash
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/BlueEcko/LJFDDISPLAYS.git && cd LJFDDISPLAYS
   sudo bash install.sh && sudo reboot
   ```
   (Existing kiosk device: `git fetch origin && git reset --hard origin/main && sudo bash install.sh && sudo reboot`.)
3. **Power-cycle the USDD device**, wait ~45 s. Required — the USDD only re-reads
   the 1080p30 EDID on a full power-up, not when the Pi toggles hot-plug; until it
   does it outputs 1080p60, which the switcher **deliberately refuses** (60 fps over
   the CSI-2 lane wedges the Pi).
4. Run the one-shot bring-up — it checks the board is detected, forces 1080p,
   brings the pipeline up at 30 fps, and captures the idle reference (with the USDD
   on its **normal idle screen**), stopping with a clear message if anything's off:
   ```bash
   sudo usdd-setup.sh
   ```
5. Bench test: `sudo touch /run/usdd/force-alert` (takes over), `sudo rm /run/usdd/force-alert`
   (hands back). Then reboot and confirm both services come up on their own.

The shipped thresholds (`USDD_ON_THRESHOLD=0.9` / `OFF 0.6` in `/boot/firmware/usdd.conf`)
suit the current USDD (idle ~0.4, alerts ~1.3–4.1). If a site differs, run
`sudo usdd-calibrate.sh measure`, fire a test alert, adjust, then
`sudo systemctl restart usdd-switcher`.

Logs: `journalctl -u usdd-switcher -f`, `journalctl -u usdd-capture-setup`.

**Key requirement:** the USDD must run at **1080p30** — the shipped EDID enforces
it and capture-setup refuses anything else. 1080p60 (148.5 MHz) locks under the
chip's cap but its bandwidth crashes the single CSI-2 lane.

### If a device ever hangs on boot

If a Pi with the board ever wedges at boot on `usdd-capture-setup` (e.g. a driver
hang), you don't need console access: power off, put the SD card in any computer,
open **`cmdline.txt`** on the FAT32 `bootfs` partition, and append (same line, no
newline) `systemd.mask=usdd-capture-setup.service systemd.mask=usdd-switcher.service`.
Boot, fix, then remove the masks. (`capture-setup` also has a 90 s start timeout so
it can't block boot indefinitely.)

## Daily Operations

| Task | Command |
|------|---------|
| Change URL | Edit `/boot/firmware/kiosk.conf`, then `sudo systemctl restart kiosk` |
| View logs | `journalctl -u kiosk.service -f` |
| Kiosk script log | `cat /var/log/kiosk.log` |
| Restart display | `sudo systemctl restart kiosk` |
| Stop display | `sudo systemctl stop kiosk` |
| Check status | `sudo systemctl status kiosk` |
| Update kiosk scripts | `cd ~/LJFDDISPLAYS && git pull && sudo cp kiosk.sh /home/kiosk/.xinitrc && sudo systemctl restart kiosk` |
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
| `chromium` or `chromium-browser` | Web browser (name varies by OS version, auto-detected) |

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
Check that DPMS is disabled (must run as kiosk user):
```bash
sudo -u kiosk DISPLAY=:0 XAUTHORITY=/home/kiosk/.Xauthority xset q | grep -i dpms
```
Check kernel param:
```bash
cat /proc/cmdline | grep consoleblank
```

**Display not filling the screen:**
The kiosk script auto-detects resolution via `xrandr` and passes `--window-size` to Chromium.
To check the detected resolution:
```bash
sudo -u kiosk DISPLAY=:0 XAUTHORITY=/home/kiosk/.Xauthority xrandr
```
To force a specific resolution, add to `/boot/firmware/config.txt`:
```ini
hdmi_group=2
hdmi_mode=82   # 1920x1080 60Hz
```
