#!/usr/bin/env bash
# usdd-calibrate.sh — capture the idle reference and read the live difference,
# using the 64x36 GRAY8 frames the running switcher already writes to /run/usdd
# (so there is no /dev/video0 conflict, and the reference matches exactly what the
# switcher compares against).
#
#   sudo usdd-calibrate.sh idle      # USDD on its normal IDLE screen -> saves reference
#   sudo usdd-calibrate.sh measure   # prints difference vs reference once/sec
#                                    # -> fire a test alert and watch the number jump
#
# Requires usdd-switcher to be running (it produces the frames). Then set
# USDD_ON_THRESHOLD just below the alert reading and USDD_OFF_THRESHOLD just above
# the idle reading in /boot/firmware/usdd.conf, and: sudo systemctl restart usdd-switcher
set -uo pipefail
REF=/etc/usdd/idle.gray
FRAMEDIR=/run/usdd
SIZE=2304   # 64 x 36 GRAY8

latest() {  # newest complete frame from the switcher's detection feed
    local f
    for f in $(ls -t "$FRAMEDIR"/f*.gray 2>/dev/null); do
        [ "$(stat -c%s "$f" 2>/dev/null)" = "$SIZE" ] && { echo "$f"; return; }
    done
}

case "${1:-}" in
  idle)
    src=$(latest)
    [ -n "$src" ] || { echo "no frames in $FRAMEDIR — is usdd-switcher running? (systemctl status usdd-switcher)"; exit 1; }
    mkdir -p /etc/usdd; cp "$src" "$REF"
    echo "Saved idle reference -> $REF ($(stat -c%s "$REF") bytes; expect $SIZE)."
    ;;
  measure)
    [ -f "$REF" ] || { echo "No reference yet — run: sudo $0 idle"; exit 1; }
    echo "Difference vs idle reference (Ctrl-C to stop). Fire a test alert and watch it jump:"
    while true; do
      cur=$(latest)
      [ -n "$cur" ] && python3 - "$REF" "$cur" <<'PY'
import sys
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
n=min(len(a),len(b)) or 1
print("  MAD = %5.1f" % (sum(abs(a[i]-b[i]) for i in range(n))/n))
PY
      sleep 1
    done
    ;;
  *)
    echo "Usage: sudo $0 {idle|measure}"; exit 1;;
esac
