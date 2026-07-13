#!/usr/bin/env python3
"""usdd-switcher — take the TV over with the live USDD capture when its alert
screen appears, then hand back to the kiosk dashboard when it clears.

Design (see CLAUDE.md "USDD Alert Switcher"):
  * Runs as the `kiosk` user inside the existing X session (DISPLAY=:0), the
    same way kiosk-refresh.service does. It never stops the kiosk, so the
    Chromium dashboard keeps running underneath the whole time.
  * Exactly one GStreamer pipeline owns /dev/video0 at a time:
      IDLE  -> v4l2src ! (downscaled GRAY8) ! multifilesink   (detection only)
      ALERT -> v4l2src ! tee ! <video sink over Chromium> + (detection feed)
    The ALERT video sink is an X client, so it overlays the dashboard; killing
    the pipeline destroys its window and reveals the dashboard again.
  * Detection = mean-absolute-difference of the latest 64x36 GRAY8 frame vs a
    calibrated idle reference. Thresholds/behaviour live in /boot/firmware/usdd.conf.

Bench testing without a real alert: `sudo touch /run/usdd/force-alert` forces a
takeover; remove the file to hand back.
"""
import os, sys, time, glob, signal, subprocess

CONF = "/boot/firmware/usdd.conf"
FRAMEDIR = "/run/usdd"
FORCE = os.path.join(FRAMEDIR, "force-alert")
GW, GH = 64, 36
GSIZE = GW * GH


def log(msg):
    print(f"[usdd-switcher] {msg}", flush=True)


def load_conf():
    cfg = dict(ENABLED="1", ON_THRESHOLD="25", OFF_THRESHOLD="12",
               ON_DEBOUNCE="3", OFF_DEBOUNCE="6", MAX_ALERT_SEC="210",
               REFERENCE="/etc/usdd/idle.gray", FPS="2", SINK="glimagesink")
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("USDD_") and "=" in line:
                    k, v = line[5:].split("=", 1)
                    v = v.split("#", 1)[0]  # drop inline comments (e.g. "25  # note")
                    cfg[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        log(f"{CONF} not found; using defaults")
    return cfg


def build_pipeline(display, fps, sink):
    src = ["gst-launch-1.0", "-q", "v4l2src", "device=/dev/video0", "io-mode=mmap",
           "!", "video/x-raw,format=BGR,width=1920,height=1080"]
    detect = ["videorate", "!", f"video/x-raw,framerate={fps}/1",
              "!", "videoconvert", "!", "videoscale",
              "!", f"video/x-raw,format=GRAY8,width={GW},height={GH}",
              "!", "multifilesink", f"location={FRAMEDIR}/f%05d.gray",
              "max-files=4", "post-messages=false"]
    if display:
        return src + ["!", "tee", "name=t",
                      "t.", "!", "queue", "max-size-buffers=3", "leaky=downstream",
                      "!", "videoconvert", "!", sink, "force-aspect-ratio=false",
                      "t.", "!", "queue", "!"] + detect
    return src + ["!"] + detect


def start_pipeline(display, fps, sink):
    for f in glob.glob(f"{FRAMEDIR}/f*.gray"):
        try:
            os.remove(f)
        except OSError:
            pass
    return subprocess.Popen(build_pipeline(display, fps, sink),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            preexec_fn=os.setsid)


def stop_pipeline(p):
    if p and p.poll() is None:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            p.wait(timeout=5)
        except Exception:
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            except Exception:
                pass


def read_latest():
    for path in sorted(glob.glob(f"{FRAMEDIR}/f*.gray"), reverse=True):
        try:
            with open(path, "rb") as f:
                b = f.read()
            if len(b) == GSIZE:
                return b
        except OSError:
            continue
    return None


def mad(a, b):
    return sum(abs(a[i] - b[i]) for i in range(GSIZE)) / GSIZE


def main():
    os.makedirs(FRAMEDIR, exist_ok=True)
    cfg = load_conf()
    if cfg["ENABLED"] != "1":
        log("USDD_ENABLED=0; switcher idle (capture pipeline stays up). Exiting.")
        return

    fps, sink = cfg["FPS"], cfg["SINK"]
    on_t, off_t = float(cfg["ON_THRESHOLD"]), float(cfg["OFF_THRESHOLD"])
    on_d, off_d = int(cfg["ON_DEBOUNCE"]), int(cfg["OFF_DEBOUNCE"])
    max_alert = float(cfg["MAX_ALERT_SEC"])

    ref = None
    try:
        with open(cfg["REFERENCE"], "rb") as f:
            ref = f.read()
        if len(ref) != GSIZE:
            log(f"reference wrong size ({len(ref)} != {GSIZE}); ignoring")
            ref = None
        else:
            log(f"loaded idle reference {cfg['REFERENCE']}")
    except OSError:
        log(f"no idle reference at {cfg['REFERENCE']} — run usdd-calibrate.sh. "
            "Content detection disabled; only force-alert / timeout will switch.")

    state = "IDLE"
    pipe = start_pipeline(False, fps, sink)
    log(f"started in IDLE (dashboard); sink={sink} on={on_t} off={off_t}")
    over = under = 0
    alert_since = 0.0

    try:
        while True:
            time.sleep(0.5)
            if pipe.poll() is not None:
                log(f"pipeline exited (code {pipe.returncode}); restarting in {state}")
                time.sleep(1.0)
                pipe = start_pipeline(state == "ALERT", fps, sink)
                continue

            forced = os.path.exists(FORCE)
            frame = read_latest()
            diff = mad(frame, ref) if (frame is not None and ref is not None) else None

            if state == "IDLE":
                hot = forced or (diff is not None and diff >= on_t)
                over = over + 1 if hot else 0
                if over >= (1 if forced else on_d):
                    log(f"ALERT onset (mad={diff}, forced={forced}) -> taking over")
                    stop_pipeline(pipe)
                    pipe = start_pipeline(True, fps, sink)
                    state, alert_since, under = "ALERT", time.time(), 0
            else:  # ALERT
                if forced:
                    cool = False           # forced alert holds until the file is removed
                elif diff is not None:
                    cool = diff <= off_t
                else:
                    cool = False           # no reference: rely on the safety timeout
                under = under + 1 if cool else 0
                timed_out = (time.time() - alert_since) >= max_alert
                cleared_force = (not forced) and diff is None  # bench force removed
                if (under >= off_d) or timed_out or cleared_force:
                    log(f"hand back to dashboard (mad={diff}, timeout={timed_out})")
                    stop_pipeline(pipe)
                    pipe = start_pipeline(False, fps, sink)
                    state, over = "IDLE", 0
    except KeyboardInterrupt:
        pass
    finally:
        stop_pipeline(pipe)


if __name__ == "__main__":
    main()
