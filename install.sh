#!/usr/bin/env bash
# install.sh - One-time setup for LJFD Kiosk Display on Raspberry Pi OS Lite.
# Run as root (or with sudo) on a fresh Pi OS Lite installation.
#
# What this script does:
#   1. Installs minimal X11 and Chromium packages
#   2. Creates a dedicated 'kiosk' user
#   3. Deploys kiosk.sh, kiosk.service, and kiosk.conf
#   4. Configures display, SSH, and power management
#   5. Enables the kiosk service

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIOSK_USER="kiosk"
KIOSK_HOME="/home/$KIOSK_USER"

echo "=== LJFD Kiosk Display Setup ==="
echo ""

# --- Step 1: System update ---
echo "[1/7] Updating package lists..."
apt-get update -qq

# --- Step 2: Install minimal packages ---
echo "[2/7] Installing minimal X11 and Chromium packages..."

# Chromium package name varies: 'chromium-browser' (Bullseye) vs 'chromium' (Bookworm+)
if apt-cache show chromium-browser &>/dev/null; then
    CHROMIUM_PKG="chromium-browser"
else
    CHROMIUM_PKG="chromium"
fi

apt-get install --no-install-recommends -y \
    xserver-xorg-core \
    xserver-xorg-video-fbdev \
    xserver-xorg-input-libinput \
    xinit \
    x11-xserver-utils \
    "$CHROMIUM_PKG"

# --- Step 3: Create kiosk user ---
echo "[3/7] Creating kiosk user..."
if ! id "$KIOSK_USER" &>/dev/null; then
    useradd -m -s /bin/bash -G video,input,tty "$KIOSK_USER"
    echo "Created user: $KIOSK_USER"
else
    echo "User $KIOSK_USER already exists, skipping."
    usermod -aG video,input,tty "$KIOSK_USER"
fi

# --- Step 4: Deploy files ---
echo "[4/7] Deploying kiosk files..."

install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 755 \
    "$SCRIPT_DIR/kiosk.sh" "$KIOSK_HOME/.xinitrc"

if [ ! -f /boot/firmware/kiosk.conf ]; then
    install -m 644 "$SCRIPT_DIR/kiosk.conf" /boot/firmware/kiosk.conf
    echo "Installed default kiosk.conf to /boot/firmware/"
else
    echo "kiosk.conf already exists on boot partition, not overwriting."
fi

install -m 644 "$SCRIPT_DIR/kiosk.service" /etc/systemd/system/kiosk.service

touch /var/log/kiosk.log
chown "$KIOSK_USER":"$KIOSK_USER" /var/log/kiosk.log

# --- Step 5: Configure X server permissions ---
echo "[5/7] Configuring X server permissions..."
XWRAPPER_CONF="/etc/X11/Xwrapper.config"
if [ -f "$XWRAPPER_CONF" ]; then
    sed -i 's/^allowed_users=.*/allowed_users=anybody/' "$XWRAPPER_CONF"
else
    echo "allowed_users=anybody" > "$XWRAPPER_CONF"
fi

# --- Step 6: System configuration ---
echo "[6/7] Configuring system..."

# Disable getty on tty1 (kiosk.service takes over)
systemctl disable getty@tty1.service 2>/dev/null || true

# Enable SSH
systemctl enable ssh.service 2>/dev/null || true

# Disable Wi-Fi power management if NetworkManager is present
if [ -d /etc/NetworkManager/conf.d ]; then
    cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF
fi

# Disable console blanking via kernel command line
CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ] && ! grep -q "consoleblank=0" "$CMDLINE"; then
    sed -i 's/$/ consoleblank=0/' "$CMDLINE"
    echo "Added consoleblank=0 to kernel command line."
fi

# --- Step 7: Enable kiosk service ---
echo "[7/7] Enabling kiosk service..."
systemctl daemon-reload
systemctl enable kiosk.service

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit /boot/firmware/kiosk.conf with your display URLs"
echo "  2. Reboot: sudo reboot"
echo ""
echo "The display will start automatically on boot."
echo "SSH access remains available for remote management."
