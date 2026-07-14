#!/usr/bin/env bash
# usdd-capture-setup.sh — bring up the tc358743 HDMI-to-CSI2 capture pipeline.
#
# Runs at boot (usdd-capture-setup.service), before usdd-switcher. It:
#   1. Locates the tc358743 media device + subdev (node numbers vary per boot).
#   2. Presents a 1080p30-only EDID so the USDD (an EDID-driven Broadcom/Pi source)
#      outputs 1920x1080p30 @ 74.25 MHz — under the tc358743 driver's 165 MHz cap.
#      A live USDD that has been running latches to its default 173 MHz CVT mode
#      and only re-reads the EDID on a real hot-plug, so we hold HPD low ~20 s.
#   3. Wires csi2 -> /dev/video0 as BGR3 1920x1080.
#
# Exit codes: 0 = pipeline ready; 2 = no lockable signal (USDD absent/over-cap).
set -uo pipefail

EDID_FILE="${USDD_EDID:-/etc/usdd/1080P30EDID.txt}"
log() { echo "[usdd-setup] $*"; }

# --- locate media device + entities (numbers renumber across boots) ---
MEDIA=""
for m in /dev/media*; do
    if media-ctl -d "$m" -p 2>/dev/null | grep -q tc358743; then MEDIA="$m"; break; fi
done
[ -z "$MEDIA" ] && { log "ERROR: tc358743 not found on any /dev/media*"; exit 1; }

ENTITY=$(media-ctl -d "$MEDIA" -p 2>/dev/null | grep -oE 'tc358743 [0-9]+-[0-9a-f]+' | head -n1)
SUBDEV=$(media-ctl -d "$MEDIA" -e "$ENTITY")
VIDNODE=$(media-ctl -d "$MEDIA" -e "rp1-cfe-csi2_ch0")
[ -z "$SUBDEV" ] && { log "ERROR: could not resolve tc358743 subdev"; exit 1; }
[ -z "$VIDNODE" ] && VIDNODE=/dev/video0
log "media=$MEDIA entity='$ENTITY' subdev=$SUBDEV video=$VIDNODE"

# "Locked" means a valid signal AT 1080p30 (pixel clock <= ~80 MHz). 1080p60
# (148.5 MHz) also locks under the driver's 165 MHz cap, but its bandwidth
# crashes streaming on the single CSI-2 lane — so we insist on 30 and force the
# HPD re-read otherwise (the USDD only honours our 1080p30-only EDID on a full
# hot-plug; a short --set-edid leaves it at 60).
locked() {
    local pc
    pc=$(v4l2-ctl -d "$SUBDEV" --query-dv-timings 2>/dev/null | awk '/Pixelclock/{print $2}')
    [ -n "$pc" ] && [ "$pc" -le 80000000 ]
}

# --- present EDID; force a full HPD cycle if the source is latched over-cap ---
v4l2-ctl -d "$SUBDEV" --set-edid=file="$EDID_FILE" >/dev/null 2>&1
sleep 2
if ! locked; then
    log "signal absent/over-cap; forcing ~20 s HPD low so the USDD re-reads EDID"
    v4l2-ctl -d "$SUBDEV" --clear-edid >/dev/null 2>&1
    sleep 20
    v4l2-ctl -d "$SUBDEV" --set-edid=file="$EDID_FILE" >/dev/null 2>&1
    for _ in $(seq 1 25); do locked && break; sleep 1; done
fi
if ! locked; then
    log "ERROR: no lockable signal (USDD absent, or won't drop under 165 MHz)."
    v4l2-ctl -d "$SUBDEV" --log-status >/dev/null 2>&1
    dmesg | grep -i 'Detected format' | tail -1 | sed 's/^/[usdd-setup] /'
    exit 2
fi
log "locked: $(v4l2-ctl -d "$SUBDEV" --query-dv-timings | grep -Ei 'width|height|frames' | tr '\n' ' ')"

# --- apply timings and wire the CSI-2 pipeline to the capture node ---
v4l2-ctl -d "$SUBDEV" --set-dv-bt-timings query >/dev/null
media-ctl -d "$MEDIA" -V '"csi2":0 [fmt:BGR888_1X24/1920x1080 field:none colorspace:srgb]'
media-ctl -d "$MEDIA" -V '"csi2":4 [fmt:BGR888_1X24/1920x1080 field:none colorspace:srgb]'
media-ctl -d "$MEDIA" -l '"csi2":4 -> "rp1-cfe-csi2_ch0":0 [1]'
v4l2-ctl -d "$VIDNODE" --set-fmt-video=width=1920,height=1080,pixelformat=BGR3 >/dev/null
log "pipeline ready on $VIDNODE (BGR3 1920x1080p30)"
