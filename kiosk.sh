#!/usr/bin/env bash
# kiosk.sh - Reads /boot/firmware/kiosk.conf and launches Chromium in kiosk mode.
# Installed as /home/kiosk/.xinitrc — called by startx inside an X session.
# Must not exit (or X will terminate). Uses exec to replace shell with Chromium.

set -euo pipefail

CONFIG="/boot/firmware/kiosk.conf"
LOG="/var/log/kiosk.log"

# --- Load configuration ---
if [ ! -f "$CONFIG" ]; then
    echo "$(date): ERROR - Config file not found: $CONFIG" >> "$LOG"
    sleep infinity
fi

source "$CONFIG"

# Resolve the active URL
case "$ACTIVE_URL" in
    URL_1) KIOSK_URL="$URL_1" ;;
    URL_2) KIOSK_URL="$URL_2" ;;
    *)
        echo "$(date): ERROR - Invalid ACTIVE_URL '$ACTIVE_URL' in $CONFIG" >> "$LOG"
        sleep infinity
        ;;
esac

echo "$(date): Starting kiosk with URL: $KIOSK_URL" >> "$LOG"

# --- Disable screen blanking and DPMS ---
xset -dpms
xset s off
xset s noblank

# --- Clean up Chromium crash flags ---
# Prevents "Chromium didn't shut down correctly" restore bar
CHROMIUM_PREFS="$HOME/.config/chromium/Default/Preferences"
CHROMIUM_STATE="$HOME/.config/chromium/Local State"
if [ -f "$CHROMIUM_PREFS" ]; then
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$CHROMIUM_PREFS"
    sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$CHROMIUM_PREFS"
fi
if [ -f "$CHROMIUM_STATE" ]; then
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$CHROMIUM_STATE"
fi

# --- Launch Chromium in kiosk mode ---
# Binary name varies: 'chromium-browser' (Bullseye) vs 'chromium' (Bookworm+)
CHROMIUM_BIN=$(command -v chromium-browser 2>/dev/null || command -v chromium)

# Get screen resolution to force Chromium to fill the display
SCREEN_RES=$(xrandr | grep '\*' | awk '{print $1}')
SCREEN_W=$(echo "$SCREEN_RES" | cut -d'x' -f1)
SCREEN_H=$(echo "$SCREEN_RES" | cut -d'x' -f2)
echo "$(date): Screen resolution: ${SCREEN_W}x${SCREEN_H}" >> "$LOG"

exec "$CHROMIUM_BIN" \
    --kiosk \
    --start-fullscreen \
    --window-position=0,0 \
    --window-size=${SCREEN_W},${SCREEN_H} \
    --noerrdialogs \
    --disable-infobars \
    --disable-translate \
    --disable-features=TranslateUI \
    --no-first-run \
    --fast \
    --fast-start \
    --incognito \
    --disable-pinch \
    --overscroll-history-navigation=0 \
    --disk-cache-dir=/dev/null \
    --check-for-update-interval=31536000 \
    --disable-session-crashed-bubble \
    --disable-component-update \
    "$KIOSK_URL"
