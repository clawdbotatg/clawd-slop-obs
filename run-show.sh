#!/bin/bash
# run-show.sh  —  parameterized slop.computer show launcher
#
# Derived faithfully from ~/Desktop/slopcomputer.app/Contents/MacOS/launch.
# The ONLY behavioral change: the MAIN Chrome URL is an argument, not hardcoded
# to /another. Each show is a fresh custom URL (room + invite + godMode), so:
#
#   ./run-show.sh 'https://live.slop.computer/<room>?invite=<tok>&godMode=<tok>'
#
# or via env:  SLOP_URL='https://…' ./run-show.sh
#
# Everything else mirrors the proven launcher: quit Chrome+OBS, open Chrome MAIN
# at the URL, position it, grab the FRESH CGWindowID, patch the OBS "Untitled"
# scene collection's window-capture source, force 1080p, launch OBS, and
# re-assert the OBS window geometry to beat OBS's startup restore.
#
# It also opens the gesture EYE (the same URL + &fx=0, titled SLOP-EYE) as a
# second window of the same Chrome, at the exact bounds of the MAIN window,
# stacked behind it. The always-running slop-detector latches onto that title;
# the page lays every camera out large for detection (EyeStage). Occlusion
# flags keep the hidden eye painting. No more clicking 👁 per show.
#
# Finally it opens the EQ window (live.slop.computer/eq?slug=<room>) as a third
# window of the same Chrome, on top, at one initial narrow+tall size so the
# sliders are visible (at the room window's size the page shows only its
# stream preview). Every window a show needs comes from this one script.
#
# Bounds are AppleScript order {left, top, right, bottom}.

set -u

# ---- 0. Self-detach into a FRESH SESSION so the show outlives its caller. ----
# Without this, Chrome (launched with `nohup … &`) still shares the caller's
# process group — so when a Claude Code session (or any parent terminal) closes,
# the whole group is reaped and the browser dies with it. `nohup` only ignores
# SIGHUP; it does NOT save you from a process-group/session teardown.
# macOS ships no setsid(1), so use Python's os.setsid() to start a new session
# (new pgid, no controlling terminal). Re-exec ourselves inside it exactly once.
if [ -z "${SLOP_DETACHED:-}" ]; then
  export SLOP_DETACHED=1
  # stdout/stderr -> /dev/null: the script's own log() tees to $LOG, so capturing
  # stdout here too would double every line. Detach stdin from any terminal.
  exec nohup python3 -c 'import os,sys; os.setsid(); os.execvp("/bin/bash", ["/bin/bash"]+sys.argv[1:])' \
       "$0" "$@" >/dev/null 2>&1 </dev/null
fi

# ============================ CONFIG ============================
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OBS_APP="/Applications/OBS.app"
PROFILE_DIR="${SLOP_PROFILE_DIR:-$HOME/.openclaw/browser/openclaw/user-data}"
SCENES="$HOME/Library/Application Support/obs-studio/basic/scenes"

# The show URL: arg 1 > $SLOP_URL > the old default (/another).
URL_MAIN="${1:-${SLOP_URL:-https://live.slop.computer/another}}"

# Chrome MAIN window  -> x65 y30  1706x1045  (enlarged to fit the OBS share)
MAIN_L=65;   MAIN_T=30;  MAIN_R=1771; MAIN_B=1075

# OBS instance -> scene collection -> which Chrome window it captures
COLL_MAIN="Untitled"        # default OBS captures the MAIN window

# Stream resolution for the MAIN profile (canvas + output). 1080p 16:9 landscape.
MAIN_BASE_W=1920; MAIN_BASE_H=1080   # canvas (base) resolution + aspect
MAIN_OUT_W=1920;  MAIN_OUT_H=1080    # scaled output (streamed) resolution

# OBS window placement (best-effort; OBS also remembers its own geometry per collection)
OBS_MAIN_X=659;  OBS_MAIN_Y=184; OBS_MAIN_W=1259; OBS_MAIN_H=889
# ===============================================================

LOG="/tmp/slopcomputer.log"
log(){ echo "[slopcomputer] $*" | tee -a "$LOG"; }
: > "$LOG"
log "=== launch $(date) ==="
log "URL_MAIN=$URL_MAIN"

# ---- 1. Quit Chrome + ALL OBS. Quit Chrome *cleanly* so it doesn't relaunch into
#         session-restore — that restored/blank window is what OBS was wrongly
#         capturing. SIGKILL only as a last resort, then stamp the profile clean. ----
log "Quitting Chrome + OBS..."
osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1
pkill -x OBS 2>/dev/null
# give Chrome up to 15s to exit on its own (a clean exit => no restore window)
for i in $(seq 1 15); do pgrep -f "Google Chrome" >/dev/null 2>&1 || break; sleep 1; done
pgrep -f "Google Chrome" >/dev/null 2>&1 && { log "  Chrome didn't quit cleanly; forcing."; pkill -f "Google Chrome" 2>/dev/null; sleep 2; }
for i in $(seq 1 15); do pgrep -x OBS >/dev/null 2>&1 || break; sleep 1; done

# Stamp the profile as a CLEAN exit so Chrome won't restore the prior session or
# pop the "restore pages?" window on relaunch (the stray window OBS grabbed).
PREFS="$PROFILE_DIR/Default/Preferences"
python3 - "$PREFS" <<'PY' 2>&1 | tee -a "$LOG"
import json, sys, os
p = sys.argv[1]
if not os.path.exists(p):
    print("  prefs: not found -> SKIP"); raise SystemExit
d = json.load(open(p))
d.setdefault("profile", {}).update({"exit_type": "Normal", "exited_cleanly": True})
d.setdefault("session", {})["restore_on_startup"] = 5  # 5 = New Tab page, never restore
json.dump(d, open(p, "w"))
print("  prefs: stamped clean exit + restore_on_startup=5 (no stray restore window)")
PY
sleep 1

# ---- 2. Launch Chrome MAIN (normal window, with remote-debugging like the live rig) ----
log "Launching MAIN window..."
# The three --disable-* flags keep an occluded window painting at full rate:
# the EYE sits entirely behind MAIN, and Chrome otherwise stops rendering it
# (stale capture, no hands).
nohup arch -arm64 "$CHROME" \
  --user-data-dir="$PROFILE_DIR" --profile-directory=Default \
  --remote-debugging-port=18800 --remote-allow-origins='*' \
  --no-first-run --no-default-browser-check \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding \
  --disable-background-timer-throttling \
  --new-window "$URL_MAIN" >/dev/null 2>&1 &
sleep 3

# ---- 3. Wait until the slop page actually LOADS (poll CDP), THEN position that
#         exact window. Positioning before the URL commits was why the resize
#         sometimes missed and the blank window ended up wider. ----
log "Waiting for the slop page to load (CDP :18800)..."
for i in $(seq 1 20); do
  curl -s http://localhost:18800/json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if any('live.slop.computer' in (t.get('url') or '') and 'fx=0' not in (t.get('url') or '') and t.get('type')=='page' for t in d) else 1)" 2>/dev/null \
    && { log "  slop page is up."; break; }
  sleep 1
done
log "Positioning window..."
osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Google Chrome"
  repeat with w in windows
    set u to ""
    try
      set u to URL of active tab of w
    end try
    -- host match (survives 307 path redirects) but exclude the EQ overlay window,
    -- which also lives on live.slop.computer and would otherwise get sized to the
    -- capture dimensions and become ambiguous with the main room window.
    if (u contains "live.slop.computer") and (u does not contain "/eq") and (u does not contain "fx=0") then
      set bounds of w to {$MAIN_L, $MAIN_T, $MAIN_R, $MAIN_B}
    end if
  end repeat
end tell
APPLESCRIPT
sleep 1

# ---- 4. Read the FRESH MAIN CGWindowID by matching the bounds we just set ----
log "Reading fresh CGWindowID..."
# Identify the capture window by the EXACT SIZE we just set it to (1706x1045).
# Only the window we resized has those dimensions, so a stray blank/restore
# window can't win even if one exists. Fallbacks: position match, then widest.
TGTW=$((MAIN_R - MAIN_L)); TGTH=$((MAIN_B - MAIN_T))
MAIN_ID=$(swift - <<SWIFT 2>/dev/null
import Cocoa
let ws = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String:Any]]
var bySize = 0, byPos = 0, wideID = 0, wideW = 0
for w in ws {
  let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
  let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
  let name  = (w[kCGWindowName as String] as? String) ?? ""
  if layer != 0 || !owner.contains("Chrome") { continue }
  if name.contains("SLOP-EYE") { continue }   // the eye is the same size on purpose
  guard let b = w[kCGWindowBounds as String] as? [String:Any] else { continue }
  let x  = b["X"] as? Int ?? -99999
  let y  = b["Y"] as? Int ?? -99999
  let ww = b["Width"] as? Int ?? 0
  let hh = b["Height"] as? Int ?? 0
  let wid = (w[kCGWindowNumber as String] as? Int) ?? 0
  if abs(ww - $TGTW) <= 20 && abs(hh - $TGTH) <= 40 { bySize = wid }
  if abs(x - $MAIN_L) <= 20 && abs(y - $MAIN_T) <= 40 { byPos = wid }
  if ww > 1000 && ww > wideW { wideID = wid; wideW = ww }
}
print(bySize != 0 ? bySize : (byPos != 0 ? byPos : wideID))
SWIFT
)
log "MAIN_ID=$MAIN_ID (matched by size ${TGTW}x${TGTH})"
[ "${MAIN_ID:-0}" = "0" ]  && log "WARNING: could not find MAIN window id"

# ---- 4b. Open the EYE: same URL + fx=0, same Chrome, same bounds, behind MAIN.
#          Opened only AFTER MAIN_ID is read, so two same-size windows can't
#          confuse the matcher (it also skips SLOP-EYE titles). ----
case "$URL_MAIN" in *\?*) URL_EYE="$URL_MAIN&fx=0";; *) URL_EYE="$URL_MAIN?fx=0";; esac
log "Opening EYE window (fx=0)..."
"$CHROME" --user-data-dir="$PROFILE_DIR" --profile-directory=Default \
  --new-window "$URL_EYE" >/dev/null 2>&1 &
for i in $(seq 1 20); do
  curl -s http://localhost:18800/json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if any('fx=0' in (t.get('url') or '') and t.get('type')=='page' for t in d) else 1)" 2>/dev/null \
    && { log "  eye page is up."; break; }
  sleep 1
done
sleep 1
osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Google Chrome"
  repeat with w in windows
    set u to ""
    try
      set u to URL of active tab of w
    end try
    if (u contains "fx=0") then set bounds of w to {$MAIN_L, $MAIN_T, $MAIN_R, $MAIN_B}
  end repeat
  -- MAIN back on top; the eye keeps painting behind it (occlusion flags).
  repeat with w in windows
    set u to ""
    try
      set u to URL of active tab of w
    end try
    if (u contains "live.slop.computer") and (u does not contain "/eq") and (u does not contain "fx=0") then set index of w to 1
  end repeat
end tell
APPLESCRIPT
# The page retitles itself SLOP-EYE after mount; wait for it so the log proves
# the detector has something to latch onto.
EYE_ID=0
for i in $(seq 1 15); do
  EYE_ID=$(swift - <<'SWIFT' 2>/dev/null
import Cocoa
let ws = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String:Any]]
var found = 0
for w in ws {
  let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
  let name  = (w[kCGWindowName as String] as? String) ?? ""
  if owner.contains("Chrome") && name.contains("SLOP-EYE") { found = (w[kCGWindowNumber as String] as? Int) ?? 0 }
}
print(found)
SWIFT
)
  [ "${EYE_ID:-0}" != "0" ] && break
  sleep 1
done
log "EYE_ID=$EYE_ID (title SLOP-EYE; detector log: /tmp/slop-eye-detector.log)"
[ "${EYE_ID:-0}" = "0" ] && log "WARNING: no SLOP-EYE window appeared — gestures will not work"

# ---- 5. Patch the OBS scene collection's window-capture source ----
patch_collection(){ # $1=collection name  $2=window id
  python3 - "$SCENES" "$1" "$2" <<'PY'
import json, sys, glob, os
scenes, coll, wid = sys.argv[1], sys.argv[2], int(sys.argv[3])
target = None
for p in glob.glob(os.path.join(scenes, "*.json")):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if d.get("name") == coll:
        target = p; break
if target is None:
    # collection not saved yet -> bootstrap from the working Untitled template
    tmpl = os.path.join(scenes, "Untitled.json")
    if not os.path.exists(tmpl):
        print(f"  {coll}: no file and no template -> SKIP"); sys.exit(0)
    d = json.load(open(tmpl))
    d["name"] = coll
    target = os.path.join(scenes, coll + ".json")
    print(f"  {coll}: bootstrapped from Untitled template")
patched = 0
for s in d.get("sources", []):
    st = s.get("settings") or {}
    if "window" in st:
        st["window"] = wid; patched += 1
json.dump(d, open(target, "w"), indent=4)
print(f"  {coll}: set window={wid} on {patched} source(s) -> {os.path.basename(target)}")
PY
}
log "Patching OBS scene collection..."
patch_collection "$COLL_MAIN"  "${MAIN_ID:-0}"  | tee -a "$LOG"

# ---- 5b. Force the MAIN profile's video resolution (OBS rewrites basic.ini on exit, so set it
#          while OBS is down, just before launch). Updates only the 4 [Video] keys; preserves
#          all encoder/bitrate/stream-key settings. ----
ensure_obs_video(){ # $1=profile name  $2=baseW $3=baseH $4=outW $5=outH
  local prof_dir="$SCENES/../profiles/$1"
  local prof="$prof_dir/basic.ini"
  if [ ! -f "$prof" ]; then
    local src="$SCENES/../profiles/$COLL_MAIN"
    if [ -f "$src/basic.ini" ]; then
      mkdir -p "$prof_dir"
      cp -f "$src/"*.json "$prof_dir/" 2>/dev/null
      cp -f "$src/basic.ini" "$prof"
      /usr/bin/sed -i '' "s/^Name=.*/Name=$1/" "$prof" 2>/dev/null
      log "  video: bootstrapped profile '$1' from '$COLL_MAIN'"
    fi
  fi
  python3 - "$prof" "$2" "$3" "$4" "$5" <<'PY'
import sys, os
path, bw, bh, ow, oh = sys.argv[1], *sys.argv[2:6]
updates = {"BaseCX": bw, "BaseCY": bh, "OutputCX": ow, "OutputCY": oh}
if not os.path.exists(path):
    print(f"  video: profile basic.ini not found ({path}) -> SKIP (OBS will use defaults)"); sys.exit(0)
lines = open(path).read().splitlines()
out, in_vid, seen = [], False, set()
def flush_missing():
    for k, v in updates.items():
        if k not in seen: out.append(f"{k}={v}")
for line in lines:
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        if in_vid: flush_missing()
        in_vid = (s == "[Video]"); seen = set() if not in_vid else seen
        out.append(line); continue
    if in_vid and "=" in s:
        k = s.split("=", 1)[0].strip()
        if k in updates:
            out.append(f"{k}={updates[k]}"); seen.add(k); continue
    out.append(line)
if in_vid: flush_missing()
if "[Video]" not in [l.strip() for l in lines]:
    out.append("[Video]"); [out.append(f"{k}={v}") for k, v in updates.items()]
open(path, "w").write("\n".join(out) + "\n")
print(f"  video: {os.path.basename(os.path.dirname(path))} -> canvas {bw}x{bh}, output {ow}x{oh}")
PY
}
log "Setting MAIN profile resolution..."
ensure_obs_video "$COLL_MAIN" "$MAIN_BASE_W" "$MAIN_BASE_H" "$MAIN_OUT_W" "$MAIN_OUT_H" | tee -a "$LOG"

# ---- 6. Launch the OBS instance (explicit profile+collection) ----
log "Launching DEFAULT OBS ($COLL_MAIN -> main)..."
open -n -a "$OBS_APP" --args --multi --profile "$COLL_MAIN" --collection "$COLL_MAIN"
sleep 5

# ---- 7. Position the OBS window via System Events, then VERIFY + re-assert ----
obs_x(){ # $1=pid -> prints x of that pid's widest layer-0 window (or -9999)
  swift - <<SWIFT 2>/dev/null
import Cocoa
let ws = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as! [[String:Any]]
var bx = -9999, bw = -1
for w in ws {
  let p = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
  let l = (w[kCGWindowLayer as String] as? Int) ?? -1
  if p != $1 || l != 0 { continue }
  let b = w[kCGWindowBounds as String] as! [String:Any]
  let ww = b["Width"] as? Int ?? 0
  if ww > bw { bw = ww; bx = b["X"] as? Int ?? -9999 }
}
print(bx)
SWIFT
}
assert_obs_once(){ # $1=pid  $2=x $3=y $4=w $5=h  -> sets the LARGEST window; prints "ok"/"nowin"/error
  osascript 2>&1 <<A
tell application "System Events"
  tell (first process whose unix id is $1)
    set theWin to missing value
    set maxA to -1
    repeat with w in windows
      set sz to size of w
      set a to (item 1 of sz) * (item 2 of sz)
      if a > maxA then
        set maxA to a
        set theWin to w
      end if
    end repeat
    if theWin is missing value then return "nowin"
    set position of theWin to {$2, $3}
    set size of theWin to {$4, $5}
  end tell
end tell
return "ok"
A
}
log "Positioning OBS window (sustained re-assert to beat OBS geometry restore)..."
PID_MAIN=$(pgrep -f "profile $COLL_MAIN" 2>/dev/null | head -1)
[ -z "$PID_MAIN" ]  && log "  (no OBS pid for $COLL_MAIN)"
ERR_MAIN=""
for round in $(seq 1 16); do
  [ -n "$PID_MAIN" ]  && ERR_MAIN=$(assert_obs_once "$PID_MAIN"  $OBS_MAIN_X  $OBS_MAIN_Y  $OBS_MAIN_W  $OBS_MAIN_H)
  sleep 1
done
MX=$(obs_x "${PID_MAIN:-0}")
log "  OBS $COLL_MAIN ($PID_MAIN) x=$MX (target $OBS_MAIN_X)"
case "$ERR_MAIN" in
  *"not allowed"*|*-1719*) log "  NOTE: Accessibility denied for this app -> System Settings > Privacy & Security > Accessibility, enable your terminal.";;
esac

# ---- 8. Prove the gesture chain from the relay's side: POST an empty hands
#         frame with the god key (= the URL's godMode token) and log the eye
#         geometry the relay is mapping against. ----
GOD_KEY=$(printf '%s' "$URL_MAIN" | sed -nE 's/.*[?&]godMode=([^&]+).*/\1/p')
if [ -n "$GOD_KEY" ]; then
  log "Checking relay eye geometry..."
  GEOM=""
  for i in $(seq 1 15); do
    GEOM=$(curl -s -m 5 -X POST -H "X-Gesture-Key: $GOD_KEY" -H 'Content-Type: application/json' \
      -d '{"hands":[],"w":0,"h":0}' https://live.slop.computer/v1/hands 2>/dev/null)
    case "$GEOM" in *'"geom"'*) break;; esac
    sleep 2
  done
  python3 - "$GEOM" <<'PYGEOM' 2>&1 | tee -a "$LOG"
import json, sys
try:
    d = json.loads(sys.argv[1] or "{}")
except Exception:
    d = {}
g = d.get("geom")
if not g:
    print(f"  relay: {d.get('note') or d.get('error') or 'no response'} -> gestures NOT wired (eye page not reporting?)")
else:
    cams = g.get("cams") or []
    print(f"  relay: eye viewport {g.get('vw')}x{g.get('vh')}, {len(cams)} camera(s) visible to the detector, geometry age {g.get('ageMs')}ms")
    for c in cams:
        r = c.get("rect") or {}
        print(f"    cam {c.get('peerId','?')[:12]} rect {int(r.get('x',0))},{int(r.get('y',0))} {int(r.get('w',0))}x{int(r.get('h',0))} video {c.get('videoW')}x{c.get('videoH')}")
PYGEOM
fi

# ---- 9. Open the EQ window (live.slop.computer/eq?slug=<room>) in the same
#         Chrome. Opened LAST, after MAIN_ID is read and OBS is placed, so it
#         can never confuse the window matcher (which also skips /eq URLs).
#         Chrome opens it at the LAST window's size (1706x1045) and at that
#         size the page's stream preview swallows the whole viewport: all you
#         see is a black "STREAM" monitor, the EQ sliders are below the fold
#         (2026-09-14, looked like "a second video monitor" on a live show).
#         So it gets ONE initial size, narrow + tall, where the whole EQ is
#         visible (verified 640x1000). After that it's the operator's window:
#         nothing here ever touches it again. ----
EQ_L=0; EQ_T=30; EQ_R=640; EQ_B=1030
ROOM_SLUG=$(printf '%s' "$URL_MAIN" | sed -nE 's#^https?://[^/]+/([^/?]+).*#\1#p')
if [ -n "$ROOM_SLUG" ]; then
  URL_EQ="https://live.slop.computer/eq?slug=$ROOM_SLUG"
  log "Opening EQ window ($URL_EQ)..."
  "$CHROME" --user-data-dir="$PROFILE_DIR" --profile-directory=Default \
    --new-window "$URL_EQ" >/dev/null 2>&1 &
  EQ_UP=0
  for i in $(seq 1 20); do
    curl -s http://localhost:18800/json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if any('/eq' in (t.get('url') or '') and t.get('type')=='page' for t in d) else 1)" 2>/dev/null \
      && { EQ_UP=1; log "  eq page is up."; break; }
    sleep 1
  done
  if [ "$EQ_UP" = "1" ]; then
    sleep 1
    osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Google Chrome"
  repeat with w in windows
    set u to ""
    try
      set u to URL of active tab of w
    end try
    if (u contains "/eq") then set bounds of w to {$EQ_L, $EQ_T, $EQ_R, $EQ_B}
  end repeat
end tell
APPLESCRIPT
    log "  eq window sized $((EQ_R-EQ_L))x$((EQ_B-EQ_T)) (initial size only; move it where you like)"
  else
    log "WARNING: EQ window did not appear -> open $URL_EQ by hand"
  fi
else
  log "WARNING: could not derive room slug from URL_MAIN -> open the EQ window by hand"
fi

log "Done."
log "Full log: $LOG"
