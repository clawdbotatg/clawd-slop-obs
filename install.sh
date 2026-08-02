#!/bin/bash
# install.sh — set up the slop.computer show rig on this machine.
#
#   ./install.sh [path/to/service.json]
#
# Installs the committed OBS config (obs-config/) into
# ~/Library/Application Support/obs-studio, then drops in the ONE secret —
# the RTMP stream key (service.json) — from the USB stick. If no path is
# given, it looks for */slop-credentials/service.json on any mounted volume.
#
# Idempotent: safe to re-run. Quits OBS first (it rewrites config on exit,
# which would clobber what we copy in).

set -euo pipefail
cd "$(dirname "$0")"

OBS_DIR="$HOME/Library/Application Support/obs-studio"
PROFILE_DIR="$OBS_DIR/basic/profiles/Untitled"

# ---- 1. Find the credentials (before touching anything) ----
CRED="${1:-}"
if [ -z "$CRED" ]; then
  for v in /Volumes/*/slop-credentials/service.json; do
    [ -f "$v" ] && CRED="$v" && break
  done
fi
if [ -z "${CRED:-}" ] || [ ! -f "$CRED" ]; then
  if [ -f "$PROFILE_DIR/service.json" ]; then
    echo "NOTE: no USB credentials found, but a service.json is already installed — keeping it."
    CRED=""
  else
    echo "ERROR: can't find service.json (the stream key)." >&2
    echo "Insert the 'NO NAME' USB stick (slop-credentials/service.json) or pass a path:" >&2
    echo "  ./install.sh /path/to/service.json" >&2
    exit 1
  fi
fi

# ---- 2. Quit OBS so it can't overwrite the config on exit ----
if pgrep -x OBS >/dev/null 2>&1; then
  echo "Quitting OBS..."
  osascript -e 'tell application "OBS" to quit' >/dev/null 2>&1 || pkill -x OBS
  for i in $(seq 1 15); do pgrep -x OBS >/dev/null 2>&1 || break; sleep 1; done
fi

# ---- 3. Install the committed config ----
echo "Installing OBS config -> $OBS_DIR"
mkdir -p "$OBS_DIR/basic/scenes" "$PROFILE_DIR"
cp obs-config/basic/scenes/*.json "$OBS_DIR/basic/scenes/"
cp obs-config/basic/profiles/Untitled/basic.ini \
   obs-config/basic/profiles/Untitled/streamEncoder.json "$PROFILE_DIR/"
# global/user ini: only seed if missing, so we don't clobber this machine's
# window layout / permission state once it has run OBS.
for f in global.ini user.ini; do
  if [ ! -f "$OBS_DIR/$f" ]; then cp "obs-config/$f" "$OBS_DIR/$f"; echo "  seeded $f"; fi
done

# ---- 4. Install the stream key ----
if [ -n "$CRED" ]; then
  cp "$CRED" "$PROFILE_DIR/service.json"
  echo "Installed stream key from: $CRED"
fi

# ---- 5. Sanity checks ----
[ -d "/Applications/Google Chrome.app" ] || echo "WARNING: Google Chrome not found in /Applications — install it."
[ -d "/Applications/OBS.app" ] || echo "WARNING: OBS.app not found in /Applications — install it."
python3 - "$PROFILE_DIR/service.json" <<'PY'
import json, sys, os
p = sys.argv[1]
if not os.path.exists(p): print("WARNING: no service.json installed — streaming will not work."); raise SystemExit
d = json.load(open(p)); s = d.get("settings", {})
print(f"Stream target: {s.get('server')}  (key present: {bool(s.get('key'))})")
PY

cat <<'EOF'

Done. Before the first show on this machine, grant (System Settings ->
Privacy & Security):
  - Screen & System Audio Recording  -> OBS        (capture is black without it)
  - Accessibility                    -> the terminal/daemon that runs run-show.sh
                                        (window positioning via System Events)
Then test:
  ./run-show.sh 'https://live.slop.computer/<room>?invite=<tok>&godMode=<tok>'
and watch /tmp/slopcomputer.log.

If the USB stick was used: eject it and keep it somewhere safe (it holds the
plaintext stream key).
EOF
